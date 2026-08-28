/* TikTok seller center: 内容分析 → 商品卡 / 商品数据分析 (P2.0 POC).
 * Ziniao page exec. Card KPIs + product table (exposure/CTR/CVR).
 */
(function () {
  function clean(t) {
    return String(t == null ? '' : t).replace(/\s+/g, ' ').trim();
  }
  function detectCurrency(text) {
    var s = String(text || '');
    if (/[£]|GBP/i.test(s)) return 'GBP';
    if (/[€]|EUR/i.test(s)) return 'EUR';
    if (/[¥￥]|CNY|RMB/i.test(s) && !/\$/.test(s)) return 'CNY';
    if (/\$|USD/i.test(s)) return 'USD';
    return null;
  }
  function parseNumber(value) {
    if (value == null || value === '') return null;
    if (typeof value === 'number' && isFinite(value)) return value;
    var s = String(value).trim();
    if (!s || s === '-' || s === '—') return null;
    var pct = s.match(/^(-?[\d,]+(?:\.\d+)?)\s*%$/);
    if (pct) {
      var p = Number(String(pct[1]).replace(/,/g, ''));
      return isFinite(p) ? p : null;
    }
    /* 24.50K / 1.2万 / 3M */
    var km = s.match(/-?\s*[¥$€£￥]?\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*([KkMm万亿])/);
    if (km) {
      var base = Number(String(km[1]).replace(/,/g, ''));
      if (isFinite(base)) {
        var u = km[2];
        if (u === 'K' || u === 'k') return base * 1000;
        if (u === 'M' || u === 'm') return base * 1000000;
        if (u === '万') return base * 10000;
        if (u === '亿') return base * 100000000;
      }
    }
    var m = s.match(/-?\s*[¥$€£￥]?\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)/);
    if (m) {
      var n0 = Number(String(m[1]).replace(/,/g, ''));
      if (isFinite(n0)) return n0;
    }
    s = s.replace(/[,\s]/g, '').replace(/[¥$€£￥]/g, '').replace(/%/g, '');
    var n = Number(s);
    return isFinite(n) ? n : null;
  }
  function bodyText() {
    return clean((document.body && (document.body.innerText || document.body.textContent)) || '');
  }
  function findByRegex(body, patterns) {
    for (var i = 0; i < patterns.length; i++) {
      var m = body.match(patterns[i]);
      if (!m) continue;
      var raw = m[1] != null ? m[1] : m[0];
      var n = parseNumber(raw);
      if (n != null) return { value: n, label: String(m[0]).slice(0, 120) };
    }
    return null;
  }
  function cellText(el) {
    return clean(el && (el.innerText || el.textContent));
  }
  function matchProductHeader(h) {
    var t = clean(h).toLowerCase();
    if (!t) return null;
    /* 操作列 */
    if (/^action$|^操作$|^详情$|^details?$/.test(t)) return null;
    if (/商品\s*id|product\s*id|\bid\b/.test(t) && !/视频|video|card\s*name/.test(t)) return 'productId';
    /* 英文 UK 站：View-to-paid rate / Viewers（≠ 视频 Views） */
    if (
      /曝光\s*到\s*成交|曝光.*转化|\bcvr\b|转化率|conversion\s*rate|view[\s\-]*to[\s\-]*paid|paid\s*rate|viewers?\s*to\s*paid/i.test(
        t
      )
    )
      return 'cvr';
    if (
      /曝光\s*用户|曝光次数|曝光数|商品\s*曝光|impression|show|展示|viewers?\b|unique\s*viewers?|product\s*views?\b/i.test(t) &&
      !/paid|转化|rate|ctr|cvr/.test(t)
    )
      return 'impressions';
    if (/点击|clicks?/.test(t) && !/率|rate|ctr/.test(t)) return 'clicks';
    /* 2026-08-21：EU 域列名辨析——
     * 「商品点击率」= CTR（点击率）→ ctr；「CTOR（SKU 订单）」= 点击到订单转化率 → cvr（非 ctr，否则覆盖真 CTR）。
     * CTOR 须先于 orders 命中（其列名含「订单」）。*/
    if (/\bctor\b/i.test(t)) return 'cvr';
    if (/\bctr\b|点击率|click-?through/.test(t)) return 'ctr';
    if (/订单|orders?|销量|成交件数|units?|sku\s*订单/.test(t) && !/ctor|ctr|率|rate|金额|amount|avg|平均/i.test(t)) return 'orders';
    if (/\bgmv\b|销售额|成交额|revenue/.test(t)) return 'gmv';
    if (/渠道|channel|来源|source|流量来源/.test(t) && !/resource/.test(t)) return 'channel';
    /* 2026-08-21：EU 域 Arco 表首列叫「信息」，内容是渠道名（商家商品卡/商家视频/联盟/商家直播），
     * 当作 channel 列（同 UK 域「渠道/来源」列）。仅在短文本「信息」时命中，避免误抓长标题。 */
    if (t === '信息' || /^info$/i.test(t)) return 'channel';
    if (/日\s*客户|客户数|customers?/.test(t)) return 'customers';
    if (
      /商品卡\s*名称|product\s*card\s*name|商品名称|product\s*name|名称|title|name/.test(t) &&
      !/曝光|点击|gmv|订单|ctr|cvr|转化|viewer|paid|impression/.test(t)
    )
      return 'title';
    if (/商品|product/.test(t) && !/曝光|点击|gmv|订单|ctr|cvr|转化|viewer|paid|impression|card\s*analytics/.test(t))
      return 'title';
    return null;
  }
  /** 经典 5 列：名称 | GMV | CVR% | 曝光 | 操作 — 表头映射不全时按单元格形态回填 */
  /* 2026-08-21：EU 域 Arco 表每个 td 塞多值（"79.1% £1,340.68 42.02%" = 占比+金额+变化率），
   * parseNumber 抓首个数字会拿到占比 79.1 而非金额。extractMoneyAfterCurrency 专取币种符号后的金额。 */
  function extractMoneyAfterCurrency(t) {
    var s = String(t || '');
    var m = s.match(/[£$€¥￥]\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)/);
    if (m) {
      var n = Number(String(m[1]).replace(/,/g, ''));
      if (isFinite(n)) return n;
    }
    return null;
  }
  function enrichProductRowFromCells(row) {
    var cells = row.rawCells || [];
    if (!cells.length) return row;
    var money = null;
    var pct = null;
    var bigNum = null;
    for (var i = 0; i < cells.length; i++) {
      var t = clean(cells[i]);
      if (!t || /details?|详情|操作/i.test(t)) continue;
      /* 长标题 / 含 ID: 不当指标 */
      if (/\bID:\s*\d{6,}/i.test(t) && t.length > 24) continue;
      if (/[£$€¥￥]/.test(t)) {
        /* 含币种符号：优先取币种后的金额（EU 多值单元格）；取不到再退回 parseNumber */
        var mv = extractMoneyAfterCurrency(t);
        if (mv == null) mv = parseNumber(t);
        if (mv != null && money == null) money = mv;
        continue;
      }
      if (/%\s*$/.test(t) || /^\d+(\.\d+)?\s*%$/.test(t)) {
        if (pct == null) pct = parseNumber(t);
        continue;
      }
      if (/[KkMm万亿]/.test(t)) {
        var nK = parseNumber(t);
        if (nK != null && (bigNum == null || nK > bigNum)) bigNum = nK;
        continue;
      }
      if (/^\d[\d,]*(\.\d+)?$/.test(t)) {
        var n2 = parseNumber(t);
        var digits = String(t).replace(/[^\d]/g, '');
        if (
          n2 != null &&
          n2 >= 100 &&
          n2 < 1000000000 &&
          digits.length <= 9 &&
          (bigNum == null || n2 > bigNum)
        ) {
          bigNum = n2;
        }
      }
    }
    if (row.gmv == null && money != null) row.gmv = money;
    if (row.cvr == null && pct != null) row.cvr = pct;
    if (row.impressions == null && bigNum != null) row.impressions = bigNum;
    return row;
  }
  /* 2026-08-21：EU 域 Arco 表单元格塞多值（"79.1% £1,340.68 42.02%"），按列类型精确取值：
   * gmv → 币种符号后的金额；ctr/cvr → 百分比；orders/impressions/clicks/customers → 跳过开头百分比取纯数字。
   * UK 域单元格是单值，这些分支退化为首个数字，行为不变。 */
  function parseCellMetric(txt, field) {
    var s = String(txt == null ? '' : txt);
    if (field === 'gmv') {
      var mv = extractMoneyAfterCurrency(s);
      if (mv != null) return mv;
      return parseNumber(s);
    }
    if (field === 'ctr' || field === 'cvr') {
      var pm = s.match(/([\d.]+)\s*%/);
      if (pm) { var pv = Number(pm[1]); if (isFinite(pv)) return pv; }
      return parseNumber(s);
    }
    /* orders/impressions/clicks/customers/channel 等：去掉百分比段后取首个数字 */
    var stripped = s.replace(/-?\d+(?:\.\d+)?\s*%/g, ' ').replace(/[£$€¥￥]/g, ' ');
    var nm = stripped.match(/([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)/);
    if (nm) { var nv = Number(String(nm[1]).replace(/,/g, '')); if (isFinite(nv)) return nv; }
    return parseNumber(s);
  }
  /* 2026-08-21：product-analysis（详细信息 tab）Arco 表 DOM 里没有 productId。
   * 读 React fiber memoizedProps.data 拿真实 product_id。2026-08-25：UK 同页 fiber 形状可能没有
   * productInfo 包装（product_id 在行对象顶层），且 arco-table-body 选择器可能打不中——放宽查找。 */
  function findReactFiber(el) {
    if (!el) return null;
    var keys = Object.keys(el);
    for (var i = 0; i < keys.length; i++) {
      if (keys[i].indexOf('__reactFiber') === 0 || keys[i].indexOf('__reactInternal') === 0) return el[keys[i]];
    }
    return null;
  }
  function looksLikeProductRow(d) {
    if (!d || typeof d !== 'object') return false;
    if (d.productInfo && (d.productInfo.product_id || d.productInfo.productId || d.productInfo.id)) return true;
    if (d.product_id || d.productId) return true;
    if (d.product && (d.product.product_id || d.product.id || d.product.productId)) return true;
    var id = d.id != null ? String(d.id) : '';
    return /^\d{10,}$/.test(id);
  }
  function extractPidFromRow(d) {
    if (!d || typeof d !== 'object') return '';
    if (d.productInfo) {
      var a = d.productInfo.product_id || d.productInfo.productId || d.productInfo.id;
      if (a) return String(a);
    }
    if (d.product_id) return String(d.product_id);
    if (d.productId) return String(d.productId);
    if (d.product) {
      var b = d.product.product_id || d.product.productId || d.product.id;
      if (b) return String(b);
    }
    if (d.id != null && /^\d{10,}$/.test(String(d.id))) return String(d.id);
    return '';
  }
  function extractPnameFromRow(d) {
    if (!d || typeof d !== 'object') return '';
    if (d.productInfo) {
      return String(d.productInfo.product_name || d.productInfo.name || d.productInfo.title || '');
    }
    if (d.product) return String(d.product.product_name || d.product.name || d.product.title || '');
    return String(d.product_name || d.productName || d.name || d.title || '');
  }
  function fiberArrayFromProps(props) {
    if (!props || typeof props !== 'object') return null;
    var keys = ['data', 'records', 'list', 'dataSource', 'datasource', 'items', 'rows'];
    for (var i = 0; i < keys.length; i++) {
      var v = props[keys[i]];
      if (v && v.length && looksLikeProductRow(v[0])) return v;
    }
    return null;
  }
  function fiberFindData(fiber) {
    var node = fiber, hops = 0;
    while (node && hops < 60) {
      var arr = fiberArrayFromProps(node.memoizedProps) || fiberArrayFromProps(node.pendingProps);
      if (arr) return arr;
      node = node.return;
      hops++;
    }
    return null;
  }
  function fiberFindPidOnNode(fiber) {
    var node = fiber, hops = 0;
    while (node && hops < 25) {
      var props = node.memoizedProps || node.pendingProps;
      if (props) {
        var pid = extractPidFromRow(props) || extractPidFromRow(props.record) || extractPidFromRow(props.row) || extractPidFromRow(props.item);
        if (pid) return pid;
        if (props.data && !props.data.length) {
          pid = extractPidFromRow(props.data);
          if (pid) return pid;
        }
      }
      node = node.return;
      hops++;
    }
    return '';
  }
  function fiberNum(obj) {
    if (obj == null) return null;
    if (typeof obj === 'number' && isFinite(obj)) return obj;
    if (typeof obj === 'object') {
      /* 金额字段（gmv/aov_sku 等）：{metric:{amount:"473.54",currency_code:"GBP"},...} */
      if (obj.metric != null) {
        if (typeof obj.metric === 'object' && obj.metric.amount != null) return parseNumber(obj.metric.amount);
        if (typeof obj.metric === 'object' && obj.metric.amount_delimited != null) return parseNumber(obj.metric.amount_delimited);
        return parseNumber(obj.metric);
      }
      if (obj.amount != null) return parseNumber(obj.amount);
      if (obj.amount_delimited != null) return parseNumber(obj.amount_delimited);
      return null;
    }
    var s = String(obj);
    if (!s || s === '-' || s === '—' || s === 'undefined') return null;
    return parseNumber(s);
  }
  /* fiber 的 ctr/cvr 是小数分数（0.0429 = 4.29%），DB/UK 存百分比数值（2.74）→ 乘 100。
   * 仅对 ctr/cvr 字段做此换算；impressions/clicks/orders/gmv 是计数/金额，直接取。
   * 乘 100 后 round 到 2 位小数，避免 0.0185*100=1.8499999999999999 的浮点尾巴。 */
  function fiberPct(obj) {
    var n = fiberNum(obj);
    if (n == null) return null;
    if (n <= 1) n = n * 100; /* 0.0429 -> 4.29 */
    return Math.round(n * 100) / 100;
  }
  function scrapeProductFiber() {
    var arcoBody =
      document.querySelector('.theme-arco-table-body table, [class*="arco-table-body"] table') ||
      document.querySelector('[class*="arco-table"] table') ||
      document.querySelector('table');
    if (!arcoBody) return null;
    var trs = arcoBody.querySelectorAll('tbody tr');
    if (!trs.length) trs = arcoBody.querySelectorAll('tr');
    if (!trs.length) return null;
    var fiber = findReactFiber(trs[0]) || findReactFiber(arcoBody);
    var data = fiberFindData(fiber);
    var items = [];
    var headers = ['商品', 'GMV', '订单数', 'SKU 订单数', '商品成交件数', '商品曝光次数', '商品点击量', '商品点击率', 'CTOR（SKU 订单）', '加购次数', '客户数', '操作'];
    if (data && data.length) {
      for (var i = 0; i < data.length && items.length < 80; i++) {
        var d = data[i];
        var pid = extractPidFromRow(d);
        if (!pid) continue;
        var pname = extractPnameFromRow(d);
        var row = {
          productId: String(pid),
          title: String(pname),
          channel: 'product_card',
          gmv: fiberNum(d.gmv),
          orders: fiberNum(d.orders),
          impressions: fiberNum(d.product_impression_pv || d.impressions || d.product_show_pv),
          clicks: fiberNum(d.product_click_pv || d.clicks),
          ctr: fiberPct(d.product_ctr_pv || d.ctr),
          cvr: fiberPct(d.click_to_orders_rate_sku_pv || d.cvr || d.ctor),
          customers: fiberNum(d.customers),
          rawCells: []
        };
        if (d.sku_orders != null) row.skuOrders = fiberNum(d.sku_orders);
        if (d.items_sold != null) row.itemsSold = fiberNum(d.items_sold);
        items.push(row);
      }
    }
    if (!items.length) return null;
    return { products: items, headers: headers, source: 'react-fiber' };
  }
  function scrapeProductTable() {
    /* 2026-08-21：EU 域 product-analysis 优先走 React fiber（含真实 product_id，DOM 无 id）。
     * 命中则直接返回；否则退回 Arco 分离表 / 单表 DOM 刮取（UK 域 product-card-analytics 走此路）。 */
    var fiber = scrapeProductFiber();
    if (fiber && fiber.products && fiber.products.length) {
      return fiber;
    }
    var tables = Array.prototype.slice.call(document.querySelectorAll('table'));
    var best = [];
    var bestHeaders = [];
    var bestScore = -1;

    /* 2026-08-21：EU 域 product-traffic-analysis 用 Arco Design 表，表头与数据行分离在两个 table：
     * header 表 parent.theme-arco-table-header（有 thead 无 tbody 行），body 表 parent.theme-arco-table-body
     * （有 tbody tr 无 thead）。单 table 遍历抓不到完整行（header 表 items=0，body 表因无 th 被 continue 跳过）。
     * 这里检测该分离布局：用 header 表的表头做列映射，body 表的行做数据，列数对齐（同 colgroup 列宽）。
     */
    var arcoHeader = document.querySelector('.theme-arco-table-header table, [class*="arco-table-header"] table');
    var arcoBody = document.querySelector('.theme-arco-table-body table, [class*="arco-table-body"] table');
    var arcoHandled = false;
    if (arcoHeader && arcoBody) {
      var hThs = arcoHeader.querySelectorAll('thead th, tr th');
      var hFields = [];
      var hHeaders = [];
      for (var hi0 = 0; hi0 < hThs.length; hi0++) {
        var ht0 = cellText(hThs[hi0]);
        hHeaders.push(ht0);
        hFields.push(matchProductHeader(ht0));
      }
      var hMapped = hFields.filter(Boolean).length;
      var bTrs = arcoBody.querySelectorAll('tbody tr');
      var bItems = [];
      for (var bi = 0; bi < bTrs.length && bItems.length < 80; bi++) {
        var bTds = bTrs[bi].querySelectorAll('td');
        if (!bTds.length) continue;
        var brow = { rawCells: [] };
        for (var ci0 = 0; ci0 < bTds.length; ci0++) {
          var btxt = cellText(bTds[ci0]);
          brow.rawCells.push(btxt);
          var bf = hFields[ci0];
          if (!bf) continue;
          if (bf === 'title' || bf === 'productId' || bf === 'channel') {
            brow[bf] = btxt;
            if (bf === 'title' || bf === 'productId') {
              var ba = bTds[ci0].querySelector('a[href]');
              if (ba) {
                brow.href = ba.href || ba.getAttribute('href') || null;
                if (!brow.productId) {
                  var bpm =
                    String(brow.href || '').match(/(?:product-card-details|product[_/]?id)[=/](\d+)/i) ||
                    String(brow.href || '').match(/[?&]id=(\d{6,})/i) ||
                    String(brow.href || '').match(/\/product\/(\d+)/) ||
                    String(btxt).match(/\bID:\s*(\d{6,})\b/i) ||
                    String(btxt).match(/\b(\d{10,})\b/);
                  if (bpm) brow.productId = bpm[1];
                }
              } else if (bf === 'title' && !brow.productId) {
                var bidm = String(btxt).match(/\bID:\s*(\d{6,})\b/i) || String(btxt).match(/\b(\d{10,})\b/);
                if (bidm) brow.productId = bidm[1];
              }
            }
          } else {
            /* 首个非空优先：EU 域「订单数」与「SKU 订单数」都映射 orders，取左者（真订单数），
             * 不让右列覆盖。数值 0 也算已赋值（商家直播全 0）。 */
            var bv = parseCellMetric(btxt, bf);
            if (brow[bf] == null && bv != null) brow[bf] = bv;
          }
        }
        enrichProductRowFromCells(brow);
        if (!brow.productId) {
          var bpid = fiberFindPidOnNode(findReactFiber(bTrs[bi]) || findReactFiber(bTds[0]));
          if (bpid) brow.productId = bpid;
        }
        if (
          brow.productId ||
          brow.title ||
          brow.impressions != null ||
          brow.clicks != null ||
          brow.ctr != null ||
          brow.gmv != null
        ) {
          bItems.push(brow);
        }
      }
      var bMetricRows = bItems.filter(function (it) {
        return it.impressions != null || it.cvr != null || it.clicks != null;
      }).length;
      var bScore = hMapped * 100 + bItems.length + bMetricRows * 10;
      best = bItems; bestHeaders = hHeaders; bestScore = bScore;
      arcoHandled = true;
    }

    for (var ti = 0; ti < tables.length; ti++) {
      var table = tables[ti];
      var ths = table.querySelectorAll('thead th, tr th');
      if (!ths.length) continue;
      var fields = [];
      var headers = [];
      for (var hi = 0; hi < ths.length; hi++) {
        var ht = cellText(ths[hi]);
        headers.push(ht);
        fields.push(matchProductHeader(ht));
      }
      var mapped = fields.filter(Boolean).length;
      if (mapped < 2) continue;
      var rows = table.querySelectorAll('tbody tr');
      var items = [];
      for (var ri = 0; ri < rows.length && items.length < 80; ri++) {
        var tds = rows[ri].querySelectorAll('td');
        if (!tds.length) continue;
        var row = { rawCells: [] };
        for (var ci = 0; ci < tds.length; ci++) {
          var txt = cellText(tds[ci]);
          row.rawCells.push(txt);
          var f = fields[ci];
          if (!f) continue;
          if (f === 'title' || f === 'productId' || f === 'channel') {
            row[f] = txt;
            if (f === 'title' || f === 'productId') {
              var a = tds[ci].querySelector('a[href]');
              if (a) {
                row.href = a.href || a.getAttribute('href') || null;
                if (!row.productId) {
                  var pm =
                    String(row.href || '').match(/(?:product-card-details|product[_/]?id)[=/](\d+)/i) ||
                    String(row.href || '').match(/[?&]id=(\d{6,})/i) ||
                    String(row.href || '').match(/\/product\/(\d+)/) ||
                    String(txt).match(/\bID:\s*(\d{6,})\b/i) ||
                    String(txt).match(/\b(\d{10,})\b/);
                  if (pm) row.productId = pm[1];
                }
              } else if (f === 'title' && !row.productId) {
                var idm = String(txt).match(/\bID:\s*(\d{6,})\b/i) || String(txt).match(/\b(\d{10,})\b/);
                if (idm) row.productId = idm[1];
              }
            }
          } else {
            var fv = parseCellMetric(txt, f);
            if (row[f] == null && fv != null) row[f] = fv;
          }
        }
        enrichProductRowFromCells(row);
        if (!row.productId) {
          var rpid = fiberFindPidOnNode(findReactFiber(rows[ri]) || findReactFiber(tds[0]));
          if (rpid) row.productId = rpid;
        }
        if (
          row.productId ||
          row.title ||
          row.impressions != null ||
          row.clicks != null ||
          row.ctr != null ||
          row.gmv != null
        ) {
          items.push(row);
        }
      }
      /* 优先选「映射字段多 + 行上有曝光/转化」的表，避免只含 GMV 的弱表赢 */
      var metricRows = items.filter(function (it) {
        return it.impressions != null || it.cvr != null || it.clicks != null;
      }).length;
      var score = mapped * 100 + items.length + metricRows * 10;
      if (score > bestScore) {
        bestScore = score;
        best = items;
        bestHeaders = headers;
      }
    }
    return { products: best, headers: bestHeaders };
  }
  try {
    var body = bodyText();
    var url = location.href || '';
    var title = document.title || '';
    var windowLabel = null;
    var wm =
      body.match(/最近\s*\d+\s*天/) ||
      body.match(/近\s*\d+\s*天/) ||
      body.match(/过去\s*\d+\s*天/) ||
      body.match(/Last\s*\d+\s*days?/i) ||
      body.match(/Past\s*\d+\s*days?/i) ||
      body.match(/GMT[+\-]?\d{0,2}:?\d{0,2}/i) && body.match(/最近\s*\d+|近\s*\d+|Last\s*\d+/i) ||
      body.match(/\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}\s*[\-~至]\s*\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}/) ||
      body.match(/Yesterday|昨天|Today|今天/i);
    if (wm) windowLabel = typeof wm[0] === 'string' ? wm[0] : String(wm[0]);
    /* 商品卡页默认近 7 天窗口；未解析到文案时仍标注，避免 raw_extra.window 全空 */
    if (!windowLabel && /product-card-analytics/i.test(url)) {
      windowLabel = '最近7天(default)';
    }

    var kpis = {
      impressions: findByRegex(body, [
        /曝光用户数\s*([\d,.]+[KkMm万亿]?)/i,
        /商品\s*曝光\s*([£$€]?[\d,.]+[KkMm万亿]?)/i,
        /商品曝光次数\s*([\d,.]+)/i,
        /曝光次数\s*([\d,.]+)/,
        /曝光数?\s*([\d,.]+[KkMm万亿]?)/,
        /Impressions?\s*([\d,.]+[KkMm万亿]?)/i
      ]),
      clicks: findByRegex(body, [
        /商品点击量\s*([\d,.]+)/i,
        /点击量\s*([\d,.]+)/,
        /点击数?\s*([\d,.]+[KkMm万亿]?)/,
        /Clicks?\s*([\d,.]+[KkMm万亿]?)/i
      ]),
      ctr: findByRegex(body, [
        /商品点击率\s*([\d.]+)\s*%?/,
        /点击率\s*([\d.]+)\s*%?/,
        /\bCTR\s*([\d.]+)\s*%?/i,
        /\bCTOR\b[^0-9]{0,8}([\d.]+)\s*%?/i
      ]),
      orders: findByRegex(body, [
        /SKU\s*订单数?\s*([\d,.]+)/i,
        /订单数?\s*([\d,.]+)/,
        /Orders?\s*([\d,.]+)/i
      ]),
      gmv: findByRegex(body, [
        /* 2026-08-21：EU 域 innerText 把 £ 与数字、小数点两边用空格断开（"GMV £ 1,694 .82"），
         * 容忍币种后空格 + 小数点两侧空格。首个 GMV 为总 GMV（"销量 GMV £..."），归因分解在其后。 */
        /GMV\s*[£$€¥￥]?\s*([\d,]+(?:\s*\.\s*\d+)?)/i,
        /成交额\s*[£$€]?\s*([\d,]+\.?\d*)/,
        /销售额\s*[£$€]?\s*([\d,]+\.?\d*)/
      ]),
      cvr: findByRegex(body, [
        /曝光到成交转化率\s*([\d.]+)\s*%?/,
        /转化率\s*([\d.]+)\s*%?/,
        /\bCVR\s*([\d.]+)\s*%?/i
      ]),
      customers: findByRegex(body, [/预计客户数\s*([\d,.]+)/i, /日客户数\s*([\d,.]+)/, /客户数\s*([\d,.]+)/i])
    };

    var tbl = scrapeProductTable();
    var kpiFlat = {};
    var kpiHits = {};
    Object.keys(kpis).forEach(function (k) {
      if (kpis[k]) {
        kpiFlat[k] = kpis[k].value;
        kpiHits[k] = kpis[k].label;
      } else {
        kpiFlat[k] = null;
      }
    });

    var pageHints = {
      hasProductCardNav: /商品卡|Product\s*card|商品数据|Product\s*analytics|商品分析/i.test(body),
      hasTrafficWord: /曝光|点击|CTR|CVR|Impression/i.test(body)
    };

    // 2026-08-21：导航跑偏防护（对齐 creator_health 的 wrong_page 模式）。
    // Bridge 抖动 / store 复用时页面会被甩到 order/detail 或 compass/shop-tab（商城概览），
    // 此时 KPI 正则会从订单号/概览卡里“凑”出假数字（如 orders=订单号、概览页的曝光/GMV/customers），
    // 旧行为 ok=hasKpi||hasRows 会判 ok:true 且 products:[] -> 静默入库空数据。
    // 正常商品卡明细页 URL 稳定含 product-card-analytics；概览页 shop-tab 虽也有曝光/GMV KPI，
    // 但那是整店概览不是商品卡明细，且永远没有商品明细行。故判定以 URL + 明细表行为准：
    // URL 不在商品卡明细页 且 没有商品明细行 -> 一律 wrong_page，让上层重新 visit 目标 URL，
    // 不在错页里凑数据。KPI 命中数不作为“在正确页”的证据（概览页也有 KPI）。
    // 2026-08-21：EU 域 compass 路径辨析——
    //   UK 域：/compass/product-card-analytics（product 粒度，单表）。
    //   EU 域：无 product-card-analytics（被重定向到 shop-tab）。EU「商品数据分析」下：
    //     - /compass/product-traffic-analysis = 商品流量 tab = channel 粒度（商家商品卡/商家视频/联盟/商家直播 4 行），
    //       与 DB fact_tiktok_product_traffic_daily 的 product 粒度（product_id NOT NULL）不符，converter 全跳过→0 入库。
    //     - /compass/product-analysis = 详细信息 tab = product 粒度（首列「商品」=商品名+ID，多行真实商品），与 DB grain 一致。
    //   故 EU 店 byPlatform 配 product-analysis；正则须同时认三域路径。
    var onProductCard = /product-card-analytics|product-traffic-analysis|product-analysis|product[_/]?traffic/i.test(url);
    var onOrderDetail = /\/order\/detail|order_no=/i.test(url);
    // 明细页表格/列特征（区别于概览页只有 KPI 卡片）：刮到至少 1 个商品行
    var hasDetailTable = tbl.products && tbl.products.length > 0;

    var hasKpi = Object.keys(kpiFlat).some(function (k) {
      return kpiFlat[k] != null;
    });
    var kpiHitCount = Object.keys(kpiFlat).filter(function (k) {
      return kpiFlat[k] != null;
    }).length;
    // 核心流量指标（概览页 customers 单独命中不算）：曝光/点击/GMV/订单/CVR/CTR
    var hasCoreKpi =
      kpiFlat.impressions != null ||
      kpiFlat.clicks != null ||
      kpiFlat.gmv != null ||
      kpiFlat.orders != null ||
      kpiFlat.cvr != null ||
      kpiFlat.ctr != null;
    var hasRows = hasDetailTable;

    // 跑错页：URL 不在商品卡明细页 且 没有商品明细行 -> wrong_page。
    // onOrderDetail 优先级最高；shop-tab 等概览页即便 KPI 齐全也无明细行，照拦。
    if (onOrderDetail || (!onProductCard && !hasDetailTable)) {
      return JSON.stringify({
        ok: false,
        module: 'product_traffic',
        source: 'product-traffic-poc',
        url: url,
        title: title,
        window: windowLabel,
        currency: detectCurrency(body),
        kpis: kpiFlat,
        products: [],
        raw: raw,
        error: 'wrong_page_not_product_traffic: ' + url,
        diag: {
          onProductCard: onProductCard,
          onOrderDetail: onOrderDetail,
          hasDetailTable: hasDetailTable,
          hasCoreKpi: hasCoreKpi,
          kpiHitCount: kpiHitCount
        }
      });
    }

    // 在正确页上（URL 是 product-card-analytics 或有明细行）但数据为空：
    // 要求至少有商品行，或核心 KPI 命中≥2。单凭 customers 这类非核心残留不再判 ok。
    var ok = !!(hasRows || (hasCoreKpi && kpiHitCount >= 2));

    var raw = {
      bodyLen: body.length,
      sample: body.slice(0, 500),
      window: windowLabel,
      kpiHits: kpiHits,
      tableHeaders: tbl.headers,
      productRowCount: tbl.products.length,
      pageHints: pageHints
    };

    if (!ok) {
      return JSON.stringify({
        ok: false,
        module: 'product_traffic',
        source: 'product-traffic-poc',
        url: url,
        title: title,
        window: windowLabel,
        currency: detectCurrency(body),
        kpis: kpiFlat,
        products: [],
        raw: raw,
        error:
          'no product traffic rows or core KPI. Confirm URL is 内容分析→商品卡/商品数据. url=' +
          url
      });
    }

    return JSON.stringify({
      ok: true,
      module: 'product_traffic',
      source: 'product-traffic-poc',
      url: url,
      title: title,
      window: windowLabel,
      currency: detectCurrency(body) || 'GBP',
      channelDefault: 'product_card',
      kpis: kpiFlat,
      products: tbl.products,
      raw: raw,
      error: null
    });
  } catch (e) {
    return JSON.stringify({
      ok: false,
      module: 'product_traffic',
      url: location.href || '',
      error: String(e && e.message ? e.message : e)
    });
  }
})();
