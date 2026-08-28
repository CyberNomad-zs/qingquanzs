// Service worker：接收接口数据 → 按【店铺名】分别解析/对比/告警。
// 多店铺：同一账号下有多个店(HomeCove/Twilight Cove/Agnis)，切到哪个店就记哪个店，各自独立快照与告警。
// 数据只存本机 chrome.storage.local，不上传任何服务器。

importScripts('logger.js', 'feishuApp.js');
var log = TemuLogger.createLogger('bg');

// v14：流量为主；下架曾迁服务器赛狐。
// v15：流量只报在售 + 按 productId 冷却去重（下架商品也会挂限流徽标；切店不再刷屏）。
// v16：限流分级（严重 VIP / JM+热销；一般其它）+ 定点差异汇总 + 多维表/任务同步。
// v17：修切店重复告警——stores 读写全局串行，避免 updateStoreLatest 覆盖掉
//      snapshot.alertedTrafficIds；基线必须「非空已告警 ID」，空 {} / 仅 chip 计数不算基线。
// v18：切店时 chip 会短暂掉 0，snap.trafficWatch 被写成 0，恢复后 0→N 被当成「新增」全量推。
//      规则：snap 计数禁止被瞬时拉低；chip 未相对高水位上升时只静默吸收 ID，不发飞书；
//      另加全局 productId 冷却（跨店/快照丢失兜底）。
// v19：A+B 上下架（赛狐同步滞后时的后台兜底；卡片标注「插件·后台」）
//   A: countStatus 在售数升降 → 即时飞书（数量）+ 当前店立刻 scan 点名
//   B: 空闲/手动轮巡每店 scanOnSale → 下架点名；上架「连续两轮仍在售」才点名
//   productId 6h 冷却，降低与服务器赛狐双报刷屏（无法完全消除）
// v19.2：A 数量防抖——countStatus 切店/loading 会瞬时掉（15→4→15），
//   同一新值需连续命中 ≥2 次且间隔 ≥3s 才发数量卡；回弹基准取消 pending。
//   B 扫描仍可在首次变化后防抖触发（点名本身有护栏）。
// v19.3：根因是切店串店——inject 有 mallId 但 content 没转发，DOM 店名滞后
//   把 A 店 count 记到 B 店（Agnis 12→0→12）。按 mallId 绑店；轮巡中静默数量卡；
//   归零不走 A；大幅下降加严确认。
// v19.4：两处误报
//   ① B 真清零：tabCount=0 单次扫描会把 loading 瞬间当整店下架（Agnis n=12）。
//      需连续 ≥2 次 trueZero；且与近 2min 内可信 onSaleCount>0 冲突时拒绝。
//   ② 限流基线：全局 trafficAlertedGlobal 被写进本店 snapshot.alerted*，
//      新店 pool 空时 alerted 非空 → hasTrafficBaseline 误判已就绪 → 首轮全量推
//      （HomeCove fresh=15）。全局只参与 pickFresh 冷却，不写回本店；
//      trafficBaselineAt 仅在本店非空 pool seed 时打戳。
// v19.5：限流筛选污染在售数（HomeCove 15→4 假下架）——多层护栏（chip/collapse），
//   仍未改掉「当前 DOM 列表 = 全店基准」的权威模型。
// v20：在售权威隔离（结构改造，不再叠旁路 if）
//   ① A/B 解耦：pending 未确认绝不 shouldScan；仅 confirmed 才约 B；rebound 取消定时器
//   ② trust 门闩：content 只在干净在售视图返回 trust=full-onsale；否则 diffOnSale abort
//   ③ pageMode：traffic/onsale/switch 出口 finally 复位，forceWatchFilterOn 不残留
//   collapse 比例降为 defense-in-depth，主路径靠 trust + 确认后才 B
// v21：限流池对齐 chip（修「待关注 3 · 限流池 1」少计）
//   ① scanWatchList 拒绝「整页在售当待关注」（chip≪onSale 且 items≈onSale → 丢弃）
//   ② 被动徽标短清单不得覆盖更完整的 watchItems（merge 只增不缩；trusted 全量可替换）
//   ③ pool.length < trafficWatch 时补扫 scanWatchList（高水位不升也补明细）
//   ④ 不可信/全量 dump 的 scan 结果不 seed、不写 alerted
// v22：在售数量误把「限流在售」当「全店在售」（飞书 2→12 / 3→15 假上升）
//   根因：开「商品流量待关注」后 countStatus 的在售=筛后子集；响应迟到时 DOM 已关筛选，
//   旧逻辑按到达时 DOM 标 watchFilterOn=false → 子集写进 onSaleCount；关筛选后真数恢复误报上升。
//   ① inject 请求时打 watchFilterOnAtReq + content grace
//   ② A 路径：onSaleHighWater；子集形态（≈chip 且远低于高水位）拒绝写入
//   ③ 从子集水位恢复到接近高水位 → 静默抬基准，不发上升卡
//   ④ silent 轮巡路径禁止把基准往下压
// v22.1：chip 含已下架商品，on-sale pool < chip 是常态；trusted 全量才决定是否补扫
// v22.2：报错转发飞书（签名去重 30min）+ 前台轮巡等真实上报（不再盲等 12s）
//        + 前台风控/网页打不开红卡（独立 30min 去重）
// v22.3：库存归零（pageQuery SKU stock>0→0 橙色卡）
//        + B 路径子集→全量静默重建清单，不发上架点名（修 HomeCove 假上架）
const ONSALE_MONITOR_IN_PLUGIN = true;
const ONSALE_QTY_ALERT = true;       // A：数量变化（确认后）卡
const ONSALE_SCAN_ALERT = true;      // B：清单 diff 点名
const ONSALE_ID_COOLDOWN_MS = 6 * 60 * 60 * 1000;
const ONSALE_QTY_COOLDOWN_MS = 30 * 60 * 1000; // 同一店同 from→to 数量卡 30 分钟内不重复
const ONSALE_SCAN_DEBOUNCE_MS = 6000;
const ONSALE_QTY_CONFIRM_HITS = 2;            // 同一候选值连续命中次数
const ONSALE_QTY_CONFIRM_GAP_MS = 3000;       // 首次见到候选 → 确认至少间隔
const ONSALE_QTY_PENDING_TTL_MS = 60 * 1000;  // pending 超时丢弃（页面停更时）
// 大幅下降（≥50% 或 ≥3）加严；归零一律不走 A 发卡（只靠 B 真清零点名）
const ONSALE_QTY_BIG_DROP_RATIO = 0.5;
const ONSALE_QTY_BIG_DROP_MIN = 3;
const ONSALE_QTY_BIG_DROP_HITS = 3;
const ONSALE_QTY_BIG_DROP_GAP_MS = 12000;
// B 真清零：连续命中次数 + 与近期 countStatus 交叉验证窗口
const ONSALE_TRUE_ZERO_HITS = 2;
const ONSALE_TRUE_ZERO_VS_COUNT_MS = 2 * 60 * 1000;
// B 扫描 vs 可信 countStatus：已知在售数被大幅压低 → 视为限流/筛选污染，放弃本轮
// （日志：baseline 15，筛选后 tabCount=4 扫 4 条 → 误报下架 11）
const ONSALE_SCAN_VS_COUNT_RATIO = 0.5;   // tabCount/items < count * 50%
const ONSALE_SCAN_VS_COUNT_MIN_DROP = 3;  // 且至少少 3 个
const ONSALE_SCAN_VS_COUNT_MAX_AGE_MS = 10 * 60 * 1000; // 可信 count 时效

// 库存归零检测：pageQuery 中 SKU 的 realStock/virtualStock 从 >0 变为 0 时飞书提醒
const STOCK_ZERO_ALERT = true;

// 兼容旧名：曾用 DELIST_IN_PLUGIN 只控下架扫描
const DELIST_IN_PLUGIN = ONSALE_MONITOR_IN_PLUGIN && ONSALE_SCAN_ALERT;

const GOODS_URL = 'https://agentseller.temu.com/goods/list';
const DEFAULT_CONFIG = {
  webhook: '',
  intervalMinutes: 15,
  enabled: true,
  storeName: '',
  // 机器名标签（报错转发用）：卡片标题带上，方便区分是哪台电脑。留空显示「未命名机器」。
  machineLabel: '',
  // 定时必提醒：每天固定时刻强制发飞书状态汇报（无异常也发，证明插件活着）
  mustRemindEnabled: true,
  mustRemindTimes: ['09:30', '16:30'],
  // 前台变体监测
  frontCheckEnabled: true,
  frontCheckIntervalHours: 3,
  // 飞书企业应用（多维表 + 任务）；本地填写，不进仓库
  feishuAppId: '',
  feishuAppSecret: '',
  bitableAppToken: '',
  bitableTableId: '',
  feishuTaskEnabled: true,
  feishuTasklistGuid: '',
};
const MUST_REMIND_PREFIX = 'mustRemind|';

// ---------------- 解析 ----------------
function parseCountStatus(body) {
  try {
    const j = JSON.parse(body);
    const list = j && j.result && j.result.skcTopStatusCountList;
    if (!Array.isArray(list)) return null;
    const pick = (s) => {
      const x = list.find((e) => e && e.skcTopStatus === s);
      return x && typeof x.skcTotal === 'number' ? x.skcTotal : null;
    };
    return { onSale: pick(100), unpublished: pick(0), removed: pick(200), deleted: pick(300) };
  } catch (e) { log.warn('parseCountStatus: failed to parse response'); return null; }
}
// 从 productSkuSpecList 拼规格名，如「颜色:Khaki / 数量:1pc」→「Khaki」优先单值，多维用「/」
function formatSkuSpecName(sku) {
  const specs = (sku && Array.isArray(sku.productSkuSpecList)) ? sku.productSkuSpecList : null;
  if (specs && specs.length) {
    return specs.map((sp) => String(sp.specName || sp.unitSpecName || '').trim()).filter(Boolean).join('/') || '';
  }
  return String((sku && (sku.specName || sku.skuName || sku.name)) || '').trim();
}
// 把单个 SKU 对象规范成统一结构
function normalizeSku(sku, product) {
  if (!sku || typeof sku !== 'object') return null;
  const skuId = sku.productSkuId || sku.skuId || sku.skuIdStr || sku.id || sku.skuSpecId || '';
  const name = formatSkuSpecName(sku);
  const extCode = String(sku.extCode || sku.skuExtCode || sku.outerSkuId || '').trim();
  if (!skuId && !name && !extCode) return null;
  return {
    skuId: skuId ? String(skuId) : '',
    name: name || extCode || ('SKU' + (skuId ? ' ' + skuId : '')),
    extCode: extCode,
    img: sku.thumbUrl || sku.skuImgUrl || sku.imageUrl || sku.imgUrl || '',
    productId: product && (product.productId || product.productIdStr) ? String(product.productId || product.productIdStr) : '',
    skc: product && (product.productSkcId || product.skcId) ? String(product.productSkcId || product.skcId) : '',
    productName: product && product.productName ? String(product.productName) : '',
    stock: typeof sku.realStock === 'number' ? sku.realStock
      : (typeof sku.virtualStock === 'number' ? sku.virtualStock : null),
  };
}
// 从 pageQuery 商品项提取 SKU 列表（真实字段：productSkuSummaries[].productSkuId + productSkuSpecList）
function extractSkusFromProduct(it) {
  if (!it || typeof it !== 'object') return [];
  const arr = Array.isArray(it.productSkuSummaries) ? it.productSkuSummaries
    : (Array.isArray(it.skuList) ? it.skuList
      : (Array.isArray(it.productSkus) ? it.productSkus : null));
  if (!arr) return [];
  return arr.map((sku) => normalizeSku(sku, it)).filter(Boolean);
}
function parsePageQuery(body) {
  try {
    const j = JSON.parse(body);
    const r = j && j.result;
    if (!r) return null;
    const pageItems = Array.isArray(r.pageItems) ? r.pageItems
      : (Array.isArray(r.list) ? r.list : []);
    const products = [];
    const flatSkus = [];
    for (const it of pageItems) {
      if (!it || typeof it !== 'object') continue;
      const productId = it.productId != null ? String(it.productId) : '';
      if (!productId) continue;
      const skus = extractSkusFromProduct(it);
      // 货号：SKU extCode 优先；商品级 extCode 兜底
      const skuCodes = [];
      const codeSeen = {};
      const pushCode = (c) => {
        const s = String(c || '').trim();
        if (!s) return;
        const k = s.toUpperCase();
        if (codeSeen[k]) return;
        codeSeen[k] = true;
        skuCodes.push(s);
      };
      for (const s of skus) if (s && s.extCode) pushCode(s.extCode);
      if (it.extCode) pushCode(it.extCode);
      const product = {
        productId,
        skc: it.productSkcId != null ? String(it.productSkcId) : '',
        name: String(it.productName || '').slice(0, 80),
        skus,
        skuCount: skus.length,
        skuCodes,
      };
      products.push(product);
      for (const s of skus) flatSkus.push(s);
    }
    return {
      total: typeof r.total === 'number' ? r.total : null,
      products,
      pageSkus: flatSkus,
      pageSkuCount: flatSkus.length,
      multiSkuProducts: products.filter((p) => p.skuCount > 1),
    };
  } catch (e) { log.warn('parsePageQuery: failed to parse response'); return null; }
}
// 在未知 JSON 树里找「看起来像 SKU 列表」的数组（编辑页 parent/list 结构会漂移）
function findSkuLikeArray(node, depth) {
  if (depth > 6 || node == null) return null;
  if (Array.isArray(node)) {
    if (!node.length) return null;
    const sample = node.slice(0, 5).filter((x) => x && typeof x === 'object');
    if (sample.length && sample.every((x) =>
      x.productSkuId != null || x.skuId != null || x.productSkuSpecList != null
      || x.specName != null || x.skuSpecId != null)) {
      return node;
    }
    for (const el of node.slice(0, 20)) {
      const found = findSkuLikeArray(el, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (typeof node === 'object') {
    // 优先常见键
    for (const k of ['list', 'skuSpecList', 'skuSpecs', 'productSkuSummaries', 'skuList', 'data', 'records', 'items']) {
      if (Array.isArray(node[k])) {
        const found = findSkuLikeArray(node[k], depth + 1);
        if (found) return found;
      }
    }
    for (const k of Object.keys(node).slice(0, 30)) {
      const found = findSkuLikeArray(node[k], depth + 1);
      if (found) return found;
    }
  }
  return null;
}
function parseSkuSpecList(body) {
  try {
    const j = JSON.parse(body);
    // 1) 浅路径 2) 深搜「SKU 形」数组
    let list = j && j.result && j.result.list;
    if (!Array.isArray(list)) list = j && j.result && j.result.skuSpecList;
    if (!Array.isArray(list)) list = j && j.result && j.result.skuSpecs;
    if (!Array.isArray(list)) list = j && j.result && j.result.productSkuSummaries;
    if (!Array.isArray(list)) list = j && j.result && j.result.data;
    if (!Array.isArray(list)) list = j && j.result && Array.isArray(j.result) ? j.result : null;
    if (!Array.isArray(list)) list = j && j.data && j.data.list;
    if (!Array.isArray(list)) list = j && Array.isArray(j.data) ? j.data : null;
    if (!Array.isArray(list)) list = findSkuLikeArray(j, 0);
    if (!Array.isArray(list)) {
      log.warn('parseSkuSpecList: no sku-like array, result keys=' +
        (j && j.result ? Object.keys(j.result).slice(0, 12).join(',') : 'null'));
      chrome.storage.local.set({ lastSkuSpecRawFail: body.slice(0, 3000) });
      return null;
    }
    const specs = list.map((it) => normalizeSku(it, null)).filter(Boolean);
    if (!specs.length) {
      log.warn('parseSkuSpecList: parsed ' + list.length + ' items but none had skuId/name, first item keys=' +
        (list[0] && typeof list[0] === 'object' ? Object.keys(list[0]).slice(0, 12).join(',') : typeof list[0]));
      chrome.storage.local.set({ lastSkuSpecRawFail: body.slice(0, 3000) });
      return null;
    }
    return { skuSpecs: specs, skuSpecCount: specs.length };
  } catch (e) { log.warn('parseSkuSpecList: failed to parse response: ' + (e && e.message ? e.message : String(e))); return null; }
}
function parseSkuPriceQuery(body) {
  try {
    const j = JSON.parse(body);
    const r = j && j.result;
    if (!r) return null;
    // 数据结构未知，先整体保存，后续按需解析
    return { skuPriceRaw: r };
  } catch (e) { log.warn('parseSkuPriceQuery: failed to parse response'); return null; }
}

// ---------------- 存取 ----------------
async function getConfig() {
  const { config } = await chrome.storage.local.get('config');
  return Object.assign({}, DEFAULT_CONFIG, config || {});
}
// 所有 stores 的读-改-写必须走 withStores，否则并发会互相覆盖 snapshot
//（典型：chipStats 的 updateStoreLatest 盖掉 _diffAndAlert 刚写入的 alertedTrafficIds
//  → 切店后再扫同一批限流商品被当成「新出现」重复飞书）。
let storesChain = Promise.resolve();
function withStores(fn) {
  const run = storesChain.then(() => fn());
  // 成功/失败都继续队列，避免一条 rejection 卡死后续写入
  storesChain = run.then(() => {}, () => {});
  return run;
}
async function getStores() {
  const { stores } = await chrome.storage.local.get('stores');
  return stores || {};
}
async function saveStores(stores) {
  await chrome.storage.local.set({ stores });
}
// 更新某店的最新读数（串行）
async function updateStoreLatest(name, patch) {
  return withStores(async () => {
    const stores = await getStores();
    const s = stores[name] || { latest: {}, snapshot: {} };
    s.latest = Object.assign({}, s.latest, patch, { ts: Date.now() });
    stores[name] = s;
    await saveStores(stores);
    return s;
  });
}
// 合并 patch 到 snapshot（串行），供 mustRemind / sku diff 等使用
async function updateStoreSnapshot(name, snapPatch) {
  return withStores(async () => {
    const stores = await getStores();
    const s = stores[name] || { latest: {}, snapshot: {} };
    s.snapshot = Object.assign({}, s.snapshot || {}, snapPatch);
    stores[name] = s;
    await saveStores(stores);
    return s;
  });
}
// alerted map 是否已有有效基线（空 {} 不算——否则首次空池 seed 后，明细一出现会全量误报）
function alertedMapSize(map) {
  return map && typeof map === 'object' ? Object.keys(map).length : 0;
}
function hasTrafficBaseline(snap) {
  if (!snap || typeof snap !== 'object') return false;
  // v19.4：必须本店正式 seed 过（trafficBaselineAt）且本店 alerted 非空。
  // 仅 alerted 非空不够——历史 bug 会把全局冷却 ID 灌进本店 snapshot，
  // 新店 pool 空时被误判「已有基线」→ 首轮全量推。
  // 仅 trafficBaselineAt 也不够（半截写入）。
  if (!snap.trafficBaselineAt) return false;
  const n = alertedMapSize(snap.alertedTrafficIds)
    + alertedMapSize(snap.alertedWatchIds)
    + alertedMapSize(snap.alertedDeclineIds);
  return n > 0;
}
// 全账号级别的 productId 冷却（不按店）。切店/snapshot 丢失时仍能挡住同一 SPU 重复推。
async function getGlobalAlerted() {
  const { trafficAlertedGlobal } = await chrome.storage.local.get('trafficAlertedGlobal');
  return trafficAlertedGlobal || {};
}
async function saveGlobalAlerted(map) {
  await chrome.storage.local.set({ trafficAlertedGlobal: map });
}

// ---------------- 飞书 ----------------
// template：飞书卡片色条 red/orange/blue/green/turquoise/wathet/purple/violet/carmine/yellow/grey
async function sendFeishu(webhook, title, lines, template) {
  if (!webhook) return { ok: false, msg: '未配置飞书 webhook' };
  const card = {
    msg_type: 'interactive',
    card: {
      header: { title: { tag: 'plain_text', content: title }, template: template || 'red' },
      elements: [{ tag: 'div', text: { tag: 'lark_md', content: lines.join('\n') } }],
    },
  };
  try {
    const resp = await fetch(webhook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(card) });
    const data = await resp.json().catch(() => ({}));
    const ok = resp.ok && (data.code === 0 || data.StatusCode === 0 || data.code === undefined);
    if (ok) log.info('Feishu sent OK: ' + title);
    return { ok, msg: ok ? '已发送' : ('飞书返回：' + JSON.stringify(data)) };
  } catch (e) {
    log.error('Feishu send FAILED: ' + (e && e.message ? e.message : 'unknown'));
    return { ok: false, msg: '发送失败：' + (e && e.message) };
  }
}

// ---------------- 报错转发飞书 ----------------
// 插件运行时报错（SW 各 catch / content 全局监听 / SW 未捕获）经现有 webhook 推到用户飞书。
// 复用告警 webhook，不触发 FeishuApp.syncAfterAlert（不写多维表/任务）。
const ERROR_REPORT_COOLDOWN_MS = 30 * 60 * 1000;       // 同一签名 30 分钟内只发一次
const ERROR_REPORT_KEEP_MS = 2 * 60 * 60 * 1000;        // 冷却历史保留窗口（排障用）
const ERROR_REPORT_KEY = 'errorReportCooldown';         // { signature: ts } 存 storage，跨 SW 回收存活
let _reportDepth = 0;                                   // 递归守卫（计数器，防 await 嵌套）
let reportErrorChain = Promise.resolve();               // 串行化：防并发同签名双发 + storage lost-update

// 错误签名归一化：同一根因 → 同一签名，跨数字/ID/时间戳/URL/栈帧稳定。
// 保留店铺名（避免不同店的同类错误被过度合并），不把机器名算进签名（固定维度，放 title）。
function normalizeErrorSignature(raw) {
  let s = String(raw || '');
  const nl = s.indexOf('\n');
  if (nl >= 0) s = s.slice(0, nl);                       // 只取首行，丢栈
  s = s
    .replace(/\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}\]?/g, '') // 时间戳
    .replace(/0x[0-9a-f]+/gi, '#hex')
    .replace(/\b[a-f0-9]{12,}\b/gi, '#id')               // 长 hex（productId / requestId）
    .replace(/https?:\/\/\S+/g, '#url')
    .replace(/\b\d+\b/g, '#')                            // 数字（放最后，避免吃掉上面占位符里的数）
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase()
    .slice(0, 160);
  return s;
}

async function getErrorCooldown() {
  const { [ERROR_REPORT_KEY]: m } = await chrome.storage.local.get(ERROR_REPORT_KEY);
  return m && typeof m === 'object' ? m : {};
}
function pruneErrorCooldown(m, now) {
  const out = {};
  for (const k of Object.keys(m || {})) {
    const ts = m[k];
    if (typeof ts === 'number' && now - ts < ERROR_REPORT_KEEP_MS) out[k] = ts;
  }
  return out;
}

// opts: { source }  source 用于卡片标注来源（content/front/cycle/frontCycle/mustRemind/msg/global）
async function reportErrorToFeishu(rawMsg, opts) {
  if (_reportDepth > 0) return;                          // 递归守卫：已在上报中，跳过
  const sig = normalizeErrorSignature(rawMsg);
  if (!sig) return;
  // 前缀黑名单：上报自身 / 飞书失败不回环（content 不会产生这些前缀，纯防将来）
  if (/^(feishu send failed|feishuapp|error report|sw uncaught|sw unhandledrejection)/i.test(sig)) return;
  if (/resizeobserver/i.test(sig)) return;

  // 串行化：把读冷却→判→发→写冷却整段放进链，杜绝并发双发与 storage 覆盖
  reportErrorChain = reportErrorChain.then(async () => {
    _reportDepth++;
    try {
      const cfg = await getConfig();
      if (!cfg.webhook) return;                          // 没配 webhook，静默
      const now = Date.now();
      const m = pruneErrorCooldown(await getErrorCooldown(), now);
      if (m[sig] && now - m[sig] < ERROR_REPORT_COOLDOWN_MS) return; // 冷却内，跳过
      const label = (cfg.machineLabel && String(cfg.machineLabel).trim()) || '未命名机器';
      const title = '🛑 Temu 插件报错 · ' + label;
      const lines = [
        '**机器:** ' + label,
        '**来源:** ' + ((opts && opts.source) || 'bg'),
        '**签名:** `' + sig + '`',
        '',
        '**消息:**',
        '```',
        String(rawMsg).slice(0, 1500),
        '```',
        '',
        '_时间：' + new Date().toLocaleString('zh-CN') + '_',
      ];
      // sendFeishu 失败降级为 warn（WARN 不进 ERROR 上报路径，从根断回环）
      try {
        await sendFeishu(cfg.webhook, title, lines, 'red');
      } catch (e) {
        log.warn('reportError sendFeishu failed: ' + ((e && e.message) || e));
      }
      // 无论 send 成败都打冷却戳：飞书侧故障时也别在 30 分钟内重试同签名（防刷屏）
      m[sig] = now;
      await chrome.storage.local.set({ [ERROR_REPORT_KEY]: m });
    } catch (e) {
      // 上报自身出错：warn，不 error，不回环
      log.warn('reportErrorToFeishu internal: ' + ((e && e.message) || e));
    } finally {
      _reportDepth--;
    }
  }).catch(() => {});                                    // 链不断
}

// ---------------- 前台页面被风控 / 打不开提醒 ----------------
// v22.2：前台商品页弹人机验证 / 网络打不开时通知飞书，运营去人工过验证或排查网络。
// 两条入口：
//  ① content-front detectCaptcha 命中 → frontCapture 带 captcha → 这里发卡；
//  ② background cycleFrontProducts 新开 tab 超时（waitForFrontCapture 25s 没数据）→
//     检查 tab 状态，导航失败/错误页也走这里。
// 独立去重：同一店同一原因 30 分钟内只发一次（复用与报错转发相同的冷却思路，但用单独 storage key，
// 避免和插件代码报错互相挤占冷却槽）。
const FRONT_BLOCK_COOLDOWN_MS = 30 * 60 * 1000;
const FRONT_BLOCK_KEY = 'frontBlockCooldown';
let frontBlockChain = Promise.resolve();

async function getFrontBlockCooldown() {
  const { [FRONT_BLOCK_KEY]: m } = await chrome.storage.local.get(FRONT_BLOCK_KEY);
  return m && typeof m === 'object' ? m : {};
}

// reason: 'captcha' | 'load-failed'  ；sigKey 区分店+原因（不把 URL 算进签名，避免同店多商品各发一次）
async function notifyFrontBlocked(store, url, opts) {
  const reason = (opts && opts.reason) || 'captcha';
  const info = opts && opts.info ? opts.info : {};
  const sigKey = store + '|' + reason;
  frontBlockChain = frontBlockChain.then(async () => {
    try {
      const cfg = await getConfig();
      if (!cfg.webhook) return;
      const now = Date.now();
      const m = await getFrontBlockCooldown();
      // 修剪（保留 2h）
      const keep = {};
      for (const k of Object.keys(m)) {
        if (typeof m[k] === 'number' && now - m[k] < 2 * 60 * 60 * 1000) keep[k] = m[k];
      }
      if (keep[sigKey] && now - keep[sigKey] < FRONT_BLOCK_COOLDOWN_MS) return; // 冷却内
      const label = (cfg.machineLabel && String(cfg.machineLabel).trim()) || '未命名机器';
      const reasonText = reason === 'captcha'
        ? '人机验证 / 风控拦截'
        : '网页打不开 / 加载失败';
      const lines = [
        '**机器:** ' + label,
        '**店铺:** ' + store,
        '**原因:** ' + reasonText,
        '**链接:** [' + String(url || '').slice(0, 70) + '](' + url + ')',
      ];
      if (info.keyword) lines.push('**命中标志:** ' + info.keyword);
      if (info.snippet) lines.push('', '**页面片段:**', '> ' + String(info.snippet).slice(0, 180));
      lines.push('', '_需人工：到该店 Temu 前台过验证 / 检查网络，再点「前台变体全查」复测_');
      lines.push('_时间：' + new Date().toLocaleString('zh-CN') + '_');
      try {
        await sendFeishu(cfg.webhook, '🚫 Temu 前台访问异常 · ' + label, lines, 'red');
      } catch (e) {
        log.warn('notifyFrontBlocked sendFeishu failed: ' + ((e && e.message) || e));
      }
      keep[sigKey] = now;
      await chrome.storage.local.set({ [FRONT_BLOCK_KEY]: keep });
    } catch (e) {
      log.warn('notifyFrontBlocked internal: ' + ((e && e.message) || e));
    }
  }).catch(() => {});
}

// ---------------- 定时必提醒（每天固定时刻强制汇报各店状态） ----------------
function parseHHMM(s) {
  const m = String(s || '').trim().match(/^(\d{1,2})[:.：](\d{2})$/);
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  return { h, min, label: String(h).padStart(2, '0') + ':' + String(min).padStart(2, '0') };
}
// 下一次触发时间戳（本地时区）；若今天该时刻已过（或 5 秒内），排到明天
function nextWhen(hhmm) {
  const p = parseHHMM(hhmm);
  if (!p) return null;
  const now = new Date();
  const t = new Date(now.getFullYear(), now.getMonth(), now.getDate(), p.h, p.min, 0, 0);
  if (t.getTime() <= now.getTime() + 5000) t.setDate(t.getDate() + 1);
  return t.getTime();
}
function fmtNum(v) { return typeof v === 'number' ? String(v) : '—'; }
async function sendMustRemind(slot) {
  const cfg = await getConfig();
  if (!cfg.enabled || cfg.mustRemindEnabled === false) {
    log.info('MustRemind skipped: disabled');
    return { ok: false, msg: '未启用' };
  }
  if (!cfg.webhook) {
    log.warn('MustRemind skipped: no webhook');
    return { ok: false, msg: '未配置飞书 webhook' };
  }
  const stores = await getStores();
  const names = Object.keys(stores).sort();
  const lines = [
    '**定时必提醒' + (slot ? ' · ' + slot : '') + '**',
    '_存活汇报 + 限流差异（相对上一固定时点）_',
    '',
  ];
  const allDiffItems = []; // { store, item, change } change=added|upgraded|removed
  let anyDiff = false;

  if (!names.length) {
    lines.push('_暂无店铺数据。请打开 goods/list 或点「轮巡所有店」。_');
  } else {
    for (const name of names) {
      const s = stores[name] || {};
      const L = s.latest || {};
      const snap = s.snapshot || {};
      const stale = L.ts && (Date.now() - L.ts > 2 * 60 * 60 * 1000);
      const pool = buildTrafficPool(L);
      const currMap = {};
      for (const it of pool) {
        currMap[String(it.productId)] = {
          severity: it.severity,
          name: it.name,
          skc: it.skc,
          skuCodes: it.skuCodes,
          hotSale: it.hotSale,
          kinds: it.kinds,
          reason: it.reason,
          productId: it.productId,
        };
      }
      const prevMap = snap.slotTrafficMap || {};
      const added = [];
      const upgraded = [];
      const removed = [];
      for (const pid of Object.keys(currMap)) {
        if (!prevMap[pid]) added.push(currMap[pid]);
        else if (prevMap[pid].severity !== 'severe' && currMap[pid].severity === 'severe') {
          upgraded.push(currMap[pid]);
        }
      }
      for (const pid of Object.keys(prevMap)) {
        if (!currMap[pid]) removed.push(Object.assign({ productId: pid }, prevMap[pid]));
      }
      const storeDiff = added.length + upgraded.length + removed.length;
      if (storeDiff) anyDiff = true;

      lines.push('**🏬 ' + name + '**' + (stale ? ' ⚠️数据超过2小时未更新' : ''));
      lines.push(
        '在售 **' + fmtNum(L.onSale) + '**'
        + ' · 待关注 **' + fmtNum(L.trafficWatch) + '**'
        + ' · 下降 **' + fmtNum(L.trafficDecline) + '**'
        + ' · 限流池 **' + pool.length + '**'
        + '（严重 ' + pool.filter((p) => p.severity === 'severe').length
        + ' / 一般 ' + pool.filter((p) => p.severity !== 'severe').length + '）'
      );
      // 差异段（相对上一固定时点）
      if (!Object.keys(prevMap).length) {
        lines.push('_本时点建立限流基准 ' + pool.length + ' 条，不报差异_');
      } else if (!storeDiff) {
        lines.push('_限流无变化_');
      } else {
        if (added.length) {
          lines.push('新增限流 **' + added.length + '**：');
          lines.push(...itemLines(added, added.length));
          for (const it of added) allDiffItems.push({ store: name, item: it, change: 'added' });
        }
        if (upgraded.length) {
          lines.push('升级为严重 **' + upgraded.length + '**：');
          lines.push(...itemLines(upgraded, upgraded.length));
          for (const it of upgraded) allDiffItems.push({ store: name, item: it, change: 'upgraded' });
        }
        if (removed.length) {
          lines.push('解除/不再见 **' + removed.length + '**：');
          for (const it of removed.slice(0, 8)) {
            const nm = String(it.name || it.productId || '').replace(/[[\]]/g, '').slice(0, 28);
            // 解除项尽量保留可点开的历史编辑链（便于复查）
            if (it.productId) {
              lines.push('• ~~[' + nm + '](' + editLink(it.productId) + ')~~  SKC ' + (it.skc || '-'));
            } else {
              lines.push('• ~~' + nm + '~~  SKC ' + (it.skc || '-'));
            }
          }
          if (removed.length > 8) lines.push('_…另有 ' + (removed.length - 8) + ' 条_');
        }
      }
      // 当前仍在限流池的商品：始终列出可点链接（无变化/建基准时以前只写数字）
      if (pool.length) {
        const severeN = pool.filter((p) => p.severity === 'severe').length;
        const generalN = pool.length - severeN;
        lines.push('**当前限流 ' + pool.length + '**（严重 ' + severeN + ' / 一般 ' + generalN + '）：');
        // 最多列 12 条，避免卡片过长；chip 更大时提示
        const show = pool.slice(0, 12);
        lines.push(...itemLines(show, pool.length));
        if (pool.length > 12) {
          lines.push('_…另有 ' + (pool.length - 12) + ' 条未列出；打开 goods/list「商品流量待关注」可看全_');
        }
      } else if (typeof L.trafficWatch === 'number' && L.trafficWatch > 0) {
        lines.push('_待关注 chip=' + L.trafficWatch + ' 但本页未扫到在售限流明细（请打开该店 goods/list 或点轮巡）_');
      }
      lines.push('上次检查：' + (L.ts ? new Date(L.ts).toLocaleString('zh-CN') : '—'));
      lines.push('');

      // 写回 slotTrafficMap（走串行队列，避免盖掉即时告警的 alertedTrafficIds）
      await updateStoreSnapshot(name, { slotTrafficMap: currMap, slotTrafficMapTs: Date.now() });
    }
  }

  const lastCycle = (await chrome.storage.local.get('lastCycle')).lastCycle;
  if (lastCycle && lastCycle.ts) {
    lines.push('上次轮巡：' + new Date(lastCycle.ts).toLocaleString('zh-CN'));
  }
  lines.push('_汇报时间：' + new Date().toLocaleString('zh-CN') + '_');

  // 有差异用橙/红，无差异用蓝存活
  const hasSevereDiff = allDiffItems.some((d) => d.item && d.item.severity === 'severe');
  const template = anyDiff ? (hasSevereDiff ? 'red' : 'orange') : 'blue';
  const title = anyDiff
    ? ('🔔 Temu 限流定点汇总' + (slot ? ' · ' + slot : ''))
    : ('📋 Temu 监测定时汇报' + (slot ? ' · ' + slot : ''));
  const r = await sendFeishu(cfg.webhook, title, lines, template);

  // 差异条目同步多维表 + 严重任务
  if (anyDiff && typeof FeishuApp !== 'undefined') {
    const byStore = {};
    for (const d of allDiffItems) {
      if (d.change === 'removed') continue;
      if (!byStore[d.store]) byStore[d.store] = [];
      byStore[d.store].push(d.item);
    }
    for (const storeName of Object.keys(byStore)) {
      try {
        await FeishuApp.syncAfterAlert(cfg, storeName, byStore[storeName]);
      } catch (e) {
        log.warn('MustRemind FeishuApp: ' + ((e && e.message) || e));
      }
    }
  }

  await chrome.storage.local.set({
    lastMustRemind: {
      ts: Date.now(), ok: r.ok, msg: r.msg, slot: slot || '',
      anyDiff: anyDiff, diffCount: allDiffItems.length,
    },
  });
  log.info('MustRemind done: slot=' + (slot || '') + ' ok=' + r.ok + ' anyDiff=' + anyDiff);
  return r;
}
async function setupMustRemindAlarms() {
  const all = await chrome.alarms.getAll();
  for (const a of all) {
    if (a.name.startsWith(MUST_REMIND_PREFIX)) await chrome.alarms.clear(a.name);
  }
  const cfg = await getConfig();
  if (cfg.mustRemindEnabled === false) {
    log.info('MustRemind alarms cleared (disabled)');
    return;
  }
  const raw = Array.isArray(cfg.mustRemindTimes) && cfg.mustRemindTimes.length
    ? cfg.mustRemindTimes
    : DEFAULT_CONFIG.mustRemindTimes;
  const seen = {};
  for (const t of raw) {
    const p = parseHHMM(t);
    if (!p || seen[p.label]) continue;
    seen[p.label] = true;
    const when = nextWhen(p.label);
    if (!when) continue;
    chrome.alarms.create(MUST_REMIND_PREFIX + p.label, { when });
    log.info('MustRemind alarm set: ' + p.label + ' → ' + new Date(when).toLocaleString('zh-CN'));
  }
}

// ---------------- 商品明细 → 带链接的告警行 ----------------
// 后台商品操作都是弹窗、无深链，唯一稳定可点的是编辑页（实测格式：SPU ID 即 productId）。
function editLink(productId) {
  return 'https://agentseller.temu.com/goods/edit?from=productList&productId=' + productId;
}

// v16：限流分级
// 严重：SKU货号 VIP*（自有） 或 （JM* 且 热销款=黑猫）
// 一般：有限流但不满足严重
function classifySeverity(item) {
  const codes = Array.isArray(item && item.skuCodes) ? item.skuCodes : [];
  const hot = !!(item && item.hotSale);
  let hasVip = false;
  let hasJm = false;
  for (const c of codes) {
    const s = String(c || '').trim();
    if (/^VIP/i.test(s)) hasVip = true;
    if (/^JM/i.test(s)) hasJm = true;
  }
  if (hasVip) return { severity: 'severe', reason: '自有VIP' };
  if (hasJm && hot) return { severity: 'severe', reason: '黑猫JM+热销款' };
  return { severity: 'general', reason: '其它限流' };
}

function mergeSkuCodes() {
  const out = [];
  const seen = {};
  for (let i = 0; i < arguments.length; i++) {
    const arr = arguments[i];
    if (!Array.isArray(arr)) continue;
    for (const c of arr) {
      const s = String(c || '').trim();
      if (!s) continue;
      const k = s.toUpperCase();
      if (seen[k]) continue;
      seen[k] = true;
      out.push(s);
    }
  }
  return out;
}

// 用 pageQuery 缓存的 extCode 补全 DOM 条目的货号
function enrichWithPageCodes(items, productSkuCodeMap) {
  const map = productSkuCodeMap || {};
  return (items || []).map((it) => {
    if (!it) return it;
    const fromPage = map[String(it.productId)] || [];
    return Object.assign({}, it, {
      skuCodes: mergeSkuCodes(it.skuCodes, fromPage),
    });
  });
}

function buildProductSkuCodeMap(pageProducts) {
  const map = {};
  for (const p of pageProducts || []) {
    if (!p || !p.productId) continue;
    map[String(p.productId)] = Array.isArray(p.skuCodes) ? p.skuCodes.slice() : [];
  }
  return map;
}

// 合并 watch + decline 为在售限流池，附 kinds / severity
function buildTrafficPool(latest) {
  const byId = {};
  const codeMap = latest && latest.productSkuCodeMap ? latest.productSkuCodeMap : {};
  const absorb = (list, kind) => {
    for (const raw of list || []) {
      if (!raw || !raw.productId) continue;
      if (raw.saleStatus === 'removed') continue;
      // 被动扫要求 onSale；主动扫已标 onSale
      if (raw.saleStatus && raw.saleStatus !== 'onSale' && raw.saleStatus !== 'unknown') continue;
      const pid = String(raw.productId);
      const prev = byId[pid] || {
        productId: pid,
        name: raw.name || '',
        skc: raw.skc || '',
        skuCodes: [],
        hotSale: false,
        kinds: [],
        saleStatus: raw.saleStatus || 'onSale',
      };
      prev.name = raw.name || prev.name;
      prev.skc = raw.skc || prev.skc;
      prev.skuCodes = mergeSkuCodes(prev.skuCodes, raw.skuCodes, codeMap[pid]);
      prev.hotSale = prev.hotSale || !!raw.hotSale;
      if (prev.kinds.indexOf(kind) < 0) prev.kinds.push(kind);
      if (raw.saleStatus === 'onSale') prev.saleStatus = 'onSale';
      byId[pid] = prev;
    }
  };
  absorb(latest && latest.watchItems, 'watch');
  absorb(latest && latest.declineItems, 'decline');
  const pool = [];
  for (const pid of Object.keys(byId)) {
    const it = byId[pid];
    // unknown 且无任何限流 kind 不应出现；有 kind 则保留（主动扫可能 unknown→已标 onSale）
    if (it.saleStatus === 'removed') continue;
    if (it.saleStatus === 'unknown' && !(it.kinds && it.kinds.length)) continue;
    // 严格：被动 unknown 可能是下架误读——若只有 decline/watch 但 status unknown，仍排除
    // 例外：主动 scan 已写 onSale
    if (it.saleStatus !== 'onSale') continue;
    const cls = classifySeverity(it);
    it.severity = cls.severity;
    it.reason = cls.reason;
    pool.push(it);
  }
  // 严重优先
  pool.sort((a, b) => {
    if (a.severity !== b.severity) return a.severity === 'severe' ? -1 : 1;
    return String(a.name || '').localeCompare(String(b.name || ''), 'zh');
  });
  return pool;
}

// items：限流商品；带 severity 时行首加红/橙标记
function itemLines(items, total) {
  const lines = [];
  if (Array.isArray(items) && items.length) {
    for (const it of items) {
      const nm = String(it.name || '商品').replace(/[[\]]/g, '').slice(0, 28);
      const sev = it.severity === 'severe' ? '🔴' : (it.severity === 'general' ? '🟠' : '•');
      const codeStr = (it.skuCodes && it.skuCodes.length)
        ? '  货号 ' + it.skuCodes.slice(0, 3).join('/')
        : '';
      const reason = it.reason ? '  _' + it.reason + '_' : '';
      const hot = it.hotSale ? ' 🔥' : '';
      lines.push(sev + ' [' + nm + '](' + editLink(it.productId) + ')  SKC ' + (it.skc || '-') + codeStr + hot + reason);
    }
    if (typeof total === 'number' && total > items.length) {
      lines.push('_（本页可见 ' + items.length + ' 条，共 ' + total + ' 条，其余在其它页；点「商品流量待关注」筛选可看全）_');
    }
  } else if (typeof total === 'number' && total > 0) {
    lines.push('_（当前页未显示具体商品，共 ' + total + ' 条；打开「商品流量待关注」筛选可查看）_');
  }
  return lines;
}

// 让 content.js 主动点「商品流量待关注」筛选，捞出这几条被限流的具体商品（productId+name+skc）
async function scanWatchViaTab() {
  const tab = await getGoodsTab();
  if (!tab) return null;
  return await sendTabRetry(tab.id, { cmd: 'scanWatchList' }, 3);
}

// v21：合并限流明细。
// - 被动扫只见当前页徽标（常 1~2 条），绝不能把已有 3 条清单砍成 1 条。
// - trusted 主动扫（筛选真正收窄）可以整体替换（以筛选结果为准）。
// - 不可信/短清单：只并入新 ID，保留旧条目。
function mergeWatchItemLists(prev, next, opts) {
  opts = opts || {};
  const trustedReplace = !!opts.trustedReplace;
  const prevArr = Array.isArray(prev) ? prev : [];
  const nextArr = Array.isArray(next) ? next : [];
  if (!nextArr.length) return prevArr.slice();
  if (trustedReplace) {
    // 可信全量：以 next 为准，但仍并入 next 没有、prev 有且 chip 未降到 0 时？
    // 可信筛选视图 = 当前在售待关注全集 → 直接用 next。
    return nextArr.slice();
  }
  // 默认：按 productId 合并，next 覆盖同 ID 字段，prev 多出的保留
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
      skuCodes: mergeSkuCodes(old.skuCodes, it.skuCodes),
      hotSale: !!(old.hotSale || it.hotSale),
      saleStatus: it.saleStatus === 'onSale' ? 'onSale' : (old.saleStatus || it.saleStatus || 'onSale'),
    });
  }
  return Object.keys(byId).map((k) => byId[k]);
}

// 主动扫结果是否可作为「权威限流清单」写入（seed / 替换 watchItems）
function isTrustedWatchScan(scan) {
  if (!scan || !scan.applied || !Array.isArray(scan.items) || !scan.items.length) return false;
  // content v21 显式 trusted；旧版无该字段时用规模护栏兜底
  if (scan.trusted === false) return false;
  if (scan.trusted === true) return true;
  const n = scan.items.length;
  const chip = typeof scan.chipCount === 'number' ? scan.chipCount
    : (typeof scan.chipTotal === 'number' ? scan.chipTotal : null);
  const onSale = typeof scan.onSaleTabCount === 'number' ? scan.onSaleTabCount : null;
  // 明细 ≈ 在售全集 且 chip 明显更小 → 假全量
  if (onSale != null && onSale > 0 && n >= onSale && chip != null && chip < onSale) return false;
  if (chip != null && chip >= 0 && n > chip + 1) return false;
  return true;
}

// chip 显示 N 条待关注，但 pool 明细对不齐时需要补扫（不要求 chip 相对高水位上升）
// v22.1：chip 含已下架商品，on-sale pool < chip 是常态（Twilight chip=3 / 在售池=2）。
//   pool<chip 只有在「尚未拿到可信全量」时才补扫；已 trusted 就不再空转（否则 90s 一次、
//   每次点 chip 干扰轮巡）。pool>chip+1 才是真多计，始终收缩。
function needsWatchRescan(latest, poolLen, trusted) {
  const chip = typeof latest.trafficWatch === 'number' ? latest.trafficWatch : 0;
  if (chip < 0) return false;
  const have = typeof poolLen === 'number' ? poolLen
    : (Array.isArray(latest.watchItems) ? latest.watchItems.length : 0);
  if (chip === 0) return have > 0; // chip 清零仍留着旧明细 → 扫一次确认清空
  if (have > chip + 1) return true; // 多计（历史 merge 残留 / 假全量）→ 收缩
  if (!trusted && have < chip) return true; // 被动徽标可能不全 → 补一次可信全量
  return false;
}

// 补扫冷却：筛选失败时避免每 2s chipStats 都点一次待关注 chip
const WATCH_RESCAN_COOLDOWN_MS = 90 * 1000;
const watchRescanAt = {}; // storeName → ts

// ---------------- 对比 & 告警（按店） ----------------
// 按店串行：同一店的多条读数消息（切店时常一秒内来两条）排队逐个处理，
// 避免"都读到旧快照各报一次"的竞态导致同一事件重复告警。
const alertChains = {};
// v15：同一商品冷却期内不重复告警。切店/翻页会让「本页可见 decline 数」在 0↔1 抖动，
// 旧版按计数上升触发 → 一切店就再推一次。改成按 productId 去重。
const ALERT_COOLDOWN_MS = 6 * 60 * 60 * 1000; // 6 小时
function pruneAlertedMap(map, now) {
  const out = {};
  const keepFor = ALERT_COOLDOWN_MS * 4; // 保留 24h 历史，便于排障
  for (const id of Object.keys(map || {})) {
    const ts = map[id];
    if (typeof ts === 'number' && now - ts < keepFor) out[id] = ts;
  }
  return out;
}
// 从 items 里挑出冷却期外、尚未报过的新 productId
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
function diffAndAlert(name) {
  const prev = alertChains[name] || Promise.resolve();
  const next = prev.then(() => _diffAndAlert(name)).catch(() => {});
  alertChains[name] = next;
  return next;
}

async function _diffAndAlert(name) {
  const cfg = await getConfig();
  if (!cfg.enabled) return;

  // 先在串行锁外做主动扫（可能点 tab，耗时长），避免长时间占住 stores 队列。
  // v18：用「高水位」判断是否真增长，避免 snap 被切店瞬时 0 污染后 0→N 误触发全量扫+告警。
  // v21：chip 未升高但 pool 明细 < chip 时也补扫（修限流池少计；不发飞书，只补名单）。
  let preScanItems = null;
  let preScanTrusted = false;
  {
    const storesPeek = await getStores();
    const sPeek = storesPeek[name];
    if (!sPeek) return;
    const latestPeek = sPeek.latest || {};
    const snapPeek = sPeek.snapshot || {};
    const highPeek = Math.max(
      typeof snapPeek.trafficWatchHigh === 'number' ? snapPeek.trafficWatchHigh : 0,
      typeof snapPeek.trafficWatch === 'number' ? snapPeek.trafficWatch : 0
    );
    const watchNow = typeof latestPeek.trafficWatch === 'number' ? latestPeek.trafficWatch : 0;
    const poolPeekLen = buildTrafficPool(latestPeek).length;
    const chipUp = watchNow > highPeek && watchNow > 0;
    const needFill = needsWatchRescan(latestPeek, poolPeekLen, !!snapPeek.trafficScanTrusted);
    const lastRescan = watchRescanAt[name] || 0;
    const cooled = Date.now() - lastRescan >= WATCH_RESCAN_COOLDOWN_MS;
    // chip 真升高：立即扫（不受补扫冷却限制）；仅 pool 补扫：走 90s 冷却且轮巡中不扫
    // （轮巡切店时点 chip 会污染 countStatus、拖累 waitForStoreCapture → 整店 B 扫描被跳）
    const shouldScan = chipUp || (needFill && cooled && !cycling);
    if (needFill && !chipUp && (!cooled || cycling)) {
      log.info('scanWatchViaTab skip: store=' + name
        + ' pool=' + poolPeekLen + ' chip=' + watchNow
        + (cycling ? ' cycling=1' : ' leftMs=' + (WATCH_RESCAN_COOLDOWN_MS - (Date.now() - lastRescan))));
    }
    if (shouldScan) {
      watchRescanAt[name] = Date.now();
      log.info('scanWatchViaTab trigger: store=' + name
        + ' chip=' + watchNow + ' high=' + highPeek
        + ' pool=' + poolPeekLen + ' reason=' + (chipUp ? 'chip-up' : 'pool-short'));
      const scan = await scanWatchViaTab();
      if (scan && scan.applied && Array.isArray(scan.items) && scan.items.length) {
        const scanStore = scan.store ? String(scan.store).trim() : '';
        if (!scanStore || scanStore === name) {
          if (isTrustedWatchScan(scan)) {
            preScanItems = scan.items;
            // 规模与 chip 对齐才允许整体替换（收缩假全量 / 对齐少计）
            preScanTrusted = scan.trusted === true && (
              typeof scan.chipCount !== 'number'
              || scan.items.length <= scan.chipCount + 1
            );
          } else {
            log.warn('scanWatchViaTab rejected untrusted: store=' + name
              + ' items=' + scan.items.length
              + ' reason=' + (scan.trustReason || 'untrusted')
              + ' chip=' + (scan.chipCount != null ? scan.chipCount : 'null')
              + ' onSale=' + (scan.onSaleTabCount != null ? scan.onSaleTabCount : 'null'));
            // 不可信时若带徽标降级明细，仍可 merge 进 pool（不替换、不 seed 全量）
            if (scan.trustReason === 'badge-fallback' || scan.trusted === false) {
              preScanItems = scan.items;
              preScanTrusted = false;
            }
          }
        } else {
          log.warn('scanWatchViaTab store mismatch: want=' + name + ' got=' + scanStore);
        }
      } else if (scan && scan.applied === false) {
        log.info('scanWatchViaTab not applied: store=' + name
          + ' reason=' + (scan.trustReason || scan.msg || 'n/a'));
      }
    }
  }

  // 读 latest + 判定 + 写 snapshot 整段串行，杜绝与 updateStoreLatest 交叉覆盖
  const result = await withStores(async () => {
    const stores = await getStores();
    const s = stores[name];
    if (!s) return null;
    let latest = s.latest || {};
    const snap = s.snapshot || {};
    const now = Date.now();
    // v19.4：本店 alerted 与全局冷却分离。
    //  - storeAlerted：只含本店 snapshot 里的 ID，写回本店，决定「是否已 seed」
    //  - globalAlerted：跨店/快照丢失兜底，只参与 pickFresh 冷却，绝不整表灌进本店
    // 历史 bug：Object.assign(global, store) 写回 → 新店 pool 空时 alerted 非空，
    // 被 hasTrafficBaseline 当成已就绪，首轮 15 条全推（HomeCove）。
    let globalAlerted = pruneAlertedMap(await getGlobalAlerted(), now);
    let storeAlerted = pruneAlertedMap(
      Object.assign({}, snap.alertedWatchIds || {}, snap.alertedDeclineIds || {}, snap.alertedTrafficIds || {}),
      now
    );
    // pickFresh 用的合并视图（读路径）；写回本店只用 storeAlerted
    const cooldownView = () => Object.assign({}, globalAlerted, storeAlerted);

    // 在售数量下降：v14 起关闭
    // ---- 限流池（在售 ∩ 待关注/下降）分级 ----
    const prevHigh = Math.max(
      typeof snap.trafficWatchHigh === 'number' ? snap.trafficWatchHigh : 0,
      typeof snap.trafficWatch === 'number' ? snap.trafficWatch : 0
    );
    const curWatch = typeof latest.trafficWatch === 'number' ? latest.trafficWatch : null;
    // 真增长：当前 chip 高于历史高水位（不是相对瞬时 snap）
    const chipReallyUp = curWatch != null && curWatch > prevHigh;

    // 合并主动扫明细进 latest（同一锁内写回，防止丢失）
    // v21：可信筛选结果可替换；否则只增不减，避免 12 条假 seed 后被 1 条被动徽标砍光
    if (preScanItems && preScanItems.length) {
      const merged = mergeWatchItemLists(latest.watchItems, preScanItems, {
        trustedReplace: preScanTrusted,
      });
      const prevN = Array.isArray(latest.watchItems) ? latest.watchItems.length : 0;
      latest = Object.assign({}, latest, { watchItems: merged, ts: Date.now() });
      s.latest = latest;
      log.info('Watch items merged: store=' + name
        + ' prev=' + prevN
        + ' next=' + preScanItems.length
        + ' merged=' + merged.length
        + ' trusted=' + preScanTrusted);
    }

    const pool = buildTrafficPool(latest);
    const baselineReady = hasTrafficBaseline(snap);

    let fresh = [];
    let seeded = false;
    let silenced = 0;
    if (!baselineReady) {
      // 首次只 seed 不告警。pool 为空时不建基线、不写 trafficBaselineAt。
      // v21：若本轮只有不可信 dump（pool 被假 12 条撑满）不应发生——上游已拒；
      // 仍要求 pool 与 chip 大致同阶，防止漏网 seed 把全店标 alerted。
      const chipForSeed = typeof latest.trafficWatch === 'number' ? latest.trafficWatch : null;
      const seedLooksLikeFullOnsale = chipForSeed != null && chipForSeed > 0
        && pool.length >= Math.max(chipForSeed * 2, chipForSeed + 3);
      if (pool.length > 0 && !seedLooksLikeFullOnsale) {
        storeAlerted = markAlerted(storeAlerted, pool, now);
        globalAlerted = markAlerted(globalAlerted, pool, now);
        seeded = true;
        log.info('Traffic baseline seeded: store=' + name + ' known=' + Object.keys(storeAlerted).length
          + ' pool=' + pool.length);
      } else if (pool.length > 0 && seedLooksLikeFullOnsale) {
        log.warn('Traffic baseline seed refused (pool≫chip): store=' + name
          + ' pool=' + pool.length + ' chip=' + chipForSeed);
      } else {
        log.info('Traffic baseline deferred: store=' + name + ' pool empty (wait items)');
      }
    } else {
      // 候选 = 店内+全局冷却都未报过的
      fresh = pickFreshItems(pool, cooldownView(), now);
      // 冷却内但等级从 general→severe 的，也要再报一次（升级）——升级不受 chip 限制
      const upgrades = [];
      for (const it of pool) {
        if (!it || it.severity !== 'severe') continue;
        const pid = String(it.productId);
        if (fresh.some((f) => String(f.productId) === pid)) continue;
        if (upgrades.some((f) => String(f.productId) === pid)) continue;
        const prevSev = (snap.trafficSeverityMap && snap.trafficSeverityMap[pid]) || '';
        if (prevSev && prevSev !== 'severe') upgrades.push(it);
      }

      if (fresh.length && !chipReallyUp) {
        // v18 核心：切店/翻页/回到某店时，本页第一次扫到的限流 ID 可能不在 alerted 里，
        // 但 chip 并没有比历史高水位更高 → 只是「看见」，不是「新增」。静默吸收，不发飞书。
        silenced = fresh.length;
        log.info('Silent absorb (no chip rise): store=' + name
          + ' absorb=' + silenced
          + ' chip=' + (curWatch != null ? curWatch : 'null')
          + ' high=' + prevHigh
          + ' pool=' + pool.length);
        storeAlerted = markAlerted(storeAlerted, fresh, now);
        globalAlerted = markAlerted(globalAlerted, fresh, now);
        fresh = [];
      }

      if (upgrades.length) {
        for (const it of upgrades) fresh.push(it);
      }

      if (fresh.length) {
        storeAlerted = markAlerted(storeAlerted, fresh, now);
        globalAlerted = markAlerted(globalAlerted, fresh, now);
      } else if (chipReallyUp && !silenced) {
        log.info('Watch chip rose but no fresh traffic items: store=' + name
          + ' high=' + prevHigh + '→' + curWatch + ' pool=' + pool.length);
      }

      // 无论是否告警，本轮见过的 pool 都写入 alerted，避免下轮再当新
      if (pool.length) {
        storeAlerted = markAlerted(storeAlerted, pool, now);
        globalAlerted = markAlerted(globalAlerted, pool, now);
      }
    }

    // 写回快照（同一锁内）
    const newSnap = Object.assign({}, snap);
    if (typeof latest.onSale === 'number') newSnap.onSale = latest.onSale;
    if (typeof latest.total === 'number') newSnap.total = latest.total;
    // v18：chip 快照禁止被瞬时低值拉低（切店 loading 常读到 0 → 下次 0→N 误报）
    if (typeof latest.trafficWatch === 'number') {
      const prevW = typeof newSnap.trafficWatch === 'number' ? newSnap.trafficWatch : null;
      if (prevW == null) {
        newSnap.trafficWatch = latest.trafficWatch;
      } else if (latest.trafficWatch >= prevW) {
        newSnap.trafficWatch = latest.trafficWatch;
      } else if (latest.trafficWatch === 0) {
        log.info('Ignore transient chip=0: store=' + name + ' keep snap.trafficWatch=' + prevW);
      } else {
        // 非 0 的下降：可能是真解除部分限流，允许下调 display；高水位另计
        newSnap.trafficWatch = latest.trafficWatch;
      }
    }
    if (typeof latest.trafficDecline === 'number') {
      const prevD = typeof newSnap.trafficDecline === 'number' ? newSnap.trafficDecline : null;
      if (prevD == null || latest.trafficDecline > 0 || latest.trafficDecline >= prevD) {
        newSnap.trafficDecline = latest.trafficDecline;
      }
    }
    // 高水位：只升不降（用于判断「是否真有新增限流」）
    const highNext = Math.max(
      prevHigh,
      typeof latest.trafficWatch === 'number' ? latest.trafficWatch : 0,
      typeof newSnap.trafficWatch === 'number' ? newSnap.trafficWatch : 0
    );
    newSnap.trafficWatchHigh = highNext;

    // 只写本店见过的 ID；全局冷却单独存 trafficAlertedGlobal
    newSnap.alertedTrafficIds = storeAlerted;
    newSnap.alertedWatchIds = storeAlerted;
    newSnap.alertedDeclineIds = storeAlerted;
    // v22.1：本轮拿到可信全量（list-narrowed）→ 标记，供 needsWatchRescan 判断是否还需补扫
    if (preScanTrusted) newSnap.trafficScanTrusted = true;
    // 仅正式 seed 时打戳；pool 空 / 仅全局污染 绝不动 trafficBaselineAt
    if (seeded) newSnap.trafficBaselineAt = now;
    const sevMap = Object.assign({}, newSnap.trafficSeverityMap || {});
    for (const it of pool) {
      if (it && it.productId) sevMap[String(it.productId)] = it.severity;
    }
    newSnap.trafficSeverityMap = sevMap;
    newSnap.ts = Date.now();
    s.snapshot = newSnap;
    s.latest = latest;
    stores[name] = s;
    await saveStores(stores);
    await saveGlobalAlerted(globalAlerted);
    log.info('Snapshot updated: store=' + name
      + ' alerted=' + Object.keys(storeAlerted).length
      + ' pool=' + pool.length
      + ' fresh=' + fresh.length
      + ' silent=' + silenced
      + ' chipUp=' + chipReallyUp
      + ' high=' + highNext
      + ' baseline=' + (baselineReady || seeded));
    return { fresh: fresh.slice(), chipReallyUp: chipReallyUp, poolSize: pool.length, silenced: silenced };
  });

  if (!result || !result.fresh || !result.fresh.length) return;

  const fresh = result.fresh;
  const severe = fresh.filter((i) => i.severity === 'severe');
  const general = fresh.filter((i) => i.severity !== 'severe');
  const lines = ['**🏬 ' + name + '**'];
  if (severe.length) {
    lines.push('**🔴 严重限流 ' + severe.length + ' 个**（自有VIP / 黑猫JM+热销款）');
    lines.push(...itemLines(severe, severe.length));
  }
  if (general.length) {
    lines.push('**🟠 一般限流 ' + general.length + ' 个**');
    lines.push(...itemLines(general, general.length));
  }
  lines.push('', '_检查时间：' + new Date().toLocaleString('zh-CN') + '_');
  const template = severe.length ? 'red' : 'orange';
  log.info('Alert triggered: store=' + name + ' severe=' + severe.length + ' general=' + general.length);
  const r = await sendFeishu(cfg.webhook, '🔔 Temu 限流告警', lines, template);
  await chrome.storage.local.set({
    lastAlert: { ts: Date.now(), ok: r.ok, msg: r.msg, store: name, lines, severe: severe.length, general: general.length },
  });
  try {
    if (typeof FeishuApp !== 'undefined') {
      await FeishuApp.syncAfterAlert(cfg, name, fresh);
    }
  } catch (e) {
    log.warn('FeishuApp sync: ' + ((e && e.message) || e));
  }
}

// pageQuery 同商品 SKU 消失检测。
// 只对比「本轮 pageQuery 里再次出现的 productId」——当前页以外的商品本轮没看到，绝不判下架。
// 首轮只建 snapshot.productSkuMap，不告警。
async function diffProductSkus(name, products) {
  if (!Array.isArray(products) || !products.length) return 0;
  const cfg = await getConfig();
  const stores = await getStores();
  const s = stores[name] || { latest: {}, snapshot: {} };
  const prevMap = (s.snapshot && s.snapshot.productSkuMap) || {};
  const nextMap = Object.assign({}, prevMap);
  const removed = []; // { productId, productName, skc, skuId, name }
  let compared = 0;

  for (const p of products) {
    if (!p || !p.productId) continue;
    const pid = String(p.productId);
    const currSkus = Array.isArray(p.skus) ? p.skus : [];
    // 当前商品在本页出现但 SKU 列表空：可能接口字段漂移/截断，跳过该商品、保留旧基准
    if (!currSkus.length) continue;
    const currById = {};
    for (const sk of currSkus) {
      if (sk && sk.skuId) currById[String(sk.skuId)] = sk;
    }
    const prev = prevMap[pid];
    if (prev && prev.skus && typeof prev.skus === 'object') {
      compared += 1;
      for (const skuId of Object.keys(prev.skus)) {
        if (!currById[skuId]) {
          const old = prev.skus[skuId] || {};
          removed.push({
            productId: pid,
            productName: p.name || prev.name || '',
            skc: p.skc || prev.skc || '',
            skuId,
            name: old.name || skuId,
          });
        }
      }
    }
    // 更新该 product 的 SKU 基准（只记 id→name）
    const skusObj = {};
    for (const sk of currSkus) {
      if (sk && sk.skuId) skusObj[String(sk.skuId)] = { name: sk.name || '', img: sk.img || '' };
    }
    nextMap[pid] = {
      name: p.name || (prev && prev.name) || '',
      skc: p.skc || (prev && prev.skc) || '',
      skus: skusObj,
      ts: Date.now(),
    };
  }

  // 写回快照（合并式：本页商品更新，其它页旧基准保留；串行避免盖掉 alerted）
  await updateStoreSnapshot(name, { productSkuMap: nextMap });

  if (!removed.length) {
    if (compared) log.info('diffProductSkus: store=' + name + ' compared=' + compared + ' removed=0');
    return 0;
  }

  log.info('diffProductSkus: store=' + name + ' compared=' + compared + ' removed=' + removed.length);
  if (!cfg.enabled) return removed.length;

  const lines = [
    '**🏬 ' + name + '**',
    '📦 后台检测到 SKU 规格消失 **' + removed.length + '** 个（同商品内对比，非整 SKC 下架）',
    '',
  ];
  // 按商品分组展示
  const byProduct = {};
  for (const r of removed) {
    const k = r.productId;
    if (!byProduct[k]) byProduct[k] = { productId: k, productName: r.productName, skc: r.skc, skus: [] };
    byProduct[k].skus.push(r);
  }
  for (const g of Object.values(byProduct)) {
    const nm = String(g.productName || '商品').replace(/[[\]]/g, '').slice(0, 30);
    lines.push('• [' + nm + '](' + editLink(g.productId) + ')' + (g.skc ? '  SKC ' + g.skc : ''));
    for (const sk of g.skus) {
      lines.push('   ❌ ' + (sk.name || sk.skuId) + '  (skuId ' + sk.skuId + ')');
    }
  }
  lines.push('');
  lines.push('_说明：对比来源 = 商品列表 pageQuery 的 productSkuSummaries；仅对「本页再次出现的商品」做 SKU 集合 diff，避免分页误报。_');
  lines.push('_检查时间：' + new Date().toLocaleString('zh-CN') + '_');
  const fr = await sendFeishu(cfg.webhook, '🔔 Temu SKU 规格消失', lines, 'orange');
  await chrome.storage.local.set({
    lastAlert: { ts: Date.now(), ok: fr.ok, msg: fr.msg, store: name, kind: 'skuRemoved', lines },
  });
  return removed.length;
}

// ---------------- 库存变零 ----------------
// 对每页 pageQuery 的 SKU，对比其 stock（normalizeSku 的 realStock ?: virtualStock）：
// 前一次 >0、本次 ==0 才算「变零」，发飞书。首轮只 seed 基准不发卡（与 diffProductSkus 一致）。
// stock 为 null（未知）不参与：避免不可靠数据误报；只对「本页再次出现的商品」对比，避免分页误报。
async function diffProductStocks(name, products) {
  if (!Array.isArray(products) || !products.length) return 0;
  const cfg = await getConfig();
  const stores = await getStores();
  const s = stores[name] || { latest: {}, snapshot: {} };
  const prevMap = (s.snapshot && s.snapshot.productStockMap) || {};
  const nextMap = Object.assign({}, prevMap);
  const zeroed = []; // { productId, productName, skc, skuId, name, prevStock }

  for (const p of products) {
    if (!p || !p.productId) continue;
    const pid = String(p.productId);
    const currSkus = Array.isArray(p.skus) ? p.skus : [];
    // 本页商品 SKU 列表空：可能接口字段漂移/截断，跳过该商品、保留旧基准
    if (!currSkus.length) continue;
    const prev = prevMap[pid];
    const skusObj = {};
    for (const sk of currSkus) {
      if (!sk || !sk.skuId) continue;
      const skuId = String(sk.skuId);
      skusObj[skuId] = { name: sk.name || '', stock: sk.stock, img: sk.img || '' };
      const prevSk = prev && prev.skus && prev.skus[skuId];
      // 前次已知 >0，本次 ==0 → 真「变零」；前次 null 或无基准（首见）不判
      if (
        prevSk && typeof prevSk.stock === 'number' && prevSk.stock > 0
        && typeof sk.stock === 'number' && sk.stock === 0
      ) {
        zeroed.push({
          productId: pid,
          productName: p.name || prev.name || '',
          skc: p.skc || prev.skc || '',
          skuId,
          name: sk.name || prevSk.name || skuId,
          prevStock: prevSk.stock,
        });
      }
    }
    nextMap[pid] = {
      name: p.name || (prev && prev.name) || '',
      skc: p.skc || (prev && prev.skc) || '',
      skus: skusObj,
      ts: Date.now(),
    };
  }

  // 写回基准（合并式：本页商品更新，其它页旧基准保留；串行避免盖掉其它 snapshot 字段）
  await updateStoreSnapshot(name, { productStockMap: nextMap });

  if (!zeroed.length) return 0;
  log.info('diffProductStocks: store=' + name + ' products=' + products.length + ' zeroed=' + zeroed.length);

  // 全账号 skuId 冷却：同一 SKU 反复 0↔正 不要每次都刷屏
  const coolKey = 'stockZeroAlertedGlobal';
  const { [coolKey]: coolMap0 = {} } = await chrome.storage.local.get(coolKey);
  const now = Date.now();
  const { fresh, blocked } = filterByCooldown(zeroed.map((z) => z.skuId), coolMap0, now, ONSALE_ID_COOLDOWN_MS);
  if (blocked.length) log.info('diffProductStocks: cooldown-blocked=' + blocked.length);
  if (!fresh.length) return 0;
  const coolNext = Object.assign({}, coolMap0);
  for (const id of fresh) coolNext[id] = now;
  await chrome.storage.local.set({ [coolKey]: coolNext });

  if (!cfg.enabled) return fresh.length;

  // 按商品分组展示
  const freshSet = new Set(fresh);
  const byProduct = {};
  for (const r of zeroed) {
    if (!freshSet.has(r.skuId)) continue;
    const k = r.productId;
    if (!byProduct[k]) byProduct[k] = { productId: k, productName: r.productName, skc: r.skc, skus: [] };
    byProduct[k].skus.push(r);
  }
  const lines = [
    '**🏬 ' + name + '**',
    '📦 后台检测到库存变零 SKU **' + fresh.length + '** 个（前次 >0 → 本次 0）',
    '',
  ];
  for (const g of Object.values(byProduct)) {
    const nm = String(g.productName || '商品').replace(/[[\]]/g, '').slice(0, 30);
    lines.push('• [' + nm + '](' + editLink(g.productId) + ')' + (g.skc ? '  SKC ' + g.skc : ''));
    for (const sk of g.skus) {
      lines.push('   ⚠️ ' + (sk.name || sk.skuId) + '  (原库存 ' + sk.prevStock + '，skuId ' + sk.skuId + ')');
    }
  }
  lines.push('');
  lines.push('_说明：对比来源 = 商品列表 pageQuery 的 productSkuSummaries 库存（realStock ?: virtualStock）；仅对本页再次出现的商品做比对，避免分页误报。_');
  lines.push('_检查时间：' + new Date().toLocaleString('zh-CN') + '_');
  const fr = await sendFeishu(cfg.webhook, '💰 Temu 商品库存变零', lines, 'orange');
  await chrome.storage.local.set({
    lastAlert: { ts: Date.now(), ok: fr.ok, msg: fr.msg, store: name, kind: 'stockZero', lines },
  });
  return fresh.length;
}

// 在售清单 diff：找出「上一轮在售、这一轮不在」的商品 = 下架/移出在售，带商品名+编辑链接告警。
// items 为 content.js 扫「在售中」tab 得到的当前在售商品(productId+name+skc)。返回下架数量(供日志)。
// scanStore 为扫描瞬间页面实际所在店：与 name 不符 = 切店竞态（这批是别店数据）→ 整轮作废。
// ---------------- 在售 A+B（数量 + 点名；与赛狐双通道用 productId 冷却） ----------------
function pruneTsMap(map, now, ttl) {
  const out = {};
  const m = map && typeof map === 'object' ? map : {};
  for (const k of Object.keys(m)) {
    const t = Number(m[k]);
    if (Number.isFinite(t) && now - t < ttl) out[k] = t;
  }
  return out;
}
async function getOnSaleAlertedGlobal() {
  const { onSaleAlertedGlobal } = await chrome.storage.local.get('onSaleAlertedGlobal');
  return onSaleAlertedGlobal || { delist: {}, onshelf: {}, qty: {} };
}
async function saveOnSaleAlertedGlobal(map) {
  await chrome.storage.local.set({ onSaleAlertedGlobal: map });
}
function filterByCooldown(ids, coolMap, now, ttl) {
  const fresh = [];
  const blocked = [];
  for (const id of ids) {
    const t = coolMap && coolMap[id];
    if (t && now - Number(t) < ttl) blocked.push(id);
    else fresh.push(id);
  }
  return { fresh, blocked };
}
function markCooldown(coolMap, ids, now) {
  const m = Object.assign({}, coolMap || {});
  for (const id of ids) if (id) m[String(id)] = now;
  return m;
}

/**
 * v22：判断 countStatus 的在售数是否像「限流筛选后的子集」而非全店在售。
 * 截图实证：待关注 chip=3 时 tab「在售中 2」；关筛选后「在售中 12」。
 * 形态：onSale 远低于高水位，且 onSale ≤ chip(±1) 或 ≤ 高水位*50%。
 */
function looksLikeWatchFilterSubset(onSale, latest, snap) {
  if (typeof onSale !== 'number' || onSale < 0) return false;
  const high = (typeof snap.onSaleHighWater === 'number' && snap.onSaleHighWater > 0)
    ? snap.onSaleHighWater
    : (typeof snap.onSaleCount === 'number' && snap.onSaleCount > 0 ? snap.onSaleCount : null);
  if (high == null || high < 4) return false;
  if (!(onSale < high && onSale <= Math.floor(high * ONSALE_QTY_BIG_DROP_RATIO))) return false;

  const twCandidates = [
    latest && latest.trafficWatch,
    snap.trafficWatch,
    snap.trafficWatchHigh,
    latest && latest.trafficWatchHigh,
  ].filter((n) => typeof n === 'number' && n >= 0);
  const tw = twCandidates.length ? Math.max.apply(null, twCandidates) : null;

  // 子集常 ≈ 限流 chip（Twilight: 2≈3；HomeCove: 3≈3/6）
  if (tw != null && tw > 0 && onSale <= tw + 1) return true;
  // 无 chip 时：相对高水位腰斩也视为可疑（仍走 bigDrop 确认路径，这里只给调用方提示）
  if (tw == null && onSale <= Math.floor(high * 0.35)) return true;
  return false;
}

/** 从被污染的低基准「恢复」到接近高水位——不应发上升卡 */
function looksLikeSubsetRecovery(prev, next, snap) {
  if (typeof prev !== 'number' || typeof next !== 'number') return false;
  if (!(next > prev)) return false;
  const high = (typeof snap.onSaleHighWater === 'number' && snap.onSaleHighWater > 0)
    ? snap.onSaleHighWater
    : null;
  // prev 是明显缩水；next 回到高水位附近或大幅抬升
  if (high != null && high >= 4) {
    if (prev < high * ONSALE_QTY_BIG_DROP_RATIO && next >= Math.ceil(high * 0.8)) return true;
    if (prev <= Math.floor(high * 0.35) && next >= prev * 2) return true;
  }
  // 无高水位：小→大 且 prev 很小（≤5）next≥prev*3（2→12 / 3→15）
  if (prev > 0 && prev <= 5 && next >= prev * 3 && (next - prev) >= 6) return true;
  return false;
}

/**
 * A：countStatus 在售数量 diff（带防抖确认）。
 * - 首轮只建 onSaleCount 基准
 * - 变化先挂 pendingQty；同一候选值连续命中 ≥2 次且间隔 ≥3s 才确认
 * - 回弹到基准值 → 取消 pending，不告警（修 15→4→15 切店毛刺）
 * - v20：确认后才改基准并发数量卡；**仅 confirmed 才 shouldScan 约 B**
 *   （pending 绝不拉 B——修 HomeCove 毛刺约 B 后筛后 4===4 改基准）
 * - v22：拒绝限流子集写入；子集恢复静默抬基准；silent 不降基准
 * - 返回 { dropped, rose, from, to, shouldScan, pending, confirmed, cancelScan, silentRecover }
 */
async function diffOnSaleCount(name, onSaleCount, opts) {
  if (!ONSALE_MONITOR_IN_PLUGIN || !ONSALE_QTY_ALERT) return null;
  if (typeof onSaleCount !== 'number' || onSaleCount < 0 || !Number.isFinite(onSaleCount)) return null;
  opts = opts || {};
  const silent = !!opts.silent; // 轮巡切店中：只同步基准，不发数量卡

  const cfg = await getConfig();
  if (!cfg.enabled) return null;
  const now = Date.now();

  const decision = await withStores(async () => {
    const stores = await getStores();
    const s = stores[name] || { latest: {}, snapshot: {} };
    const snap = s.snapshot || {};
    const latest = s.latest || {};
    const prev = typeof snap.onSaleCount === 'number' ? snap.onSaleCount : null;
    const highWater = (typeof snap.onSaleHighWater === 'number' && snap.onSaleHighWater > 0)
      ? snap.onSaleHighWater
      : (prev != null ? prev : null);
    let pending = snap.pendingQty && typeof snap.pendingQty === 'object' ? snap.pendingQty : null;
    // pending 超时清掉
    if (pending && pending.firstTs && now - pending.firstTs > ONSALE_QTY_PENDING_TTL_MS) {
      log.info('OnSale qty pending expired: store=' + name + ' cand=' + pending.to);
      pending = null;
    }

    // v22：限流子集读数 → 一律忽略（不降基准、不挂 pending、不发卡）
    if (looksLikeWatchFilterSubset(onSaleCount, latest, snap)) {
      log.info('OnSale count ignored (watch-filter subset): store=' + name
        + ' onSale=' + onSaleCount
        + ' high=' + (highWater != null ? highWater : 'null')
        + ' tw=' + (typeof latest.trafficWatch === 'number' ? latest.trafficWatch : 'null'));
      // 若 pending 正指向该子集候选，一并清掉
      let cancelScan = false;
      if (pending && pending.to === onSaleCount) {
        pending = null;
        cancelScan = true;
        s.snapshot = Object.assign({}, snap, { pendingQty: null });
        stores[name] = s;
        await saveStores(stores);
      }
      return {
        first: false,
        from: prev,
        to: onSaleCount,
        dropped: 0,
        rose: 0,
        shouldScan: false,
        pending: false,
        confirmed: false,
        cancelScan: cancelScan,
        ignoredSubset: true,
      };
    }

    // 轮巡中：静默同步基准，但 v22 禁止把基准往下压（避免筛选/切店中间态写脏）
    if (silent) {
      let nextCount = onSaleCount;
      if (prev != null && onSaleCount < prev) {
        log.info('OnSale silent skip drop: store=' + name + ' keep=' + prev + ' got=' + onSaleCount);
        nextCount = prev;
      }
      const nextHigh = Math.max(
        typeof highWater === 'number' ? highWater : 0,
        typeof nextCount === 'number' ? nextCount : 0
      ) || highWater;
      s.snapshot = Object.assign({}, snap, {
        onSaleCount: nextCount,
        onSaleCountTs: now,
        pendingQty: null,
        onSaleHighWater: nextHigh > 0 ? nextHigh : snap.onSaleHighWater,
      });
      stores[name] = s;
      await saveStores(stores);
      return {
        first: prev == null,
        from: prev,
        to: nextCount,
        dropped: 0,
        rose: 0,
        shouldScan: false,
        pending: false,
        confirmed: false,
        cancelScan: false,
        silent: true,
      };
    }

    // 首轮：只建基准
    if (prev == null) {
      s.snapshot = Object.assign({}, snap, {
        onSaleCount: onSaleCount,
        onSaleCountTs: now,
        pendingQty: null,
        onSaleHighWater: onSaleCount,
      });
      stores[name] = s;
      await saveStores(stores);
      log.info('OnSale count baseline: store=' + name + ' count=' + onSaleCount);
      return {
        first: true, from: null, to: onSaleCount, dropped: 0, rose: 0,
        shouldScan: false, pending: false, confirmed: false, cancelScan: false,
      };
    }

    // 读数回到已确认基准 → 取消 pending（典型切店 15→4→15）
    if (onSaleCount === prev) {
      const hadPending = !!pending;
      if (hadPending) {
        log.info('OnSale qty pending cancelled (rebound): store=' + name
          + ' base=' + prev + ' wasCand=' + pending.to);
      }
      const nextHigh = Math.max(highWater || 0, onSaleCount);
      s.snapshot = Object.assign({}, snap, {
        onSaleCountTs: now,
        pendingQty: null,
        onSaleHighWater: nextHigh > 0 ? nextHigh : snap.onSaleHighWater,
      });
      stores[name] = s;
      await saveStores(stores);
      return {
        first: false, from: prev, to: onSaleCount, dropped: 0, rose: 0,
        shouldScan: false, pending: false, confirmed: false,
        // v20：回弹时取消已约 B（若有历史路径武装了定时器）
        cancelScan: hadPending,
      };
    }

    // v22：从被污染的低基准恢复到全量 → 静默抬基准，不发上升卡、不约 B
    if (looksLikeSubsetRecovery(prev, onSaleCount, Object.assign({}, snap, {
      onSaleHighWater: highWater,
    }))) {
      const nextHigh = Math.max(highWater || 0, onSaleCount);
      s.snapshot = Object.assign({}, snap, {
        onSaleCount: onSaleCount,
        onSaleCountTs: now,
        pendingQty: null,
        onSaleHighWater: nextHigh,
      });
      stores[name] = s;
      await saveStores(stores);
      log.info('OnSale qty silent recover (subset→full): store=' + name
        + ' ' + prev + '→' + onSaleCount + ' high=' + nextHigh);
      return {
        first: false,
        from: prev,
        to: onSaleCount,
        dropped: 0,
        rose: 0, // 对告警层：不算上升
        shouldScan: false,
        pending: false,
        confirmed: false,
        cancelScan: true,
        silentRecover: true,
      };
    }

    // 候选变化：开启 / 刷新 pending
    const sameCand = pending && pending.to === onSaleCount;
    let nextPending;
    if (sameCand) {
      nextPending = {
        from: prev,
        to: onSaleCount,
        firstTs: pending.firstTs || now,
        lastTs: now,
        hits: (pending.hits || 1) + 1,
      };
    } else {
      // 新候选（含从 4 改成别的）：重新计 hits
      if (pending) {
        log.info('OnSale qty pending retarget: store=' + name
          + ' oldCand=' + pending.to + ' newCand=' + onSaleCount + ' base=' + prev);
      }
      nextPending = {
        from: prev,
        to: onSaleCount,
        firstTs: now,
        lastTs: now,
        hits: 1,
      };
    }

    // 归零：几乎全是切店/loading 串读，A 路径永不确认（真清零交给 B tabCount===0）
    const isZeroDrop = onSaleCount === 0 && prev > 0;
    const dropN = onSaleCount < prev ? prev - onSaleCount : 0;
    const isBigDrop = dropN > 0 && (
      isZeroDrop
      || dropN >= Math.max(ONSALE_QTY_BIG_DROP_MIN, Math.ceil(prev * ONSALE_QTY_BIG_DROP_RATIO))
    );
    const needHits = isBigDrop ? ONSALE_QTY_BIG_DROP_HITS : ONSALE_QTY_CONFIRM_HITS;
    const needGap = isBigDrop ? ONSALE_QTY_BIG_DROP_GAP_MS : ONSALE_QTY_CONFIRM_GAP_MS;
    const gapOk = (now - nextPending.firstTs) >= needGap;
    const hitsOk = nextPending.hits >= needHits;
    // 归零永不 confirmed
    const confirmed = !isZeroDrop && gapOk && hitsOk;

    if (!confirmed) {
      s.snapshot = Object.assign({}, snap, {
        // 基准保持 prev，不把毛刺写进 onSaleCount
        pendingQty: nextPending,
      });
      stores[name] = s;
      await saveStores(stores);
      log.info('OnSale qty pending: store=' + name + ' ' + prev + '→' + onSaleCount
        + ' hits=' + nextPending.hits + '/' + needHits
        + ' gapMs=' + (now - nextPending.firstTs)
        + (isZeroDrop ? ' zeroDrop=1' : (isBigDrop ? ' bigDrop=1' : '')));
      return {
        first: false,
        from: prev,
        to: onSaleCount,
        dropped: dropN,
        rose: onSaleCount > prev ? onSaleCount - prev : 0,
        // v20：pending 绝不约 B；数量卡与清单扫描都等确认
        shouldScan: false,
        pending: true,
        confirmed: false,
        cancelScan: false,
      };
    }

    // 确认：落基准、清 pending；抬高水位
    const dropped = onSaleCount < prev ? prev - onSaleCount : 0;
    const rose = onSaleCount > prev ? onSaleCount - prev : 0;
    const nextHigh = Math.max(highWater || 0, onSaleCount);
    s.snapshot = Object.assign({}, snap, {
      onSaleCount: onSaleCount,
      onSaleCountTs: now,
      pendingQty: null,
      onSaleHighWater: nextHigh,
    });
    stores[name] = s;
    await saveStores(stores);
    log.info('OnSale qty confirmed: store=' + name + ' ' + prev + '→' + onSaleCount
      + ' hits=' + nextPending.hits + ' high=' + nextHigh);
    return {
      first: false,
      from: prev,
      to: onSaleCount,
      dropped: dropped,
      rose: rose,
      shouldScan: dropped > 0 || rose > 0,
      pending: false,
      confirmed: true,
      cancelScan: false,
    };
  });

  if (!decision || decision.first) return decision;
  // 未确认 / 子集忽略 / 静默恢复：不发数量卡，也不约 B
  if (decision.ignoredSubset || decision.silentRecover) return decision;
  if (!decision.confirmed || (!decision.dropped && !decision.rose)) return decision;

  // 数量卡冷却：同店同 from→to 30 分钟内不重复
  let g = await getOnSaleAlertedGlobal();
  g.qty = pruneTsMap(g.qty, now, ONSALE_QTY_COOLDOWN_MS);
  const qtyKey = name + '|' + decision.from + '→' + decision.to;
  if (g.qty[qtyKey] && now - g.qty[qtyKey] < ONSALE_QTY_COOLDOWN_MS) {
    log.info('OnSale qty alert cooled: ' + qtyKey);
    return decision;
  }
  g.qty[qtyKey] = now;
  await saveOnSaleAlertedGlobal(g);

  const lines = [
    '**🏬 ' + name + '**',
    decision.dropped
      ? ('📉 在售数量下降 **' + decision.from + ' → ' + decision.to + '**（少 ' + decision.dropped + '）')
      : ('📈 在售数量上升 **' + decision.from + ' → ' + decision.to + '**（多 ' + decision.rose + '）'),
    '_来源：插件·后台 countStatus（已连续确认，过滤切店毛刺）_',
    '_将尝试扫描在售清单点名；若本页不在该店则等空闲轮巡_',
    '',
    '_检查时间：' + new Date().toLocaleString('zh-CN') + '_',
  ];
  const title = decision.dropped ? '🔔 Temu 在售下降（数量）' : '🟢 Temu 在售上升（数量）';
  const template = decision.dropped ? 'red' : 'green';
  const r = await sendFeishu(cfg.webhook, title, lines, template);
  await chrome.storage.local.set({
    lastAlert: { ts: now, ok: r.ok, msg: r.msg, store: name, kind: 'onsale-qty', lines: lines },
  });
  log.warn('OnSale qty alert: store=' + name + ' ' + decision.from + '→' + decision.to + ' feishu=' + r.ok);
  return decision;
}

/**
 * B：在售清单 diff 点名。
 * - v20 权威：仅 scanMeta.trust==='full-onsale' 才允许写 onSaleIds / 覆盖 onSaleCount
 * - 下架：上轮在售、本轮不在 → 立即点名（productId 冷却）
 * - 上架：新进先 pending，**连续两轮仍在售** 再点名（与赛狐二次确认同思路）
 * - 真清零（v19.4）：tabCount===0 需连续 ≥2 次；且近 2min 内可信 onSaleCount>0 时拒绝
 * - collapse（v19.5，降为 defense-in-depth）：相对可信 count 大幅缩水 → abort
 * - items 空且非已确认真清零 → 不动基准
 */
function isOnSaleScanCollapsed(scanN, trustedCount, trustedTs, now) {
  if (typeof scanN !== 'number' || scanN < 0) return false;
  if (typeof trustedCount !== 'number' || trustedCount <= 0) return false;
  if (typeof trustedTs === 'number' && trustedTs > 0
      && (now - trustedTs) > ONSALE_SCAN_VS_COUNT_MAX_AGE_MS) {
    return false; // 可信 count 太旧，不拿来卡
  }
  if (scanN >= trustedCount) return false;
  const drop = trustedCount - scanN;
  if (drop < ONSALE_SCAN_VS_COUNT_MIN_DROP) return false;
  // 扫到不足可信数的一半，或直接少很多（例如 15→4）
  if (scanN <= Math.floor(trustedCount * ONSALE_SCAN_VS_COUNT_RATIO)) return true;
  if (drop >= Math.max(ONSALE_SCAN_VS_COUNT_MIN_DROP, Math.ceil(trustedCount * ONSALE_SCAN_VS_COUNT_RATIO))) {
    return true;
  }
  return false;
}

async function diffOnSale(name, items, onSaleTabCount, scanStore, scanMeta) {
  if (!ONSALE_MONITOR_IN_PLUGIN || !ONSALE_SCAN_ALERT) return { delisted: 0, listed: 0 };
  if (scanStore && scanStore !== name) {
    log.warn('onSale scan store mismatch: want=' + name + ' got=' + scanStore + '，本轮作废');
    return { delisted: 0, listed: 0, aborted: true };
  }
  if (!Array.isArray(items)) {
    log.warn('onSale scan invalid items: store=' + name);
    return { delisted: 0, listed: 0, aborted: true };
  }
  scanMeta = scanMeta || {};
  // v20：只有干净全量在售视图才写基准。缺 trust / untrusted / 仍带筛选 → 一律 abort
  if (scanMeta.watchFilterOn) {
    log.warn('onSale scan rejected (watch filter on): store=' + name);
    return { delisted: 0, listed: 0, aborted: true, reason: 'watch-filter-on' };
  }
  if (scanMeta.trust !== 'full-onsale') {
    const why = scanMeta.trustReason || scanMeta.trust || 'missing-trust';
    log.warn('onSale scan rejected (untrusted view): store=' + name + ' reason=' + why);
    return { delisted: 0, listed: 0, aborted: true, reason: 'untrusted-view', trustReason: why };
  }

  const cfg = await getConfig();
  const now = Date.now();
  const looksZero = typeof onSaleTabCount === 'number' && onSaleTabCount === 0 && items.length === 0;

  // 非零扫描路径：空且不是 0 → 扫描失败，不动基准
  if (!items.length && !looksZero) {
    log.warn('onSale scan empty (not authoritative zero): store=' + name + ' tabCount=' + onSaleTabCount);
    // 顺手清掉可能残留的 pendingTrueZero（下一次非空会正式清）
    return { delisted: 0, listed: 0, aborted: true };
  }

  // 防残缺/污染：以干净视图「在售中 N」为权威（真零路径 known=0，跳过）
  const known = (typeof onSaleTabCount === 'number' && onSaleTabCount >= 0)
    ? onSaleTabCount
    : null;
  if (known != null && known > 0 && items.length < known) {
    log.warn('onSale scan incomplete: store=' + name + ' scanned=' + items.length + ' known=' + known);
    return { delisted: 0, listed: 0, aborted: true };
  }
  if (known != null && items.length > known) {
    log.warn('onSale scan overflow: store=' + name + ' scanned=' + items.length + ' known=' + known + '，疑似视图污染，本轮作废');
    return { delisted: 0, listed: 0, aborted: true };
  }

  const newMap = {};
  for (const it of items) {
    if (it && it.productId) {
      newMap[String(it.productId)] = {
        name: it.name || '',
        skc: it.skc || '',
        productId: String(it.productId),
      };
    }
  }

  let g = await getOnSaleAlertedGlobal();
  g.delist = pruneTsMap(g.delist, now, ONSALE_ID_COOLDOWN_MS);
  g.onshelf = pruneTsMap(g.onshelf, now, ONSALE_ID_COOLDOWN_MS);

  const pack = await withStores(async () => {
    const stores = await getStores();
    const s = stores[name] || { latest: {}, snapshot: {} };
    const snap = s.snapshot || {};
    const prevMap = snap.onSaleIds && typeof snap.onSaleIds === 'object' ? snap.onSaleIds : null;
    const prevPending = snap.pendingOnshelf && typeof snap.pendingOnshelf === 'object' ? snap.pendingOnshelf : {};
    let pendingTZ = snap.pendingTrueZero && typeof snap.pendingTrueZero === 'object'
      ? snap.pendingTrueZero
      : null;

    // —— v19.5：相对可信 countStatus / 已确认清单，扫描结果大幅缩水 → 筛选污染，不动基准 ——
    // 可信数优先用已确认 onSaleCount；没有则用 prevMap 大小（清单基准）
    if (!looksZero) {
      const trustedCount = (typeof snap.onSaleCount === 'number' && snap.onSaleCount > 0)
        ? snap.onSaleCount
        : (prevMap ? Object.keys(prevMap).length : null);
      const trustedTs = typeof snap.onSaleCountTs === 'number' ? snap.onSaleCountTs : 0;
      const scanN = (known != null) ? known : Object.keys(newMap).length;
      if (isOnSaleScanCollapsed(scanN, trustedCount, trustedTs, now)) {
        log.warn('onSale scan rejected (collapsed vs trusted count): store=' + name
          + ' scanN=' + scanN + ' trusted=' + trustedCount
          + ' items=' + items.length + '（疑似限流筛选污染，本轮放弃）');
        return { aborted: true, reason: 'collapsed-vs-count' };
      }
      // 相对已确认清单：扫到条数远少于 prevMap，且会触发大批下架 → 也拒
      if (prevMap) {
        const prevN = Object.keys(prevMap).length;
        const wouldDelist = Object.keys(prevMap).filter((pid) => !(pid in newMap)).length;
        if (prevN >= ONSALE_SCAN_VS_COUNT_MIN_DROP
            && wouldDelist >= ONSALE_SCAN_VS_COUNT_MIN_DROP
            && isOnSaleScanCollapsed(Object.keys(newMap).length, prevN, 0, now)) {
          log.warn('onSale scan rejected (collapsed vs baseline ids): store=' + name
            + ' scanned=' + Object.keys(newMap).length + ' baseline=' + prevN
            + ' wouldDelist=' + wouldDelist);
          return { aborted: true, reason: 'collapsed-vs-baseline' };
        }
      }
    }

    // —— v19.4 真清零二次确认 ——
    if (looksZero) {
      // 与近 2min 内可信 countStatus>0 冲突 → 拒绝（loading 瞬时 0）
      const cnt = typeof snap.onSaleCount === 'number' ? snap.onSaleCount : null;
      const cntTs = typeof snap.onSaleCountTs === 'number' ? snap.onSaleCountTs : 0;
      if (cnt != null && cnt > 0 && cntTs && (now - cntTs) < ONSALE_TRUE_ZERO_VS_COUNT_MS) {
        log.warn('onSale trueZero rejected (recent countStatus>0): store=' + name
          + ' count=' + cnt + ' ageMs=' + (now - cntTs));
        s.snapshot = Object.assign({}, snap, { pendingTrueZero: null });
        stores[name] = s;
        await saveStores(stores);
        return { aborted: true, reason: 'trueZero-vs-count' };
      }

      const hits = (pendingTZ && pendingTZ.hits ? pendingTZ.hits : 0) + 1;
      const firstTs = (pendingTZ && pendingTZ.firstTs) || now;
      if (hits < ONSALE_TRUE_ZERO_HITS) {
        s.snapshot = Object.assign({}, snap, {
          pendingTrueZero: { hits: hits, firstTs: firstTs, lastTs: now },
        });
        stores[name] = s;
        await saveStores(stores);
        log.info('onSale trueZero pending: store=' + name
          + ' hits=' + hits + '/' + ONSALE_TRUE_ZERO_HITS
          + ' (baseline kept, no delist yet)');
        return { aborted: true, reason: 'trueZero-pending', hits: hits };
      }
      // 连续命中够了 → 放行后面的 diff（newMap 为空 → 全量 delist）
      log.warn('onSale trueZero confirmed: store=' + name
        + ' hits=' + hits + ' will delist baseline');
      // 清 pending，继续走正常 diff
      pendingTZ = null;
    } else if (pendingTZ) {
      // 非零扫描：取消 pending trueZero
      log.info('onSale trueZero cancelled (non-zero scan): store=' + name
        + ' wasHits=' + (pendingTZ.hits || 0)
        + ' tabCount=' + onSaleTabCount + ' items=' + items.length);
      pendingTZ = null;
    }

    if (!prevMap) {
      // 首轮：建确认基准，不告警；当前列表全部视为已确认在售（不进 pending）
      // 首轮 trueZero（空店）也建空基准，不告警
      s.snapshot = Object.assign({}, snap, {
        onSaleIds: newMap,
        onSaleIdsTs: now,
        pendingOnshelf: {},
        pendingTrueZero: null,
        onSaleCount: typeof known === 'number' ? known : Object.keys(newMap).length,
        onSaleCountTs: now,
      });
      stores[name] = s;
      await saveStores(stores);
      log.info('First onSale baseline: store=' + name + ' items=' + Object.keys(newMap).length);
      return { first: true, delistedIds: [], listedIds: [], nextPending: {}, from: 0, to: Object.keys(newMap).length };
    }

    // v22.3：子集基准恢复到全量时静默重建清单，不发上架点名。
    // 典型：限流筛选把 onSaleIds 污染成 5，关筛选后扫到 15 → 另外 10 个会被当成「新上架」。
    // A 路径已有 looksLikeSubsetRecovery 静默抬数量基准；B 路径此前漏防（HomeCove 2026-08-24 19:17 误报）。
    {
      const prevN = Object.keys(prevMap).length;
      const currN = Object.keys(newMap).length;
      const highWater = (typeof snap.onSaleHighWater === 'number' && snap.onSaleHighWater > 0)
        ? snap.onSaleHighWater
        : ((typeof snap.onSaleCount === 'number' && snap.onSaleCount > prevN) ? snap.onSaleCount : null);
      const recoverSnap = Object.assign({}, snap, {
        onSaleHighWater: highWater != null ? highWater : snap.onSaleHighWater,
      });
      // 恢复形态：清单变大，且符合 A 同款「子集→全量」判定；同时 prev 中绝大多数仍在本轮（不是真换了一批发品）
      const stillPresent = Object.keys(prevMap).filter((pid) => pid in newMap).length;
      const prevMostlyKept = prevN === 0 || stillPresent >= Math.ceil(prevN * 0.8);
      if (currN > prevN && prevMostlyKept && looksLikeSubsetRecovery(prevN, currN, recoverSnap)) {
        const nextHigh = Math.max(highWater || 0, currN, typeof known === 'number' ? known : 0);
        s.snapshot = Object.assign({}, snap, {
          onSaleIds: newMap,
          onSaleIdsTs: now,
          pendingOnshelf: {},
          pendingTrueZero: null,
          onSaleCount: typeof known === 'number' ? known : currN,
          onSaleCountTs: now,
          onSaleHighWater: nextHigh > 0 ? nextHigh : snap.onSaleHighWater,
        });
        stores[name] = s;
        await saveStores(stores);
        log.info('OnSale list silent recover (subset→full): store=' + name
          + ' ' + prevN + '→' + currN + ' kept=' + stillPresent + ' high=' + nextHigh);
        return {
          first: false,
          delistedIds: [],
          listedIds: [],
          nextPending: {},
          from: prevN,
          to: currN,
          silentRecover: true,
        };
      }
    }

    // —— 下架：确认基准有、本轮没有 ——
    const rawDelisted = Object.keys(prevMap).filter((pid) => !(pid in newMap));
    // —— 上架二次确认 ——
    // 1) 上轮 pending 且本轮仍在 → 确认上架
    const confirmedListed = [];
    for (const pid of Object.keys(prevPending)) {
      if (pid in newMap) confirmedListed.push(pid);
      // else: 抖动，丢弃
    }
    // 2) 本轮有、不在确认基准、也不是本轮刚确认 → 新 pending
    const listedSet = new Set(confirmedListed);
    const nextPending = {};
    for (const pid of Object.keys(newMap)) {
      if (pid in prevMap) continue;
      if (listedSet.has(pid)) continue;
      const row = newMap[pid];
      nextPending[pid] = {
        productId: pid,
        name: row.name || '',
        skc: row.skc || '',
        firstSeenTs: (prevPending[pid] && prevPending[pid].firstSeenTs) || now,
      };
    }

    // 下一轮确认基准 = 上轮确认 − 下架 + 本轮确认上架（pending 不进基准）
    const nextOnSale = {};
    for (const pid of Object.keys(prevMap)) {
      if (!(pid in newMap)) continue; // 下架去掉
      nextOnSale[pid] = prevMap[pid];
    }
    for (const pid of confirmedListed) {
      nextOnSale[pid] = newMap[pid] || prevPending[pid] || { productId: pid, name: '', skc: '' };
    }
    // 本轮仍在售且已在基准的，刷新名称
    for (const pid of Object.keys(nextOnSale)) {
      if (newMap[pid]) nextOnSale[pid] = newMap[pid];
    }

    const fromN = Object.keys(prevMap).length;
    const toN = Object.keys(nextOnSale).length;

    s.snapshot = Object.assign({}, snap, {
      onSaleIds: nextOnSale,
      onSaleIdsTs: now,
      pendingOnshelf: nextPending,
      pendingTrueZero: null,
      onSaleCount: typeof known === 'number' ? known : toN,
      onSaleCountTs: now,
    });
    stores[name] = s;
    await saveStores(stores);

    if (Object.keys(nextPending).length) {
      log.info('OnSale pending onshelf: store=' + name + ' n=' + Object.keys(nextPending).length
        + ' ids=' + Object.keys(nextPending).slice(0, 8).join(','));
    }

    return {
      first: false,
      delistedIds: rawDelisted,
      listedIds: confirmedListed,
      nextPending: nextPending,
      prevMap: prevMap,
      newMap: newMap,
      from: fromN,
      to: toN,
    };
  });

  if (!pack || pack.aborted) return { delisted: 0, listed: 0, aborted: true, reason: pack && pack.reason };
  if (pack.first) return { delisted: 0, listed: 0, first: true };
  if (pack.silentRecover) return { delisted: 0, listed: 0, silentRecover: true };

  // 冷却过滤
  const dCool = filterByCooldown(pack.delistedIds, g.delist, now, ONSALE_ID_COOLDOWN_MS);
  const lCool = filterByCooldown(pack.listedIds, g.onshelf, now, ONSALE_ID_COOLDOWN_MS);
  if (dCool.blocked.length) log.info('Delist cooled skip: store=' + name + ' n=' + dCool.blocked.length);
  if (lCool.blocked.length) log.info('Onshelf cooled skip: store=' + name + ' n=' + lCool.blocked.length);

  const delistedIds = dCool.fresh;
  const listedIds = lCool.fresh;
  g.delist = markCooldown(g.delist, delistedIds, now);
  g.onshelf = markCooldown(g.onshelf, listedIds, now);
  await saveOnSaleAlertedGlobal(g);

  if (!cfg.enabled) return { delisted: delistedIds.length, listed: listedIds.length };

  const prevMap = pack.prevMap || {};
  const newMapRef = pack.newMap || {};

  if (delistedIds.length) {
    const its = delistedIds.map((pid) => ({
      productId: pid,
      name: (prevMap[pid] && prevMap[pid].name) || '',
      skc: (prevMap[pid] && prevMap[pid].skc) || '',
    }));
    const pendingN = Object.keys(pack.nextPending || {}).length;
    const lines = [
      '**🏬 ' + name + '**',
      '📉 在售下架 **' + delistedIds.length + '** 个（确认基准 ' + pack.from + ' → ' + pack.to
        + (listedIds.length ? '，同期确认上架 ' + listedIds.length : '')
        + (pendingN ? '，待确认上架 ' + pendingN : '')
        + '）:',
      ...itemLines(its, null),
      '',
      '_来源：插件·后台在售清单（赛狐可能尚未同步）_',
      '_检查时间：' + new Date().toLocaleString('zh-CN') + '_',
    ];
    const r = await sendFeishu(cfg.webhook, '🔔 Temu 在售下架点名', lines, 'red');
    await chrome.storage.local.set({
      lastAlert: { ts: now, ok: r.ok, msg: r.msg, store: name, kind: 'delist', lines: lines },
    });
    log.warn('Delisted named: store=' + name + ' n=' + delistedIds.length + ' feishu=' + r.ok);
  }

  if (listedIds.length) {
    const its = listedIds.map((pid) => ({
      productId: pid,
      name: (newMapRef[pid] && newMapRef[pid].name) || (prevMap[pid] && prevMap[pid].name) || '',
      skc: (newMapRef[pid] && newMapRef[pid].skc) || '',
    }));
    const lines = [
      '**🏬 ' + name + '**',
      '📈 在售上架 **' + listedIds.length + '** 个（连续两轮确认，基准 ' + pack.from + ' → ' + pack.to + '）:',
      ...itemLines(its, null),
      '',
      '_来源：插件·后台在售清单（二次确认，防抖动）_',
      '_检查时间：' + new Date().toLocaleString('zh-CN') + '_',
    ];
    const r = await sendFeishu(cfg.webhook, '🟢 Temu 在售上架点名', lines, 'green');
    await chrome.storage.local.set({
      lastAlert: { ts: now, ok: r.ok, msg: r.msg, store: name, kind: 'onshelf', lines: lines },
    });
    log.warn('Onshelf named: store=' + name + ' n=' + listedIds.length + ' feishu=' + r.ok);
  }

  return { delisted: delistedIds.length, listed: listedIds.length };
}

// 当前店：数量**确认**后防抖触发 scanOnSale 点名（v20：pending 不再约 B）
const _scanOnSaleTimers = {};
const _scanOnSaleRunning = {};
function scheduleScanOnSaleForStore(name, reason) {
  if (!ONSALE_MONITOR_IN_PLUGIN || !ONSALE_SCAN_ALERT) return;
  if (!name) return;
  if (_scanOnSaleTimers[name]) clearTimeout(_scanOnSaleTimers[name]);
  const why = reason || 'confirmed-qty';
  _scanOnSaleTimers[name] = setTimeout(() => {
    delete _scanOnSaleTimers[name];
    triggerScanOnSale(name, why).catch((e) => {
      log.warn('triggerScanOnSale error: ' + ((e && e.message) || e));
    });
  }, ONSALE_SCAN_DEBOUNCE_MS);
}
// v20：rebound / 筛选忽略 count 时取消已约 B，避免毛刺定时器仍开火
function cancelScheduledScanOnSale(name) {
  if (!name) return;
  if (_scanOnSaleTimers[name]) {
    clearTimeout(_scanOnSaleTimers[name]);
    delete _scanOnSaleTimers[name];
    log.info('scanOnSale timer cancelled: store=' + name);
  }
}

function scanMetaFromOs(os) {
  return {
    watchFilterOn: !!(os && os.watchFilterOn),
    trust: (os && os.trust) || 'untrusted',
    trustReason: (os && os.trustReason) || undefined,
  };
}

async function triggerScanOnSale(name, reason) {
  if (!ONSALE_MONITOR_IN_PLUGIN || !ONSALE_SCAN_ALERT) return null;
  if (_scanOnSaleRunning[name]) {
    log.info('scanOnSale busy: store=' + name);
    return null;
  }
  _scanOnSaleRunning[name] = true;
  try {
    const tab = await getGoodsTab();
    if (!tab) {
      log.warn('scanOnSale skip: no goods tab store=' + name);
      return null;
    }
    // 确认当前页就是目标店，否则不强制切店（避免抢人）；留给空闲轮巡
    const ping = await sendTabRetry(tab.id, { cmd: 'ping' }, 3);
    const cur = ping && ping.store ? String(ping.store).trim() : '';
    if (cur && cur !== name) {
      log.info('scanOnSale defer (not on store): want=' + name + ' cur=' + cur + ' reason=' + reason);
      return null;
    }
    log.info('scanOnSale trigger: store=' + name + ' reason=' + reason);
    const os = await sendTabRetry(tab.id, { cmd: 'scanOnSale' }, 3);
    if (!os) {
      log.warn('scanOnSale no response: store=' + name);
      return null;
    }
    if (os.msg) log.warn('scanOnSale msg: store=' + name + ' ' + os.msg);
    if (!Array.isArray(os.items)) return null;
    const scanStore = os.store ? String(os.store).trim() : name;
    return await diffOnSale(name, os.items, os.onSaleTabCount, scanStore, scanMetaFromOs(os));
  } finally {
    delete _scanOnSaleRunning[name];
  }
}

// 假店名（颜色/规格）黑名单——与 content.js 同步，双重防护
// 历史污染：Beige/Black/Charcoal/Grey/Rustic Brown/White Grey/Black Grey 等被误建成「店」
const FAKE_STORE_WORDS = /^(black|white|grey|gray|beige|brown|charcoal|red|blue|green|pink|purple|yellow|orange|gold|silver|ivory|cream|navy|olive|tan|khaki|maroon|coral|mint|teal|cyan|magenta|wine|rose|nude|camel|sand|stone|rustic|dark|light|natural|clear|multi|assorted|random|one size|os|xs|s|m|l|xl|xxl|xxxl|sku|skc|spu|usd|cny|eur|gbp|new|beta|seller|central|best|english|chinese|all|more|less|edit|save|submit|cancel|close|next|prev|back|home|cart|account|login|sign|menu|search|help|support|local|warehouse|free|shipping|sale|off|pack|size|color|colour|style|qty|quantity|option|select)$/i;
function isFakeStoreName(t) {
  if (!t) return true;
  const s = String(t).trim();
  if (s.length < 2 || s.length > 30) return true;
  if (/^[A-Z0-9]+$/.test(s)) return true;
  if (/^(Seller Central|Beta|NEW|SKC|SKU|USD|Best Seller|当前店铺)$/i.test(s)) return true;
  const words = s.split(/\s+/);
  if (words.every((w) => FAKE_STORE_WORDS.test(w))) return true;
  if (words.length === 1 && FAKE_STORE_WORDS.test(words[0])) return true;
  return false;
}
// mallId → 店名（API 归属用；比 DOM 顶栏更可靠，切店时 DOM 常滞后）
async function getMallMap() {
  const { mallMap } = await chrome.storage.local.get('mallMap');
  return (mallMap && typeof mallMap === 'object') ? mallMap : {};
}
async function rememberMallId(mallId, storeName) {
  if (!mallId || !storeName) return;
  const id = String(mallId).trim();
  const n = String(storeName).trim();
  if (!/^\d{6,}$/.test(id) || isFakeStoreName(n)) return;
  const map = await getMallMap();
  if (map[id] === n) return;
  map[id] = n;
  await chrome.storage.local.set({ mallMap: map });
  log.info('mallMap learn: ' + id + ' → ' + n);
}
// 解析店铺名：优先 mallId 映射（接口归属），再 DOM 店名；并学习 mallId↔店名
async function resolveStore(msgStore, mallId) {
  const id = mallId ? String(mallId).trim() : '';
  const dom = msgStore && String(msgStore).trim() && !isFakeStoreName(String(msgStore).trim())
    ? String(msgStore).trim()
    : null;

  if (id && /^\d{6,}$/.test(id)) {
    const map = await getMallMap();
    if (map[id]) {
      // DOM 与映射一致或 DOM 空：用映射；DOM 不同则仍信 mallId（切店 DOM 滞后），但若 DOM 稳定可纠正
      if (dom && dom !== map[id]) {
        // 若该 DOM 名尚未绑过别的 mall，允许纠正映射（店名变更/首次学错）
        const owned = Object.keys(map).find((k) => map[k] === dom && k !== id);
        if (!owned) {
          await rememberMallId(id, dom);
          return dom;
        }
        log.info('resolveStore: mallId=' + id + ' map=' + map[id] + ' dom=' + dom + ' → prefer mallId');
      }
      return map[id];
    }
    // 未知 mallId：有 DOM 就学习并采用
    if (dom) {
      await rememberMallId(id, dom);
      return dom;
    }
  }

  if (dom) return dom;
  if (msgStore && String(msgStore).trim()) {
    log.warn('Rejected fake store name: ' + String(msgStore).trim());
  }
  // 回退：仅当 storage 里只有 1 个真店时用它；否则用配置名；再否则 null
  const stores = await getStores();
  const known = Object.keys(stores).filter((n) => n && !isFakeStoreName(n));
  if (known.length === 1) {
    if (id) await rememberMallId(id, known[0]);
    return known[0];
  }
  const cfg = await getConfig();
  if (cfg.storeName && cfg.storeName.trim() && !isFakeStoreName(cfg.storeName)) return cfg.storeName.trim();
  return null;
}
// 启动/重载时清掉历史误建的假店
async function cleanupFakeStores() {
  const fake = await withStores(async () => {
    const stores = await getStores();
    const names = Object.keys(stores).filter(isFakeStoreName);
    if (!names.length) return [];
    for (const n of names) delete stores[n];
    await saveStores(stores);
    return names;
  });
  if (!fake.length) return;
  // 同步清 productUrls 里挂在假店下的链接（挪不了，直接丢）
  const cfg = await getConfig();
  if (cfg.productUrls) {
    let changed = false;
    for (const n of fake) {
      if (cfg.productUrls[n]) { delete cfg.productUrls[n]; changed = true; }
    }
    if (changed) await chrome.storage.local.set({ config: cfg });
  }
  log.warn('Cleaned up fake stores: ' + fake.join(', '));
}

// ---------------- 消息处理 ----------------
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    try {
    if (msg.type === 'log') {
      if (msg.entry && msg.entry.ts && msg.entry.level) {
        TemuLogger._writeEntry(msg.entry);
        // content / content-front 的 ERROR（含全局未捕获异常监听）转发上报飞书
        if (msg.entry.level === 'ERROR') {
          reportErrorToFeishu(msg.entry.msg, { source: 'page' }).catch(() => {});
        }
      }
      sendResponse({ ok: true });
      return;
    }
    if (msg.type === 'capture') {
      const name = await resolveStore(msg.store, msg.mallId);
      if (!name) {
        log.warn('Capture skipped: unresolved store (kind=' + msg.kind + ' raw=' + (msg.store || 'null')
          + ' mallId=' + (msg.mallId || 'null') + ')');
        sendResponse({ ok: true, skipped: true });
        return;
      }
      if (msg.mallId) await rememberMallId(msg.mallId, name);
      log.info('Capture: kind=' + msg.kind + ' store=' + name + (msg.mallId ? (' mallId=' + msg.mallId) : ''));
      if (msg.kind === 'countStatus') {
        const p = parseCountStatus(msg.body);
        if (p && p.onSale != null) {
          // v19.5/v20：限流筛选激活时 countStatus 是子集（在售15被压成4），
          // 绝不能写进 A 基准 / 约 B，否则连环假下架。
          // v22：watchFilterOnAtReq（请求时）或到达时 flag 任一为真即忽略。
          if (msg.watchFilterOn || msg.watchFilterOnAtReq) {
            log.info('countStatus ignored (watch filter on): store=' + name
              + ' onSale=' + p.onSale
              + (msg.watchFilterOnAtReq ? ' atReq=1' : '')
              + (msg.watchFilterOn ? ' now=1' : ''));
            cancelScheduledScanOnSale(name);
          } else {
            // 先读快照做子集启发式：即使 flag 漏标，也不把子集写进 latest.onSale
            let treatAsSubset = false;
            try {
              const storesPeek = await getStores();
              const sPeek = storesPeek[name] || {};
              treatAsSubset = looksLikeWatchFilterSubset(p.onSale, sPeek.latest || {}, sPeek.snapshot || {});
            } catch (e) { /* ignore */ }
            if (treatAsSubset) {
              log.info('countStatus ignored (subset heuristic pre-latest): store=' + name
                + ' onSale=' + p.onSale);
              cancelScheduledScanOnSale(name);
              // 不更新 latest.onSale，避免 popup 显示限流在售数
            } else {
              await updateStoreLatest(name, {
                onSale: p.onSale, unpublished: p.unpublished, removed: p.removed, deleted: p.deleted,
                mallId: msg.mallId || undefined,
              });
              // A：在售数量 diff；轮巡切店期间只更新 latest/基准，不发数量卡（防串店毛刺）
              // v20：仅 confirmed && shouldScan 才约 B；rebound 明确 cancelScan
              try {
                const q = await diffOnSaleCount(name, p.onSale, { silent: !!cycling });
                if (q && q.cancelScan) cancelScheduledScanOnSale(name);
                if (q && q.confirmed && q.shouldScan && !cycling) {
                  scheduleScanOnSaleForStore(name, q.dropped ? 'confirmed-qty-drop' : 'confirmed-qty-rise');
                }
              } catch (e) {
                log.warn('diffOnSaleCount error: ' + ((e && e.message) || e));
              }
            }
          }
          await diffAndAlert(name);
        }
      } else if (msg.kind === 'pageQuery') {
        const p = parsePageQuery(msg.body);
        if (p) {
          // 保存一份精简样本，便于排障（不是整页 body，只前 2 个多 SKU 商品）
          try {
            const sample = (p.multiSkuProducts || []).slice(0, 2).map((pr) => ({
              productId: pr.productId, name: pr.name, skuCount: pr.skuCount,
              skus: (pr.skus || []).map((s) => ({ skuId: s.skuId, name: s.name })),
            }));
            await chrome.storage.local.set({
              lastPageSkuSample: {
                store: name, total: p.total, pageSkuCount: p.pageSkuCount,
                productCount: (p.products || []).length,
                multiSkuCount: (p.multiSkuProducts || []).length,
                sample, ts: Date.now(),
              },
            });
          } catch (e) { /* ignore */ }
          log.info('pageQuery SKU: store=' + name
            + ' products=' + (p.products || []).length
            + ' skus=' + p.pageSkuCount
            + ' multiSku=' + (p.multiSkuProducts || []).length);
          // 合并货号 map（跨页保留）——在 withStores 内读旧 map，避免并发丢字段
          await withStores(async () => {
            const prevStores = await getStores();
            const s0 = prevStores[name] || { latest: {}, snapshot: {} };
            const prevMap = (s0.latest && s0.latest.productSkuCodeMap) || {};
            const productSkuCodeMap = Object.assign({}, prevMap, buildProductSkuCodeMap(p.products));
            s0.latest = Object.assign({}, s0.latest, {
              total: p.total,
              pageProducts: p.products,
              pageSkus: p.pageSkus,
              pageSkuCount: p.pageSkuCount,
              multiSkuProducts: p.multiSkuProducts,
              productSkuCodeMap: productSkuCodeMap,
              ts: Date.now(),
            });
            prevStores[name] = s0;
            await saveStores(prevStores);
          });
          // 同 product 内 SKU 消失检测（仅对比本页再次出现的商品，避免分页假下架）
          await diffProductSkus(name, p.products || []);
          // 同 product 内 SKU 库存变零检测（前次 >0 → 本次 0）
          await diffProductStocks(name, p.products || []);
        }
      } else if (msg.kind === 'skuSpecList') {
        // 始终保存原始响应便于排障（成功/失败都存）
        await chrome.storage.local.set({ lastSkuSpecRaw: msg.body.slice(0, 3000) });
        const p = parseSkuSpecList(msg.body);
        if (p) {
          log.info('skuSpecList captured: store=' + name + ' count=' + p.skuSpecCount);
          await updateStoreLatest(name, { skuSpecs: p.skuSpecs, skuSpecCount: p.skuSpecCount });
        } else {
          log.warn('skuSpecList parse FAILED for store=' + name + ' — raw saved to lastSkuSpecRaw');
        }
      } else if (msg.kind === 'skuPriceQuery') {
        const p = parseSkuPriceQuery(msg.body);
        if (p) {
          log.info('skuPriceQuery captured: store=' + name);
          await updateStoreLatest(name, { skuPriceRaw: p.skuPriceRaw });
        }
      }
      sendResponse({ ok: true });
      return;
    }
    // ---- 前台商品页 variant 监控 ----
    if (msg.type === 'frontCapture') {
      const d = msg.data;
      if (!d || !d.url) { sendResponse({ ok: false, msg: 'invalid data' }); return; }
      log.info('FrontCapture: url=' + d.url + ' title=' + (d.title || '').slice(0, 30) + ' variants=' + d.totalOptions + ' avail=' + d.availableOptions);
      const cfg = await getConfig();
      const productUrls = cfg.productUrls || {};
      let store = null;
      for (const [s, urls] of Object.entries(productUrls)) {
        if (Array.isArray(urls) && urls.some((u) => {
          const a = String(u || '').split('?')[0]; const b = String(d.url || '').split('?')[0];
          return a === b || (d.fullUrl && a === String(d.fullUrl).split('?')[0]);
        })) { store = s; break; }
      }
      if (!store) {
        const known = Object.keys(await getStores()).filter((n) => n && !isFakeStoreName(n));
        store = known.find((n) => (d.fullUrl || d.url).toLowerCase().includes(n.toLowerCase())) || null;
      }
      if (!store) { sendResponse({ ok: false, msg: 'URL not configured for any store' }); return; }
      // v22.2：人机验证 / 页面打不开（content-front detectCaptcha 命中）
      if (d.captcha) {
        log.warn('FrontCapture captcha/blocked: store=' + store + ' url=' + d.url);
        const info = d.captchaInfo || {};
        await notifyFrontBlocked(store, d.fullUrl || d.url, info);
        sendResponse({ ok: true, captcha: true, store });
        return;
      }
      const key = d.url;
      const { changes } = await withStores(async () => {
        const stores = await getStores();
        const s = stores[store] || { latest: {}, snapshot: {} };
        if (!s.frontLatest) s.frontLatest = {};
        if (!s.frontSnapshot) s.frontSnapshot = {};
        const prev = s.frontLatest[key];
        s.frontLatest[key] = { title: d.title, price: d.price, variants: d.variants, totalOptions: d.totalOptions,
          availableOptions: d.availableOptions, fullUrl: d.fullUrl, ts: Date.now() };
        const ch = [];
        if (prev && prev.variants && d.variants) {
          for (const g of d.variants) {
            const prevG = (prev.variants || []).find((pg) => pg.group === g.group);
            if (!prevG) continue;
            const prevNames = new Set((prevG.options || []).filter((o) => !o.disabled).map((o) => o.name));
            const currNames = new Set((g.options || []).filter((o) => !o.disabled).map((o) => o.name));
            const added = [...currNames].filter((n) => !prevNames.has(n));
            const removed = [...prevNames].filter((n) => !currNames.has(n));
            if (added.length) ch.push('➕ ' + g.group + ' 新增：' + added.join('、'));
            if (removed.length) ch.push('❌ ' + g.group + ' 下架/缺货：' + removed.join('、'));
          }
          if (prev.price && d.price && prev.price !== d.price) {
            ch.push('💰 价格变化：' + prev.price + ' → ' + d.price);
          }
        } else if (prev) {
          log.info('FrontSnapshot first diff baseline: store=' + store + ' url=' + key);
        }
        s.frontSnapshot[key] = Object.assign({}, s.frontLatest[key]);
        stores[store] = s;
        await saveStores(stores);
        return { changes: ch };
      });
      if (changes.length > 0) {
        log.info('FrontAlert: store=' + store + ' url=' + key + ' changes=' + changes.length);
        const lines = ['**🏬 ' + store + ' 前台变体变化**',
          '商品：[' + (d.title || key) + '](' + (d.fullUrl || key) + ')',
          '', ...changes, '',
          '_检测时间：' + new Date().toLocaleString('zh-CN') + '_'];
        const r = await sendFeishu(cfg.webhook, '🔔 Temu 前台变体监测', lines, 'orange');
        await chrome.storage.local.set({ lastFrontAlert: { ts: Date.now(), ok: r.ok, store, url: key, changes } });
      }
      sendResponse({ ok: true, store, changes });
      return;
    }
    if (msg.type === 'addProductUrl') {
      const name = (msg.store || '').trim();
      const url = (msg.url || '').trim();
      if (!name || !url) { sendResponse({ ok: false, msg: '店铺名和链接不能为空' }); return; }
      const cfg = await getConfig();
      const productUrls = Object.assign({}, cfg.productUrls || {});
      if (!productUrls[name]) productUrls[name] = [];
      const base = url.split('?')[0];
      if (!productUrls[name].includes(base)) {
        productUrls[name].push(base);
        cfg.productUrls = productUrls;
        await chrome.storage.local.set({ config: cfg });
        log.info('ProductUrl added: store=' + name + ' url=' + base);
        sendResponse({ ok: true, msg: '已添加', url: base });
      } else {
        sendResponse({ ok: false, msg: '该链接已存在' });
      }
      return;
    }
    if (msg.type === 'deleteProductUrl') {
      const name = (msg.store || '').trim();
      const url = (msg.url || '').trim();
      const cfg = await getConfig();
      const productUrls = Object.assign({}, cfg.productUrls || {});
      if (productUrls[name]) {
        productUrls[name] = productUrls[name].filter((u) => u !== url);
        if (!productUrls[name].length) delete productUrls[name];
        cfg.productUrls = productUrls;
        await chrome.storage.local.set({ config: cfg });
        await withStores(async () => {
          const stores = await getStores();
          const s = stores[name];
          if (s) {
            if (s.frontLatest && s.frontLatest[url]) delete s.frontLatest[url];
            if (s.frontSnapshot && s.frontSnapshot[url]) delete s.frontSnapshot[url];
            await saveStores(stores);
          }
        });
        log.info('ProductUrl deleted: store=' + name);
        sendResponse({ ok: true, msg: '已删除' });
      } else { sendResponse({ ok: false, msg: '店铺不存在' }); }
      return;
    }
    if (msg.type === 'checkFrontNow') {
      const { store, url } = msg;
      if (!url) { sendResponse({ ok: false, msg: 'URL 不能为空' }); return; }
      log.info('FrontCheck manual: store=' + store + ' url=' + url);
      let tab = null;
      try {
        const tabs = await chrome.tabs.query({ url: 'https://www.temu.com/*' });
        tab = tabs.find((t) => {
          return ((t.url || '').split('?')[0]) === ((url || '').split('?')[0]);
        }) || null;
      } catch (e) {}
      if (tab) {
        const r = await sendTabRetry(tab.id, { cmd: 'frontCheck' }, 5);
        sendResponse(r ? { ok: true, msg: '已触发检查' } : { ok: false, msg: '无法与页面通信，请刷新后重试' });
      } else {
        try {
          const newTab = await chrome.tabs.create({ url, active: false });
          await sleep(8000);
          const stores2 = await getStores();
          const ss = stores2[store];
          const key = (url || '').split('?')[0];
          const got = ss && ss.frontLatest && ss.frontLatest[key];
          try { await chrome.tabs.remove(newTab.id); } catch (e) {}
          if (got) {
            sendResponse({ ok: true, msg: '已捕获：' + (got.title || key).slice(0, 40) + '，' + got.totalOptions + ' 个变体' });
          } else {
            sendResponse({ ok: false, msg: '未能提取变体（可能是反爬拦截）。请手动打开商品页后再试。' });
          }
        } catch (e) {
          sendResponse({ ok: false, msg: '打开页面失败：' + (e && e.message || '') });
        }
      }
      return;
    }
    if (msg.type === 'cycleFrontNow') {
      log.info('Manual front cycle requested');
      sendResponse({ ok: true, msg: '前台变体轮巡已启动' });
      cycleFrontProducts('manual'); // fire-and-forget，不阻塞 sendResponse
      return;
    }
    if (msg.type === 'chipStats') {
      const patch = {};
      if (typeof msg.trafficWatch === 'number') patch.trafficWatch = msg.trafficWatch;
      if (typeof msg.trafficDecline === 'number') patch.trafficDecline = msg.trafficDecline;
      if (Array.isArray(msg.watchItems)) patch.watchItems = msg.watchItems;
      if (Array.isArray(msg.declineItems)) patch.declineItems = msg.declineItems;
      if (Object.keys(patch).length) {
        const name = await resolveStore(msg.store);
        if (!name) {
          log.warn('ChipStats skipped: unresolved store (raw=' + (msg.store || 'null') + ')');
        } else {
          // 串行：补全货号；空/短明细不覆盖已有（被动只见当前页徽标）
          await withStores(async () => {
            const storesNow = await getStores();
            const sNow = storesNow[name] || { latest: {}, snapshot: {} };
            const prevL = sNow.latest || {};
            const codeMap = prevL.productSkuCodeMap || {};
            const chipW = typeof patch.trafficWatch === 'number' ? patch.trafficWatch
              : (typeof prevL.trafficWatch === 'number' ? prevL.trafficWatch : null);
            if (Array.isArray(patch.watchItems)) {
              if (patch.watchItems.length) {
                const enriched = enrichWithPageCodes(patch.watchItems, codeMap);
                const prevW = Array.isArray(prevL.watchItems) ? prevL.watchItems : [];
                // v21：被动徽标是当前页子集。短于已有清单时只并入、不整体替换
                // （日志：seed/主动扫后 pool=12，被动 watch=1 把清单砍成 1 → 限流池少计）
                if (prevW.length && enriched.length < prevW.length) {
                  // chip 明确为 0 时允许变空；否则 merge 保底
                  if (chipW === 0) {
                    patch.watchItems = [];
                  } else {
                    patch.watchItems = mergeWatchItemLists(prevW, enriched, { trustedReplace: false });
                  }
                } else if (prevW.length && chipW != null && chipW > 0
                  && enriched.length < chipW && enriched.length <= prevW.length) {
                  // 新扫仍明显少于 chip：并入，保留旧 ID
                  patch.watchItems = mergeWatchItemLists(prevW, enriched, { trustedReplace: false });
                } else {
                  // 更长或持平：合并字段（同 ID 用新的 name/货号）
                  patch.watchItems = mergeWatchItemLists(prevW, enriched, {
                    // 条数≥旧且≥chip（或无 chip）时可用新列表为主：trustedReplace 仅当明显完整
                    trustedReplace: chipW != null && enriched.length >= chipW && enriched.length >= prevW.length,
                  });
                  if (!patch.watchItems.length) patch.watchItems = enriched;
                }
              } else if (Array.isArray(prevL.watchItems) && prevL.watchItems.length
                && !(typeof patch.trafficWatch === 'number' && patch.trafficWatch === 0)) {
                // chip 仍 >0 或未知时，空明细视为未扫全，保留旧清单
                delete patch.watchItems;
              }
            }
            if (Array.isArray(patch.declineItems)) {
              if (patch.declineItems.length) {
                const enrichedD = enrichWithPageCodes(patch.declineItems, codeMap);
                const prevD = Array.isArray(prevL.declineItems) ? prevL.declineItems : [];
                if (prevD.length && enrichedD.length < prevD.length) {
                  patch.declineItems = mergeWatchItemLists(prevD, enrichedD, { trustedReplace: false });
                } else {
                  patch.declineItems = mergeWatchItemLists(prevD, enrichedD, {
                    trustedReplace: enrichedD.length >= prevD.length && enrichedD.length > 0,
                  });
                  if (!patch.declineItems.length) patch.declineItems = enrichedD;
                }
              } else if (Array.isArray(prevL.declineItems) && prevL.declineItems.length
                && !(typeof patch.trafficDecline === 'number' && patch.trafficDecline === 0)) {
                delete patch.declineItems;
              }
            }
            log.info('ChipStats: store=' + name
              + ' trafficWatch=' + (msg.trafficWatch != null ? msg.trafficWatch : 'null')
              + ' trafficDecline=' + (msg.trafficDecline != null ? msg.trafficDecline : 'null')
              + ' watch=' + (patch.watchItems ? patch.watchItems.length : 'keep')
              + ' decline=' + (patch.declineItems ? patch.declineItems.length : 'keep'));
            sNow.latest = Object.assign({}, prevL, patch, { ts: Date.now() });
            storesNow[name] = sNow;
            await saveStores(storesNow);
          });
          await diffAndAlert(name);
        }
      }
      sendResponse({ ok: true });
      return;
    }
    if (msg.type === 'getStatus') {
      sendResponse({
        bgVersion: 'v22.3-库存归零+B路径假上架静默恢复',
        config: await getConfig(),
        stores: await getStores(),
        ...(await chrome.storage.local.get(['lastAlert', 'lastCycle', 'lastMustRemind', 'lastFrontCycle', 'lastPageSkuSample', 'lastSkuSpecRaw', 'lastSkuSpecRawFail'])),
      });
      return;
    }
    if (msg.type === 'addStore') {
      const name = (msg.name || '').trim();
      log.info('Add store: ' + name);
      if (!name) { sendResponse({ ok: false, msg: '店铺名不能为空' }); return; }
      if (isFakeStoreName(name)) { sendResponse({ ok: false, msg: '「' + name + '」看起来像颜色/规格名，不是店铺名' }); return; }
      const added = await withStores(async () => {
        const stores = await getStores();
        if (stores[name]) return false;
        stores[name] = { latest: {}, snapshot: {} };
        await saveStores(stores);
        return true;
      });
      if (!added) { sendResponse({ ok: false, msg: '「' + name + '」已存在' }); return; }
      sendResponse({ ok: true, msg: '已添加「' + name + '」，下次轮巡将尝试切到该店抓数' });
      return;
    }
    if (msg.type === 'deleteStore') {
      const name = (msg.name || '').trim();
      log.info('Delete store: ' + name);
      const deleted = await withStores(async () => {
        const stores = await getStores();
        if (!stores[name]) return false;
        delete stores[name];
        await saveStores(stores);
        return true;
      });
      if (!deleted) { sendResponse({ ok: false, msg: '「' + name + '」不存在' }); return; }
      sendResponse({ ok: true, msg: '已删除「' + name + '」' });
      return;
    }
    if (msg.type === 'checkNow') {
      log.info('Manual check requested');
      sendResponse(await pollNow());
      return;
    }
    if (msg.type === 'cycleNow') {
      log.info('Manual cycle requested');
      sendResponse(await cycleStores('manual'));
      return;
    }
    if (msg.type === 'testFeishu') {
      log.info('Test Feishu requested');
      const cfg = await getConfig();
      const r = await sendFeishu(cfg.webhook, '✅ Temu 监测测试', ['这是一条测试消息，收到说明飞书配置正常。', '', `_${new Date().toLocaleString('zh-CN')}_`], 'green');
      sendResponse(r);
      return;
    }
    if (msg.type === 'mustRemindNow') {
      log.info('Manual mustRemind requested');
      sendResponse(await sendMustRemind('手动'));
      return;
    }
    } catch (e) {
      log.error('Message handler error: ' + (e && e.message ? e.message : String(e)));
      reportErrorToFeishu('Message handler error: ' + (e && e.message ? e.message : String(e)), { source: 'msg' }).catch(() => {});
      sendResponse({ ok: false, msg: 'Internal error' });
    }
  })();
  return true;
});

// ---------------- 自动轮巡（切遍每个店抓数，再切回原店；仅空闲时触发） ----------------
const IDLE_SECONDS = 240; // 无操作 4 分钟视为空闲
let cycling = false;

async function getGoodsTab() {
  const tabs = await chrome.tabs.query({ url: 'https://agentseller.temu.com/*' });
  return tabs.find((t) => /goods\/list/.test(t.url || '')) || tabs[0] || null;
}
function sendTab(tabId, cmd) {
  return new Promise((resolve) => {
    try {
      chrome.tabs.sendMessage(tabId, cmd, (resp) => {
        if (chrome.runtime.lastError) resolve(null); else resolve(resp);
      });
    } catch (e) { resolve(null); }
  });
}
async function sendTabRetry(tabId, cmd, tries) {
  for (let i = 0; i < (tries || 8); i++) {
    const r = await sendTab(tabId, cmd);
    if (r) return r;
    await new Promise((res) => setTimeout(res, 1000)); // 页面重载后 content 未就绪，重试
  }
  return null;
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
// 等某店在切换后被重新抓到（latest.ts 比切换前更新、且有 onSale）
async function waitForStoreCapture(name, sinceTs, timeout) {
  const t0 = Date.now();
  while (Date.now() - t0 < (timeout || 25000)) {
    const stores = await getStores();
    const L = stores[name] && stores[name].latest;
    // 任一 fresh capture（pageQuery 也写 ts）即证明已切到该店。
    // v22.1：不再要求 onSale——watch filter 残留时 countStatus 被忽略、onSale 永不落地，
    // 会让轮巡误判 timeout 跳过该店 B 扫描（日志 Agnis/HomeCove ✗）。
    if (L && (L.ts || 0) > sinceTs) return true;
    await sleep(1500);
  }
  return false;
}

async function cycleStores(reason) {
  if (cycling) return { ok: false, msg: '轮巡进行中' };
  cycling = true;
  log.info('Cycle started: reason=' + reason);
  const cycleLog = [];
  try {
    const tab = await getGoodsTab();
    if (!tab) { log.warn('Cycle: no goods tab found'); return { ok: false, msg: '没有打开的 Temu 商品页' }; }
    const cur = await sendTabRetry(tab.id, { cmd: 'ping' }, 5);
    const original = cur && cur.store;
    cycleLog.push('当前店：' + (original || '未知'));

    // 店铺清单：合并「已知店」（顶栏记下 / 面板手动添加）+ 弹窗探测。
    // 过滤假店名（颜色/规格被误读写进 storage 的）
    const known = Object.keys(await getStores()).filter((n) => n && !isFakeStoreName(n));
    let listedNames = [];
    // 已知已够 2 家仍可跳过探测；只有 1 家时必须探测，否则永远单店
    if (known.length < 2) {
      const listed = await sendTabRetry(tab.id, { cmd: 'listStores' }, 5);
      listedNames = (listed && listed.names) || [];
    }
    const names = [...new Set([...known, ...listedNames])].filter(Boolean);
    cycleLog.push(
      known.length >= 2
        ? ('店铺(已知)：' + names.join(', '))
        : ('店铺(已知' + known.length + '+探测' + listedNames.length + ')：' + names.join(', '))
    );
    if (known.length < 2 && listedNames.length === 0) {
      cycleLog.push('提示：可在面板「添加店铺」填 HomeCove / Twilight Cove 等，或手动切到各店一次');
    }
    if (names.length === 0) { log.warn('Cycle: no stores identified'); return { ok: false, msg: '没识别到店铺清单' }; }
    log.info('Cycle stores: ' + names.length + ' stores: ' + names.join(', '));

    // 只有当前这一家店：不要打开切店弹窗；仍扫在售清单（A+B）
    const others = names.filter((n) => n && n !== original);
    if (others.length === 0) {
      cycleLog.push('仅 1 家店，跳过切店');
      log.info('Cycle: single store, skip switching');
      if (ONSALE_MONITOR_IN_PLUGIN && ONSALE_SCAN_ALERT && original) {
        const os = await sendTabRetry(tab.id, { cmd: 'scanOnSale' }, 3);
        if (os && os.msg) log.warn('scanOnSale aborted: store=' + original + ' ' + os.msg);
        if (os && Array.isArray(os.items)) {
          const d = await diffOnSale(original, os.items, os.onSaleTabCount, os.store, scanMetaFromOs(os));
          if (d && d.aborted) cycleLog.push('  ↳在售扫描作废(' + (d.reason || 'abort') + ')');
          if (d && (d.delisted || d.listed)) {
            if (d.delisted) cycleLog.push('  ↳下架' + d.delisted + '个');
            if (d.listed) cycleLog.push('  ↳上架' + d.listed + '个');
          }
        }
      }
      const summary = cycleLog.join(' | ');
      log.info('Cycle completed: ' + summary);
      await chrome.storage.local.set({ lastCycle: { ts: Date.now(), reason, summary } });
      return { ok: true, msg: summary };
    }

    for (const name of others) {
      const since = Date.now();
      const r = await sendTabRetry(tab.id, { cmd: 'switchTo', target: name }, 5);
      if (!r || !r.ok) { log.warn('Cycle switch FAILED: store=' + name); cycleLog.push('切到 ' + name + ' 失败：' + (r && r.msg)); continue; }
      const got = await waitForStoreCapture(name, since, 25000);
      cycleLog.push((got ? '✓ ' : '✗ ') + name);
      if (got) {
        log.info('Cycle captured: store=' + name);
      } else {
        log.warn('Cycle capture TIMEOUT: store=' + name);
      }
      // v19：空闲/手动轮巡每店扫在售清单（下架点名 + 上架二次确认）
      if (ONSALE_MONITOR_IN_PLUGIN && ONSALE_SCAN_ALERT && got) {
        const os = await sendTabRetry(tab.id, { cmd: 'scanOnSale' }, 3);
        if (os && os.msg) log.warn('scanOnSale aborted: store=' + name + ' ' + os.msg);
        if (os && Array.isArray(os.items)) {
          const d = await diffOnSale(name, os.items, os.onSaleTabCount, os.store, scanMetaFromOs(os));
          if (d && d.aborted) {
            log.info('Cycle onsale aborted: store=' + name + ' reason=' + (d.reason || ''));
            cycleLog.push('  ↳在售扫描作废(' + (d.reason || 'abort') + ')');
          }
          if (d && (d.delisted || d.listed)) {
            log.warn('Cycle onsale: store=' + name + ' delist=' + (d.delisted || 0) + ' onshelf=' + (d.listed || 0));
            if (d.delisted) cycleLog.push('  ↳下架' + d.delisted + '个');
            if (d.listed) cycleLog.push('  ↳上架' + d.listed + '个');
          }
        }
      }
    }
    // 切回原店（已在原店则跳过，避免再弹一次「切换店铺」）
    if (original) {
      const curNow = await sendTabRetry(tab.id, { cmd: 'ping' }, 3);
      if (curNow && curNow.store === original) {
        cycleLog.push('已在原店 ' + original);
        // 原店也扫一轮在售（单店/多店回切后都覆盖到）
        if (ONSALE_MONITOR_IN_PLUGIN && ONSALE_SCAN_ALERT) {
          const os = await sendTabRetry(tab.id, { cmd: 'scanOnSale' }, 3);
          if (os && os.msg) log.warn('scanOnSale aborted: store=' + original + ' ' + os.msg);
          if (os && Array.isArray(os.items)) {
            const d = await diffOnSale(original, os.items, os.onSaleTabCount, os.store, scanMetaFromOs(os));
            if (d && d.aborted) cycleLog.push('  ↳' + original + '在售扫描作废(' + (d.reason || 'abort') + ')');
            if (d && (d.delisted || d.listed)) {
              if (d.delisted) cycleLog.push('  ↳' + original + '下架' + d.delisted + '个');
              if (d.listed) cycleLog.push('  ↳' + original + '上架' + d.listed + '个');
            }
          }
        }
      } else {
        const since = Date.now();
        await sendTabRetry(tab.id, { cmd: 'switchTo', target: original }, 5);
        const gotBack = await waitForStoreCapture(original, since, 25000);
        if (ONSALE_MONITOR_IN_PLUGIN && ONSALE_SCAN_ALERT && gotBack) {
          const os = await sendTabRetry(tab.id, { cmd: 'scanOnSale' }, 3);
          if (os && os.msg) log.warn('scanOnSale aborted: store=' + original + ' ' + os.msg);
          if (os && Array.isArray(os.items)) {
            const d = await diffOnSale(original, os.items, os.onSaleTabCount, os.store, scanMetaFromOs(os));
            if (d && d.aborted) cycleLog.push('  ↳' + original + '在售扫描作废(' + (d.reason || 'abort') + ')');
            if (d && (d.delisted || d.listed)) {
              if (d.delisted) cycleLog.push('  ↳' + original + '下架' + d.delisted + '个');
              if (d.listed) cycleLog.push('  ↳' + original + '上架' + d.listed + '个');
            }
          }
        }
        cycleLog.push('已切回 ' + original);
      }
    }
    const summary = cycleLog.join(' | ');
    log.info('Cycle completed: ' + summary);
    await chrome.storage.local.set({ lastCycle: { ts: Date.now(), reason, summary } });
    return { ok: true, msg: summary };
  } catch (e) {
    log.error('Cycle error: ' + (e && e.message ? e.message : String(e)));
    // fire-and-forget：不 await（否则拖延 throw；throw 出去的 rejection 会被全局 unhandledrejection 再抓一次，靠冷却去重收口为单卡）
    reportErrorToFeishu('Cycle error: ' + (e && e.message ? e.message : String(e)), { source: 'cycle' }).catch(() => {});
    throw e;
  } finally { cycling = false; }
}

async function pollNow() {
  log.info('Poll: reloading goods list page');
  const tab = await getGoodsTab();
  if (!tab) { log.warn('Poll: no goods tab found'); return { ok: false, msg: '未找到打开的 Temu 后台标签页，请先登录并打开商品列表页' }; }
  if (/goods\/list/.test(tab.url || '')) { await chrome.tabs.reload(tab.id, { bypassCache: false }); return { ok: true, msg: '已刷新后台商品页' }; }
  await chrome.tabs.update(tab.id, { url: GOODS_URL });
  return { ok: true, msg: '已导航到商品列表页' };
}

// ---------------- 前台商品页变体轮巡 ----------------
let frontCycling = false;

// v22.2：等指定 tab 上报一次「有效」frontCapture（带 variants 或 title）。
// 不再盲 sleep —— content-front 拿到数据会立刻 sendMessage，这里收到即 resolve，
// 拿不到就等到 timeout 放弃。返回 true=拿到有效数据。
// captcha 上报虽非有效数据，但已是「content-front 已处理」信号，提前结束等待
// （返回 false → 调用方走 checkTabLoadFailed；captcha 页 tab 仍在正常 temu 域 →
//  返回 false → 不再发 load-failed，避免与 captcha 卡重复；captcha 卡已在 frontCapture 分支发）。
function waitForFrontCapture(tabId, keyBase, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (ok) => { if (done) return; done = true; try { chrome.runtime.onMessage.removeListener(listener); } catch (e) {} resolve(ok); };
    const listener = (msg, sender) => {
      if (!msg || msg.type !== 'frontCapture' || !msg.data) return;
      if (!sender || !sender.tab || sender.tab.id !== tabId) return;
      const d = msg.data;
      const u = String(d.url || '').split('?')[0];
      if (u !== keyBase) return;
      if (d.captcha) finish(false);              // 风控已识别，不白等
      else if (d.title || (d.variants && d.variants.length)) finish(true); // 有效数据
    };
    chrome.runtime.onMessage.addListener(listener);
    setTimeout(() => finish(false), timeoutMs);
  });
}

// v22.2：waitForFrontCapture 超时后，判断 tab 是「真打不开」还是「只是慢渲染」。
// 真打不开 → notifyFrontBlocked(load-failed)；慢渲染（tab 还在 loading / 正常 temu 域）→ 只 warn 不打扰。
// 返回 true=判定为加载失败/错误页。
async function checkTabLoadFailed(tabId) {
  try {
    const t = await chrome.tabs.get(tabId);
    if (!t) return true; // tab 已没了
    const u = String(t.url || '');
    // chrome 内部错误页 / 空白页
    if (/^(chrome-error:|chrome:\/\/|about:|edge:\/\/)/i.test(u)) return true;
    if (!u || u === 'about:blank') return true;
    // 仍停在非 temu 域（被重定向到错误/拦截页）
    if (!/https?:\/\/(www\.)?temu\.com/i.test(u)) return true;
    // title 是经典错误标题
    const title = String(t.title || '');
    if (/error|无法|not found|can't be reached|未连接|ERR_/i.test(title)) return true;
    return false; // 正常 temu 域、title 不像错误 → 当作慢渲染
  } catch (e) {
    // tab.get 抛错通常意味着 tab 已关闭 → 当失败
    return true;
  }
}

async function cycleFrontProducts(reason) {
  if (frontCycling) { log.info('FrontCycle skipped: already running'); return; }
  frontCycling = true;
  log.info('FrontCycle started: reason=' + reason);
  try {
    const cfg = await getConfig();
    const productUrls = cfg.productUrls || {};
    const allUrls = [];
    for (const [store, urls] of Object.entries(productUrls)) {
      if (!Array.isArray(urls)) continue;
      for (const url of urls) allUrls.push({ store, url });
    }
    if (!allUrls.length) { log.info('FrontCycle: no URLs configured'); return; }
    log.info('FrontCycle: checking ' + allUrls.length + ' URLs across ' + Object.keys(productUrls).length + ' stores');

    let checked = 0;
    let okCount = 0;
    for (const { store, url } of allUrls) {
      const keyBase = String(url).split('?')[0];
      try {
        let tab = null;
        try {
          const tabs = await chrome.tabs.query({ url: 'https://www.temu.com/*' });
          tab = tabs.find((t) => ((t.url || '').split('?')[0]) === keyBase) || null;
        } catch (e) { /* ignore */ }

        if (tab) {
          log.info('FrontCycle: reusing tab for ' + url.slice(0, 60));
          // 先挂监听再发 frontCheck，避免响应和消息竞态
          const waitP = waitForFrontCapture(tab.id, keyBase, 18000);
          const resp = await sendTabRetry(tab.id, { cmd: 'frontCheck', budgetMs: 15000 }, 3);
          // frontCheck 响应里 hasData=true 就已上报成功；否则等监听兜底
          let got = !!(resp && resp.hasData);
          if (!got) got = await waitP;
          if (got) okCount++;
          else {
            log.warn('FrontCycle: no valid data from reused tab for ' + url.slice(0, 60));
            // v22.2：复用 tab 也可能被风控/打不开（用户停留在错误页），同样检查并提醒
            if (await checkTabLoadFailed(tab.id)) {
              await notifyFrontBlocked(store, url, { reason: 'load-failed' });
            }
          }
        } else {
          log.info('FrontCycle: opening tab for ' + url.slice(0, 60));
          const newTab = await chrome.tabs.create({ url, active: false });
          // content-front init 自带重试；这里等到它真上报成功或 25s 超时
          const got = await waitForFrontCapture(newTab.id, keyBase, 25000);
          if (got) okCount++;
          else {
            log.warn('FrontCycle: no valid data from new tab for ' + url.slice(0, 60));
            // v22.2：新开 tab 超时 → 判网页打不开（网络/风控），提醒飞书
            // （content-front 若已检测到 captcha 会走 frontCapture.captcha 自行提醒；
            //  这里兜的是「连 content-front 都没注入/没上报」的纯加载失败）
            const failed = await checkTabLoadFailed(newTab.id);
            if (failed) await notifyFrontBlocked(store, url, { reason: 'load-failed' });
          }
          try { await chrome.tabs.remove(newTab.id); } catch (e) { /* ignore */ }
        }
        checked++;
      } catch (e) {
        log.warn('FrontCycle: error checking ' + url.slice(0, 60) + ': ' + (e && e.message || e));
      }
    }
    log.info('FrontCycle completed: checked=' + checked + '/' + allUrls.length + ' ok=' + okCount);
    await chrome.storage.local.set({ lastFrontCycle: { ts: Date.now(), reason, checked, total: allUrls.length, ok: okCount } });
  } catch (e) {
    log.error('FrontCycle error: ' + (e && e.message ? e.message : String(e)));
    reportErrorToFeishu('FrontCycle error: ' + (e && e.message ? e.message : String(e)), { source: 'frontCycle' }).catch(() => {});
  } finally { frontCycling = false; }
}

// 定时：空闲则轮巡所有店，否则不打扰（靠随看随记覆盖当前店）
// 必提醒：每天固定时刻强制发状态汇报（无异常也发）
chrome.alarms.onAlarm.addListener((a) => {
  log.info('Alarm fired: ' + a.name);
  if (a.name === 'poll') {
    chrome.idle.queryState(IDLE_SECONDS, (state) => {
      if (state === 'idle' || state === 'locked') {
        log.info('System idle, starting automatic cycle');
        cycleStores('idle');
      } else {
        log.info('System active, skipping automatic cycle');
      }
    });
    return;
  }
  if (a.name.startsWith(MUST_REMIND_PREFIX)) {
    const slot = a.name.slice(MUST_REMIND_PREFIX.length);
    // chrome.alarms 的 when 是一次性的 → 发完立刻重排下一天同一时刻
    (async () => {
      try {
        await sendMustRemind(slot);
      } catch (e) {
        log.error('MustRemind error: ' + (e && e.message ? e.message : String(e)));
        reportErrorToFeishu('MustRemind error: ' + (e && e.message ? e.message : String(e)), { source: 'mustRemind' }).catch(() => {});
      } finally {
        await setupMustRemindAlarms();
      }
    })();
    return;
  }
  if (a.name === 'frontPoll') {
    log.info('FrontPoll alarm fired');
    cycleFrontProducts('scheduled');
  }
});

async function setupAlarm() {
  await chrome.storage.local.remove('trafficSample'); // 清早期诊断残留
  const cfg = await getConfig();
  await chrome.alarms.clear('poll');
  chrome.alarms.create('poll', { periodInMinutes: Math.max(1, cfg.intervalMinutes || 15) });
  log.info('Alarm set: every ' + cfg.intervalMinutes + 'min, enabled=' + cfg.enabled);
  await setupMustRemindAlarms();
  // 前台变体监测闹钟
  await chrome.alarms.clear('frontPoll');
  const frontHours = Math.max(1, cfg.frontCheckIntervalHours || 3);
  if (cfg.frontCheckEnabled !== false && cfg.productUrls && Object.keys(cfg.productUrls).length) {
    chrome.alarms.create('frontPoll', { periodInMinutes: frontHours * 60 });
    log.info('FrontPoll alarm set: every ' + frontHours + 'h');
  } else {
    log.info('FrontPoll alarm skipped (disabled or no URLs)');
  }
}
chrome.runtime.onInstalled.addListener(() => { log.info('Extension installed/updated, setting up alarm'); setupAlarm(); });
chrome.runtime.onStartup.addListener(() => { log.info('Chrome startup, setting up alarm'); setupAlarm(); });
chrome.storage.onChanged.addListener((changes, area) => { if (area === 'local' && changes.config) { log.info('Config changed, reconfiguring alarm'); setupAlarm(); } });

log.info('Service worker started');
// 全局兜底：SW 未捕获的 error / 未处理的 promise rejection 也尽力上报飞书。
// （SW 被强杀那一刻来不及发，可接受；能在 SW 仍存活时捕到的都发。）
self.addEventListener('error', (ev) => {
  try {
    const m = ev && ev.message ? ev.message : 'unknown error';
    const loc = ev && ev.filename ? (' @ ' + ev.filename + ':' + (ev.lineno || 0)) : '';
    reportErrorToFeishu('SW uncaught: ' + m + loc, { source: 'global' }).catch(() => {});
  } catch (e) { /* ignore */ }
});
self.addEventListener('unhandledrejection', (ev) => {
  try {
    const r = ev && ev.reason;
    const m = (r && r.message) ? r.message : String(r);
    reportErrorToFeishu('SW unhandledrejection: ' + m, { source: 'global' }).catch(() => {});
  } catch (e) { /* ignore */ }
});
// SW 被唤醒时：清理历史假店 + 补闹钟
cleanupFakeStores().catch((e) => log.warn('cleanupFakeStores: ' + (e && e.message || e)));
setupAlarm();
