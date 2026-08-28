/* TikTok orders page: open filter drawer, pick date shortcut, apply.
 * Sync IIFE for ziniao page exec.
 * Placeholder replaced by PowerShell: __ACTION__ (open|pick)
 * No // comments (minified to one line). */
(function () {
  var ACTION = '__ACTION__';

  function cleanText(t) {
    return String(t == null ? '' : t)
      .replace(/\s+/g, ' ')
      .trim();
  }

  function isVisible(el) {
    if (!el || el.nodeType !== 1) return false;
    var st = window.getComputedStyle(el);
    if (!st || st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) === 0) {
      return false;
    }
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function clickEl(el) {
    if (!el) return false;
    try {
      el.scrollIntoView({ block: 'center', inline: 'center' });
    } catch (e) {}
    try {
      if (el.focus) el.focus();
    } catch (e2) {}
    var opts = { bubbles: true, cancelable: true, view: window };
    try {
      el.dispatchEvent(new MouseEvent('mousedown', opts));
      el.dispatchEvent(new MouseEvent('mouseup', opts));
      el.dispatchEvent(new MouseEvent('click', opts));
    } catch (e3) {
      try {
        el.click();
      } catch (e4) {
        return false;
      }
    }
    return true;
  }

  function findVisibleByText(labels, root, maxLen) {
    root = root || document;
    maxLen = maxLen || 30;
    var nodes = root.querySelectorAll('button, a, span, div, li, p, label, [role="button"], [role="tab"]');
    var candidates = [];
    for (var i = 0; i < nodes.length && i < 8000; i++) {
      var el = nodes[i];
      if (!isVisible(el)) continue;
      var t = cleanText(el.innerText || el.textContent || '');
      if (!t || t.length > maxLen) continue;
      for (var k = 0; k < labels.length; k++) {
        if (t === labels[k] || t.toLowerCase() === String(labels[k]).toLowerCase()) {
          candidates.push({ el: el, text: t, exact: true, priority: k });
          break;
        }
      }
    }
    if (!candidates.length) {
      for (var i2 = 0; i2 < nodes.length && i2 < 8000; i2++) {
        var el2 = nodes[i2];
        if (!isVisible(el2)) continue;
        var t2 = cleanText(el2.innerText || el2.textContent || '');
        if (!t2 || t2.length > maxLen) continue;
        for (var k2 = 0; k2 < labels.length; k2++) {
          var lab = String(labels[k2]);
          if (t2.indexOf(lab) >= 0 || t2.toLowerCase().indexOf(lab.toLowerCase()) >= 0) {
            candidates.push({ el: el2, text: t2, exact: false, priority: k2 });
            break;
          }
        }
      }
    }
    if (!candidates.length) return null;
    candidates.sort(function (a, b) {
      return (b.exact ? 1 : 0) - (a.exact ? 1 : 0) || a.priority - b.priority || a.text.length - b.text.length;
    });
    return candidates[0];
  }

  var DRAWER_SELS = [
    '.arco-drawer',
    '[class*="drawer"]',
    '[class*="Drawer"]',
    'aside',
    '[role="dialog"]',
    '.semi-sidesheet',
    '.tiktok-drawer'
  ];

  function findDrawer() {
    for (var i = 0; i < DRAWER_SELS.length; i++) {
      var els = document.querySelectorAll(DRAWER_SELS[i]);
      for (var j = 0; j < els.length; j++) {
        if (!isVisible(els[j])) continue;
        var t = cleanText(els[j].innerText || '').slice(0, 200);
        if (/筛选|filter|订单创建|创建时间|订单状态/i.test(t)) {
          return els[j];
        }
      }
    }
    return null;
  }

  function findFilterButton() {
    var labels = ['筛选', 'Filter', 'Filters'];
    var nodes = document.querySelectorAll('button, [role="button"], a, div, span');
    var candidates = [];
    for (var i = 0; i < nodes.length && i < 3000; i++) {
      var el = nodes[i];
      if (!isVisible(el)) continue;
      var t = cleanText(el.innerText || el.textContent || '');
      if (!t || t.length > 30) continue;
      for (var k = 0; k < labels.length; k++) {
        if (t === labels[k] || t.indexOf(labels[k]) === 0) {
          candidates.push({ el: el, text: t, priority: k, len: t.length });
          break;
        }
      }
    }
    if (!candidates.length) return null;
    candidates.sort(function (a, b) {
      return a.priority - b.priority || a.len - b.len;
    });
    return candidates[0];
  }

  var action = String(ACTION || 'open').toLowerCase();

  if (action === 'open') {
    var existing = findDrawer();
    if (existing) {
      return JSON.stringify({
        ok: true,
        action: 'open',
        drawerOpen: true,
        alreadyOpen: true,
        message: 'filter drawer already open'
      });
    }
    var btn = findFilterButton();
    if (!btn) {
      return JSON.stringify({
        ok: false,
        action: 'open',
        drawerOpen: false,
        error: '未找到筛选按钮'
      });
    }
    clickEl(btn.el);

    var opened = false;
    var checks = 0;
    var maxChecks = 20;
    var checkInterval = 100;
    function pollDrawer() {
      while (checks < maxChecks) {
        checks++;
        var d = findDrawer();
        if (d) { opened = true; break; }
      }
    }
    pollDrawer();

    if (!opened) {
      var parent = btn.el.parentElement;
      if (parent) {
        clickEl(parent);
        checks = 0;
        pollDrawer();
      }
    }

    return JSON.stringify({
      ok: opened,
      action: 'open',
      drawerOpen: opened,
      triggerVia: btn.text,
      message: opened ? 'filter drawer opened' : '点击筛选按钮但未检测到抽屉打开'
    });
  }

  if (action === 'pick') {
    var drawer = findDrawer();
    if (!drawer) {
      return JSON.stringify({
        ok: false,
        action: 'pick',
        error: '筛选抽屉未打开'
      });
    }

    var dateSection = null;
    var allNodes = drawer.querySelectorAll('div, span, label, p, h3, h4, h5');
    for (var n = 0; n < allNodes.length && n < 2000; n++) {
      var nd = allNodes[n];
      var txt = cleanText(nd.innerText || nd.textContent || '');
      if (txt.length < 40 && /订单创建时间|创建时间|Order created|Create time/i.test(txt)) {
        dateSection = nd;
        break;
      }
    }

    var dateClicked = false;
    if (dateSection) {
      var container = dateSection;
      for (var up = 0; up < 4; up++) {
        if (container.parentElement) container = container.parentElement;
        else break;
      }

      var dateInput = container.querySelector('input[placeholder*="日期"], input[type="text"], input[placeholder*="自"], input[placeholder*="至"], input[placeholder*="Date"]');
      if (dateInput && isVisible(dateInput)) {
        clickEl(dateInput);
        dateClicked = true;
      }

      if (!dateClicked) {
        var triggerEls = container.querySelectorAll('[class*="picker"], [class*="Picker"], [class*="date"], [class*="Date"], [class*="range"], [class*="Range"], [class*="trigger"], [class*="Trigger"], button, [role="button"]');
        for (var te = 0; te < triggerEls.length; te++) {
          if (isVisible(triggerEls[te])) {
            clickEl(triggerEls[te]);
            dateClicked = true;
            break;
          }
        }
      }
    }

    var shortcut = findVisibleByText(
      ['昨天', '昨日', 'Yesterday', 'yesterday'],
      drawer,
      20
    );

    if (!shortcut) {
      shortcut = findVisibleByText(
        ['昨天', '昨日', 'Yesterday', 'yesterday'],
        document,
        20
      );
    }

    var shortcutClicked = false;
    var shortcutText = '';
    if (shortcut) {
      shortcutClicked = clickEl(shortcut.el);
      shortcutText = shortcut.text;
    }

    var applyBtn = findVisibleByText(
      ['应用', 'Apply', '确定', '确认', 'OK', 'Done'],
      drawer,
      20
    );
    var applied = false;
    var applyText = '';
    if (applyBtn) {
      applied = clickEl(applyBtn.el);
      applyText = applyBtn.text;
    }

    if (!applyBtn) {
      applyBtn = findVisibleByText(
        ['应用', 'Apply', '确定', '确认', 'OK', 'Done'],
        document,
        20
      );
      if (applyBtn) {
        applied = clickEl(applyBtn.el);
        applyText = applyBtn.text;
      }
    }

    return JSON.stringify({
      ok: shortcutClicked && applied,
      softOk: shortcutClicked,
      action: 'pick',
      dateSection: !!dateSection,
      dateClicked: dateClicked,
      shortcutClicked: shortcutClicked,
      shortcutText: shortcutText,
      applied: applied,
      applyText: applyText,
      message: shortcutClicked && applied
        ? '已选昨天并应用'
        : shortcutClicked
          ? '已选昨天但未找到应用按钮'
          : '未找到昨天快捷项',
      error: shortcutClicked ? null : '未找到昨天快捷项'
    });
  }

  return JSON.stringify({
    ok: false,
    action: action,
    error: 'unknown action: ' + action
  });
})();
