/* vm 回归测试：scrape-product-traffic-page.js
 * 覆盖：UK 域 product-card-analytics 成功、EU 域 product-traffic-analysis 成功、
 * order/detail wrong_page、shop-tab 概览 wrong_page、空页普通失败。
 * 用 mock DOM，验证改动后旧场景不坏 + 新 EU 场景通过。
 */
const fs = require('fs');
const vm = require('vm');

const code = fs.readFileSync('scripts/scrape-product-traffic-page.js', 'utf8');

function makeMock(opts) {
  const url = opts.url;
  const bodyText = opts.bodyText;
  const tables = opts.tables || [];
  // 构造 mock document
  function mkEl(tag, text, children, attrs) {
    return {
      tagName: tag,
      nodeType: 1,
      innerText: text,
      textContent: text,
      _children: children || [],
      _attrs: attrs || {},
      getAttribute(k) { return this._attrs[k] || null; },
      querySelector(sel) {
        // 简化：只支持 'a[href]' 和 tag
        if (sel === 'a[href]') {
          for (const c of this._children) if (c.tagName === 'a' && c._attrs.href) return c;
          return null;
        }
        return null;
      },
      querySelectorAll(sel) {
        if (sel === 'thead th, tr th') {
          return (this._children || []).filter(c => c.tagName === 'th');
        }
        if (sel === 'tbody tr') {
          return (this._children || []).filter(c => c.tagName === 'tr');
        }
        if (sel === 'td') {
          return (this._children || []).filter(c => c.tagName === 'td');
        }
        return [];
      },
      getBoundingClientRect() { return { width: 100, height: 20 }; },
    };
  }
  function mkTh(text) { return mkEl('th', text); }
  function mkTd(text, href) {
    const attrs = href ? { href } : {};
    const children = href ? [mkEl('a', text, [], { href })] : [];
    return mkEl('td', text, children, attrs);
  }
  function mkTr(cells) { return mkEl('tr', cells.map(c => c.innerText || '').join(' '), cells); }
  function mkTable(headers, rows) {
    const ths = headers.map(mkTh);
    const trs = rows.map(r => mkTr(r.map(c => typeof c === 'string' ? mkTd(c) : mkTd(c.text, c.href))));
    return mkEl('table', headers.join(' '), [...ths, ...trs]);
  }
  // arco 分离表：header 表（有 th 无 tr 数据）+ body 表（有 tr 无 th）
  function mkArcoTables(headers, rows) {
    const headerTable = mkEl('table', headers.join(' '), headers.map(mkTh));
    const bodyTrs = rows.map(r => mkTr(r.map(c => typeof c === 'string' ? mkTd(c) : mkTd(c.text, c.href))));
    const bodyTable = mkEl('table', rows.map(r => r.join(' ')).join(' '), bodyTrs);
    // 给 arco 选择器：querySelector('.theme-arco-table-header table') —— mock 里直接把这两个 table 标记
    headerTable._arcoHeader = true;
    bodyTable._arcoBody = true;
    return [headerTable, bodyTable];
  }

  const allTables = tables.length ? tables : [];
  const document = {
    title: opts.title || 'TikTok Shop Seller Center',
    querySelector(sel) {
      if (sel === '.theme-arco-table-header table, [class*="arco-table-header"] table') {
        return allTables.find(t => t._arcoHeader) || null;
      }
      if (sel === '.theme-arco-table-body table, [class*="arco-table-body"] table') {
        return allTables.find(t => t._arcoBody) || null;
      }
      return null;
    },
    querySelectorAll(sel) {
      if (sel === 'table') return allTables;
      if (sel === 'a, [role="menuitem"], [role="tab"], [role="link"], li, div, span') return [];
      return [];
    },
    body: { innerText: bodyText, textContent: bodyText },
  };
  const window = { getComputedStyle() { return { display: 'block', visibility: 'visible' }; } };
  const location = { href: url };
  const ctx = { document, window, location, JSON, Number, isFinite, String, Array, Object, Math, RegExp };
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  // 脚本是 IIFE 返回 JSON 字符串
  const out = ctx.__lastReturn || ctx.result;
  return ctx;
}

// 由于 IIFE 直接 return（不赋值全局），改用：把脚本包一层捕获 return
function runScrape(opts) {
  const bodyText = opts.bodyText;
  const allTables = opts.tables || [];
  const document = {
    title: opts.title || 'TikTok Shop Seller Center',
    querySelector(sel) {
      if (/arco-table-header/.test(sel)) return allTables.find(t => t._arcoHeader) || null;
      if (/arco-table-body/.test(sel)) return allTables.find(t => t._arcoBody) || null;
      return null;
    },
    querySelectorAll(sel) {
      if (sel === 'table') return allTables;
      return [];
    },
    body: { innerText: bodyText, textContent: bodyText },
  };
  const window = { getComputedStyle() { return { display: 'block', visibility: 'visible' }; } };
  const location = { href: opts.url };
  const ctx = { document, window, location, JSON, Number, isFinite, String, Array, Object, Math, RegExp, parseInt, parseFloat };
  vm.createContext(ctx);
  // 包装 IIFE 捕获返回值
  const wrapped = '(function(){var __r=(' + code.replace(/^\(function\s*\(/, '(function(').replace(/\}\)\(\)\s*;?\s*$/, '})()') + ');return __r;})()';
  try {
    const ret = vm.runInContext(wrapped, ctx);
    return JSON.parse(ret);
  } catch (e) {
    return { ok: false, error: 'eval:' + e.message };
  }
}

// ---- helpers to build arco tables ----
function mkTh(text) { return { tagName:'th', nodeType:1, innerText:text, textContent:text, getAttribute(){return null;}, querySelectorAll(){return [];}, querySelector(){return null;}, getBoundingClientRect(){return {width:100,height:20};} }; }
function mkTd(text, href) { return { tagName:'td', nodeType:1, innerText:text, textContent:text, _attrs: href?{href}:{}, getAttribute(k){return this._attrs[k]||null;}, querySelector(sel){ if(sel==='a[href]'&&href){return {href,getAttribute(k){return k==='href'?href:null;}};} return null; }, querySelectorAll(){return [];}, getBoundingClientRect(){return {width:100,height:20};} }; }
function mkTr(cells){ return { tagName:'tr', nodeType:1, innerText:cells.map(c=>typeof c==='string'?c:c.text).join(' '), textContent:cells.map(c=>typeof c==='string'?c:c.text).join(' '), _children:cells.map(c=>typeof c==='string'?mkTd(c):mkTd(c.text,c.href)), querySelectorAll(sel){ if(sel==='td')return this._children; return []; }, getBoundingClientRect(){return {width:100,height:20};} }; }
function mkArcoTable(headers, rows, isHeader) {
  const children = isHeader ? headers.map(mkTh) : rows.map(mkTr);
  const t = {
    tagName:'table', nodeType:1,
    innerText:(isHeader?headers:rows.map(r=>r.join(' '))).join(' '),
    textContent:(isHeader?headers:rows.map(r=>r.join(' '))).join(' '),
    _children:children,
    querySelectorAll(sel){
      if(sel==='thead th, tr th') return isHeader?children:[];
      if(sel==='tbody tr') return isHeader?[]:children;
      if(sel==='td') return isHeader?[]:((children[0]&&children[0]._children)||[]);
      return [];
    },
    querySelector(){return null;},
    getBoundingClientRect(){return {width:100,height:20};},
  };
  if (isHeader) t._arcoHeader = true; else t._arcoBody = true;
  return t;
}

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  PASS', name); }
  else { fail++; console.log('  FAIL', name, detail || ''); }
}

// Case 1: EU 域 product-traffic-analysis 成功（Arco 分离表）
console.log('Case 1: EU product-traffic-analysis');
{
  const headers = ['信息','GMV','订单数','SKU 订单数','商品成交件数','平均订单金额（SKU 订单）','商品曝光次数','商品点击量','商品点击率','加购次数','加购率','CTOR（SKU 订单）','操作'];
  const rows = [
    ['商家商品卡','79.1% £1,340.68 42.02%','80.7% 92 45.88%','79.83% 95 45.71%','73.83% 110 45%','£14.11 6.81%','72.98% 104,343 26.39%','69.47% 2,860 21.04%','2.74% 7.03%','79.9% 497 31.92%','17.38% 13.75%','3.32% 31.26%','查看详情'],
    ['商家直播','0% £0.00 --','0% 0 --','0% 0 --','0% 0 --','£0.00','0.01% 8 42.86%','0% 0 100%','0% 100%','0% 0 --','0%','0%','查看详情'],
  ];
  const bodyText = '商家中心 商品数据分析 最近 7 天 关键指标 销量 GMV £ 1,694 .82 商家直播归因 GMV £ 0.00 流量 预计客户数 113 商品曝光次数 142,984 商品点击量 4,117 商品点击率 2.88% 表现明细 ' + headers.join(' ') + ' ' + rows.map(r=>r.join(' ')).join(' ');
  const r = runScrape({
    url: 'https://seller.eu.tiktokshopglobalselling.com/compass/product-traffic-analysis?shop_region=GB&timeRange=2026-08-15%7C2026-08-22',
    bodyText,
    tables: [mkArcoTable(headers, rows, true), mkArcoTable(headers, rows, false)],
  });
  check('ok true', r.ok === true, JSON.stringify(r).slice(0,200));
  check('impressions KPI', r.kpis && r.kpis.impressions === 142984, r.kpis && r.kpis.impressions);
  check('clicks KPI', r.kpis && r.kpis.clicks === 4117);
  check('gmv KPI', r.kpis && r.kpis.gmv === 1694, r.kpis && r.kpis.gmv);
  check('products len 2', r.products && r.products.length === 2, r.products && r.products.length);
  const p0 = r.products && r.products[0];
  check('p0 channel', p0 && p0.channel === '商家商品卡', p0 && p0.channel);
  check('p0 impressions', p0 && p0.impressions === 104343, p0 && p0.impressions);
  check('p0 clicks', p0 && p0.clicks === 2860);
  check('p0 gmv', p0 && p0.gmv === 1340.68);
  check('p0 ctr', p0 && p0.ctr === 2.74, p0 && p0.ctr);
  check('p0 orders=92 not 95', p0 && p0.orders === 92, p0 && p0.orders);
  check('p0 cvr=CTOR 3.32', p0 && p0.cvr === 3.32, p0 && p0.cvr);
  check('p0 title not 成交件数', p0 && p0.title === undefined, p0 && p0.title);
}

// Case 2: UK 域 product-card-analytics 成功（单表，回归不坏）
console.log('Case 2: UK product-card-analytics (regression)');
{
  const headers = ['商品','曝光','点击','CTR','GMV','操作'];
  const rows = [
    ['Product A','10000','500','5%','£200.00','查看详情'],
    ['Product B','5000','200','4%','£100.00','查看详情'],
  ];
  const bodyText = '商品卡分析 最近 7 天 曝光 15000 点击 700 GMV £300 ' + headers.join(' ') + ' ' + rows.map(r=>r.join(' ')).join(' ');
  // UK 单表：thead + tbody 同一表
  const tbl = {
    tagName:'table', nodeType:1, innerText: headers.join(' ')+' '+rows.map(r=>r.join(' ')).join(' '),
    querySelectorAll(sel){
      if(sel==='thead th, tr th') return headers.map(mkTh);
      if(sel==='tbody tr') return rows.map(r=>mkTr(r));
      if(sel==='td') return rows.length?rows[0].map(c=>mkTd(c)):[]; // not used this way
      return [];
    },
    querySelector(){return null;},
  };
  const r = runScrape({ url:'https://seller-uk.tiktok.com/compass/product-card-analytics?shop_region=GB', bodyText, tables:[tbl] });
  check('ok true', r.ok === true, JSON.stringify(r).slice(0,200));
  check('impressions 15000', r.kpis && r.kpis.impressions === 15000, r.kpis && r.kpis.impressions);
  check('products len 2', r.products && r.products.length === 2, r.products && r.products.length);
}

// Case 3: order/detail wrong_page
console.log('Case 3: order/detail wrong_page');
{
  const r = runScrape({ url:'https://seller-uk.tiktok.com/order/detail?order_no=123', bodyText:'订单详情 订单号 123 金额 £50 退款 £5' });
  check('ok false', r.ok === false);
  check('wrong_page', r.error && /wrong_page_not_product_traffic/.test(r.error), r.error);
}

// Case 4: shop-tab 概览 wrong_page
console.log('Case 4: shop-tab overview wrong_page');
{
  const r = runScrape({ url:'https://seller.eu.tiktokshopglobalselling.com/compass/shop-tab?shop_region=GB', bodyText:'商城概览 曝光 113,157 GMV £1,781 日均客户数 16' });
  check('ok false', r.ok === false);
  check('wrong_page', r.error && /wrong_page_not_product_traffic/.test(r.error), r.error);
}

// Case 5: 空页普通失败
console.log('Case 5: empty page');
{
  const r = runScrape({ url:'https://seller-uk.tiktok.com/compass/product-card-analytics?shop_region=GB', bodyText:'商家中心 商品卡' });
  check('ok false', r.ok === false, JSON.stringify(r).slice(0,120));
}

// Case 6: EU 域 product-analysis（详细信息 tab）React fiber 路径——DOM 无 productId，靠 fiber data 拿真实 ID
console.log('Case 6: EU product-analysis (react fiber)');
{
  // 构造 fiber：arco body table 的首个 tr 挂 __reactFiber，沿 .return 链找到 memoizedProps.data
  const fiberData = [
    { productInfo: { product_id: '1729806178562120681', product_name: 'Struttura Wooden Shelving Floor Lamp' },
      gmv: { metric: { amount: '473.54', currency_code: 'GBP' } }, orders: { metric: '15' },
      product_impression_pv: { metric: '25590' }, product_click_pv: { metric: '1098' },
      product_ctr_pv: { metric: '0.0429' }, click_to_orders_rate_sku_pv: { metric: '0.0137' }, customers: { metric: '15' } },
    { productInfo: { product_id: '1729855818147404777', product_name: 'Single Tier Black Dish Drainer Rack' },
      gmv: { metric: { amount: '288.18' } }, orders: { metric: '22' },
      product_impression_pv: { metric: '29964' }, product_click_pv: { metric: '755' },
      product_ctr_pv: { metric: '0.0252' }, click_to_orders_rate_sku_pv: { metric: '0.0291' }, customers: { metric: '22' } },
  ];
  const dataNode = { memoizedProps: { data: fiberData } };
  const midNode = { memoizedProps: {}, return: dataNode };
  const fiber = { memoizedProps: {}, return: midNode };
  // mkArcoTable 的 body tr 没有 __reactFiber；这里手工建一个带 fiber 的 body table
  function mkTrWithFiber() {
    const t = mkTr(['Struttura Wooden Shelving Floor Lamp', '23.35% £473.54 35.75%', '10.74% 15 35%', '查看详情']);
    t.__reactFiber = fiber;
    return t;
  }
  const bodyTbl = {
    tagName:'table', nodeType:1, innerText:'商品 GMV 订单数 操作 Struttura 473.54 15 查看',
    textContent:'商品 GMV 订单数 操作 Struttura 473.54 15 查看',
    querySelectorAll(sel){
      if(sel==='tbody tr') return [mkTrWithFiber(), mkTrWithFiber()]; // 两个 tr 共用同一 fiber（mock 简化）
      if(sel==='thead th, tr th') return [];
      return [];
    },
    querySelector(){return null;},
  };
  bodyTbl._arcoBody = true;
  const headerTbl = mkArcoTable(['商品','GMV','订单数','SKU 订单数','商品成交件数','商品曝光次数','商品点击量','商品点击率','CTOR','加购次数','客户数','操作'], [], true);
  const bodyText = '商品数据分析 详细信息 热卖商品 商品流量 商品榜单 商品 GMV 订单数 SKU 订单数 商品成交件数 商品曝光次数 商品点击量 商品点击率 CTOR 加购次数 客户数 操作 Struttura 473.54 15 25590 1098 4.29 1.37';
  const r = runScrape({
    url: 'https://seller.eu.tiktokshopglobalselling.com/compass/product-analysis?shop_region=GB',
    bodyText,
    tables: [headerTbl, bodyTbl],
  });
  check('ok true', r.ok === true, JSON.stringify(r).slice(0,200));
  check('products len 2 (fiber)', r.products && r.products.length === 2, r.products && r.products.length);
  const p0 = r.products && r.products[0];
  check('p0 productId real id', p0 && p0.productId === '1729806178562120681', p0 && p0.productId);
  check('p0 title clean', p0 && p0.title === 'Struttura Wooden Shelving Floor Lamp', p0 && p0.title);
  check('p0 gmv from money obj', p0 && p0.gmv === 473.54, p0 && p0.gmv);
  check('p0 orders', p0 && p0.orders === 15, p0 && p0.orders);
  check('p0 impressions', p0 && p0.impressions === 25590, p0 && p0.impressions);
  check('p0 clicks', p0 && p0.clicks === 1098);
  check('p0 ctr pct 4.29', p0 && p0.ctr === 4.29, p0 && p0.ctr);
  check('p0 cvr pct 1.37', p0 && p0.cvr === 1.37, p0 && p0.cvr);
  check('p0 channel product_card', p0 && p0.channel === 'product_card', p0 && p0.channel);
}

console.log('\n=== ' + pass + ' passed, ' + fail + ' failed ===');
process.exit(fail > 0 ? 1 : 0);
