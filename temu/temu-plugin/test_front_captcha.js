// 纯逻辑单测：前台人机验证 / 页面打不开检测规则
// 运行：node test_front_captcha.js
//
// detectCaptcha 的核心规则（与 content-front.js 保持一致）：
//   1. outerHTML 命中关键词之一；
//   2. 且 (有验证码容器 iframe/canvas/... ) 或 (正文 <400 字符)；
//   3. 否则不算（避免商品文案里恰好提到 "captcha" 之类误杀）。

const KEYWORDS = [
  'verify you are human', 'verify that you are', 'are you human',
  'human verification', 'robot verification', 'unusual traffic',
  '请验证', '人机验证', '滑块验证', '安全验证', '验证一下', '拖动滑块',
  'captcha', 'recaptcha', 'geetest', 'nc_iconfont', 'tcaptcha',
  'access denied', '请求被拦截', '访问被拒', '页面不存在', 'not found',
  '无法访问', '网络错误', '连接超时', 'ERR_CONNECTION', 'ERR_NAME',
];

function detectCaptchaFromHtml(html, bodyText) {
  if (!html) return null;
  const low = html.toLowerCase();
  const hit = KEYWORDS.find((k) => low.indexOf(k.toLowerCase()) >= 0);
  if (!hit) return null;
  const hasBox = /iframe|canvas/i.test(html);
  const shortPage = (bodyText || '').replace(/\s+/g, ' ').trim().length < 400;
  if (!hasBox && !shortPage) return null;
  return { keyword: hit, hasBox, shortPage };
}

function assert(cond, msg) {
  if (!cond) throw new Error('FAIL: ' + msg);
  console.log('OK  ' + msg);
}

// 1) 正常商品页（内容丰富、无关键词）→ 不报
{
  const html = '<div><h1>2件装狗狗咀嚼玩具</h1><span class="price">£10.04</span>'
    + '<div class="variant">Blue</div><div class="variant">Yellow</div></div>';
  const body = '2件装狗狗咀嚼玩具 £10.04 Blue Yellow 适用于宠物咀嚼 牙齿清洁 …'.repeat(20);
  assert(!detectCaptchaFromHtml(html, body), '正常商品页不报');
}

// 2) 英文人机验证页（有 captcha 关键词 + iframe + 正文短）→ 报
{
  const html = '<html><body><iframe src="https://recaptcha.net/..."></iframe>'
    + '<div>Verify you are human</div></body></html>';
  const body = 'Verify you are human';
  const r = detectCaptchaFromHtml(html, body);
  assert(r, '英文人机验证页报');
  assert(r.hasBox === true, '识别到验证码容器');
}

// 3) 中文风控页（滑块验证 + 正文短）→ 报
{
  const html = '<div class="nc_iconfont"></div><div>请完成滑块验证</div>';
  const body = '请完成滑块验证，以确认你不是机器人';
  const r = detectCaptchaFromHtml(html, body);
  assert(r && /滑块验证|nc_iconfont/.test(r.keyword), '中文滑块验证页报');
}

// 4) 商品文案里恰好含 "captcha" 但页面内容丰富、无验证码容器 → 不误杀
{
  const html = '<h1>玩具</h1><p>This toy is not a captcha puzzle game.</p>'
    + '<span>Blue</span><span>Yellow</span><span>Red</span>';
  const body = 'This toy is not a captcha puzzle game. '.repeat(30);
  assert(!detectCaptchaFromHtml(html, body), '商品文案含 captcha 但内容丰富 → 不误杀');
}

// 5) 网络错误页（ERR_CONNECTION + 正文短）→ 报
{
  const html = '<div>ERR_CONNECTION_TIMED_OUT</div>';
  const body = '无法访问此网站 连接已超时 ERR_CONNECTION_TIMED_OUT';
  const r = detectCaptchaFromHtml(html, body);
  assert(r && /ERR_CONNECTION|无法访问/.test(r.keyword), '网络错误页报');
}

// 6) Access denied 拦截页 → 报
{
  const html = '<div>Access Denied You do not have permission</div>';
  const body = 'Access Denied';
  const r = detectCaptchaFromHtml(html, body);
  assert(r, 'Access Denied 拦截页报');
}

// 7) loading 瞬态（关键词没命中、正文短）→ 不报（detectCaptcha 靠关键词门控）
{
  const html = '<div class="loading">Loading…</div>';
  const body = 'Loading';
  assert(!detectCaptchaFromHtml(html, body), '纯 loading 无关键词 → 不报');
}

// 8) 关键词命中但正文丰富 + 无容器（例如商品页底部小字 legal 提到 verify）→ 不误杀
{
  const html = '<h1>喷雾拖把</h1><div>variants x 37</div>'
    + '<footer>Temu may ask you to verify that you are human for bulk access. </footer>';
  const body = '喷雾拖把 轻量 微纤维 360度旋转 适合木地板瓷砖浴室 '.repeat(25)
    + ' footer legal verify that you are human';
  assert(!detectCaptchaFromHtml(html, body), 'footer legal 文案命中但内容丰富 → 不误杀');
}

console.log('\nAll front captcha detection tests passed.');
