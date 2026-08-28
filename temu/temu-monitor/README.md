# Temu 多店铺监测（temu-monitor）

本目录两件事：

1. **服务器赛狐上下架**（生产）— `src/sellfox/` + `deploy/`
2. **Playwright 浏览器流量**（维护者应急 only）— 勿发同事日常

同事日常主路径是仓库根目录 **`temu-plugin/`（v22.3）**，不是本目录的 `npm start`。

## 主路径（2026-08-28 · 对齐 v22.3）

| 在哪跑 | 跑什么 | 怎么用 |
|--------|--------|--------|
| **同事日常 Chrome** | 限流分级 + 在售 A+B 上下架兜底 + 必提醒 + 报错/风控转发 | 装 `../temu-plugin/`，popup 显示 **`后台：v22.3-库存归零+B路径假上架静默恢复`** |
| **固定 IP 服务器** | 赛狐下架 / 上架点名 | systemd `temu-sellfox` |
| **本机 Playwright** | 仅维护者应急流量 | `npm run once`；**勿与插件同飞书双开** |

- 同事**不要**再依赖 `temu-traffic-local` zip / 本机 `npm start` 常驻。  
- 上下架**不要**在同事机开 `fullRun`、**不要**本机跑 sellfox（无白名单）。  
- 插件与赛狐上下架**双通道都报**（策略 A：文案区分，接受偶尔两张）。详见 `PLUGIN_PARITY.md`、`../SLO.md`。

详表：`PLUGIN_PARITY.md` · 赛狐：`SELLFOX.md` · 部署：`deploy/README-SERVER.md` · 演进：`../ROADMAP.md` · 同事说明：`../temu-plugin/使用说明.txt`。

## 插件（日常 · 在仓库根 `temu-plugin/`）

1. Chrome → 开发者模式 → 加载已解压 `temu-plugin/`  
2. 设置填飞书 Webhook  
3. 打开并保留 `https://agentseller.temu.com/goods/list`  
4. 升级后 **关开扩展开关**；popup 显示 `后台：v19.3-mallId绑店`  
5. **关掉**本机 Node 流量常驻 / 旧开机自启，避免与插件流量双报  

发版前闸门：

```powershell
cd ..\temu-plugin
powershell -NoProfile -File .\check.ps1
```

## 服务器 · 赛狐上下架

见 **`deploy/README-SERVER.md`**。本机打包：`deploy\pack-sellfox.ps1`。

```bash
npm run sellfox:probe
npm run sellfox:dry
npm run sellfox:once
npm run sellfox:start   # 服务器上用 systemd，勿在同事笔记本当生产
```

## 本机 Playwright（应急 only）

```bash
cd temu-monitor
npm install
# config.json → fullRun: false
npm run login
npm run once    # 不要与插件同时作为生产、不要共用生产群 webhook
```

`deploy\pack-traffic-local.ps1`（若有）：**维护者应急打包**，默认不要发给同事当日常方案。

## 目录

```
temu-plugin/           同事日常 · 限流 + 在售 A+B（仓库根）
temu-monitor/
  src/sellfox/         服务器 · 上下架
  src/run.js ...       浏览器流量（应急）
  deploy/              Linux 部署 + 打包
  PLUGIN_PARITY.md     通道分工（本文件的细则）
  SELLFOX.md
```

## 命令速查

| 命令 | 说明 |
|------|------|
| （插件）轮巡 / 测试飞书 / `check.ps1` | 日常限流 + 后台上下架 |
| `npm run sellfox:once` / `start` | 服务器上下架 |
| `npm run login` / `once` | 本机应急流量 |
