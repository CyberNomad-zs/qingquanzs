# Temu 店铺监测

多店铺「在售数量下降 / 商品流量异常」监测，异常时推飞书告警。

本仓库包含两套实现：

| 目录 | 说明 | 状态 |
|------|------|------|
| [`temu-plugin/`](temu-plugin/) | **Chrome 扩展（推荐）** — 装在同事日常浏览器里，复用已有登录态 | 当前主力（v22.3 · manifest `0.2.17`） |
| [`temu-monitor/`](temu-monitor/) | 赛狐服务器上下架 + Playwright 应急 | 赛狐生产常驻；Playwright 仅应急 |

**维护者请先读：**

- [技术路线图（详版）](ROADMAP.md) — 架构演进、改版原因、bug 与修法  
- [告警 SLO](SLO.md) — P0/P1、双通道策略 A、何时热修  
- [能力分工](temu-monitor/PLUGIN_PARITY.md) — 插件 v22.3 + 赛狐  

同事装机见 [`temu-plugin/使用说明.txt`](temu-plugin/使用说明.txt)。发版闸门：`temu-plugin/check.ps1`。

## 快速开始（插件）

1. 打开 `chrome://extensions` → 开启「开发者模式」→「加载已解压的扩展程序」→ 选择 `temu-plugin/`
2. 插件图标 → ⚙ 设置 → 填自己飞书群的 Webhook
3. 打开 Temu 后台商品列表 `https://agentseller.temu.com/goods/list`，点「立即检查 / 轮巡所有店」

详见 [`temu-plugin/使用说明.txt`](temu-plugin/使用说明.txt)。

## 服务器赛狐（上下架 7×24）

见 [`temu-monitor/SELLFOX.md`](temu-monitor/SELLFOX.md) 与 [`temu-monitor/deploy/README-SERVER.md`](temu-monitor/deploy/README-SERVER.md)。  
同事本机**不要**放 `sellfox.config.json`、不要开 `fullRun`。

## Playwright（仅维护者应急）

```bash
cd temu-monitor
npm install
copy config.example.json config.json   # Windows；fullRun 保持 false
# 编辑 config.json 填入飞书 webhook（勿与插件同一生产群双开）
npm run login    # 首次人工登录一次（写入 .userdata）
npm run once     # 单轮试跑
```

详见 [`temu-monitor/README.md`](temu-monitor/README.md)。日常流量请用插件，不要 `npm start` 与插件并行生产。

## 安全说明

以下内容**不会**进仓库（见 `.gitignore`）：

- `temu-monitor/config.json`（含真实 webhook）→ 用 `config.example.json` 作模板
- `temu-monitor/.userdata/`（浏览器登录态 / cookie）
- `*.pem`（扩展打包私钥）
- `logs/`、`data/`、`capture/` 运行时与抓包产物
- `node_modules/`、`*.crx`、`*.zip`、`_dist/`

请勿把真实 webhook、登录态或 `.pem` 提交进 Git。
