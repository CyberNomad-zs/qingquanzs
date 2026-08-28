// 隔离世界：① 注入 inject.js；② 转发接口响应(带当前店名)；③ 读流量待关注 chip；
// ④ 接收后台指令自动切店(轮巡用)。
(function () {
  var LOG = TemuLogger.createLogger('content');
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  LOG.info('content.js loaded -- v22');

  // 全局未捕获异常上报：走 LOG.error → sendToBg → SW 的 msg.type==='log' ERROR 分支 → 飞书。
  // content.js 是声明式注入、SPA 切店不重载 document，IIFE 只跑一次，监听不会重复挂。
  function _fmtErr(e) {
    try {
      if (e && e.message) return (e.name || 'Error') + ': ' + e.message;
      return String(e);
    } catch (_) { return 'unserializable error'; }
  }
  window.addEventListener('error', (ev) => {
    try {
      const m = (ev && ev.error) ? _fmtErr(ev.error)
        : ((ev && ev.message) ? ev.message : 'unknown');
      const loc = ev && ev.filename ? (' @ ' + ev.filename + ':' + (ev.lineno || 0)) : '';
      LOG.error('content uncaught: ' + m + loc);
    } catch (_) {}
  });
  window.addEventListener('unhandledrejection', (ev) => {
    try {
      const r = ev && ev.reason;
      LOG.error('content unhandledrejection: ' + _fmtErr(r));
    } catch (_) {}
  });

  // 页面操作互斥锁：scanWatchList/scanOnSaleList/switchTo 都会改动「快速筛选/tab/切店」状态，
  // 绝不能并发——否则「商品流量待关注」筛选一打开，并发的在售扫描就只扫到筛选后的几条，
  // 误判成「下架 N 个」（这是历史假告警「在售 13→3」的根因）。所有改动型指令排队串行执行。
  let opChain = Promise.resolve();
  function withLock(fn) {
    const run = opChain.then(fn, fn); // 无论上一个成功/失败都接着跑（fn 不依赖上个结果）
    opChain = run.then(() => {}, (e) => { LOG.warn('Locked operation failed: ' + (e && e.message || e)); }); // 吞掉结果/异常，保持链条连续
    return run; // 调用方拿到 fn 的真实结果/异常
  }

  // v20 pageMode：traffic / onsale / switch / idle
  // 仅 traffic 期间允许 forceWatchFilterOn；出口 finally 必须回 idle 并清 force 标志。
  // v22：筛选关闭后 grace 数秒，挡住迟来的「限流子集」countStatus。
  let pageMode = 'idle'; // 'idle' | 'traffic' | 'onsale' | 'switch'
  // forceWatchFilterOn 定义见下方「转发接口响应」；此处先声明以便 grace 同步 DOM。
  let forceWatchFilterOn = false;
  let watchFilterGraceUntil = 0;
  const WATCH_FILTER_GRACE_MS = 4000;
  function markWatchFilterGrace(ms) {
    const until = Date.now() + (ms || WATCH_FILTER_GRACE_MS);
    if (until > watchFilterGraceUntil) watchFilterGraceUntil = until;
    syncWatchFilterDomFlags();
  }
  function inWatchFilterGrace() {
    return Date.now() < watchFilterGraceUntil;
  }
  function setForceWatchFilterOn(v) {
    forceWatchFilterOn = !!v;
    syncWatchFilterDomFlags();
  }
  function syncWatchFilterDomFlags() {
    // MAIN world inject 读这些属性（隔离世界不能写 page window 变量）
    try {
      const root = document.documentElement;
      if (!root) return;
      root.setAttribute('data-temu-force-watch-filter', forceWatchFilterOn ? '1' : '0');
      root.setAttribute('data-temu-watch-filter-grace', inWatchFilterGrace() ? '1' : '0');
    } catch (e) { /* ignore */ }
  }

  // 注入 MAIN world hook
  try {
    const s = document.createElement('script');
    s.src = chrome.runtime.getURL('inject.js');
    s.onload = () => s.remove();
    (document.head || document.documentElement).appendChild(s);
    LOG.info('inject.js injected into MAIN world');
  } catch (e) { LOG.warn('inject.js injection failed: ' + (e && e.message || e)); }

  // ---------- 读当前店铺名（右上角英文店名） ----------
  // 假店名黑名单：商品颜色/规格/尺码常被误读成「店名」写进 storage
  // （历史假店：Beige/Black/Charcoal/Grey/Rustic Brown/White Grey/Black Grey…）
  const FAKE_STORE_WORDS = /^(black|white|grey|gray|beige|brown|charcoal|red|blue|green|pink|purple|yellow|orange|gold|silver|ivory|cream|navy|olive|tan|khaki|maroon|coral|mint|teal|cyan|magenta|wine|rose|nude|camel|sand|stone|rustic|dark|light|natural|clear|multi|assorted|random|one size|os|xs|s|m|l|xl|xxl|xxxl|sku|skc|spu|usd|cny|eur|gbp|new|beta|seller|central|best|seller|english|chinese|all|more|less|edit|save|submit|cancel|close|next|prev|back|home|cart|account|login|sign|menu|search|help|support|local|warehouse|free|shipping|sale|off|pack|size|color|colour|style|qty|quantity|option|select)$/i;
  function isFakeStoreName(t) {
    if (!t) return true;
    const s = String(t).trim();
    if (s.length < 2 || s.length > 30) return true;
    // 纯大写+数字货号
    if (/^[A-Z0-9]+$/.test(s)) return true;
    // UI 固定词
    if (/^(Seller Central|Beta|NEW|SKC|SKU|USD|Best Seller)$/i.test(s)) return true;
    // 整句是颜色/规格词（含多词如 "Rustic Brown" / "Black Grey" / "Ivory White"）
    const words = s.split(/\s+/);
    if (words.every((w) => FAKE_STORE_WORDS.test(w))) return true;
    // 单色词（"Black"）
    if (words.length === 1 && FAKE_STORE_WORDS.test(words[0])) return true;
    return false;
  }
  function findStoreNameEl() {
    const W = window.innerWidth;
    let best = null;
    for (const el of document.querySelectorAll('span,a,div,button,p')) {
      const t = (el.textContent || '').trim();
      if (!/^[A-Za-z][A-Za-z0-9]*(?:\s[A-Za-z0-9]+){0,3}$/.test(t)) continue;
      if (isFakeStoreName(t)) continue;
      if (el.children.length > 2) continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.top < 0 || r.top > 90) continue;
      if (r.left < W * 0.5) continue;
      if (!best || r.left > best.left) best = { el, left: r.left };
    }
    return best ? best.el : null;
  }
  function readStoreName() {
    const el = findStoreNameEl();
    if (!el) return null;
    const t = (el.textContent || '').trim();
    return isFakeStoreName(t) ? null : t;
  }

  // ---------- 转发接口响应 ----------
  // 限流筛选激活时，countStatus/pageQuery 返回的是「筛选后子集」而非全店在售数。
  // 转发给 background 时带上 watchFilterOn，避免把 在售15→筛选后4 写成下架。
  // forceWatchFilterOn 仅 pageMode==='traffic' 期间为 true（见 scanWatchList）。
  // v22：优先用 inject 在**请求发起时**打的 watchFilterOnAtReq；再 OR 当前 DOM / force / grace。
  window.addEventListener('message', (e) => {
    if (e.source !== window) return;
    const d = e.data;
    if (!d || d.__temuMon !== true) return;
    try {
      const filterOn = !!(
        d.watchFilterOnAtReq
        || forceWatchFilterOn
        || inWatchFilterGrace()
        || isWatchFilterOn()
      );
      chrome.runtime.sendMessage({
        type: 'capture',
        kind: d.kind,
        url: d.url,
        body: d.body,
        store: readStoreName(),
        mallId: d.mallId || null,
        watchFilterOn: filterOn,
        watchFilterOnAtReq: !!d.watchFilterOnAtReq,
        pageMode: pageMode,
      });
    } catch (err) {}
  });

  // ---------- 读流量异常 ----------
  // ①「商品流量待关注」是常驻的快速筛选 chip，实测 DOM（勿凭空改）：
  //     <div class="use-quick-field_tsx_card__HASH"><span>商品流量待关注</span>
  //       <span class="use-quick-field_tsx_countDistance__HASH">4</span></div>
  //   计数在独立的 countDistance span 里（chip 常驻，N=0 也在，只有 N 变大才是真异常）。
  // ②「商品流量近期有下降」不是 chip，是逐行红色徽标（见 countDeclineBadges）。
  // 关键坑：行内徽标「商品流量待关注 ›」嵌在价格 TD 里 → 价格单元格文本也含该标签。
  //   旧的"全页捞文本+最短优先"靠排序巧合才没读到价格数字；这里改为直接锚定 chip 容器。
  function readChipCount(all, label) {
    const re = new RegExp(label);
    // 精确路径：定位快速筛选 chip 容器（class 前缀 use-quick-field_tsx_card__ 稳定，
    // hash 后缀随构建变，用 *= 匹配前缀；card__ 带双下划线以免误匹配 cardBlock__）。
    for (const card of document.querySelectorAll('[class*="use-quick-field_tsx_card__"]')) {
      if (!re.test(card.textContent || '')) continue;
      const cnt = card.querySelector('[class*="countDistance"]');
      if (cnt && /\d/.test(cnt.textContent || '')) {
        return Number((cnt.textContent || '').replace(/[^\d]/g, ''));
      }
      const m = (card.textContent || '').match(new RegExp(label + '[^\\d]{0,3}([\\d,]+)'));
      if (m) return Number(m[1].replace(/,/g, ''));
    }
    // 兜底：chip class 若被改名，退回旧的全页文本匹配（最短优先 + 就近数字）
    const labels = all
      .filter((e) => re.test(e.textContent || '') && (e.textContent || '').trim().length < 24)
      .sort((a, b) => (a.textContent || '').length - (b.textContent || '').length);
    for (const el of labels) {
      for (const cand of [el, el.parentElement, el.parentElement && el.parentElement.parentElement]) {
        if (!cand) continue;
        const m = (cand.textContent || '').match(new RegExp(label + '[^\\d]{0,3}([\\d,]+)'));
        if (m) return Number(m[1].replace(/,/g, ''));
      }
      let sib = el.nextElementSibling;
      for (let i = 0; i < 3 && sib; i++, sib = sib.nextElementSibling) {
        const st = (sib.textContent || '').trim();
        if (/^[\d,]+$/.test(st)) return Number(st.replace(/,/g, ''));
      }
    }
    return null; // 读不到 → 未知（不当作 0，也不当作"有"）
  }
  // 「商品流量近期有下降」不是带计数的筛选 chip，而是逐行的红色徽标（列「商品优化事项」下）。
  // 因此按"当前页可见的行内徽标个数"来统计。注意：只覆盖当前页（默认 20 条/页），
  // 下降商品若在其它页则数不到——被动读数的固有限制，要精确总数得点筛选（主动模式）。
  function countDeclineBadges(all) {
    let n = 0;
    for (const e of all) {
      const t = (e.textContent || '').trim();
      if (!/商品流量近期有下降/.test(t) || t.length > 20) continue;
      // 只数最内层节点，避免父容器重复计数
      if ([...e.children].some((c) => /商品流量近期有下降/.test(c.textContent || ''))) continue;
      const r = e.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) n++; // 只数真正渲染出来的行徽标，排除隐藏的筛选项/图例
    }
    return n;
  }
  // 扫描当前页商品行：按「SPU ID(=productId)」边界把行分组成商品，
  // 识别哪些商品带「商品流量待关注 / 商品流量近期有下降」徽标，取 productId + 商品名 + SKC。
  // 局限：只覆盖当前页(默认 20 条/页)，跨页的限流/下降商品扫不到——被动读的固有限制
  //（chip 计数 trafficWatch 才是全量总数；这里只为「点名 + 给编辑链接」）。
  // v15：同时识别在售/已下架状态——下架商品也会显示「限流/待关注」徽标，但用户只关心在售。
  // v16：额外抓 SKU货号（VIP/JM 分级）+ 「热销款」标签（黑猫严重条件）。
  function detectSaleStatus(text) {
    const t = String(text || '');
    // 行内状态徽标：优先「在售」；已下架/已终止/已删除都不算在售
    if (/已下架|已终止|已删除|下架\/已终止/.test(t)) return 'removed';
    if (/(^|[^一-鿿])在售([^一-鿿]|$)/.test(t) || /在售中/.test(t)) return 'onSale';
    // 列表「商品信息」格常见单独的「在售」小标签
    if (/\b在售\b/.test(t) || /在售/.test(t)) return 'onSale';
    return 'unknown';
  }
  // 从表格行抽 SKU 货号：列文本多为 JMCAT* / VIP* 短码；也兼容「货号：XXX」
  function extractSkuCodesFromText(text) {
    const t = String(text || '');
    const codes = [];
    const seen = {};
    const push = (c) => {
      const s = String(c || '').trim();
      if (!s || s.length < 2 || s.length > 40) return;
      if (/^(SPU|SKC|SKU|ID|USD|CNY)$/i.test(s)) return;
      const key = s.toUpperCase();
      if (seen[key]) return;
      seen[key] = true;
      codes.push(s);
    };
    // 货号：XXX / 货号:XXX
    let m;
    const reLabeled = /货号\s*[:：]?\s*([A-Za-z][A-Za-z0-9_\-]{1,36})/g;
    while ((m = reLabeled.exec(t))) push(m[1]);
    // 独立 token：VIP* / JM*（及一般货号字母数字）
    const reToken = /\b((?:VIP|JM)[A-Za-z0-9_\-]{0,30}|[A-Z]{2,}[A-Z0-9_\-]{2,})\b/g;
    while ((m = reToken.exec(t))) {
      // 排除明显非货号
      if (/^(SPU|SKC|SKU|USD|CNY|NEW|BETA)$/i.test(m[1])) continue;
      push(m[1]);
    }
    return codes;
  }
  function extractSkuCodesFromRow(tr) {
    const codes = [];
    const seen = {};
    const add = (arr) => {
      for (const c of arr || []) {
        const k = String(c).toUpperCase();
        if (seen[k]) continue;
        seen[k] = true;
        codes.push(c);
      }
    };
    // 优先「SKU货号」列：找只含货号、不含 SPU/中文长标题的 td
    const tds = [...tr.querySelectorAll('td')];
    for (const td of tds) {
      const raw = (td.textContent || '').trim();
      if (!raw || raw.length > 80) continue;
      if (/SPU\s*ID|商品流量|热销款|申报价格|创建时间/.test(raw)) continue;
      // 短单元格更像货号列
      if (raw.length <= 48 && /[A-Za-z]/.test(raw) && !/[一-鿿]/.test(raw)) {
        add(extractSkuCodesFromText(raw));
      }
    }
    // 兜底整行
    if (!codes.length) add(extractSkuCodesFromText(tr.textContent || ''));
    return codes;
  }
  function scanProducts() {
    const rows = [...document.querySelectorAll('[data-testid="beast-core-table-body-tr"]')];
    const products = [];
    let cur = null;
    for (const tr of rows) {
      const t = tr.textContent || '';
      const spu = t.match(/SPU\s*ID[:：]\s*(\d+)/); // DOM「SPU ID」= API/编辑页的 productId
      if (spu) {
        // 商品名只在「商品信息」那一格取（含 SPU ID 的 td），排除「标签：值」属性行，取最长一段。
        // （曾扫整行 → 第 3 条抓成隔壁「商品属性」列的「主体材质：铝合金」，故限定到该 td。）
        const infoTd = [...tr.querySelectorAll('td')].find((td) => /SPU\s*ID/.test(td.textContent || '')) || tr;
        const name = [...infoTd.querySelectorAll('*')].map((e) => (e.textContent || '').trim())
          .filter((x) => x.length >= 6 && x.length <= 80 && /[一-龥]/.test(x) && !/^.{0,6}[:：]/.test(x) && !/SPU|SKC|热销款/.test(x))
          .sort((a, b) => b.length - a.length)[0] || '';
        cur = {
          productId: spu[1],
          skc: (t.match(/SKC\s*ID[:：]\s*(\d+)/) || [])[1] || '',
          name: name,
          watch: false,
          decline: false,
          hotSale: /热销款/.test(t),
          skuCodes: extractSkuCodesFromRow(tr),
          saleStatus: detectSaleStatus(t),
        };
        products.push(cur);
      }
      if (cur) {
        if (/商品流量待关注/.test(t)) cur.watch = true;
        if (/商品流量近期有下降/.test(t)) cur.decline = true;
        if (/热销款/.test(t)) cur.hotSale = true;
        // 多规格商品 SKU 可能在后续行；合并货号
        const more = extractSkuCodesFromRow(tr);
        if (more.length) {
          const seen = {};
          for (const c of cur.skuCodes) seen[String(c).toUpperCase()] = true;
          for (const c of more) {
            const k = String(c).toUpperCase();
            if (!seen[k]) { seen[k] = true; cur.skuCodes.push(c); }
          }
        }
        // 后续行可能才带状态徽标，合并识别（removed 优先，不被 unknown 覆盖）
        const st = detectSaleStatus(t);
        if (st === 'removed') cur.saleStatus = 'removed';
        else if (st === 'onSale' && cur.saleStatus !== 'removed') cur.saleStatus = 'onSale';
      }
    }
    return products;
  }
  // 只保留在售商品。
  // 被动扫（全部 tab）：必须识别到「在售」徽标——下架商品也会挂限流/下降，unknown 不当在售。
  // 主动扫（已切「在售中」tab）：调用方会把非 removed 标成 onSale。
  function onlyOnSale(items) {
    return (items || []).filter((p) => p && p.saleStatus === 'onSale');
  }
  function readTraffic() {
    const all = [...document.querySelectorAll('*')];
    return {
      watch: readChipCount(all, '商品流量待关注'),
      decline: countDeclineBadges(all),
    };
  }
  const pickItem = (p) => ({
    productId: p.productId,
    name: p.name,
    skc: p.skc,
    saleStatus: p.saleStatus || 'unknown',
    skuCodes: Array.isArray(p.skuCodes) ? p.skuCodes.slice() : [],
    hotSale: !!p.hotSale,
  });
  // 常驻轮询：每 2s 读一次 chip 计数 + 扫一次商品明细，但**只在结果变化时上报**
  //（靠 dedupe 避免刷爆后台）。这样用户后点「商品流量待关注」筛选/翻页时，
  // 明细也会在 2s 内自动刷新——旧版只在加载后 40s 内扫、之后点筛选就不扫了。
  let tries = 0;
  let lastKey = '';
  setInterval(() => {
    tries++;
    // 商品表格是否已渲染出行——徽标在行里，必须等行出来再扫，否则会在徽标出现前就读成空
    const gridReady = !!document.querySelector('[data-testid="beast-core-table-body-tr"]');
    const { watch, decline } = readTraffic();
    const msg = { type: 'chipStats', store: readStoreName() };
    if (watch != null) msg.trafficWatch = watch;
    let watchItems = [];
    let declineItems = [];
    if (gridReady) {
      const products = scanProducts();
      // v15：只报在售——下架商品也会挂「待关注/近期下降」徽标，但用户不关心
      watchItems = onlyOnSale(products.filter((p) => p.watch)).map(pickItem);
      declineItems = onlyOnSale(products.filter((p) => p.decline)).map(pickItem);
      // 被动 decline 计数也只数在售徽标，避免下架商品把 0→1 刷屏
      const onSaleDecline = onlyOnSale(products.filter((p) => p.decline)).length;
      msg.trafficDecline = onSaleDecline;
      msg.watchItems = watchItems;
      msg.declineItems = declineItems;
    }
    // 有 count 时等网格就绪再发（尽量带上明细）；网格长时间卡「加载中」(tries>8≈16s)时 count-only 兜底
    const readyOrTimedOut = gridReady || tries > 8;
    if (!((msg.trafficWatch != null && readyOrTimedOut) || 'trafficDecline' in msg)) return;
    // 结果没变化就不重发；变化了（如刚点了筛选、切了店）才上报
    const key = JSON.stringify([msg.store, msg.trafficWatch, msg.trafficDecline,
      watchItems.map((i) => i.productId), declineItems.map((i) => i.productId)]);
    if (key === lastKey) return;
    lastKey = key;
    LOG.info('Traffic update: watch=' + (watch != null ? watch : 'null') + ' decline=' + (decline != null ? decline : 'null') + ' watchItems=' + watchItems.length + ' declineItems=' + declineItems.length);
    try { chrome.runtime.sendMessage(msg); } catch (e) {}
  }, 2000);

  // ---------- 切店自动化（轮巡用，由后台指令驱动） ----------
  async function waitFor(fn, timeout, step) {
    const t0 = Date.now();
    for (;;) { let r; try { r = fn(); } catch (e) { r = null; } if (r) return r; if (Date.now() - t0 > (timeout || 6000)) return null; await sleep(step || 200); }
  }
  function textEls(re, maxLen) {
    return [...document.querySelectorAll('*')].filter((e) => { const t = (e.textContent || '').trim(); return re.test(t) && t.length <= (maxLen || 40); });
  }
  function innermost(els) { return els.slice().sort((a, b) => (a.textContent || '').length - (b.textContent || '').length)[0] || null; }
  function clickableAncestor(el) {
    let n = el;
    for (let i = 0; i < 6 && n; i++) {
      if (n.tagName === 'BUTTON' || n.tagName === 'A' || n.getAttribute('role') === 'button') return n;
      try { if (window.getComputedStyle(n).cursor === 'pointer') return n; } catch (e) {}
      n = n.parentElement;
    }
    return el;
  }
  // 完整鼠标事件序列（很多组件要 mousedown/up 才触发，单纯 click 不生效）
  function realClick(el) {
    if (!el) return false;
    try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
    const r = el.getBoundingClientRect();
    const x = r.left + Math.min(r.width / 2, 20);
    const y = r.top + Math.min(r.height / 2, 12);
    const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0, pointers: 1 };
    try {
      el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, opts, { pointerId: 1, pointerType: 'mouse' })));
    } catch (e) {}
    for (const type of ['mousedown', 'mouseup', 'click']) {
      try { el.dispatchEvent(new MouseEvent(type, opts)); } catch (e) {}
    }
    try {
      el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, opts, { pointerId: 1, pointerType: 'mouse' })));
    } catch (e) {}
    try { el.click(); } catch (e) {}
    return true;
  }
  function visible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    const b = el.getBoundingClientRect();
    if (b.width <= 0 || b.height <= 0) return false;
    try {
      const st = window.getComputedStyle(el);
      if (st.visibility === 'hidden' || st.display === 'none' || Number(st.opacity) === 0) return false;
    } catch (e) {}
    return true;
  }
  function modalOpen() {
    // 标题「切换店铺」或副文案「您的账户存在…」；maxLen 放宽，副文案可能整段在一个节点
    return textEls(/切换店铺/, 12).filter(visible).length > 0
      || textEls(/您的账户存在/, 40).filter(visible).length > 0;
  }
  // 定位切店弹窗根节点（标题向上找合适宽高的容器）
  function findModalRoot() {
    const title = innermost(textEls(/切换店铺|您的账户存在/, 40).filter(visible));
    if (!title) return null;
    let best = null;
    let node = title;
    for (let i = 0; i < 16 && node && node !== document.body; i++) {
      const r = node.getBoundingClientRect();
      const cls = String(node.className || '');
      if (r.width >= 280 && r.width <= Math.min(960, window.innerWidth) && r.height >= 160) {
        best = node;
        if (/modal|dialog|popup|drawer|Modal|Dialog|Popup|Drawer/i.test(cls)) return node;
      }
      node = node.parentElement;
    }
    return best;
  }
  function isStoreNameText(t) {
    if (!t) return false;
    const s = String(t).trim();
    if (s.length < 2 || s.length > 36) return false;
    if (!/^[A-Za-z][A-Za-z0-9]*(?:\s[A-Za-z0-9]+){0,4}$/.test(s)) return false;
    if (isFakeStoreName(s)) return false;
    if (/^(NEW|Beta|Seller|Central|Temu|Close|Switch)$/i.test(s)) return false;
    return true;
  }
  // 从「HomeCove半托管」「Twilight Cove半托管切换」里抠出英文店名
  // （真实 DOM：店名文本节点和半托管标签在同一父级，textContent 无空格粘连）
  function extractStoreName(t) {
    if (!t) return null;
    const s = String(t).replace(/\s+/g, ' ').trim();
    if (isStoreNameText(s)) return s;
    const m = s.match(/^([A-Za-z][A-Za-z0-9]*(?:\s[A-Za-z0-9]+){0,4})/);
    if (m && isStoreNameText(m[1])) return m[1];
    // 去掉中文后缀再试
    const stripped = s.replace(/(半托管|全托管|当前店铺|切换|\s)+/g, ' ').trim();
    if (isStoreNameText(stripped)) return stripped;
    return null;
  }
  // 弹窗内「切换」控件：不限 button（beast-core 常用可点 div/span）
  function modalSwitchControls(root) {
    const scope = root || document;
    const out = [];
    for (const el of scope.querySelectorAll('*')) {
      if (!visible(el)) continue;
      const t = (el.textContent || '').trim();
      // 只要自身（或仅一层子节点）文本是「切换」，避免吃到整行
      if (t !== '切换') continue;
      if (el.children.length > 2) continue;
      out.push(clickableAncestor(el));
    }
    return [...new Set(out)];
  }
  // 从切店弹窗一行里抠英文店名
  function storeNameNear(el) {
    let node = el;
    for (let i = 0; i < 10 && node; i++) {
      const cands = [];
      // 直接文本节点（HomeCove 常是 mallName 下的裸文本，不在单独 span 里）
      for (const child of node.childNodes) {
        if (child.nodeType === 3) {
          const n = extractStoreName(child.textContent || '');
          if (n) cands.push(n);
        }
      }
      for (const e of node.querySelectorAll('span,div,p,a,button,b,strong,label')) {
        const n = extractStoreName((e.textContent || '').trim());
        if (n) cands.push(n);
        for (const child of e.childNodes) {
          if (child.nodeType === 3) {
            const n2 = extractStoreName(child.textContent || '');
            if (n2) cands.push(n2);
          }
        }
      }
      const self = extractStoreName((node.textContent || '').trim());
      if (self) cands.push(self);
      // 优先较短的纯店名
      cands.sort((a, b) => a.length - b.length);
      if (cands.length) return cands[0];
      node = node.parentElement;
    }
    return null;
  }
  // 在弹窗内枚举店名
  function listStoreNamesInModal(root) {
    if (!root) return [];
    const names = [];
    // ① 最稳：class 含 mallName（真实结构 account-info_mallName__xxx）
    for (const el of root.querySelectorAll('[class*="mallName"],[class*="mallInfo"],[class*="MallName"]')) {
      // 优先第一个文本节点 = 纯店名
      for (const child of el.childNodes) {
        if (child.nodeType === 3) {
          const n = extractStoreName(child.textContent || '');
          if (n) { names.push(n); break; }
        }
      }
      const n2 = extractStoreName((el.textContent || '').trim());
      if (n2) names.push(n2);
    }
    // ② innerText / textContent 整段（"HomeCove半托管 切换 Twilight Cove半托管…"）
    try {
      const raw = String(root.innerText || root.textContent || '');
      // 全局扫：英文店名紧贴可选的半托管/切换
      const re = /([A-Za-z][A-Za-z0-9]*(?:\s[A-Za-z0-9]+){0,4})(?=半托管|全托管|当前店铺|\s*切换|$|\n)/g;
      let m;
      while ((m = re.exec(raw))) {
        const n = extractStoreName(m[1]);
        if (n) names.push(n);
      }
      for (const line of raw.split(/\r?\n/)) {
        const n = extractStoreName(line);
        if (n) names.push(n);
      }
    } catch (e) {}
    // ③ 「切换」按钮向上回溯
    for (const sw of modalSwitchControls(root)) {
      const n = storeNameNear(sw);
      if (n) names.push(n);
    }
    // ④ 卡片 section
    for (const sec of root.querySelectorAll('[class*="mallSection"],[class*="switchSection"]')) {
      const n = extractStoreName((sec.textContent || '').trim());
      if (n) names.push(n);
      for (const child of sec.childNodes) {
        if (child.nodeType === 3) {
          const n2 = extractStoreName(child.textContent || '');
          if (n2) names.push(n2);
        }
      }
    }
    return [...new Set(names)].filter((n) => n && !isFakeStoreName(n));
  }
  function closeModal() {
    if (!modalOpen()) return true;
    const root = findModalRoot();
    const sels = [
      '[aria-label="Close"]',
      '[aria-label="close"]',
      '[aria-label="关闭"]',
      '.beast-core-modal-close',
      '.semi-modal-close',
      '.SnowModal_closeIcon',
      '[class*="modal-close"]',
      '[class*="Modal_close"]',
      '[class*="closeIcon"]',
      '[class*="CloseIcon"]',
      '[class*="close-icon"]',
      '[data-testid*="close"]',
    ];
    const scopes = root ? [root, document] : [document];
    for (const scope of scopes) {
      for (const s of sels) {
        let nodes = [];
        try { nodes = [...scope.querySelectorAll(s)]; } catch (e) { continue; }
        for (const x of nodes) {
          if (x && visible(x)) {
            realClick(x);
            if (!modalOpen()) return true;
          }
        }
      }
    }
    // 坐标点弹窗右上角 X（截图里是圆形关闭，常无文字/无 close class）
    if (root) {
      const r = root.getBoundingClientRect();
      const points = [
        [r.right - 18, r.top + 18],
        [r.right - 28, r.top + 28],
        [r.right - 22, r.top + 22],
        [r.right - 36, r.top + 20],
        [r.right - 14, r.top + 32],
        [r.right - 44, r.top + 24],
      ];
      for (const [x, y] of points) {
        const el = document.elementFromPoint(x, y);
        if (!el) continue;
        // 不要点到标题文字本身
        if (/切换店铺|您的账户/.test((el.textContent || '').trim()) && (el.textContent || '').trim().length > 2) continue;
        realClick(clickableAncestor(el));
        if (!modalOpen()) return true;
      }
    }
    // 点遮罩
    const masks = document.querySelectorAll('[class*="modal-mask"],[class*="Modal_mask"],[class*="mask"],[class*="Mask"]');
    for (const m of masks) {
      if (visible(m) && m.getBoundingClientRect().width > window.innerWidth * 0.5) {
        realClick(m);
        if (!modalOpen()) return true;
      }
    }
    // Escape 兜底
    for (const type of ['keydown', 'keyup']) {
      document.dispatchEvent(new KeyboardEvent(type, { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
    }
    try { document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true })); } catch (e) {}
    if (!modalOpen()) return true;
    // 最终手段：直接隐藏弹窗+遮罩，避免卡死页面（不依赖 React 是否吃合成点击）
    try {
      const hide = (el) => { if (el && el.style) { el.style.setProperty('display', 'none', 'important'); el.style.setProperty('pointer-events', 'none', 'important'); } };
      if (root) {
        hide(root);
        let p = root.parentElement;
        for (let i = 0; i < 6 && p && p !== document.body; i++) {
          const cls = String(p.className || '');
          const r = p.getBoundingClientRect();
          if (/modal|dialog|popup|wrapper|portal|Mask|mask/i.test(cls) || (r.width > window.innerWidth * 0.8 && r.height > window.innerHeight * 0.8)) {
            hide(p);
          }
          p = p.parentElement;
        }
      }
      document.querySelectorAll('[class*="modal-mask"],[class*="Modal_mask"],[class*="mask"],[class*="Mask"],[class*="modal-wrapper"],[class*="Modal_wrapper"]').forEach((el) => {
        const r = el.getBoundingClientRect();
        if (r.width > 100) hide(el);
      });
      // 清掉 body 滚动锁
      try { document.body.style.removeProperty('overflow'); document.documentElement.style.removeProperty('overflow'); } catch (e) {}
      LOG.warn('closeModal: forced hide overlay');
    } catch (e) { LOG.warn('closeModal force hide error: ' + (e && e.message || e)); }
    return !modalOpen();
  }

  // 压缩输出某元素的 HTML 骨架（去 style/data 属性），便于回传诊断
  function domSkel(el, maxLen) {
    if (!el) return 'null';
    let h = (el.outerHTML || '');
    h = h.replace(/\s(style|data-[\w-]+|aria-[\w-]+)="[^"]*"/g, '').replace(/>\s+</g, '><').replace(/\s{2,}/g, ' ');
    return h.slice(0, maxLen || 2200);
  }

  async function openStoreModal(diag) {
    diag = diag || [];
    try { window.scrollTo(0, 0); document.documentElement.scrollTop = 0; } catch (e) {}
    await sleep(150);
    if (modalOpen()) { diag.push('弹窗已开'); return true; }
    const nameEl = findStoreNameEl();
    diag.push('店名=' + (nameEl ? (nameEl.textContent || '').trim() : 'null'));
    if (nameEl) {
      // 只点一次触发下拉：点店名的可点祖先 + 店名右侧箭头坐标（避免多次点击把下拉又关掉）
      const r = nameEl.getBoundingClientRect();
      realClick(clickableAncestor(nameEl));
      await sleep(120);
      const el = document.elementFromPoint(Math.min(window.innerWidth - 3, r.right + 14), r.top + r.height / 2);
      if (el && el !== nameEl) realClick(el);
    } else {
      // 读不到店名：点右上角头像/热区
      const W = window.innerWidth || 1280;
      for (const y of [24, 36, 48]) {
        for (const x of [W - 40, W - 80, W - 120, W - 160]) {
          const el = document.elementFromPoint(x, y);
          if (el) realClick(clickableAncestor(el));
        }
      }
      diag.push('无店名,已点右上热区');
    }
    // 下拉里“切换”按钮：只认可见的、精确文本“切换”，取最后一个（下拉通常在 DOM 靠后）
    const sw = await waitFor(() => {
      const cands = textEls(/^切换$/, 6).filter(visible);
      return cands.length ? clickableAncestor(cands[cands.length - 1]) : null;
    }, 3500);
    diag.push('下拉切换按钮=' + !!sw);
    if (sw) realClick(sw);
    let ok = !!(await waitFor(() => (modalOpen() ? true : null), 4500));
    // 仍未开：再点一次右上 + 宽松「切换」
    if (!ok) {
      const W = window.innerWidth || 1280;
      for (const x of [W - 48, W - 100, W - 140]) {
        const el = document.elementFromPoint(x, 32);
        if (el) realClick(clickableAncestor(el));
      }
      await sleep(300);
      const loose = textEls(/^切换/, 12).filter(visible);
      if (loose.length) realClick(clickableAncestor(loose[loose.length - 1]));
      ok = !!(await waitFor(() => (modalOpen() ? true : null), 4000));
      diag.push('重试打开=' + ok);
    }
    diag.push('弹窗打开=' + ok);
    if (!ok) {
      LOG.warn('Open store modal failed: ' + diag.join(' ; '));
    }
    return ok;
  }

  // 等弹窗里店铺行渲染完（必须在 modal root 内看到店名/切换/托管）
  async function waitModalStoreRows() {
    return !!(await waitFor(() => {
      const root = findModalRoot();
      if (!root) return null;
      if (listStoreNamesInModal(root).length > 0) return true;
      if (modalSwitchControls(root).length > 0) return true;
      if (/托管|当前店铺/.test(root.textContent || '')) return true;
      return null;
    }, 6000, 250));
  }

  async function listStores() {
    if (!(await openStoreModal())) return [];
    const rowsReady = await waitModalStoreRows();
    if (!rowsReady) LOG.warn('listStores: modal opened but store rows not ready');
    await sleep(400);
    const root = findModalRoot();
    let names = listStoreNamesInModal(root);
    // 诊断：0 店时把弹窗里短文本打出来，方便对照 DOM
    if (!names.length) {
      const sample = [];
      const scope = root || document.body;
      for (const el of scope.querySelectorAll('span,div,p,button,a')) {
        if (!visible(el) || el.children.length > 2) continue;
        const t = (el.textContent || '').trim();
        if (t && t.length <= 24) sample.push(el.tagName + ':' + t);
        if (sample.length >= 25) break;
      }
      let textPreview = '';
      try { textPreview = String((root && (root.innerText || root.textContent)) || '').replace(/\s+/g, ' ').trim().slice(0, 240); } catch (e) {}
      LOG.warn('listStores empty diag: root=' + !!(root) + ' switches=' + modalSwitchControls(root).length
        + ' text="' + textPreview + '" sample=' + sample.join(' | '));
      if (root) LOG.warn('listStores root skel: ' + domSkel(root, 1200));
    }
    // 务必关掉弹窗
    for (let i = 0; i < 3 && modalOpen(); i++) {
      closeModal();
      await sleep(250);
    }
    if (modalOpen()) LOG.warn('listStores: modal still open after close attempts');
    const uniq = [...new Set(names)];
    LOG.info('listStores: ' + uniq.length + ' stores: ' + uniq.join(', '));
    return uniq;
  }

  async function switchTo(target) {
    pageMode = 'switch';
    try {
      return await switchToInner(target);
    } finally {
      pageMode = 'idle';
      setForceWatchFilterOn(false);
    }
  }
  async function switchToInner(target) {
    const diag = [];
    const cur = readStoreName();
    // 已是目标店：绝不要再点弹窗
    if (cur && String(cur) === String(target)) {
      if (modalOpen()) closeModal();
      LOG.info('switchTo skip: already on ' + target);
      return { ok: true, msg: '已是当前店 ' + target + '，无需切换' };
    }
    if (!(await openStoreModal(diag))) return { ok: false, msg: '打不开弹窗 | ' + diag.join(' ; ') };
    await waitModalStoreRows();
    await sleep(250);
    const root = findModalRoot();
    const esc = String(target).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const nameRe = new RegExp('^' + esc + '$', 'i');
    let btn = null;
    for (const b of modalSwitchControls(root)) {
      const name = storeNameNear(b);
      if (name && nameRe.test(name)) {
        if (b.disabled || b.getAttribute('aria-disabled') === 'true') {
          closeModal();
          return { ok: true, msg: '弹窗显示已是当前店 ' + target };
        }
        // 当前店行常带「当前店铺」且切换按钮灰色
        let card = b.parentElement;
        let cardText = '';
        for (let i = 0; i < 6 && card; i++) {
          cardText = card.textContent || '';
          if (/半托管|全托管|当前店铺/.test(cardText)) break;
          card = card.parentElement;
        }
        if (/当前店铺/.test(cardText) && nameRe.test(name)) {
          // 若目标就是当前店
          closeModal();
          return { ok: true, msg: '已标记当前店铺 ' + target };
        }
        btn = b;
        break;
      }
    }
    // 点 mallName / 店名文本旁的切换按钮
    if (!btn && root) {
      for (const el of root.querySelectorAll('[class*="mallName"],[class*="mallSection"],span,div,p,a')) {
        if (!visible(el)) continue;
        const n = extractStoreName((el.textContent || '').trim());
        if (!n || !nameRe.test(n)) continue;
        // 同卡片内找切换按钮
        let card = el;
        for (let i = 0; i < 6 && card; i++) {
          const sw = [...card.querySelectorAll('button,[role=button],div,span')].find((b) => {
            const t = (b.textContent || '').trim();
            return t === '切换' && visible(b) && !b.disabled;
          });
          if (sw) { btn = clickableAncestor(sw); break; }
          card = card.parentElement;
        }
        if (btn) break;
      }
    }
    if (!btn) {
      closeModal();
      return { ok: false, msg: '没找到可点的切换入口(' + target + ')' };
    }
    LOG.info('Switching store to: ' + target);
    realClick(btn);
    await sleep(1500);
    if (modalOpen()) {
      const now = readStoreName();
      if (now && String(now) === String(target)) {
        closeModal();
        return { ok: true, msg: '已在 ' + target + '（弹窗已关）' };
      }
      if (now && cur && String(now) === String(cur)) {
        closeModal();
        return { ok: false, msg: '已点切换但未离开 ' + cur + '，已关弹窗' };
      }
    }
    return { ok: true, msg: '已点击切换到 ' + target };
  }

  // ---------- 主动捞「商品流量待关注」明细（发现异常时调，点筛选→扫→重置） ----------
  // 读列表底部「共有 N 条」（筛选生效后该数=待关注总数）
  function readTotalCount() {
    const el = [...document.querySelectorAll('*')].find(
      (x) => x.children.length === 0 && /共有\s*[\d,]+\s*条/.test(x.textContent || '')
    );
    if (!el) return null;
    const m = (el.textContent || '').match(/共有\s*([\d,]+)\s*条/);
    return m ? Number(m[1].replace(/,/g, '')) : null;
  }
  // 定位「商品流量待关注」快速筛选 chip 容器（与 readChipCount 同一稳定 class 前缀）
  function findWatchChip() {
    for (const card of document.querySelectorAll('[class*="use-quick-field_tsx_card__"]')) {
      if (/商品流量待关注/.test(card.textContent || '')) return card;
    }
    return null;
  }
  // 判断「商品流量待关注」chip 是否处于选中（筛选生效）状态。
  // Temu 选中态：class 带 selected/active、aria-pressed、内部 checkbox，或主色描边。
  function isChipSelected(chip) {
    if (!chip) return false;
    const root = chip.closest('[class*="use-quick-field"]') || chip;
    const nodes = [root, chip];
    for (const n of nodes) {
      if (!n) continue;
      const cls = String(n.className || '');
      if (/(?:^|[\s_-])(?:selected|is-selected|isselected|active|is-active|isactive|checked|is-checked|current)(?:[\s_-]|$)/i.test(cls)) {
        return true;
      }
      if (n.getAttribute('aria-pressed') === 'true') return true;
      if (n.getAttribute('aria-selected') === 'true') return true;
      if (n.getAttribute('data-selected') === 'true') return true;
    }
    const input = root.querySelector && root.querySelector('input[type="checkbox"],input[type="radio"]');
    if (input && input.checked) return true;
    // 选中 chip 常见主色蓝边（截图：蓝框「商品流量待关注」）
    try {
      const st = window.getComputedStyle(root);
      const bw = parseFloat(st.borderTopWidth) || parseFloat(st.outlineWidth) || 0;
      if (bw >= 1) {
        const color = st.borderTopColor || st.outlineColor || '';
        const m = color.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i);
        if (m) {
          const r = Number(m[1]); const g = Number(m[2]); const b = Number(m[3]);
          if (b >= 160 && b > r + 30 && b > g + 20) return true;
        }
      }
    } catch (e) { /* ignore */ }
    return false;
  }
  function isWatchFilterOn() {
    return isChipSelected(findWatchChip());
  }
  // 点「重置」清掉快速筛选，恢复用户视图
  function clickReset() {
    const btn = textEls(/^重置$/, 6).filter(visible)[0];
    if (btn) realClick(clickableAncestor(btn));
  }
  // 强制清掉「商品流量待关注」等快速筛选。
  // 历史假告警根因：只点「重置」有时清不掉 chip 选中，在售 tab 计数被筛成限流子集（15→4），
  // 随后 scanOnSale 把子集当全量基准，误报下架。这里：若 chip 仍选中则再点一次 toggle + 重置。
  async function clearWatchFilter(opts) {
    opts = opts || {};
    const waitMs = opts.waitMs || 800;
    let cleared = !isWatchFilterOn();
    for (let attempt = 1; attempt <= 3 && !cleared; attempt++) {
      const chip = findWatchChip();
      if (chip && isChipSelected(chip)) {
        LOG.info('clearWatchFilter: toggle off watch chip (attempt ' + attempt + ')');
        realClick(clickableAncestor(chip));
        await sleep(400);
      }
      clickReset();
      await sleep(waitMs);
      cleared = !isWatchFilterOn();
    }
    if (!cleared) LOG.warn('clearWatchFilter: watch chip still selected after retries');
    return cleared;
  }
  // 点开「商品流量待关注」筛选 → 扫出这几条商品(productId+name+skc) → 重置。
  // 筛选生效后网格里每行都是待关注商品，故取全部行（不再依赖行内徽标）。
  // 只覆盖筛选后的当前页(默认 20 条)，>20 条的溢出由 total 提示行说明。
  // v15：先切「在售中」再点待关注 chip——Temu 的「商品流量待关注」chip 会把已下架商品也算进去，
  // 用户只要在售；不切 tab 时会扫到下架 SKC 并误报。
  async function scanWatchList() {
    LOG.info('scanWatchList: scanning (on-sale only)...');
    pageMode = 'traffic';
    setForceWatchFilterOn(false);
    try {
      return await scanWatchListInner();
    } finally {
      // 关闭 force 后仍 grace 数秒：挡住筛选期间已发出、清除后才返回的 countStatus
      setForceWatchFilterOn(false);
      markWatchFilterGrace(WATCH_FILTER_GRACE_MS);
      pageMode = 'idle';
    }
  }
  async function scanWatchListInner() {
    const findTab = (re) => {
      const labels = [...document.querySelectorAll('[data-testid="beast-core-tab-itemLabel"]')].filter(visible);
      return labels.find((e) => re.test((e.textContent || '').trim())) || textEls(re, 14).filter(visible)[0] || null;
    };
    const backToAll = () => { const t = findTab(/^全部/); if (t) realClick(clickableAncestor(t)); };
    const mapWatchItem = (p) => ({
      productId: p.productId,
      name: p.name,
      skc: p.skc,
      saleStatus: 'onSale',
      skuCodes: Array.isArray(p.skuCodes) ? p.skuCodes.slice() : [],
      hotSale: !!p.hotSale,
      watch: true,
      decline: !!p.decline,
    });
    // ① 复位干净视图，再切「在售中」——排除已下架/已终止
    backToAll();
    await sleep(300);
    await clearWatchFilter({ waitMs: 600 });
    const onSaleTab = findTab(/^在售中/);
    if (onSaleTab) {
      realClick(clickableAncestor(onSaleTab));
      await waitFor(() => document.querySelector('[data-testid="beast-core-table-body-tr"]'), 6000, 300);
      await sleep(1000);
    } else {
      LOG.warn('scanWatchList: 在售中 tab not found, continue with current view');
    }
    const chip = findWatchChip();
    if (!chip) {
      LOG.warn('scanWatchList: chip not found');
      backToAll();
      return {
        store: readStoreName(), items: [], applied: false, trusted: false,
        trustReason: 'chip-not-found', msg: '未找到待关注筛选 chip',
      };
    }
    // chip 上的「待关注 N」= 权威目标规模（可含已下架；在售明细应 ≤ N）
    const chipN = readChipCount([...document.querySelectorAll('*')], '商品流量待关注');
    const before = readTotalCount();
    const cleanOnSaleTab = readTabCount(/^在售中/);
    // 点选期间强制标记筛选态，防止中间 countStatus 把筛选后在售数写进基准
    setForceWatchFilterOn(true);
    realClick(clickableAncestor(chip));
    // 等列表真正刷新：底部「共有 N 条」变小才算筛选生效（=before 时继续等，不靠假 selected）
    await waitFor(() => {
      const t = readTotalCount();
      return (t != null && before != null && t < before) ? t : null;
    }, 8000, 300);
    await sleep(1200); // 等筛选后的网格稳定渲染
    const after = readTotalCount();
    const productsAfter = scanProducts();
    const watchLike = productsAfter.filter((p) => p.watch).length;
    // v21：applied 必须有「列表被筛小」或「在售全集确实都是待关注」的硬证据。
    // 旧版 `|| isWatchFilterOn()` 在 chip 视觉选中但列表未刷新时，会把整页在售 12 条当限流明细
    // （Twilight/HomeCove 日志：chip=3/6 却 onSaleItems=12/15 → seed 污染 → 限流池少计）。
    const narrowed = after != null && before != null && after < before;
    const allOnSaleAreWatch = cleanOnSaleTab != null && chipN != null
      && chipN >= cleanOnSaleTab && after != null && after === cleanOnSaleTab
      && productsAfter.length > 0;
    const allRowsWatchBadge = productsAfter.length > 0 && watchLike === productsAfter.length
      && after != null && before != null && after <= before
      && (chipN == null || productsAfter.length <= chipN + 1);

    let applied = false;
    let trusted = false;
    let trustReason = '';
    let items = [];

    if (narrowed || allOnSaleAreWatch || allRowsWatchBadge) {
      // 筛选视图下：非 removed 视为在售待关注（不依赖行内徽标）
      items = productsAfter
        .filter((p) => p && p.saleStatus !== 'removed')
        .map(mapWatchItem);
      applied = items.length > 0 || (after === 0);
      trusted = true;
      trustReason = narrowed ? 'list-narrowed' : (allOnSaleAreWatch ? 'all-onsale-watch' : 'all-rows-badge');
    }

    // 硬护栏：明细条数 ≈ 在售全集，但 chip 明显更小 → 筛选没生效，整锅丢弃
    // （日志实锤：Twilight chip=3 / items=12 / onSale=12）
    if (items.length && cleanOnSaleTab != null && cleanOnSaleTab > 0
      && items.length >= cleanOnSaleTab
      && chipN != null && chipN < cleanOnSaleTab) {
      LOG.warn('scanWatchList reject full-onsale dump: items=' + items.length
        + ' onSale=' + cleanOnSaleTab + ' chip=' + chipN);
      items = [];
      applied = false;
      trusted = false;
      trustReason = 'full-onsale-as-watch';
    }
    // 明细远超 chip（chip 含下架也应 ≥ 在售待关注）→ 不可信
    if (items.length && chipN != null && chipN >= 0 && items.length > chipN + 1) {
      LOG.warn('scanWatchList reject oversize: items=' + items.length + ' chip=' + chipN);
      items = [];
      applied = false;
      trusted = false;
      trustReason = 'items-exceed-chip';
    }
    // 筛选未收窄时：绝不以 isWatchFilterOn 单独放行；降级只收带徽标行（被动级，不标 trusted）
    if (!applied && !trusted) {
      const badgeOnly = productsAfter
        .filter((p) => p && p.watch && p.saleStatus !== 'removed')
        .map(mapWatchItem);
      if (badgeOnly.length && (chipN == null || badgeOnly.length <= chipN + 1)) {
        items = badgeOnly;
        applied = true;
        trusted = false;
        trustReason = 'badge-fallback';
        LOG.info('scanWatchList badge-fallback: items=' + items.length + ' (filter not narrowed)');
      } else {
        trustReason = trustReason || 'filter-not-applied';
        LOG.warn('scanWatchList not applied: before=' + before + ' after=' + after
          + ' chip=' + chipN + ' onSale=' + cleanOnSaleTab
          + ' filterOn=' + isWatchFilterOn() + ' watchLike=' + watchLike
          + '/' + productsAfter.length);
      }
    }

    // 复位（必须彻底清掉筛选，否则会污染随后的在售扫描 → 误报下架）
    // 注意：先保持 force=true 直到 clear 完成，再 grace；中间迟来的响应仍标 filterOn
    const cleared = await clearWatchFilter({ waitMs: 800 });
    // 额外等总数/在售 tab 回到筛选前水平（筛选态 tab 也会被压成子集）
    await waitFor(() => {
      if (isWatchFilterOn()) return null;
      const t = readTotalCount();
      if (before != null && t != null && t >= before) return t;
      const tab = readTabCount(/^在售中/);
      if (cleanOnSaleTab != null && tab != null && tab >= cleanOnSaleTab) return tab;
      if (before == null && !isWatchFilterOn()) return true;
      return null;
    }, 8000, 300);
    if (!cleared || isWatchFilterOn()) {
      LOG.warn('scanWatchList: filter residual after clear, retry once');
      await clearWatchFilter({ waitMs: 1000 });
    }
    setForceWatchFilterOn(false);
    markWatchFilterGrace(WATCH_FILTER_GRACE_MS);
    backToAll();
    await sleep(600);
    LOG.info('scanWatchList done: applied=' + applied + ' trusted=' + trusted
      + ' reason=' + trustReason
      + ' onSaleItems=' + items.length
      + ' total=' + after + ' chip=' + chipN + ' onSaleTab=' + cleanOnSaleTab
      + ' filterOn=' + isWatchFilterOn());
    return {
      store: readStoreName(),
      items: items,
      total: items.length,
      applied: applied,
      trusted: trusted,
      trustReason: trustReason,
      chipTotal: after,
      chipCount: chipN,
      onSaleTabCount: cleanOnSaleTab,
      filterCleared: !isWatchFilterOn(),
    };
  }

  // 读某个 tab 标签上印的数字（形如「在售中 13」/「全部 214」）。干净无筛选视图下=真实数量。
  function readTabCount(re) {
    const labels = [...document.querySelectorAll('[data-testid="beast-core-tab-itemLabel"]')].filter(visible);
    for (const el of labels) {
      const t = (el.textContent || '').trim();
      if (re.test(t)) { const m = t.match(/(\d[\d,]*)/); if (m) return Number(m[1].replace(/,/g, '')); }
    }
    return null;
  }
  // 扫「在售中」商品清单：先复位到干净视图 → 点在售 tab → 确认视图生效 → scanProducts。
  // v20：返回 trust='full-onsale'|'untrusted'。只有 full-onsale 才允许 background 写基准。
  // ⚠️ 关键①：扫描前**必须**清掉一切快速筛选（尤其「商品流量待关注」）。
  // ⚠️ 关键②：点完「在售中」必须验证视图真的生效（底部「共有 N 条」== tab 上「在售中 N」）再扫。
  // ⚠️ 关键③：scanned===tabCount 单独不够——筛成 4 时 4===4 永远成立；主权威是 trust。
  async function scanOnSaleList() {
    LOG.info('scanOnSaleList: scanning...');
    pageMode = 'onsale';
    setForceWatchFilterOn(false);
    try {
      return await scanOnSaleListInner();
    } finally {
      setForceWatchFilterOn(false);
      pageMode = 'idle';
    }
  }
  function untrustedOnSale(extra) {
    return Object.assign({
      store: readStoreName(),
      items: [],
      onSaleTabCount: null,
      watchFilterOn: isWatchFilterOn(),
      trust: 'untrusted',
    }, extra || {});
  }
  async function scanOnSaleListInner() {
    const findTab = (re) => {
      const labels = [...document.querySelectorAll('[data-testid="beast-core-tab-itemLabel"]')].filter(visible);
      return labels.find((e) => re.test((e.textContent || '').trim())) || textEls(re, 14).filter(visible)[0] || null;
    };
    const backToAll = () => { const t = findTab(/^全部/); if (t) realClick(clickableAncestor(t)); };
    // ① 复位到干净、无快速筛选的状态
    backToAll();
    await sleep(300);
    const filterCleared = await clearWatchFilter({ waitMs: 1000 });
    if (!filterCleared) {
      LOG.warn('scanOnSaleList aborted: 商品流量待关注筛选无法清除，本轮放弃（不动基准）');
      backToAll();
      return untrustedOnSale({
        msg: '限流筛选未清除，本轮放弃扫描',
        watchFilterOn: true,
        trustReason: 'filter-uncleared',
      });
    }
    // ② 点「在售中」tab 并等视图生效；点击可能被残留弹窗拦截 → 失败重试一次
    let tabCount = null;
    let viewOk = false;
    let viewSoft = false; // tabCount 读不到时的软通过（偏保守，最终 trust 仍看 filter）
    for (let attempt = 1; attempt <= 2 && !viewOk; attempt++) {
      if (isWatchFilterOn()) {
        LOG.warn('scanOnSaleList: watch filter reappeared before attempt ' + attempt + ', clearing');
        await clearWatchFilter({ waitMs: 800 });
      }
      const onSaleTab = findTab(/^在售中/);
      if (onSaleTab) realClick(clickableAncestor(onSaleTab));
      await waitFor(() => document.querySelector('[data-testid="beast-core-table-body-tr"]'), 8000, 300);
      await sleep(1800);
      if (isWatchFilterOn()) {
        LOG.warn('scanOnSaleList: 在售视图仍带限流筛选(第' + attempt + '次) tabCount=' + readTabCount(/^在售中/));
        await clearWatchFilter({ waitMs: 800 });
        continue;
      }
      tabCount = readTabCount(/^在售中/);
      if (tabCount == null) {
        // v20：读不到 tab 数 → 无法交叉验证，标 soft，后面若 filter off 仍可 full（真零/空店场景）
        viewOk = true;
        viewSoft = true;
        break;
      }
      const ok = await waitFor(() => {
        if (isWatchFilterOn()) return null;
        const t = readTotalCount();
        return (t != null && t === tabCount) ? true : null;
      }, 6000, 300);
      if (ok && !isWatchFilterOn()) { viewOk = true; break; }
      // footer 读不到但 filter off + tabCount 可读：允许继续，trust 仍要求 filter off
      if (readTotalCount() == null && !isWatchFilterOn()) {
        viewOk = true;
        viewSoft = true;
        break;
      }
      LOG.warn('scanOnSaleList: 在售视图未生效(第' + attempt + '次) gridTotal=' + readTotalCount() + ' tabCount=' + tabCount + ' filterOn=' + isWatchFilterOn());
      await clearWatchFilter({ waitMs: 800 });
    }
    if (!viewOk) {
      LOG.warn('scanOnSaleList aborted: 在售视图两次都未生效，本轮放弃（不动基准）');
      backToAll();
      return untrustedOnSale({
        onSaleTabCount: tabCount,
        msg: '在售视图未生效，本轮放弃扫描',
        trustReason: 'view-not-ready',
      });
    }
    // ③ 扫前最后一道：限流筛选仍开着就放弃
    if (isWatchFilterOn()) {
      LOG.warn('scanOnSaleList aborted: watch filter still on at scan time');
      backToAll();
      return untrustedOnSale({
        msg: '限流筛选仍开启，本轮放弃扫描',
        watchFilterOn: true,
        trustReason: 'filter-on-at-scan',
      });
    }
    // ④ 读干净视图下「在售中 N」
    const onSaleTabCount = readTabCount(/^在售中/);
    const products = scanProducts();
    const items = products.map((p) => ({ productId: p.productId, name: p.name, skc: p.skc }));
    // ⑤ overflow = 视图污染
    if (onSaleTabCount != null && items.length > onSaleTabCount) {
      LOG.warn('scanOnSaleList aborted: scanned=' + items.length + ' > tabCount=' + onSaleTabCount + '（视图污染，本轮放弃）');
      backToAll();
      return untrustedOnSale({
        onSaleTabCount: onSaleTabCount,
        msg: '扫描行数超过在售数，疑似视图污染，本轮放弃',
        trustReason: 'overflow',
      });
    }
    // 扫完再确认一次 filter
    if (isWatchFilterOn()) {
      LOG.warn('scanOnSaleList aborted: filter reappeared after scan');
      backToAll();
      return untrustedOnSale({
        onSaleTabCount: onSaleTabCount,
        msg: '扫描后筛选又出现，本轮放弃',
        watchFilterOn: true,
        trustReason: 'filter-after-scan',
      });
    }
    var scanMsg = 'scanOnSale: tabCount=' + onSaleTabCount + ' scanned=' + items.length
      + ' filterOn=false trust=full-onsale' + (viewSoft ? ' softView=1' : '');
    if (items.length && onSaleTabCount && items.length < onSaleTabCount) scanMsg += ' (WARNING: possible page truncation)';
    LOG.info(scanMsg);
    backToAll();
    LOG.info('scanOnSaleList done: items=' + items.length + ' onSaleTabCount=' + onSaleTabCount);
    return {
      store: readStoreName(),
      items: items,
      onSaleTabCount: onSaleTabCount,
      watchFilterOn: false,
      trust: 'full-onsale',
      trustReason: viewSoft ? 'soft-view' : 'clean-onsale',
    };
  }

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg || !msg.cmd) return;
    (async () => {
      try {
        if (msg.cmd === 'ping') { sendResponse({ store: readStoreName() }); return; } // 只读，不入锁
        if (msg.cmd === 'listStores') { sendResponse({ names: await withLock(listStores) }); return; }
        if (msg.cmd === 'switchTo') { sendResponse(await withLock(() => switchTo(msg.target))); return; }
        if (msg.cmd === 'scanOnSale') { sendResponse(await withLock(scanOnSaleList)); return; }
        if (msg.cmd === 'scanWatchList') { sendResponse(await withLock(scanWatchList)); return; }
      } catch (e) { LOG.error('Command handler error: cmd=' + msg.cmd + ' error=' + String((e && e.message) || e)); sendResponse({ ok: false, msg: String((e && e.message) || e) }); }
    })();
    return true;
  });
})();
