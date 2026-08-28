const DEFAULT = {
  webhook: '',
  intervalMinutes: 15,
  enabled: true,
  storeName: '',
  machineLabel: '',
  mustRemindEnabled: true,
  mustRemindTimes: ['09:30', '16:30'],
  feishuAppId: '',
  feishuAppSecret: '',
  bitableAppToken: '',
  bitableTableId: '',
  feishuTaskEnabled: true,
  feishuTasklistGuid: '',
};

function timesToStr(arr) {
  if (!Array.isArray(arr) || !arr.length) return '09:30, 16:30';
  return arr.join(', ');
}
function parseTimes(str) {
  const parts = String(str || '')
    .split(/[,，;；\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
  const out = [];
  const seen = {};
  for (const p of parts) {
    const m = p.match(/^(\d{1,2})[:.：](\d{2})$/);
    if (!m) continue;
    const h = Number(m[1]);
    const min = Number(m[2]);
    if (h > 23 || min > 59) continue;
    const label = String(h).padStart(2, '0') + ':' + String(min).padStart(2, '0');
    if (seen[label]) continue;
    seen[label] = true;
    out.push(label);
  }
  return out.length ? out : DEFAULT.mustRemindTimes.slice();
}

async function load() {
  const { config } = await chrome.storage.local.get('config');
  const c = Object.assign({}, DEFAULT, config || {});
  document.getElementById('webhook').value = c.webhook || '';
  document.getElementById('storeName').value = c.storeName || '';
  document.getElementById('machineLabel').value = c.machineLabel || '';
  document.getElementById('interval').value = c.intervalMinutes || 15;
  document.getElementById('enabled').checked = c.enabled !== false;
  document.getElementById('mustRemindEnabled').checked = c.mustRemindEnabled !== false;
  document.getElementById('mustRemindTimes').value = timesToStr(c.mustRemindTimes);
  document.getElementById('frontCheckEnabled').checked = c.frontCheckEnabled !== false;
  document.getElementById('frontCheckInterval').value = c.frontCheckIntervalHours || 3;
  document.getElementById('feishuAppId').value = c.feishuAppId || '';
  document.getElementById('feishuAppSecret').value = c.feishuAppSecret || '';
  document.getElementById('bitableAppToken').value = c.bitableAppToken || '';
  document.getElementById('bitableTableId').value = c.bitableTableId || '';
  document.getElementById('feishuTaskEnabled').checked = c.feishuTaskEnabled !== false;
  document.getElementById('feishuTasklistGuid').value = c.feishuTasklistGuid || '';
}

document.getElementById('save').addEventListener('click', async () => {
  const { config: oldCfg } = await chrome.storage.local.get('config');
  const productUrls = (oldCfg && oldCfg.productUrls) || {};
  const config = {
    webhook: document.getElementById('webhook').value.trim(),
    storeName: document.getElementById('storeName').value.trim(),
    machineLabel: document.getElementById('machineLabel').value.trim(),
    intervalMinutes: Math.max(1, Number(document.getElementById('interval').value) || 15),
    enabled: document.getElementById('enabled').checked,
    mustRemindEnabled: document.getElementById('mustRemindEnabled').checked,
    mustRemindTimes: parseTimes(document.getElementById('mustRemindTimes').value),
    frontCheckEnabled: document.getElementById('frontCheckEnabled').checked,
    frontCheckIntervalHours: Math.max(1, Math.min(24, Number(document.getElementById('frontCheckInterval').value) || 3)),
    productUrls: productUrls,
    feishuAppId: document.getElementById('feishuAppId').value.trim(),
    feishuAppSecret: document.getElementById('feishuAppSecret').value.trim(),
    bitableAppToken: document.getElementById('bitableAppToken').value.trim(),
    bitableTableId: document.getElementById('bitableTableId').value.trim(),
    feishuTaskEnabled: document.getElementById('feishuTaskEnabled').checked,
    feishuTasklistGuid: document.getElementById('feishuTasklistGuid').value.trim(),
  };
  await chrome.storage.local.set({ config });
  const el = document.getElementById('saved');
  const bitableOk = !!(config.feishuAppId && config.feishuAppSecret && config.bitableAppToken && config.bitableTableId);
  el.textContent = '✓ 已保存（必提醒 ' + config.mustRemindTimes.join('、')
    + (bitableOk ? ' · 多维表已配' : ' · 多维表未配') + '）';
  setTimeout(() => (el.textContent = ''), 4000);
});

// ---- 前台商品 URL 管理 ----
async function renderProductUrls() {
  const { config, stores } = await chrome.storage.local.get(['config', 'stores']);
  const productUrls = (config && config.productUrls) || {};
  const storeNames = Object.keys(stores || {}).filter((n) => n && n !== '当前店铺');
  const allStores = [...new Set([...storeNames, ...Object.keys(productUrls)])].sort();

  const sel = document.getElementById('puStore');
  sel.innerHTML = allStores.map((n) => '<option value="' + escAttr(n) + '">' + esc(n) + '</option>').join('') || '<option>(暂无店铺)</option>';

  const section = document.getElementById('productUrlSection');
  const entries = [];
  for (const [store, urls] of Object.entries(productUrls)) {
    if (!Array.isArray(urls)) continue;
    for (const url of urls) {
      entries.push({ store, url });
    }
  }
  if (!entries.length) {
    section.innerHTML = '<div style="color:#8a9099;font-size:12px;">暂无配置。请选择店铺并粘贴 Temu 前台商品链接。</div>';
  } else {
    section.innerHTML = entries.map((e) =>
      '<div style="display:flex;justify-content:space-between;align-items:center;margin:6px 0;padding:4px 8px;background:#f6f7f9;border-radius:4px;font-size:12px;">'
      + '<span><b>' + esc(e.store) + '</b> · ' + esc(e.url.slice(0, 70)) + '</span>'
      + '<span class="puDel" data-store="' + escAttr(e.store) + '" data-url="' + escAttr(e.url) + '" style="color:#d92d20;cursor:pointer;font-size:14px;opacity:.6;" title="删除">✕</span>'
      + '</div>'
    ).join('');
    section.querySelectorAll('.puDel').forEach((el) => {
      el.addEventListener('click', async () => {
        const store = el.getAttribute('data-store');
        const url = el.getAttribute('data-url');
        const { config: cfg } = await chrome.storage.local.get('config');
        const productUrls = Object.assign({}, (cfg && cfg.productUrls) || {});
        if (productUrls[store]) {
          productUrls[store] = productUrls[store].filter((u) => u !== url);
          if (!productUrls[store].length) delete productUrls[store];
        }
        cfg.productUrls = productUrls;
        await chrome.storage.local.set({ config: cfg });
        try { chrome.runtime.sendMessage({ type: 'deleteProductUrl', store, url }); } catch (e) {}
        renderProductUrls();
      });
    });
  }
}

function escAttr(s) { return String(s).replace(/"/g, '&quot;'); }
function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

document.getElementById('puAdd').addEventListener('click', async () => {
  const store = document.getElementById('puStore').value;
  const url = document.getElementById('puUrl').value.trim();
  if (!store) { alert('请先选择店铺'); return; }
  if (!url || !/^https?:\/\/www\.temu\.com\//.test(url)) { alert('请输入有效的 Temu 前台商品链接（以 https://www.temu.com/ 开头）'); return; }
  const { config } = await chrome.storage.local.get('config');
  const productUrls = Object.assign({}, (config && config.productUrls) || {});
  if (!productUrls[store]) productUrls[store] = [];
  const base = url.split('?')[0];
  if (productUrls[store].includes(base)) { alert('该链接已存在'); return; }
  productUrls[store].push(base);
  config.productUrls = productUrls;
  await chrome.storage.local.set({ config });
  document.getElementById('puUrl').value = '';
  renderProductUrls();
});

const origLoad = load;
load = async function () {
  await origLoad();
  renderProductUrls();
};

load();
