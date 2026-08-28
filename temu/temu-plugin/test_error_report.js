// 本地单测：验证报错签名归一化 + 冷却逻辑（不连真实 chrome/飞书）。
// 运行：node test_error_report.js
// 注意：文件名不能以下划线 _ 开头，Chrome 扩展目录保留 _* 给系统用，会导致「无法加载清单」。
const fs = require('fs');
const path = require('path');

const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');

// 抄 test_sku_parse.js 的 extractFn：从 background.js 文本里抠出纯函数源码
function extractFn(src, name) {
  const re = new RegExp('function ' + name + '\\s*\\(');
  const m = re.exec(src);
  if (!m) throw new Error('fn not found: ' + name);
  const i = normalizeErrorSignature_findStart(src, m.index);
  const start = src.indexOf('{', i);
  let depth = 0;
  for (let j = start; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') {
      depth--;
      if (depth === 0) return src.slice(i, j + 1);
    }
  }
  throw new Error('unclosed ' + name);
}
// 避开上面 normalizeErrorSignature 定义前的引用；直接定位 function 声明
function normalizeErrorSignature_findStart(src, from) { return from; }

let code = extractFn(bg, 'normalizeErrorSignature') + '\n'
  + extractFn(bg, 'pruneErrorCooldown') + '\n'
  + 'const ERROR_REPORT_COOLDOWN_MS = 30 * 60 * 1000;\n'
  + 'const ERROR_REPORT_KEEP_MS = 2 * 60 * 60 * 1000;\n';

// chrome / log stub —— 纯函数测试不碰 storage，但 pruneErrorCooldown 不需要 chrome
const chrome = { storage: { local: { get: async () => ({}), set: async () => {} } } };
const log = { warn: () => {}, info: () => {}, error: () => {} };
const self = {};
global.chrome = chrome;
global.log = log;

eval(code);

let pass = 0, fail = 0;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (detail ? ' :: ' + detail : '')); }
}
function eq(name, a, b) {
  ok(name + ' : "' + a + '" == "' + b + '"', a === b, 'got ' + JSON.stringify(a) + ' want ' + JSON.stringify(b));
}

console.log('\n== normalizeErrorSignature ==');

// ① 不同 productId 数字 → 同一签名（核心去重）
const a1 = normalizeErrorSignature('Cycle error: store=HomeCove NetworkError productId=12345');
const a2 = normalizeErrorSignature('Cycle error: store=HomeCove NetworkError productId=99999');
eq('不同 productId 归一为同签名', a1, a2);

// ② 不同 store 名 → 不同签名（避免过度合并）
const b1 = normalizeErrorSignature('Cycle error: store=HomeCove NetworkError productId=1');
const b2 = normalizeErrorSignature('Cycle error: store=Twilight Cove NetworkError productId=1');
ok('不同店铺保持不同签名', b1 !== b2, b1 + ' vs ' + b2);

// ③ 带时间戳两条 → 同签名
const t1 = normalizeErrorSignature('[2026-08-19 09:30:01] Message handler error: timeout 456');
const t2 = normalizeErrorSignature('[2026-08-19 10:15:22] Message handler error: timeout 789');
eq('带时间戳归一为同签名', t1, t2);

// ④ 带 \n 栈 → 只取首行
const s1 = normalizeErrorSignature('content uncaught: TypeError: boom\n    at foo (bar.js:12)\n    at baz');
const s2 = normalizeErrorSignature('content uncaught: TypeError: boom');
eq('含栈只取首行', s1, s2);

// ⑤ URL 被替换为占位
const u1 = normalizeErrorSignature('fetch https://agentseller.temu.com/api/foo?id=1 failed');
const u2 = normalizeErrorSignature('fetch https://agentseller.temu.com/api/bar?id=2 failed');
eq('URL 被归一', u1, u2);

// ⑥ 空/无首行 → 空串（reportErrorToFeishu 会跳过）
eq('空输入返回空', normalizeErrorSignature(''), '');
eq('纯换行返回空', normalizeErrorSignature('\nstack only'), '');

// ⑦ 长 hex id 被替换
const h1 = normalizeErrorSignature('requestId=abc123def456789 failed');
const h2 = normalizeErrorSignature('requestId=fff000111222333 failed');
eq('长 hex id 归一', h1, h2);

// ⑧ 前缀黑名单场景：这些签名本身不会被跳过（跳过在 reportErrorToFeishu 里判定），
//    这里只验签名稳定
ok('签名长度截断 ≤160', normalizeErrorSignature('x'.repeat(500)).length <= 160);

console.log('\n== pruneErrorCooldown ==');
const now = 1_000_000_000_000;
const m0 = {
  'sig-a': now - 10 * 60 * 1000,                  // 10 分钟前 → 保留（< 2h）
  'sig-b': now - 3 * 60 * 60 * 1000,              // 3 小时前 → 丢弃（> 2h KEEP）
  'sig-c': now - (2 * 60 * 60 * 1000 - 60_000), // 刚到边内 1 分钟 → 保留
};
const pruned = pruneErrorCooldown(m0, now);
ok('保留 2h 内的条目', 'sig-a' in pruned && 'sig-c' in pruned, JSON.stringify(Object.keys(pruned)));
ok('丢弃超 2h 的条目', !('sig-b' in pruned), JSON.stringify(Object.keys(pruned)));
ok('健壮：空/非对象输入不抛', (() => { try { pruneErrorCooldown(null, now); return true; } catch (e) { return false; } })());

console.log('\n== 冷却窗口判定（模拟 reportErrorToFeishu 的判断逻辑）==');
const COOLDOWN_MS = 30 * 60 * 1000;
function shouldSend(lastTs, now) {
  return !(typeof lastTs === 'number' && now - lastTs < COOLDOWN_MS);
}
ok('首次（无记录）→ 应发', shouldSend(undefined, now));
ok('30min 内同签名 → 不发', !shouldSend(now - 5 * 60 * 1000, now));
ok('30min 外同签名 → 发', shouldSend(now - 31 * 60 * 1000, now));
ok('恰好 30min → 发（边界外）', shouldSend(now - COOLDOWN_MS, now));

console.log('\n' + (fail ? '❌ FAIL x' + fail : '✅ ALL PASS') + '  (' + pass + ' passed)');
process.exit(fail ? 1 : 0);
