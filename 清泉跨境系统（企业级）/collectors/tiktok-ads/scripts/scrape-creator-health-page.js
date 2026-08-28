/* TikTok creator health: list switcher accounts + current score/violations.
 * Multi-account full scores: run-shop-modules loops scrape-creator-health-switch.js
 */
(function () {
  function clean(t) {
    return String(t == null ? '' : t).replace(/\s+/g, ' ').trim();
  }
  function bodyText() {
    return clean((document.body && (document.body.innerText || document.body.textContent)) || '');
  }
  function visible(el) {
    if (!el || el.nodeType !== 1) return false;
    var st = window.getComputedStyle(el);
    if (!st || st.display === 'none' || st.visibility === 'hidden') return false;
    var r = el.getBoundingClientRect();
    return r.width > 2 && r.height > 2;
  }
  // 2026-08-20：parseScore 原 fallback /\b(200|1\d{2}|[5-9]\d)\b/ 在任意页面都能命中 50~99 的数字，
  // 一旦导航跑偏到订单详情页（body 里满是订单号/日期/金额片段），就会"凑"出一个假健康分并 ok:true 入库。
  // 收窄：fallback 只在正文确实含健康页特征词时启用；否则要求显式 "健康/Health + 数字"。
  var HEALTH_PAGE_TERMS = /违规次数|官方账号|营销账号|达人健康|达人健康评分|Creator\s*health|Health\s*score|账号信誉|需要关注/i;
  function parseScore(body) {
    var m = body.match(/(?:健康分|健康|Health\s*score|Health)[^0-9]{0,40}?(\d{2,4})\b/);
    if (m) {
      var n0 = Number(m[1]);
      if (isFinite(n0) && n0 >= 0 && n0 <= 1000) return n0;
    }
    // fallback：仅当页面呈现健康页特征词时，才接受 50~199 的裸数字为健康分
    if (HEALTH_PAGE_TERMS.test(body)) {
      var f = body.match(/\b(200|1\d{2}|[5-9]\d)\b/);
      if (f) {
        var n1 = Number(f[1]);
        if (isFinite(n1) && n1 >= 0 && n1 <= 1000) return n1;
      }
    }
    return null;
  }
  function openSwitcher() {
    var nodes = document.querySelectorAll('button, div, span, a');
    for (var i = 0; i < nodes.length && i < 4000; i++) {
      var el = nodes[i];
      if (!visible(el)) continue;
      var t = clean(el.innerText || el.textContent || '');
      if (t === '切换账号' || t.indexOf('切换账号') === 0 || /Switch\s*account/i.test(t)) {
        try {
          el.click();
          return true;
        } catch (e) {}
      }
    }
    return false;
  }
  // 2026-08-20：creator-health URL 不自动渲染正文（只出侧边导航栏，bodyLen~130），
  // 需主动点击「达人健康评分 / Creator health」菜单/tab 触发 SPA 加载（同 violation 的 clickTab）。
  // 2026-08-21：曾尝试改点「账号健康分」tab（用户手动验证该 tab 会重定向 /health-center 渲染），
  // 但实测脚本 el.click() 点叶子 span 不触发 router 重定向，反而比点「达人健康评分」更差
  // （达人健康评分 tab 点了能渲染，只是 attempt 1 时序不够，attempt 2 多等 25s 即成——见 14:48 轮
  // Gardena/Deal to deal accepted=1）。故回退到点「达人健康评分」。真正瓶颈是 SPA 渲染时序，
  // 靠上层 run-shop-modules.ps1 attempt 间 extra 25s 解决，不是换 tab。
  function clickCreatorHealthEntry() {
    var nodes = document.querySelectorAll('a,button,div,span,li,[role="tab"],[role="menuitem"]');
    for (var i = 0; i < nodes.length && i < 6000; i++) {
      var el = nodes[i];
      if (!visible(el)) continue;
      var t = clean(el.innerText || el.textContent || el.getAttribute('aria-label') || '');
      if (!t || t.length > 24) continue;
      if (/^达人健康评分$|^Creator\s*health(\s*score)?$/i.test(t) ||
          /^达人健康$|^Creator\s*health$/i.test(t)) {
        try { el.click(); return t; } catch (e) {}
      }
    }
    return '';
  }
  function collectAccounts() {
    var accounts = [];
    var seen = {};
    function pushAcc(name, role, vc) {
      name = clean(name);
      if (!name || name.length < 2 || name.length > 40) return;
      if (/切换账号|ScoreHub|违规次数|官方账号|营销账号|了解更多|需要关注|你的店铺已绑定|店铺已绑定/.test(name)) return;
      var k = name.toLowerCase();
      if (seen[k]) return;
      seen[k] = 1;
      accounts.push({
        name: name,
        violationCount: vc == null || !isFinite(Number(vc)) ? null : Number(vc),
        role: role || ''
      });
    }
    var nodes = document.querySelectorAll('button, div, span, label, li, [role="radio"], [role="option"]');
    for (var i = 0; i < nodes.length && accounts.length < 40; i++) {
      var el = nodes[i];
      if (!visible(el)) continue;
      var t = clean(el.innerText || el.textContent || '');
      if (!t || t.length > 90) continue;
      if (!/违规次数|官方账号|营销账号|Official|Marketing/i.test(t)) continue;
      var vM = t.match(/违规次数\s*[:：]?\s*(\d+)/);
      var role = /官方|Official/i.test(t) ? 'official' : /营销|Marketing/i.test(t) ? 'marketing' : '';
      var nameLine = t
        .replace(/官方账号|营销账号|Official|Marketing|账号/gi, ' ')
        .replace(/违规次数\s*[:：]?\s*\d+/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
      var name = (nameLine.split(/\s+/)[0] || '').trim();
      if (name) pushAcc(name, role, vM ? vM[1] : null);
    }
    if (!accounts.length) {
      var body = bodyText();
      var re = /([A-Za-z0-9_\u4e00-\u9fff.\-]{2,30})\s*(官方账号|营销账号)?\s*违规次数\s*[:：]?\s*(\d+)/g;
      var mm;
      while ((mm = re.exec(body)) && accounts.length < 40) {
        pushAcc(mm[1], mm[2] || '', mm[3]);
      }
    }
    return accounts;
  }
  try {
    var url = location.href || '';
    var title = (document.title || '');
    // 2026-08-20：导航跑偏防护。visit creator-health 后 SPA 可能没真正路由过去，
    // 落到 order/detail 等页面。此时 body 里凑出的"健康分"是脏数据，必须拒绝并报 wrong_page，
    // 让上层在 retry 时重新 visit（同 reviews 的 wrong_page_not_reviews 模式）。
    // 2026-08-21：点「账号健康分」tab 后 URL 会从 /creator-health 重定向到 /health-center
    // （去掉 creator-health 段），这仍是健康中心正确页，不算跑偏。故 onCreatorHealth 接受
    // /health-center 任意子页 + /creator-health + title/body 含健康特征词。
    var onCreatorHealth =
      /health-center|creator-health|\/creator\b|达人健康|账号健康/i.test(url) ||
      /达人健康|Creator\s*health|账号健康/i.test(title);
    var onOrderDetail = /\/order\/detail|order_no=/i.test(url);
    // 先点「达人健康评分」菜单/tab 触发 SPA 正文渲染（URL 不自动加载正文）。
    // 若正文已渲染（body 够长或已含健康分/账号行），点击为空操作不影响。
    var entryClicked = '';
    var body0 = bodyText();
    if (body0.length < 600 && !/违规次数|官方账号|营销账号|Official|Marketing/i.test(body0)) {
      entryClicked = clickCreatorHealthEntry();
      // 点击后给 SPA 一点时间发起渲染请求。注意：单次 page exec 内 busy-wait 无法等异步渲染——
      // JS 单线程，忙等占着主线程，浏览器没机会 layout/paint，DOM 不会更新。这里只短等让点击事件
      // 派发出去；真正的渲染等待靠上层 run-shop-modules.ps1 的 attempt 之间 extra 25s SPA wait
      // （每次 attempt 是独立 page exec，exec 之间浏览器才能渲染）。
      var until = Date.now() + 2500;
      while (Date.now() < until) {}
    }
    var opened = openSwitcher();
    until = Date.now() + 700;
    while (Date.now() < until) {}
    var accounts = collectAccounts();
    var body = bodyText();
    var healthScore = parseScore(body);
    var statusLabel = null;
    var st = body.match(/需要关注|账号信誉良好|你的账号信誉良好|健康/);
    if (st) statusLabel = clean(st[0]).slice(0, 40);

    var violations = [];
    var rows = document.querySelectorAll('tr, [class*="table"] [class*="row"]');
    for (var r = 0; r < rows.length && violations.length < 50; r++) {
      var rt = clean(rows[r].innerText || '');
      if (!rt || rt.length < 10) continue;
      if (/违规类型|日期和时间|操作/.test(rt) && rt.length < 40) continue;
      if (/视频违规|政策违规|一般违规|降低|曝光|申诉/.test(rt)) {
        violations.push({
          type: /视频违规/.test(rt) ? '视频违规' : '违规',
          text: rt.slice(0, 300)
        });
      }
    }

    var selectedName = '';
    var sel = document.querySelector('[class*="selected"], [aria-checked="true"]');
    if (sel) selectedName = clean(sel.innerText || '').split(/\s+/)[0] || '';
    if (!selectedName && accounts.length === 1) selectedName = accounts[0].name;

    // attach current score to selected account when listing
    if (selectedName && healthScore != null) {
      for (var a = 0; a < accounts.length; a++) {
        if (accounts[a].name === selectedName) accounts[a].healthScore = healthScore;
      }
    }

    var ok = healthScore != null || accounts.length > 0 || violations.length > 0;

    // 跑错页（落到订单详情等）：即便 body 里凑出数字也不是健康分，直接报 wrong_page
    // 让上层重试 visit。onOrderDetail 优先级最高——明确不在健康页就别产出数据。
    if (onOrderDetail || (!onCreatorHealth && !HEALTH_PAGE_TERMS.test(body) && violations.length === 0)) {
      return JSON.stringify({
        ok: false,
        module: 'creator_health',
        source: 'creator-health',
        url: url,
        title: title,
        error: 'wrong_page_not_creator_health: ' + url,
        entryClicked: entryClicked,
        diag: { onCreatorHealth: onCreatorHealth, onOrderDetail: onOrderDetail, bodyLen: body.length, sample: body.slice(0, 200) }
      });
    }

    if (!ok || body.length < 50) {
      return JSON.stringify({
        ok: false,
        module: 'creator_health',
        source: 'creator-health',
        error: 'no creator health',
        url: url,
        entryClicked: entryClicked,
        bodyLen: body.length,
        sample: body.slice(0, 200)
      });
    }
    return JSON.stringify({
      ok: true,
      module: 'creator_health',
      source: 'creator-health',
      switcherOpened: opened,
      entryClicked: entryClicked,
      healthScore: healthScore,
      statusLabel: statusLabel,
      selectedName: selectedName,
      accounts: accounts,
      violations: violations,
      url: url,
      raw: { bodyLen: body.length, sample: body.slice(0, 240) }
    });
  } catch (e) {
    return JSON.stringify({ ok: false, error: String((e && e.message) || e) });
  }
})();
