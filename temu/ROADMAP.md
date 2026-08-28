# Temu 多店铺监测 · 技术路线图（维护详版）

> 面向后续维护者：从立项到当前主路径的架构演进、每次改版的**业务原因**、**代码层根因**与**修法**。  
> 同事装机说明见 `temu-plugin/使用说明.txt`；赛狐部署见 `temu-monitor/SELLFOX.md`、`temu-monitor/deploy/README-SERVER.md`。  
> 告警标准见 **`SLO.md`**（双通道策略 A：都报、文案区分、接受偶尔两张）。能力表见 `temu-monitor/PLUGIN_PARITY.md`。  
> 发版闸门：`temu-plugin/check.ps1`（含 `test_timelines.js`）。  
> 文档日期：2026-08-28。当前插件 popup 应显示 **`后台：v22.3-库存归零+B路径假上架静默恢复`**（manifest `0.2.17`）。历史演进仍以下文 v14–v19 为骨架；v20 起见 `temu-plugin/background.js` 文件头与 `使用说明.txt`。

---

## 0. 一分钟读懂现在

### 0.1 业务始终盯两件事

| # | 业务 | 当前谁做 |
|---|------|----------|
| ① | 在售变化（数量 / 下架点名 / 上架点名） | **插件 A+B（agentseller 后台为准）** + **服务器赛狐（可能滞后）** |
| ② | 流量异常（待关注 / 近期下降 / 限流分级） | **仅 Chrome 插件**（赛狐无此字段） |

### 0.2 生产三通道（勿双开同职责）

| 通道 | 目录 / 单元 | 职责 | 状态 |
|------|-------------|------|------|
| 同事日常 Chrome | `temu-plugin/` | 限流分级 + 在售 A+B 兜底 + 09:30/16:30 必提醒 + 空闲多店轮巡 + 报错/风控/库存归零 | **主力** v22.3 |
| 固定 IP 服务器 | systemd `temu-sellfox` ← `temu-monitor/src/sellfox/` | 赛狐 `selectStatus=12` 上下架点名 | **生产常驻** |
| 本机 Playwright | `temu-monitor/src/*.js` | 应急流量 / DOM 回归 | **停发日常**；勿与插件同飞书双开 |

```
同事 Chrome (plugin v22.3)
  ├─ 限流：在售 ∩ (待关注|下降) → VIP*/JM*+热销 分级
  ├─ 切店：chip 高水位 + productId 静默吸收 + withStores 串行
  ├─ 在售 A：countStatus + mallId 绑店 + pendingQty 防抖
  ├─ 在售 B：scanOnSale 清单 diff（下架立即 / 上架两轮）
  └─ 必提醒：09:30·16:30 列限流池+编辑链接
           │
           ▼ 飞书 webhook（卡片带来源标注）
服务器 43.156.50.38 · temu-sellfox
  └─ 赛狐 getParentPageList · 漏拉护栏 · 上架 pendingOnshelf
```

### 0.3 改代码前必读约束

1. **升级插件必须 chrome://extensions 关开开关**（重建 MV3 Service Worker）。只点 ↻ 或 F5 标签页会导致 background 仍跑旧逻辑，popup 显示「旧版」。
2. **所有 `stores` 的读-改-写必须走 `withStores`**（`background.js`）。并发 `get→mutate→set` 会丢 `alertedTrafficIds` / `pendingQty` 等字段。
3. **上下架双通道策略 A（已采纳）**：插件与赛狐**都报**；文案区分（插件卡含「插件·后台」）；**接受偶尔两张**。插件侧 productId **6h** 冷却。不为双报关通道；详见 `SLO.md`。
4. **本机不要给同事发** `sellfox.config.json`、`fullRun:true`、traffic-local 日常包、`.pem`、`.userdata`。
5. **赛狐改 diff 后**：scp `diff.js`+`monitor.js` 到 `/opt/temu-monitor/src/sellfox/`，`systemctl restart temu-sellfox`；先跑 `diff.selftest.js`。
6. **选择器 / 接口会漂**：UI 是 Temu beast-core（优先 `data-testid`）；列表接口带 **anti-content**，裸 HTTP 不可靠。回归用 `temu-monitor` 的 probe/calibrate 或真实 Chrome 插件。

---

## 1. 仓库地图

```
E:\project\temu\
├── ROADMAP.md                 ← 本文件
├── README.md                  ← 入口与安全说明
├── temu-plugin/               ← 日常主力
│   ├── background.js          ← SW：diff / 告警 / 轮巡 / 必提醒（看文件头版本注释）
│   ├── content.js             ← agentseller DOM + 收 hook 消息（含 mallId）
│   ├── inject.js              ← MAIN world hook fetch/XHR
│   ├── content-front.js       ← www.temu.com 前台变体
│   ├── feishuApp.js           ← 可选多维表/任务
│   ├── popup.* / options.*
│   ├── test_traffic_dedupe.js / test_onsale_ab.js / test_sku_parse.js
│   └── 使用说明.txt
├── temu-monitor/              ← Playwright 应急 + 赛狐服务器代码
│   ├── src/run.js, monitor.js, browser.js, state.js, ...
│   ├── src/sellfox/           ← 服务器上下架（纯 Node fetch）
│   │   ├── diff.js / diff.selftest.js / monitor.js / client.js / cli.js
│   ├── deploy/                ← pack-sellfox / install / systemd
│   ├── SELLFOX.md / PLUGIN_PARITY.md / OPENAPI.md
│   └── config.example.json / sellfox.config.example.json
├── temu-plugin-v*.zip         ← 历史分发包（勿当最新源）
└── _dist/                     ← 打包产物（gitignore）
```

**Git 注意**：大量插件/赛狐迭代在工作区未全部进 commit；以**目录现状 + 本 ROADMAP + 插件文件头注释**为准，不要只看 `git log`（目前仅 initial + v10–v13 相关提交）。

---

## 2. 架构三次转向（总览）

```
立项 2026-07-10
  │  需求：在售下降 + 流量异常 → 飞书
  ▼
① Playwright 本机守护（7/10–7/14）
  │  踩：代理 / 风控 / 登录态 / DOM
  │  破：系统 Chrome + .userdata 真登录 + countStatus
  ▼
② Chrome 插件为主（7/14 起）
  │  原因：同事各自登录态；免副本目录与 anti-content
  │  演进：单店→多店→点名→防误报漏报→前台/SKU→限流分级
  ▼
③ 双通道拆分（7/30–7/31）
  │  流量→插件；上下架→服务器赛狐（固定 IP 白名单）
  │  Playwright 流量退役日常；v14 DELIST_IN_PLUGIN=false
  ▼
④ 插件再接管后台上下架兜底（8/06 v19.x）
     原因：赛狐同步滞后实锤；切店串店/count 毛刺
     A+B + 防抖 + mallId 绑店；赛狐保留
```

---

## 3. 阶段详述

### 阶段 0 · 立项（约 2026-07-10）

**业务原因**

- 半托管多店需要自动盯：在售是否掉、是否出现「商品流量待关注 / 近期有下降」。
- 异常推飞书；人工刷后台不可持续。
- 需求文档极简（约 3 句 + 截图）。补充：登录成功后 / 切店时**所有弹窗都关**——只能点右上角 X，不能误点「去处理」类跳转。

**技术选型**

- `temu-monitor/`：Node + Playwright + 飞书 webhook。
- 真实后台：`https://agentseller.temu.com/goods/list`（账号里 EU 订单 URL 会跳到这里）。
- 决策：账号下店铺、15 分钟轮询、飞书告警。

**关键非显然点（仍有效）**

- 首次登录可能要短信验证码 → 无法全自动首登，需人工 `npm run login` 一次。
- 店铺切换器、列表字段、部分选择器需真实登录态校准。

---

### 阶段 1 · Playwright 攻坚（2026-07-10）

#### 1.1 网络与导航

| 现象 | 代码层根因 | 修法 | 相关 |
|------|-----------|------|------|
| 频繁 `net::ERR_CONNECTION_CLOSED` | 走 Clash `127.0.0.1:7897` 有害；直连稳 | `proxy:""`；空串=强制直连，不回落系统 `HTTPS_PROXY` | `config.js` |
| `waitUntil:'domcontentloaded'` 超时 | 重型 SPA 网络长期不空闲 | `commit` + 显式 `waitForGoodsList`；单次 goto | `browser.js` |
| 有头 `frame detached` | 网关重置阵发 + 有头不稳 | 诊断默认 headless；弃双 goto/预热 root | calibrate |

#### 1.2 自动化检测与登录态

| 现象 | 代码层根因 | 修法 |
|------|-----------|------|
| 网格永远「加载中」，列表 API 不触发 | 内置 Chromium 风控 + 未真登录 | `channel:'chrome'` 系统 Chrome；`ignoreDefaultArgs:['--enable-automation']` |
| Chrome 136+ 拒默认 User Data | CDP 禁止默认目录 | 非默认副本 `./.userdata` |
| 复制 profile 仍跳 `/auth` | App-Bound Encryption，cookie 密钥绑原目录 | 必须在副本内 `npm run login`；「复制免登录」不可行 |
| 复制 profile 全站失败 | 真实 Chrome 读 profile/系统代理 | **不设** Playwright `proxy` 选项；用 `--no-proxy-server` + `--proxy-bypass-list=*`。⚠️ 曾用 `proxy:{server:'direct://'}` 在有系统代理的机器上变成假代理 → `ERR_PROXY_CONNECTION_FAILED` |

**有效链路配方（应急 Playwright 勿回退）**

`channel:'chrome'` + 非默认 `.userdata` + 强制直连命令行 + 去 automation 默认参数 + 副本内有效登录态。

#### 1.3 DOM / 需求理解纠偏

真人浏览器截图后推翻原假设：

| 原假设 | 真相 | 代码影响 |
|--------|------|----------|
| 在售数依赖商品网格 | 「在售中 N」在顶部 tab，与网格加载无关 | 后改读 `countStatus` |
| 店铺=右上角切换器 | 早期单店「全球」聚合；多店是头像→「切换店铺」 | 旧 `stores.js` 选择器作废 |
| 流量=逐行抠橙标 | 待关注=快速筛选 **chip**；下降=行内红徽标 | chip 计数 + 徽标计数 |
| UI 通用 antd | Temu 自研 **beast-core** | 优先 `[data-testid="beast-core-…"]` |

**流量 chip 必坑（Playwright 与插件同源）**

点 chip 后必须等底部「共有 N 条」**数值变化**再读；并校验 `after < before` 才采纳。否则会读到刷新前总数（曾误读 408=全部商品）。

#### 1.4 端到端与 Windows 常驻

- `scanStore` 返回：`onSaleCount` / `trafficWatchCount` / `trafficDeclineExists` 等；`state.js` diff 幂等。
- 计划任务 `TemuMonitor` → `run-forever.ps1` → `node src/cli.js start`。
- **交付踩坑**：`.bat`/`.ps1` 全 ASCII（UTF-8 无 BOM 中文在 cmd/PS5.1 会当命令）；node 日志用 `Start-Process -RedirectStandard*`；杀进程匹配须排除自身 PID；`Stop-ScheduledTask` 不杀已 spawn 的守护。

#### 1.5 API 抓包（7/14）——可靠性分水岭

| 接口 | 用途 |
|------|------|
| `POST visage-agent-seller/product/skc/countStatus` | 在售 = `skcTopStatus:100` → `skcTotal`；另有 0 未发布 / 200 下架 / 300 删除 |
| `POST …/product/skc/pageQuery` | `total` + `pageItems[]`；含 `productSkuSummaries`（v13 用） |

**流量字段结论（定型，勿再走回头路）**

`pageQuery` 项上 `flowLimitStatus` / `flowAllowanceStatus` 等对「待关注」与普通商品**无区分**（同为 null/1）。  
「流量待关注」是**服务端按筛选条件算的**，不在商品字段里 → **读 chip DOM**，不要再试图用字段过滤。

**anti-content**

成功请求来自已加载登录页（cookie + 页面 JS 现算签名）。裸 headless HTTP 大概率被拦。  
推荐：**启页 + 拦截页面自身响应**（或 `page.evaluate(fetch)`）。不推荐为运营指标去申请官方开放平台 ISV。

Playwright 已实施：`waitForResponse(/countStatus/)` 读在售；流量 chip 仍 DOM。

#### 1.6 Playwright 假告警与登录静默死（7/14）

| 业务现象 | 代码 bug | 修法 |
|----------|----------|------|
| 飞书「内容全一样」反复刷 | chip 失败 → `trafficWatchCount=null`，`?? 0` 当 0，下轮 0→3 | diff 仅 number 比 number；`carry()` 不让 null 冲基准；筛选重试 |
| 登录过期连续多天无告警 | 进程健康，错误只进 err.log | `loginFailStreak`；连续未登录告警 + 周期再提醒 |

---

### 阶段 2 · 转向 Chrome 插件（2026-07-14）

#### 2.1 业务原因

部署目标变为：**装到每个同事自己电脑，监测各自店铺**。

| Playwright 痛点 | 插件优势 |
|-----------------|----------|
| `.userdata` 副本、App-Bound、登录过期静默 | 直接用日常登录态 |
| anti-content / 风控 | 页面自己发请求，hook 即可 |
| 单机守护分发重 | 开发者模式加载已解压即可 |
| 飞书要统一配 | options 各填各群 webhook |

**代价（可接受）**：需 Chrome 开着且留 `goods/list`；空闲轮巡会**会话级切店**（打断操作）→ 仅 idle 时切。

此后 Playwright 计划任务注销下线；代码保留应急。

#### 2.2 架构（MV3，沿用至今）

```
inject.js (MAIN world)  hook window.fetch + XHR
    → postMessage
content.js (isolated)   读 chip/DOM/店名；附 mallId；scan* 命令
    → chrome.runtime.sendMessage
background.js (SW)      parse → stores[name].{latest,snapshot} → diff → 飞书
popup / options          展示、webhook、必提醒、多维表凭证
chrome.alarms / idle     15min 刷新、必提醒、空闲轮巡
```

分发：推荐 zip「加载已解压」。外部 `.crx` 常被新版 Chrome 拒。  
打包：`打包crx.ps1`；**`.pem` 必须在插件目录外**（`E:\project\temu\temu-plugin.pem`），否则打进包泄露私钥。

#### 2.3 多店模型

- 实测店：HomeCove / Twilight Cove / Agnis（半托管）。
- 切店：右上角头像 →「切换」→ 弹窗选店；**不改 URL，全局会话级**。
- mallId 早期读不到（疑在签名里）→ 曾用顶栏英文店名；**v19.3 起 inject 转发 mallId，background 建 mallId→店名映射**。
- 用户决策：**空闲才自动轮巡**（`chrome.idle`，约 240s）。

切店 UI 自动化要点（选择器漂时对照）：

1. 触发下拉用完整指针序列 `pointerdown→mousedown→mouseup→click`（`realClick`），单纯 `.click()` 常无效。
2. 下拉「切换」：可见、精确文本、取靠后的一个。
3. `listStores` 易混入 SKC/颜色等整页英文 → 轮巡优先用 storage 已知店名。
4. 轮完必须切回原店。

#### 2.4 插件早期能力递进（v0.1 → v4）

| 标签 | 业务目标 | 代码层问题 | 修法 |
|------|----------|------------|------|
| MVP | 在售下降 + 待关注增加 | pageQuery 一页 20 条不能当流量全量 | 待关注走 chip DOM |
| 店名 | 告警带店 | 「全球」无当前店；mallId 不可读 | 手填 → 顶栏英文；过滤 `/^[A-Z0-9]+$/` 货号假店 |
| 多店 v0.2–0.3 | 一人多店 | 切店打断用户 | idle 轮巡；按 `stores{}` 分快照 |
| 下降监测 | 对称待关注 | 「文本存在」三店全误报；无 chip 漏报 | `countDeclineBadges` 可见最内层；等 gridReady |
| 限流明细 v2 | 点名 + 编辑链接 | 编辑是弹窗无 URL；**SW 重载不彻底**丢 watchItems | 深链 `goods/edit?productId=`（SPU ID=productId）；**关开开关**；popup 显 `bgVersion` |
| 下架点名 v3 | 集合 diff 带链接 | 只报数字不够运营 | `scanOnSaleList` + `onSaleIds`；空/残缺/首轮护栏；曾移除数字下降改只走 diffOnSale（为 v6 漏报埋线） |
| 限流点名 v4 | 0→N 无链接 | 被动扫只覆盖当前页 | 增加时 `scanWatchList` 点 chip 全取；按店 `alertChains` 防双发 |

**编辑链接（唯一稳定深链）**

`https://agentseller.temu.com/goods/edit?from=productList&productId=<productId>`  
DOM「SPU ID」= productId；「SKC ID」= productSkcId。

**chip 真实 DOM（防误读价格）**

容器 `[class*="use-quick-field_tsx_card__"]` + 计数 `[class*="countDistance"]`；不要全页捞最短文本（价格 TD 内嵌行徽标会污染）。

---

### 阶段 3 · 稳定性深水区（v5–v13，7/17–7/23）

#### v5 · 修下架误报（7/17）

**业务**：飞书「Twilight 下架 10（13→3）」，实际未下架。

**根因链**

1. `cycleStores` 的 `scanOnSaleList` 与待关注触发的 `scanWatchList` **同页并发**（cycle 未 await diff）。
2. 待关注 chip 独立于 tab，点「在售」清不掉筛选。
3. 扫到筛选后 3 条；countStatus 也被刷成 3。
4. 护栏 `items.length < known` → `3<3` 失效 → 与基准 13 diff → 假下架 10。

**修法**

1. content `withLock`（promise 链）串行化 `scanWatchList` / `scanOnSaleList` / `switchTo` / `listStores`。
2. `scanOnSaleList` 先复位（全部 tab + 重置）再扫，回传干净 `onSaleTabCount`。
3. `scanWatchList` 复位更彻底（toggle 关 chip + 重置 + 等「共有 N」回升）。
4. `diffOnSale` 护栏改用干净 tab 数。

假告警污染的 `onSaleIds` 会在下轮干净扫后自愈（prev⊆new → delisted=0）。

#### v6 · 下架漏报（7/17）

**业务**：真下架白天刷页时不报。

**双根因**

1. v3 把 inSale 数字下降从 `_diffAndAlert` 挪走「改由 diffOnSale」，但 diffOnSale **仅空闲轮巡** → 漏报。
2. `diffOnSale` 用旧 stores 写回，覆盖中间已更新的 snapshot → **基准腐败**。

**修法**：恢复数字下降告警；写前重读 stores。单测多场景（历史 22/22）。

#### v7 · 定时必提醒（7/20）

**业务**：无异常也要证明插件存活。  
**实现**：默认 09:30 / 16:30；`mustRemindEnabled` / `mustRemindTimes`；`chrome.alarms` 一次性 `when` 发完重排；蓝卡列各店指标。

#### v8 · 下架扫描防污染（7/22）

点在售 tab 后等 `gridTotal === tabCount` 才扫；扫到行数 > tabCount 放弃；tab 点击失败重试。

#### v9 · SKU 规格解析（7/22）

`parseSkuSpecList` 多路径（list/skuSpecList/skuSpecs/data…）；失败也落 raw。

#### v10–v11 · 前台变体（7/22）

`www.temu.com` 商品页变体增减告警；`content-front.js`；v11 `frontPoll` 默认 3h 后台 tab 轮巡。options 配每店前台链接。

#### v12 · 清假店名（7/22）

`readStoreName` 把 Black/Beige/Charcoal 等颜色当店名。  
双重 `isFakeStoreName`；启动 `cleanupFakeStores`；add/cycle/front 过滤。

#### v13 · 后台 SKU 规格（7/23）

**纠偏**：不必死磕编辑页 spec 接口；**`pageQuery` 已带 `productSkuSummaries[]`**（`productSkuId` + `productSkuSpecList`）。  
`diffProductSkus`：仅对「本页再次出现的 productId」做 SKU 集合 diff；首轮只建 `productSkuMap`，防跨页误判。  
单测：`test_sku_parse.js`（hit-068 等抓包）。

---

### 阶段 4 · 通道拆分：插件流量 + 服务器赛狐（7/30–7/31）

#### 4.1 业务原因

1. 上下架需要 7×24，不依赖同事是否开 Chrome。
2. 赛狐已授权三店；**IP 白名单** → 本机宽带 IP 常变不行。
3. 本机第二套 `.userdata` 与日常同账号易**互踢**。
4. 限流/待关注赛狐**无字段** → 必须留插件。

#### 4.2 赛狐模块

| 项 | 值 |
|----|-----|
| 代码 | `temu-monitor/src/sellfox/` |
| 接口 | `POST /api/multiplatform/temu/product/getParentPageList.json` |
| 在售定义 | `selectStatus === "12"`（已加入站点）；常见下架 13 |
| 窗口 | `dateType=updateDate`，≤30 天滑窗 |
| 状态 | `data/sellfox-state.json`（按 shopId） |
| 店 | shopId 396706 Agnis / 398202 HomeCove / 398203 Twilight Cove |
| 服务器 | 腾讯云新加坡 `43.156.50.38` / `qingquan.jmzlai.com`；`/opt/temu-monitor`；用户 `temu`；`systemctl status temu-sellfox` |
| 命令 | `npm run sellfox:probe\|dry\|once\|start` |
| 限流 | 业务码 `40019` 需退避重试 |

**本机隔离**

- `config.fullRun` 默认 **false** → `npm run once/start` 只跑浏览器流量逻辑，不调赛狐。
- 同事电脑不放 `sellfox.config.json`、不开 fullRun。
- 联调全量才 `FULL_RUN=1`。

#### 4.3 赛狐误报与修法（`diff.js`）

| 日期 | 现象 | 根因 | 修法 |
|------|------|------|------|
| 7/30–31 | HomeCove 假下架 5 + 下轮假上架 5 | 偶发漏拉 unique 954→918 | ①全量 unique / 本店 allCount 骤降 → `skipUpdate`；②「下架」须本轮 allMap **仍有该 SKC** 且 status≠12；③失踪 SKC **carry 基准**不告警 |
| 8/05 | 单轮假上架 +4（同事只上 1，后台仍 15） | 同步超前/抖动 | 上架进 `pendingOnshelf`，**连续两轮仍为 12** 才确认告警 |

改 diff 后跑 `diff.selftest.js`，再部署。

#### 4.4 v14 · 仅流量（7/31）

**业务**：防插件与赛狐双报下架；停发 traffic-local 日常包。

**代码（历史）**：`DELIST_IN_PLUGIN=false`，关闭在售下降告警与 cycle 内 scanOnSale/diffOnSale。  
**现状（v19+）**：常量演化为 `ONSALE_MONITOR_IN_PLUGIN` / `ONSALE_QTY_ALERT` / `ONSALE_SCAN_ALERT`（均 true），`DELIST_IN_PLUGIN` 为兼容别名。职责变为「插件后台兜底 + 赛狐服务器」，靠冷却与文案区分，而非再关插件上下架。

`PLUGIN_PARITY.md` 若仍写「插件不报在售」，以 **v19.3 使用说明与 background 文件头** 为准。

---

### 阶段 5 · 限流产品化与切店去重（v15–v18，8/03–8/05）

#### v15 · 在售流量去重（8/03）

| 问题 | 修法 |
|------|------|
| 「待关注」chip **含已下架** | 先切「在售中」再点 chip；被动扫只要 `saleStatus==='onSale'` |
| 切店按可见数 0→1 刷屏 | 按 **productId** 去重 + 6h 冷却（`alertedWatchIds` / `alertedDeclineIds`） |
| 首次安装刷一波 | 首次只 seed 已知 ID，不发飞书 |

#### v16 · 限流分级（8/03）

**业务**：区分严重 vs 一般限流，便于运营优先级。

| 等级 | 规则 |
|------|------|
| 🔴 严重 | SKU 货号 `VIP*`，或（`JM*` ∧ 热销款标签） |
| 🟠 一般 | 有限流信号但不满足严重 |
| ❌ 不报 | 已下架/已终止即使有徽标 |

实现：DOM 抓 skuCodes/hotSale + pageQuery extCode 补全；即时红/橙卡；定点对 `slotTrafficMap` 差异汇总；可选 `feishuApp.js` 写多维表 + 严重建任务。

#### v17 · 切店去重（8/04）

**业务**：「一切换店铺，飞书又把该店已有限流全推一遍」。

**根因**

- `updateStoreLatest` / `_diffAndAlert` / mustRemind 对 `stores` **并发 read-modify-write**。
- 后写覆盖先写 → `snapshot.alertedTrafficIds` **丢失**。
- 空 `{}` / 仅 chip 计数被当成 baselineReady。

**修法**

- 全局 **`withStores`** 串行队列（此后所有 stores 变更必须走它）。
- 基线 = 非空 alerted **或** `trafficBaselineAt`。
- 空 pool 不 seed；chipStats 空明细不覆盖已有清单。
- 单测：`test_traffic_dedupe.js`。

#### v18 · 切店静默吸收（8/05）

**业务**：v17 后切店仍推橙卡。

**根因 2**

1. 切店 loading 时 chip 瞬时 **0** 写入 `snap.trafficWatch`，恢复 0→N 被当新增。
2. 本页首次扫到的 productId 不在 alerted 时，即使 chip 未升高也 `pickFresh` 告警。

**修法**

1. `trafficWatchHigh` **只升不降**；`chipReallyUp = cur > high` 才允许即时飞书。
2. chip 未升高时 fresh ID **静默吸收**进 alerted。
3. 忽略瞬时 0 写 snap。
4. 全局 `trafficAlertedGlobal` productId 冷却兜底。

---

### 阶段 6 · 插件再接管上下架兜底（v19.x，8/06）

#### 业务原因（实锤）

赛狐对平台下架**同步滞后**：例如 Twilight SKC `7636599333` 后台已下架，赛狐仍 `selectStatus=12`。  
→ 不能只信赛狐；插件以 **agentseller 后台** 为实时兜底；服务器赛狐保留作 7×24 与对照。

#### v19 · 上下架 A+B

| 路径 | 数据源 | 行为 |
|------|--------|------|
| **A 数量** | `countStatus` → onSale | 确认后发数量卡；触发当前店防抖扫描 |
| **B 点名** | `scanOnSale` 清单 vs `onSaleIds` | 下架立即点名+编辑链接；上架 `pendingOnshelf` 两轮确认；`tabCount===0` 允许真清零 |

共用：productId **6h** 冷却（降与赛狐双报）；数量变化后若仍在该店 **6s** 防抖再扫 B；卡片「插件·后台」。

#### v19.1 · 定点列链接

必提醒不能只报数量。`sendMustRemind` 始终列出当前限流池 + 编辑链接；解除项也带链接。

#### v19.2 · 数量防抖

**业务**：HomeCove 切店/loading **15→4→15**（约 1s）连发下降+上升数量卡。

**修法（`diffOnSaleCount` + `pendingQty`）**

| 常量（background 顶部） | 含义 |
|-------------------------|------|
| `ONSALE_QTY_CONFIRM_HITS = 2` | 同一候选连续命中次数 |
| `ONSALE_QTY_CONFIRM_GAP_MS = 3000` | 首次见到→确认最小间隔 |
| `ONSALE_QTY_PENDING_TTL_MS = 60000` | pending 超时丢弃 |
| 回弹到原基准 | 取消 pending，不发卡 |

单测：`test_onsale_ab.js`（15→4→15 / 真实下降 / retarget / TTL）。

#### v19.3 · mallId 绑店（**当前**）

**业务**：切店串店——A 店 count 记到 B 店（如 Agnis 12→0→12）。

**根因**：inject 响应里**已有 mallId**，content 未转发；DOM 顶栏店名切店后滞后，background 用错店名写 snapshot。

**修法**

1. content 上报 `capture` 时带 `mallId`；`rememberMallId` / `resolveStore(msgStore, mallId)` **优先 mallId 映射**。
2. **轮巡切店期间静默数量卡**（只同步基准 + 跑 B 清单），避免切店中 A 风暴。
3. **归零不走 A 发卡**（真清零靠 B）；大幅下降（≥50% 或 ≥3）加严：`BIG_DROP_HITS=3`、`GAP=12s`。
4. 同店同 from→to 数量卡 **30min** 内不重复（`ONSALE_QTY_COOLDOWN_MS`）。

popup：`bgVersion: 'v19.3-mallId绑店'`。分发包：`temu-plugin-v19.3-mallId绑店.zip`。

---

## 4. 跨版本「元 bug」模式（改功能时对照）

| 模式 | 典型版本 | 症状 | 通用修法 |
|------|----------|------|----------|
| 视图/筛选污染 | v5, v8, v15 | 假下架、限流含已下架 | 扫前复位；干净 tab 数护栏；先在售再 chip |
| 并发写 storage | v6, v17 | 基准腐败、切店重复推 | 写前重读；**唯一** `withStores` 队列 |
| 瞬时毛刺当真相 | v18, v19.2 | 0→N、15→4→15 | 高水位、pending 连续确认、忽略 0 |
| 身份绑错主体 | v12, v19.3 | 假店名、串店 count | 黑名单；**mallId 优先于 DOM 店名** |
| 基准未建立就告警 | v3, v15, v19 | 首装刷屏 | 首轮只 seed；baseline 标志 |
| 通道双报 | v14, v19 | 同事件两张卡 | 职责拆分 + 6h 冷却 + 文案来源 |
| 能力搬迁导致漏报 | v3→v6 | 真下架不报 | 搬迁时确认**所有触发路径**仍覆盖 |
| MV3 SW 假更新 | v2 起贯穿 | popup 旧版、逻辑不生效 | **关开开关**；用 bgVersion 目检 |
| 接口/选择器漂移 | 全程 | 扫空、解析失败 | testid；多 JSON 路径；抓包回归 |
| 赛狐漏拉 | sellfox | 假下架+假上架 | skipUpdate + 失踪 carry + 上架两轮 |

---

## 5. 关键数据与状态字段（维护索引）

### 5.1 插件 `chrome.storage.local`（概念）

```
config          webhook, interval, mustRemind*, front*, feishuApp*
stores[name]
  latest        onSale, trafficWatch, items, ts, ...
  snapshot      onSale, onSaleIds, alertedTrafficIds, alertedWatchIds,
                trafficWatchHigh, trafficBaselineAt, pendingQty,
                pendingOnshelf, productSkuMap, ...
mallIdMap       mallId → storeName
trafficAlertedGlobal   跨店 productId 冷却
```

**改 snapshot 字段必须**：在 `withStores` 内读最新 → 合并 → 写回；并考虑旧版本 storage 兼容（缺字段当默认）。

### 5.2 赛狐 `data/sellfox-state.json`

```
shops[shopId].onSaleMap / allCount / pendingOnshelf / statusCounts / ts
```

删文件 = 重置基准（下轮只建不告警）。

### 5.3 在售 countStatus 语义

| skcTopStatus | 含义 |
|--------------|------|
| 100 | 在售中 |
| 0 | 未发布 |
| 200 | 已下架 |
| 300 | 已删除 |

### 5.4 飞书

- Webhook 绑群；换群必须换 webhook。
- 多群：历史 Playwright 支持 `feishuWebhooks[]`；插件主路径为 options 单 webhook（以代码为准）。
- 卡片颜色惯例：下架红 / 上架绿 / 混合或限流橙 / 必提醒蓝 / 登录问题橙。

---

## 6. 测试与回归清单

### 6.1 插件本地单测（无浏览器）

```bash
cd temu-plugin
node test_traffic_dedupe.js
node test_onsale_ab.js
node test_sku_parse.js
node --check background.js content.js popup.js options.js inject.js
```

### 6.2 插件真机冒烟

1. 关开扩展开关 → popup `后台：v19.3-mallId绑店`。
2. 开 `goods/list`，控制台 content 加载标记含 v19.3。
3. 测试飞书。
4. 手动切店：不应刷已有限流；数量卡不应 1s 内来回打。
5. 「轮巡所有店」：每店建/更新基准；轮巡中数量卡静默。
6. 必提醒：options 可 `mustRemindNow` 或等到点；应带限流链接。

### 6.3 赛狐

```bash
cd temu-monitor
node src/sellfox/diff.selftest.js
npm run sellfox:probe
npm run sellfox:dry
# 服务器
sudo -u temu node /opt/temu-monitor/src/sellfox/cli.js probe
journalctl -u temu-sellfox -f
```

### 6.4 Playwright 应急

仅维护者：`npm run login` → `npm run once`；`fullRun:false`；**关掉插件或换 webhook** 防双报。

---

## 7. 运维速查

### 7.1 插件发版

1. 改 `background.js` 文件头注释 + `getStatus.bgVersion` 字符串。
2. 同步 `content.js` 加载日志版本、`使用说明.txt`、必要时 `manifest.json` version/description。
3. 跑单测。
4. 打 zip（或 `打包crx.ps1`，注意 pem 位置；脚本末尾 `Read-Host` 勿非交互硬跑）。
5. 同事：覆盖目录 → **关开开关** → 看 popup 版本串。

### 7.2 赛狐服务器发版

```powershell
cd E:\project\temu\temu-monitor
powershell -File deploy\pack-sellfox.ps1
# scp zip；密钥一般不动
```

```bash
# 服务器解压安装见 deploy/README-SERVER.md
sudo systemctl restart temu-sellfox
sudo systemctl status temu-sellfox
```

SSH 密钥与别名见维护记忆 / 内网文档（勿写入公开仓库明文策略以外的秘密）。

### 7.3 常见故障

| 现象 | 先查 |
|------|------|
| popup 无新字段/仍双报旧逻辑 | 是否关开开关；bgVersion |
| 切店刷限流 | v17/v18 逻辑是否被改坏；withStores；trafficWatchHigh |
| 数量卡来回打 | pendingQty；mallId 是否转发；是否在 cycle 中未静默 |
| 串店 | mallIdMap；resolveStore 优先顺序 |
| 赛狐假下架一批 | 日志 unique/allCount 是否骤降；diff skip |
| 赛狐落后插件 | 预期内；看插件「插件·后台」卡 |
| 飞书 code 非 0 | webhook 是否换群/过期 |
| Playwright 未登录 | `.userdata` 内 re-login；DPAPI 需交互用户会话 |

---

## 8. 时间线速查表

| 日期 | 里程碑 |
|------|--------|
| 2026-07-10 | 立项；Playwright 代理/风控/登录破局；E2E；开机自启；一键包 |
| 2026-07-14 | countStatus 抓包；**转插件**；多店 idle 轮巡；PW 假告警/登录过期修复；守护下线 |
| 2026-07-16 | 限流/下架点名 v2–v4；打包交付 |
| 2026-07-17 | v5 下架误报锁；v6 下架漏报 |
| 2026-07-20 | v7 定时必提醒 |
| 2026-07-22 | v8–v12 扫描防污染、SKU 解析、前台变体、假店名 |
| 2026-07-23 | v13 pageQuery SKU diff |
| 2026-07-30 | 赛狐服务器上线（固定 IP） |
| 2026-07-31 | 赛狐漏拉护栏；v14 仅流量；PW 日常退役 |
| 2026-08-03 | v15 在售流量去重；v16 限流分级 |
| 2026-08-04 | v17 切店 withStores 去重 |
| 2026-08-05 | v18 静默吸收；赛狐上架两轮确认 |
| 2026-08-06 | v19 A+B；v19.1 定点链接；v19.2 数量防抖；**v19.3 mallId 绑店（当前）** |

---

## 9. 决策记录（ADR 摘要）

| 决策 | 选择 | 原因 | 不要做的事 |
|------|------|------|------------|
| 流量数据源 | chip DOM + 行内徽标 | API 字段无待关注语义 | 用 flowLimitStatus 区分待关注 |
| 列表可靠性 | 页面内请求/拦截 | anti-content | 裸 cookie HTTP 调卖家接口当生产 |
| 日常载体 | Chrome 插件 | 登录态与分发 | 强迫同事本机常驻 Playwright |
| 上下架 7×24 | 赛狐服务器 | 白名单+无浏览器 | 把 sellfox 密钥发给所有同事 |
| 上下架实时性 | 插件 A+B 兜底 | 赛狐滞后实锤 | 关掉插件上下架只信赛狐 |
| 切店轮巡 | 仅 idle | 会话级切店打断操作 | 前台工作时强制轮巡 |
| 限流去重键 | productId | 切店/chip 抖动 | 只用「本页可见条数」触发 |
| 店名归属 | mallId 优先 | DOM 滞后串店 | 只信顶栏文本 |
| 数量告警 | pending 连续确认 | loading 毛刺 | 单次 countStatus 直接发卡 |
| 升级方式 | 关开开关 | MV3 SW 生命周期 | 以为 ↻ 等于更新 background |

---

## 10. 相关文档索引

| 文档 | 内容 |
|------|------|
| `README.md` | 仓库入口、安全 gitignore 说明 |
| `SLO.md` | 告警 SLO、P0/P1、双通道策略 A、投诉分级 |
| `temu-plugin/使用说明.txt` | 同事向：安装、分级规则、A+B 行为 |
| `temu-plugin/check.ps1` | 发版闸门（syntax + 单测） |
| `temu-plugin/test_timelines.js` | P0 时间线（毛刺/chip0/mallId/轮巡静默） |
| `temu-monitor/PLUGIN_PARITY.md` | 通道分工（2026-08-06 已对齐 v19.3） |
| `temu-monitor/SELLFOX.md` | 赛狐能力、配置、命令 |
| `temu-monitor/deploy/README-SERVER.md` | Linux 部署逐步 |
| `temu-monitor/OPENAPI.md` | 开放平台相关笔记（非主路径） |
| `temu-plugin/background.js` 文件头 | **权威版本演进注释** |

---

## 11. 维护者变更本文件时

1. 新版本：更新 §0 当前版本串、§3 新小节、§8 时间线、§9 若有新 ADR。  
2. 同步 `background.js` 头注释与 `使用说明.txt`，避免三处版本不一致。  
3. 若主路径通道再变（例如再次关闭插件上下架），先改 §0.2 表再改代码开关常量。
