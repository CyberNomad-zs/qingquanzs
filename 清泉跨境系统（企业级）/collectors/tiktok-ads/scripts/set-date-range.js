/* Set TikTok ads dashboard date range. Sync IIFE for ziniao page exec.
 * Placeholders replaced by PowerShell: __DATE_MODE__ (yesterday|today), __ACTION__ (open|pick|status)
 * No // comments (minified to one line). */
(function () {
  var MODE = '__DATE_MODE__';
  var ACTION = '__ACTION__';

  function cleanText(t) {
    return String(t == null ? '' : t)
      .replace(/\s+/g, ' ')
      .trim();
  }

  function pad2(n) {
    return (n < 10 ? '0' : '') + n;
  }

  function formatYmd(d) {
    return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
  }

  function parseYmd(s) {
    var m = String(s || '').match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
    if (!m) return null;
    return {
      y: Number(m[1]),
      m: Number(m[2]),
      d: Number(m[3]),
      ymd: m[1] + '-' + pad2(Number(m[2])) + '-' + pad2(Number(m[3]))
    };
  }

  function targetMeta(mode) {
    var today = new Date();
    today.setHours(0, 0, 0, 0);
    var y = new Date(today.getTime());
    y.setDate(y.getDate() - 1);
    if (mode === 'today') {
      return { start: formatYmd(today), end: formatYmd(today), labels: ['今天', '今日', 'Today', 'today'], calendar: null };
    }
    var custom = parseYmd(mode);
    if (custom) {
      return { start: custom.ymd, end: custom.ymd, labels: [], calendar: custom };
    }
    return {
      start: formatYmd(y),
      end: formatYmd(y),
      labels: ['昨天', '昨日', 'Yesterday', 'yesterday'],
      calendar: null
    };
  }

  function parseRangeFromText(text) {
    var t = cleanText(text);
    var m = t.match(/(\d{4}[-\/]\d{1,2}[-\/]\d{1,2})\s*[-–~至到]\s*(\d{4}[-\/]\d{1,2}[-\/]\d{1,2})/);
    if (!m) return null;
    function norm(s) {
      var p = s.replace(/\//g, '-').split('-');
      return p[0] + '-' + pad2(Number(p[1])) + '-' + pad2(Number(p[2]));
    }
    return { start: norm(m[1]), end: norm(m[2]), raw: m[0] };
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

  function readDisplayedRange() {
    var nodes = document.querySelectorAll('input, button, div, span, p, a');
    var best = null;
    for (var i = 0; i < nodes.length && i < 5000; i++) {
      var el = nodes[i];
      if (!isVisible(el)) continue;
      var text = '';
      if (el.tagName === 'INPUT') text = el.value || el.getAttribute('placeholder') || '';
      else text = el.innerText || el.textContent || '';
      text = cleanText(text).slice(0, 80);
      var rg = parseRangeFromText(text);
      if (!rg) continue;
      var r = el.getBoundingClientRect();
      if (r.top > window.innerHeight * 0.55) continue;
      best = { el: el, range: rg, text: text };
      if (el.tagName === 'INPUT' || /picker|date|calendar|range/i.test(el.className || '')) break;
    }
    return best;
  }

  function findDateTrigger() {
    var shown = readDisplayedRange();
    if (shown && shown.el) {
      var cur = shown.el;
      for (var d = 0; d < 6 && cur; d++) {
        if (
          cur.matches &&
          cur.matches(
            'button, [role="button"], input, .arco-picker, .arco-picker-range, [class*="picker"], [class*="Picker"], [class*="date"], [class*="Date"]'
          )
        ) {
          return { el: cur, range: shown.range, via: 'range-text' };
        }
        cur = cur.parentElement;
      }
      return { el: shown.el, range: shown.range, via: 'range-text' };
    }
    var sels = [
      '.arco-picker-range',
      '.arco-picker',
      '[class*="RangePicker"]',
      '[class*="range-picker"]',
      '[class*="DatePicker"]',
      'input[placeholder*="日期"]',
      'input[placeholder*="Date"]'
    ];
    for (var s = 0; s < sels.length; s++) {
      var list = document.querySelectorAll(sels[s]);
      for (var j = 0; j < list.length; j++) {
        if (isVisible(list[j])) return { el: list[j], range: null, via: sels[s] };
      }
    }
    return null;
  }

  function findShortcut(labels) {
    var nodes = document.querySelectorAll(
      'button, a, li, div, span, [role="button"], [role="option"], [role="menuitem"]'
    );
    var candidates = [];
    for (var i = 0; i < nodes.length && i < 8000; i++) {
      var el = nodes[i];
      if (!isVisible(el)) continue;
      var t = cleanText(el.innerText || el.textContent || '');
      if (!t || t.length > 20) continue;
      for (var k = 0; k < labels.length; k++) {
        if (t === labels[k] || t.toLowerCase() === String(labels[k]).toLowerCase()) {
          candidates.push({ el: el, text: t, exact: true });
          break;
        }
      }
    }
    if (!candidates.length) {
      for (var i2 = 0; i2 < nodes.length && i2 < 8000; i2++) {
        var el2 = nodes[i2];
        if (!isVisible(el2)) continue;
        var t2 = cleanText(el2.innerText || el2.textContent || '');
        if (!t2 || t2.length > 20) continue;
        for (var k2 = 0; k2 < labels.length; k2++) {
          var lab = String(labels[k2]);
          if (t2.indexOf(lab) >= 0 || t2.toLowerCase().indexOf(lab.toLowerCase()) >= 0) {
            candidates.push({ el: el2, text: t2, exact: false });
            break;
          }
        }
      }
    }
    if (!candidates.length) return null;
    candidates.sort(function (a, b) {
      return (b.exact ? 1 : 0) - (a.exact ? 1 : 0) || a.text.length - b.text.length;
    });
    return candidates[0];
  }

  function findPanelRoot() {
    var panelSels = [
      '.arco-picker-container',
      '.arco-trigger-popup',
      '.arco-panel-date',
      '[class*="picker-container"]',
      '[class*="PickerDropdown"]',
      '[class*="datepicker"]',
      '[class*="DatePicker"]',
      '[class*="calendar-panel"]',
      '[class*="shortcut"]'
    ];
    for (var i = 0; i < panelSels.length; i++) {
      var els = document.querySelectorAll(panelSels[i]);
      for (var j = 0; j < els.length; j++) {
        if (isVisible(els[j]) && els[j].querySelectorAll('button, td, [class*="cell"], [class*="date"]').length > 3) {
          return els[j];
        }
      }
    }
    return null;
  }

  function panelOpen() {
    if (findPanelRoot()) return true;
    return !!findShortcut(['今天', '昨天', '近7天', 'Today', 'Yesterday', 'Last 7 days']);
  }

  function readPanelMonth(root) {
    if (!root) return null;
    var t = cleanText(root.innerText || '').slice(0, 120);
    var m = t.match(/(\d{4})\s*[年/\-.]\s*(\d{1,2})/);
    if (m) return { y: Number(m[1]), m: Number(m[2]) };
    return null;
  }

  function clickMonthNav(root, dir) {
    if (!root) return false;
    var nodes = root.querySelectorAll('button, span, div, i, svg, [class*="icon"]');
    var re = dir > 0
      ? /next|right|后|下月|arrow-right/i
      : /prev|left|前|上月|arrow-left/i;
    for (var i = 0; i < nodes.length && i < 200; i++) {
      var el = nodes[i];
      if (!isVisible(el) && el.tagName !== 'svg' && el.tagName !== 'I') continue;
      var cls = String(el.className || '') + ' ' + String(el.getAttribute && el.getAttribute('aria-label') || '');
      if (re.test(cls) || re.test(cleanText(el.getAttribute && el.getAttribute('aria-label') || ''))) {
        return clickEl(el.closest ? el.closest('button, span, div') || el : el);
      }
    }
    var icons = root.querySelectorAll('[class*="arco-icon"], [class*="arco-picker-icon"]');
    if (icons.length >= 2) {
      return clickEl(dir > 0 ? icons[icons.length - 1] : icons[0]);
    }
    return false;
  }

  function pickCalendarDay(cal) {
    var root = findPanelRoot();
    if (!root) return { ok: false, error: 'calendar panel not found' };
    var i;
    for (i = 0; i < 16; i++) {
      var pm = readPanelMonth(root);
      if (pm && pm.y === cal.y && pm.m === cal.m) break;
      if (!pm) break;
      var want = cal.y * 12 + cal.m;
      var have = pm.y * 12 + pm.m;
      clickMonthNav(root, want > have ? 1 : -1);
    }
    var wantDay = String(cal.d);
    var wantDay2 = pad2(cal.d);
    var cells = root.querySelectorAll(
      '.arco-picker-cell-in-view, .arco-picker-date, [class*="picker-cell-in-view"], [class*="picker-date"], td, div'
    );
    var hit = null;
    for (i = 0; i < cells.length && i < 400; i++) {
      var el = cells[i];
      if (!isVisible(el)) continue;
      var t = cleanText(el.innerText || el.textContent || '');
      if (t !== wantDay && t !== wantDay2) continue;
      var cls = String(el.className || '');
      if (/out-of-view|disabled|hidden|out-of-month|not-in-view/i.test(cls)) continue;
      if (el.querySelector && el.querySelectorAll('div, span, td').length > 8) continue;
      hit = el;
      if (/in-view|picker-date|picker-cell/i.test(cls)) break;
    }
    if (!hit) return { ok: false, error: 'day cell ' + cal.ymd + ' not found', month: readPanelMonth(root) };
    clickEl(hit);
    clickEl(hit);
    var applyBtns = findShortcut(['确定', '应用', 'Apply', 'OK', '确认', 'Done']);
    if (applyBtns && /确定|应用|Apply|OK|确认|Done/i.test(applyBtns.text)) {
      clickEl(applyBtns.el);
    }
    return { ok: true, clicked: cal.ymd, month: readPanelMonth(root) };
  }

  var mode = String(MODE || 'yesterday').toLowerCase();
  if (mode !== 'today' && mode !== 'yesterday' && !parseYmd(mode)) mode = 'yesterday';
  var action = String(ACTION || 'status').toLowerCase();
  var target = targetMeta(mode);
  var shown = readDisplayedRange();
  var range = shown ? shown.range : null;

  if (action === 'status') {
    var matchedStatus =
      !!(range && range.start === target.start && range.end === target.end);
    return JSON.stringify({
      ok: true,
      action: 'status',
      mode: mode,
      range: range,
      target: { start: target.start, end: target.end },
      matched: matchedStatus,
      panelOpen: panelOpen()
    });
  }

  if (
    range &&
    range.start === target.start &&
    range.end === target.end &&
    action !== 'pick'
  ) {
    return JSON.stringify({
      ok: true,
      skipped: true,
      action: action,
      mode: mode,
      before: range,
      after: range,
      message: 'already on target range'
    });
  }

  if (action === 'open') {
    var trigger = findDateTrigger();
    if (!trigger || !trigger.el) {
      return JSON.stringify({
        ok: false,
        action: 'open',
        mode: mode,
        before: range,
        error: '未找到日期选择器（页面上无日期区间控件）'
      });
    }
    clickEl(trigger.el);
    if (!panelOpen() && trigger.el.parentElement) {
      clickEl(trigger.el.parentElement);
    }
    if (!panelOpen()) {
      var icon =
        document.querySelector('[class*="calendar"]') ||
        document.querySelector('[class*="Calendar"]');
      if (icon) {
        clickEl(icon.closest ? icon.closest('button, div, span') || icon : icon);
      }
    }
    return JSON.stringify({
      ok: true,
      action: 'open',
      mode: mode,
      before: range,
      triggerVia: trigger.via,
      panelOpen: panelOpen(),
      message: 'date picker open clicked'
    });
  }

  if (action === 'pick') {
    if (!panelOpen()) {
      var trigger2 = findDateTrigger();
      if (trigger2 && trigger2.el) clickEl(trigger2.el);
    }
    var clicked = '';
    if (target.calendar) {
      var calHit = pickCalendarDay(target.calendar);
      if (!calHit.ok) {
        return JSON.stringify({
          ok: false,
          action: 'pick',
          mode: mode,
          before: range,
          panelOpen: panelOpen(),
          error: calHit.error || 'calendar pick failed',
          month: calHit.month || null
        });
      }
      clicked = calHit.clicked;
    } else {
      var sc = findShortcut(target.labels);
      if (!sc) {
        return JSON.stringify({
          ok: false,
          action: 'pick',
          mode: mode,
          before: range,
          panelOpen: panelOpen(),
          error: '未找到快捷项: ' + target.labels.join('/')
        });
      }
      clickEl(sc.el);
      clicked = sc.text;
      var applyBtns = findShortcut(['确定', '应用', 'Apply', 'OK', '确认', 'Done']);
      if (applyBtns && /确定|应用|Apply|OK|确认|Done/i.test(applyBtns.text)) {
        clickEl(applyBtns.el);
      }
    }
    var afterShown = readDisplayedRange();
    var after = afterShown ? afterShown.range : null;
    var matched =
      !!(after && after.start === target.start && after.end === target.end);
    var changed =
      !!(after && range && (after.start !== range.start || after.end !== range.end));
    return JSON.stringify({
      ok: true,
      softOk: true,
      action: 'pick',
      mode: mode,
      clicked: clicked,
      before: range,
      after: after,
      target: { start: target.start, end: target.end },
      matched: matched,
      changed: changed,
      message: 'clicked ' + clicked
    });
  }

  return JSON.stringify({
    ok: false,
    action: action,
    mode: mode,
    error: 'unknown action (use open|pick|status)'
  });
})();
