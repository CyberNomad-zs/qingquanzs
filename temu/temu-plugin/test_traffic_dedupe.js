// 纯逻辑单测：限流基线 / productId 冷却 / 切店不应重复告警
// 运行：node test_traffic_dedupe.js

const ALERT_COOLDOWN_MS = 6 * 60 * 60 * 1000;

function pruneAlertedMap(map, now) {
  const out = {};
  const keepFor = ALERT_COOLDOWN_MS * 4;
  for (const id of Object.keys(map || {})) {
    const ts = map[id];
    if (typeof ts === 'number' && now - ts < keepFor) out[id] = ts;
  }
  return out;
}
function pickFreshItems(items, alertedMap, now) {
  const fresh = [];
  const seen = {};
  for (const it of items || []) {
    if (!it || !it.productId) continue;
    const pid = String(it.productId);
    if (seen[pid]) continue;
    seen[pid] = true;
    const last = alertedMap && alertedMap[pid];
    if (typeof last === 'number' && now - last < ALERT_COOLDOWN_MS) continue;
    fresh.push(it);
  }
  return fresh;
}
function markAlerted(alertedMap, items, now) {
  const out = Object.assign({}, alertedMap || {});
  for (const it of items || []) {
    if (it && it.productId) out[String(it.productId)] = now;
  }
  return out;
}
function alertedMapSize(map) {
  return map && typeof map === 'object' ? Object.keys(map).length : 0;
}
// v19.4：必须 trafficBaselineAt + 本店 alerted 非空
function hasTrafficBaseline(snap) {
  if (!snap || typeof snap !== 'object') return false;
  if (!snap.trafficBaselineAt) return false;
  const n = alertedMapSize(snap.alertedTrafficIds)
    + alertedMapSize(snap.alertedWatchIds)
    + alertedMapSize(snap.alertedDeclineIds);
  return n > 0;
}

/**
 * v19.4 decideAlert：全局冷却只参与 pickFresh，不写回本店 snapshot
 * @returns {{fresh, storeAlerted, globalAlerted, silenced, seeded, chipReallyUp, high, writeBaselineAt}}
 */
function decideAlert(pool, storeAlertedIn, globalAlertedIn, snap, now) {
  const prevHigh = Math.max(
    typeof snap.trafficWatchHigh === 'number' ? snap.trafficWatchHigh : 0,
    typeof snap.trafficWatch === 'number' ? snap.trafficWatch : 0
  );
  const curWatch = typeof snap._curWatch === 'number' ? snap._curWatch : prevHigh;
  const chipReallyUp = curWatch > prevHigh;
  const baselineReady = hasTrafficBaseline(snap);
  let storeAlerted = Object.assign({}, storeAlertedIn || {});
  let globalAlerted = Object.assign({}, globalAlertedIn || {});
  let fresh = [];
  let silenced = 0;
  let seeded = false;

  const cooldownView = () => Object.assign({}, globalAlerted, storeAlerted);

  if (!baselineReady) {
    if (pool.length > 0) {
      storeAlerted = markAlerted(storeAlerted, pool, now);
      globalAlerted = markAlerted(globalAlerted, pool, now);
      seeded = true;
    }
    // pool 空：不 seed、不污染 storeAlerted（即使 global 有 ID）
    return {
      fresh,
      storeAlerted,
      globalAlerted,
      silenced,
      seeded,
      chipReallyUp,
      high: Math.max(prevHigh, curWatch || 0),
      writeBaselineAt: seeded,
    };
  }

  fresh = pickFreshItems(pool, cooldownView(), now);
  if (fresh.length && !chipReallyUp) {
    silenced = fresh.length;
    storeAlerted = markAlerted(storeAlerted, fresh, now);
    globalAlerted = markAlerted(globalAlerted, fresh, now);
    fresh = [];
  }
  if (fresh.length) {
    storeAlerted = markAlerted(storeAlerted, fresh, now);
    globalAlerted = markAlerted(globalAlerted, fresh, now);
  }
  // 见过的都记入
  storeAlerted = markAlerted(storeAlerted, pool, now);
  globalAlerted = markAlerted(globalAlerted, pool, now);
  return {
    fresh,
    storeAlerted,
    globalAlerted,
    silenced,
    seeded,
    chipReallyUp,
    high: Math.max(prevHigh, curWatch || 0),
    writeBaselineAt: false,
  };
}

function assert(cond, msg) {
  if (!cond) throw new Error('FAIL: ' + msg);
  console.log('OK  ' + msg);
}

const now = Date.now();
const items = [
  { productId: '111', name: 'A', severity: 'general' },
  { productId: '222', name: 'B', severity: 'general' },
  { productId: '333', name: 'C', severity: 'severe' },
];

// 1) 空 snapshot / 空 {} / 仅 baselineAt / 仅 alerted 不算基线
assert(!hasTrafficBaseline({}), 'empty snap no baseline');
assert(!hasTrafficBaseline({ alertedTrafficIds: {} }), 'empty alerted map no baseline');
assert(!hasTrafficBaseline({ trafficBaselineAt: now }), 'baselineAt alone not enough');
assert(!hasTrafficBaseline({ alertedTrafficIds: { '111': now } }), 'alerted alone not enough (v19.4)');
assert(hasTrafficBaseline({ trafficBaselineAt: now, alertedTrafficIds: { '111': now } }), 'baselineAt+alerted ready');

// 2) 首次 seed 后，同批再扫 → fresh 为空
let alerted = markAlerted({}, items, now);
assert(Object.keys(alerted).length === 3, 'seed marks 3 ids');
let fresh = pickFreshItems(items, alerted, now + 1000);
assert(fresh.length === 0, 'same items within cooldown → no fresh');

// 3) 冷却过期后可再报
fresh = pickFreshItems(items, alerted, now + ALERT_COOLDOWN_MS + 1);
assert(fresh.length === 3, 'after cooldown all fresh again');

// 4) 新 productId 可报
fresh = pickFreshItems(
  items.concat([{ productId: '999', name: 'New' }]),
  alerted,
  now + 60 * 1000
);
assert(fresh.length === 1 && fresh[0].productId === '999', 'only brand-new id is fresh');

// 5) 竞态盖掉 alerted 后，空 map 不算 ready → reseed 不告警
{
  const wiped = { alertedTrafficIds: {} };
  assert(!hasTrafficBaseline(wiped), 'wiped empty map must NOT be baseline-ready');
  const reseed = markAlerted({}, items, now);
  const f2 = pickFreshItems(items, reseed, now + 1);
  assert(f2.length === 0, 'after reseed no alert on same pool');
}

// 6) v18：切店场景——baseline 在，但本页 ID 不在 alerted，chip 未升高 → 静默
{
  const snap = {
    trafficBaselineAt: now,
    alertedTrafficIds: { 'old': now },
    trafficWatch: 4,
    trafficWatchHigh: 4,
    _curWatch: 4, // chip 没变
  };
  // 模拟 alerted 丢了部分 ID（只剩 old），pool 仍是 3 个限流
  const partial = { old: now };
  const r = decideAlert(items, partial, {}, snap, now + 1000);
  assert(r.fresh.length === 0, 'switch-store same chip → no feishu');
  assert(r.silenced === 3, 'three ids silently absorbed');
  assert(r.storeAlerted['111'] && r.storeAlerted['222'] && r.storeAlerted['333'], 'ids recorded after silent');
}

// 7) v18：chip 真升高 + 新 ID → 告警
{
  const snap = {
    trafficBaselineAt: now,
    alertedTrafficIds: { '111': now },
    trafficWatch: 4,
    trafficWatchHigh: 4,
    _curWatch: 5,
  };
  const pool = items.concat([{ productId: '999', name: 'New', severity: 'general' }]);
  const r = decideAlert(pool, { '111': now }, {}, snap, now + 1000);
  assert(r.chipReallyUp === true, 'chip 4→5 is real rise');
  assert(r.fresh.some((x) => x.productId === '999'), 'new id alerts when chip rises');
  // 已在 alerted 的 111 不在 fresh；222/333 若从未报过且 chip 升高也会在 fresh
}

// 8) v18：chip 瞬时掉 0 再恢复 4 → 高水位仍 4，不告警
{
  const snap = {
    trafficBaselineAt: now,
    alertedTrafficIds: { '111': now, '222': now, '333': now },
    trafficWatch: 4, // 我们禁止写成 0
    trafficWatchHigh: 4,
    _curWatch: 4,
  };
  const r = decideAlert(items, snap.alertedTrafficIds, {}, snap, now + 2000);
  assert(r.fresh.length === 0, 'after chip 0→4 recover no alert');
  assert(r.chipReallyUp === false, '4 not greater than high 4');
}

// 9) prune 保留 24h 内
const old = markAlerted({}, items, now - ALERT_COOLDOWN_MS * 5);
const pruned = pruneAlertedMap(old, now);
assert(Object.keys(pruned).length === 0, 'very old alerted entries pruned');

// 10) v19.4 HomeCove 回归：全局冷却污染本店
// 场景：别店已有 12 个 ID 在 global；新店 HomeCove 先 pool 空写一轮，再扫到 15 个
// 旧逻辑：global 灌进 store → hasBaseline true → chip 升高 → 15 全推
// 新逻辑：pool 空不 seed；有 pool 时 seed 不告警
{
  const globalFromOther = {};
  for (let i = 0; i < 12; i++) globalFromOther['g' + i] = now;

  // 10a) 新店 pool 空：不 seed、storeAlerted 保持空、不写 baselineAt
  const snapEmpty = {
    // 旧 bug 可能已经误写了全局 ID；即使如此，无 trafficBaselineAt 也不算 ready
    alertedTrafficIds: Object.assign({}, globalFromOther),
    trafficWatch: 0,
    trafficWatchHigh: 0,
    _curWatch: 0,
  };
  assert(!hasTrafficBaseline(snapEmpty), 'polluted alerted without baselineAt → not ready');
  const rEmpty = decideAlert([], snapEmpty.alertedTrafficIds, globalFromOther, snapEmpty, now + 100);
  assert(!rEmpty.seeded && !rEmpty.writeBaselineAt, 'empty pool no seed');
  assert(rEmpty.fresh.length === 0, 'empty pool no alert');

  // 10b) 随后 pool=15 + chip 升高：因为未 seed，只 seed 不告警
  const pool15 = [];
  for (let i = 0; i < 15; i++) pool15.push({ productId: 'h' + i, name: 'H' + i, severity: i < 5 ? 'severe' : 'general' });
  const snapNew = {
    // 干净本店（修复后 pool 空不会灌 global）
    alertedTrafficIds: {},
    trafficWatch: 0,
    trafficWatchHigh: 0,
    _curWatch: 6, // chip 升高
  };
  assert(!hasTrafficBaseline(snapNew), 'new store no baseline');
  const rSeed = decideAlert(pool15, {}, globalFromOther, snapNew, now + 200);
  assert(rSeed.seeded === true, 'first non-empty pool seeds');
  assert(rSeed.fresh.length === 0, 'seed must NOT alert (HomeCove regression)');
  assert(rSeed.writeBaselineAt === true, 'seed writes baselineAt');
  assert(Object.keys(rSeed.storeAlerted).length === 15, 'store only has 15 local ids');
  // 全局可合并本地，但本店不应被 12 个别店 ID 撑大
  assert(!rSeed.storeAlerted['g0'], 'store must not absorb foreign global ids');

  // 10c) seed 之后同 pool 再来：无 fresh
  const snapSeeded = {
    trafficBaselineAt: now + 200,
    alertedTrafficIds: rSeed.storeAlerted,
    trafficWatch: 6,
    trafficWatchHigh: 6,
    _curWatch: 6,
  };
  assert(hasTrafficBaseline(snapSeeded), 'after seed baseline ready');
  const rAgain = decideAlert(pool15, rSeed.storeAlerted, rSeed.globalAlerted, snapSeeded, now + 300);
  assert(rAgain.fresh.length === 0, 'after seed same pool no re-alert');
}

// 11) v19.4：全局冷却仍能挡住跨店同 ID 重复推
{
  const snap = {
    trafficBaselineAt: now,
    alertedTrafficIds: { 'local': now },
    trafficWatch: 3,
    trafficWatchHigh: 3,
    _curWatch: 4, // chip 升高
  };
  // 全局已报过 111；本店没报过
  const r = decideAlert(
    [{ productId: '111', name: 'A', severity: 'general' }, { productId: 'new1', name: 'N', severity: 'general' }],
    { local: now },
    { '111': now },
    snap,
    now + 500
  );
  assert(r.chipReallyUp === true, 'chip up');
  assert(!r.fresh.some((x) => x.productId === '111'), 'global cooldown blocks 111');
  assert(r.fresh.some((x) => x.productId === 'new1'), 'truly new id still alerts');
  assert(r.storeAlerted['111'] && r.storeAlerted['new1'], 'both recorded in store after pass');
}

// ─── v21：限流池对齐 chip（Twilight 待关注3·限流池1）───
function mergeWatchItemLists(prev, next, opts) {
  opts = opts || {};
  const trustedReplace = !!opts.trustedReplace;
  const prevArr = Array.isArray(prev) ? prev : [];
  const nextArr = Array.isArray(next) ? next : [];
  if (!nextArr.length) return prevArr.slice();
  if (trustedReplace) return nextArr.slice();
  const byId = {};
  for (const it of prevArr) {
    if (it && it.productId) byId[String(it.productId)] = Object.assign({}, it);
  }
  for (const it of nextArr) {
    if (!it || !it.productId) continue;
    const pid = String(it.productId);
    const old = byId[pid] || {};
    byId[pid] = Object.assign({}, old, it, {
      name: it.name || old.name || '',
      skc: it.skc || old.skc || '',
    });
  }
  return Object.keys(byId).map((k) => byId[k]);
}
function isTrustedWatchScan(scan) {
  if (!scan || !scan.applied || !Array.isArray(scan.items) || !scan.items.length) return false;
  if (scan.trusted === false) return false;
  if (scan.trusted === true) return true;
  const n = scan.items.length;
  const chip = typeof scan.chipCount === 'number' ? scan.chipCount
    : (typeof scan.chipTotal === 'number' ? scan.chipTotal : null);
  const onSale = typeof scan.onSaleTabCount === 'number' ? scan.onSaleTabCount : null;
  if (onSale != null && onSale > 0 && n >= onSale && chip != null && chip < onSale) return false;
  if (chip != null && chip >= 0 && n > chip + 1) return false;
  return true;
}
function needsWatchRescan(latest, poolLen, trusted) {
  const chip = typeof latest.trafficWatch === 'number' ? latest.trafficWatch : 0;
  if (chip < 0) return false;
  const have = typeof poolLen === 'number' ? poolLen
    : (Array.isArray(latest.watchItems) ? latest.watchItems.length : 0);
  if (chip === 0) return have > 0;
  if (have > chip + 1) return true;
  if (!trusted && have < chip) return true;
  return false;
}
function decideScanWatchApplied(opts) {
  const before = opts.before;
  const after = opts.after;
  const chipN = opts.chipN;
  const cleanOnSaleTab = opts.cleanOnSaleTab;
  const productsAfter = opts.productsAfter || [];
  const watchLike = productsAfter.filter((p) => p.watch).length;
  const narrowed = after != null && before != null && after < before;
  const allOnSaleAreWatch = cleanOnSaleTab != null && chipN != null
    && chipN >= cleanOnSaleTab && after != null && after === cleanOnSaleTab
    && productsAfter.length > 0;
  const allRowsWatchBadge = productsAfter.length > 0 && watchLike === productsAfter.length
    && after != null && before != null && after <= before
    && (chipN == null || productsAfter.length <= chipN + 1);
  const filterOn = !!opts.filterOn;
  const legacyApplied = (after != null && before != null && after !== before && after <= before)
    || (productsAfter.length > 0 && watchLike === productsAfter.length && after != null && before != null && after <= before)
    || filterOn;

  let items = [];
  let applied = false;
  let trusted = false;
  let trustReason = '';
  if (narrowed || allOnSaleAreWatch || allRowsWatchBadge) {
    items = productsAfter.filter((p) => p && p.saleStatus !== 'removed');
    applied = items.length > 0 || after === 0;
    trusted = true;
    trustReason = narrowed ? 'list-narrowed' : (allOnSaleAreWatch ? 'all-onsale-watch' : 'all-rows-badge');
  }
  if (items.length && cleanOnSaleTab != null && cleanOnSaleTab > 0
    && items.length >= cleanOnSaleTab
    && chipN != null && chipN < cleanOnSaleTab) {
    items = [];
    applied = false;
    trusted = false;
    trustReason = 'full-onsale-as-watch';
  }
  if (items.length && chipN != null && chipN >= 0 && items.length > chipN + 1) {
    items = [];
    applied = false;
    trusted = false;
    trustReason = 'items-exceed-chip';
  }
  return { items, applied, trusted, trustReason, legacyApplied };
}

// 12) Twilight 日志复现：筛选未收窄 + filterOn 视觉真 → 旧版 applied=true 吃进 12 条；v21 拒绝
{
  const products = [];
  for (let i = 0; i < 12; i++) {
    products.push({ productId: String(100 + i), watch: i < 2, saleStatus: 'onSale' });
  }
  const r = decideScanWatchApplied({
    before: 12, after: 12, chipN: 3, cleanOnSaleTab: 12,
    productsAfter: products, filterOn: true,
  });
  assert(r.legacyApplied === true, 'v21-12: legacy would accept full on-sale');
  // 未收窄且非全员徽标：v21 根本不 applied（不再靠 filterOn 放行）
  assert(r.applied === false, 'v21-12: reject un-narrowed filterOn (Twilight chip=3 items would be 12)');
  assert(r.items.length === 0, 'v21-12: no items from un-narrowed scan');
  // 若旧逻辑硬塞 12 条进来，尺寸护栏仍拒
  assert(!isTrustedWatchScan({
    applied: true, trusted: false, items: products,
    chipCount: 3, onSaleTabCount: 12,
  }), 'v21-12: isTrustedWatchScan rejects dump');
  assert(!isTrustedWatchScan({
    applied: true, items: products, chipCount: 3, onSaleTabCount: 12,
  }), 'v21-12: even without trusted flag, size guard rejects');
  // 全员徽标但条数 > chip+1：allRowsWatchBadge 也不放行
  const dump = decideScanWatchApplied({
    before: 12, after: 12, chipN: 3, cleanOnSaleTab: 12,
    productsAfter: products.map((p) => Object.assign({}, p, { watch: true })),
    filterOn: true,
  });
  assert(dump.applied === false && dump.items.length === 0,
    'v21-12b: all-watch rows still rejected when count ≫ chip');
  // 若绕过前置、硬塞 items≈onSale：尺寸护栏打 full-onsale-as-watch
  const forced = {
    items: products.map((p) => Object.assign({}, p, { watch: true })),
    applied: true,
    trusted: true,
    trustReason: 'all-rows-badge',
  };
  // 模拟护栏
  if (forced.items.length >= 12 && 3 < 12) {
    forced.items = [];
    forced.applied = false;
    forced.trusted = false;
    forced.trustReason = 'full-onsale-as-watch';
  }
  assert(forced.trustReason === 'full-onsale-as-watch', 'v21-12c: size guard reason');
}

// 13) 筛选真正收窄 12→3：可信
{
  const products = [
    { productId: 'a', watch: true, saleStatus: 'onSale' },
    { productId: 'b', watch: true, saleStatus: 'onSale' },
    { productId: 'c', watch: true, saleStatus: 'onSale' },
  ];
  const r = decideScanWatchApplied({
    before: 12, after: 3, chipN: 3, cleanOnSaleTab: 12,
    productsAfter: products, filterOn: true,
  });
  assert(r.applied && r.trusted && r.trustReason === 'list-narrowed', 'v21-13: narrowed trusted');
  assert(r.items.length === 3, 'v21-13: 3 items');
  assert(isTrustedWatchScan({
    applied: true, trusted: true, items: r.items, chipCount: 3, onSaleTabCount: 12,
  }), 'v21-13: trusted scan accepted');
}

// 14) 被动短清单不得覆盖完整清单（chipStats merge）
{
  const prev = [
    { productId: '1', name: 'A' },
    { productId: '2', name: 'B' },
    { productId: '3', name: 'C' },
  ];
  const passiveOne = [{ productId: '1', name: 'A2' }];
  const merged = mergeWatchItemLists(prev, passiveOne, { trustedReplace: false });
  assert(merged.length === 3, 'v21-14: short passive keeps 3');
  assert(merged.find((x) => x.productId === '1').name === 'A2', 'v21-14: same id updates fields');
  const replaced = mergeWatchItemLists(prev, passiveOne, { trustedReplace: true });
  assert(replaced.length === 1, 'v21-14: trusted replace may shrink');
}

// 15) needsWatchRescan：v22.1 —— pool<chip 仅未 trusted 时补扫；已 trusted 不再空转
{
  // 未 trusted：pool1 < chip3 → 补扫
  assert(needsWatchRescan({ trafficWatch: 3, watchItems: [{ productId: '1' }] }, 1, false),
    'v22.1-15: untrusted pool1 < chip3 → rescan');
  // 已 trusted：chip 含下架，pool2 < chip3 是常态，不再空转
  assert(!needsWatchRescan({ trafficWatch: 3 }, 2, true),
    'v22.1-15: trusted pool2 < chip3 → no rescan (chip含下架)');
  assert(!needsWatchRescan({ trafficWatch: 3, watchItems: [{ productId: '1' }, { productId: '2' }, { productId: '3' }] }, 3, false),
    'v22.1-15: pool==chip no rescan');
  // pool 明显多于 chip：无论 trusted 与否都收缩
  assert(needsWatchRescan({ trafficWatch: 3 }, 12, true),
    'v22.1-15: pool12 > chip3 → rescan to shrink');
  assert(needsWatchRescan({ trafficWatch: 0, watchItems: [{ productId: '1' }] }, 1, true),
    'v22.1-15: chip0 leftover → rescan');
}

// 16) seed 护栏：pool≫chip 拒绝
{
  function seedOk(poolLen, chip) {
    const seedLooksLikeFullOnsale = chip != null && chip > 0
      && poolLen >= Math.max(chip * 2, chip + 3);
    return poolLen > 0 && !seedLooksLikeFullOnsale;
  }
  assert(!seedOk(12, 3), 'v21-16: refuse seed pool12 chip3');
  assert(!seedOk(15, 6), 'v21-16: refuse seed pool15 chip6 (HomeCove log)');
  assert(seedOk(3, 3), 'v21-16: allow seed pool==chip');
  assert(seedOk(2, 3), 'v21-16: allow seed pool slightly under chip');
}

console.log('\nAll traffic dedupe tests passed (incl v19.4 baseline + v21 pool/chip).');
