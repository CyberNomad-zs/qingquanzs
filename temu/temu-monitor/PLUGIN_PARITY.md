# 能力分工（2026-08-28 · 对齐插件 v22.3）

> 历史：2026-07-31 曾定为「插件仅流量 + 服务器仅上下架」。  
> 2026-08-06 起：赛狐对平台下架存在同步滞后 → **插件恢复 agentseller 后台 A+B 上下架兜底**；赛狐仍 7×24 常驻。  
> 权威行为以 `temu-plugin/background.js` 文件头与 `使用说明.txt` 为准；本文件若冲突，以代码为准。

## 三通道

| 通道 | 职责 | 版本 / 单元 |
|------|------|-------------|
| **Chrome 插件 `temu-plugin`** | 限流分级 + 切店去重/静默吸收 + **在售 A+B 上下架** + 09:30/16:30 必提醒 + 空闲多店轮巡 + 报错转发飞书 + 前台变体/风控 + 库存归零 | **v22.3-库存归零+B路径假上架静默恢复** · manifest `0.2.17` |
| **服务器 `temu-sellfox`** | 赛狐 `selectStatus=12` 上下架点名（可滞后于后台） | systemd · 固定出口 IP |
| **本机 Playwright `temu-monitor`** | 维护者应急流量 / DOM 回归 | **停发日常**；勿与插件同飞书双开 |

## 能力对照

| 能力 | 谁做 | 备注 |
|------|------|------|
| 限流 / 待关注 / 近期下降 + 点名 | **仅插件** | 赛狐无流量字段 |
| 限流分级 VIP / JM+热销 | **插件** | 已下架不报；productId 6h 冷却 |
| 切店不重推已有限流 | **插件** | 高水位 + 静默吸收 + `withStores` |
| 在售数量变化飞书 | **插件 A**（防抖确认后） | 归零不走 A；大幅下降加严；轮巡中静默数量卡 |
| 下架 / 上架点名 + 编辑链接 | **插件 B** + **服务器赛狐** | 见下方双通道策略 **A** |
| 在售数字 popup 展示 | 插件 | 展示与告警分离 |
| 必提醒 09:30 / 16:30 | 插件 | 列当前限流池 + 链接 |
| 7×24 不依赖同事 Chrome | **仅赛狐** | 固定 IP 白名单 |

## 双通道策略（已采纳 · A）

**插件与赛狐都报上下架；文案区分；接受偶尔两张卡。**

| | 插件 · 后台 | 服务器 · 赛狐 |
|--|-------------|---------------|
| 数据源 | agentseller `countStatus` + 在售清单 | `getParentPageList` · `selectStatus=12` |
| 实时性 | 近实时（当前店）；它店靠空闲轮巡 | 约 15 分钟一轮，同步可能更慢 |
| 卡片识别 | 文案含 **「插件·后台」** | 无此标注（或走赛狐模块标题） |
| 降噪 | 同 productId **6h** 冷却；数量同 from→to **30min** | 漏拉 skip、上架两轮确认 |
| 仲裁 | **业务以 Temu 后台为准**（赛狐滞后时信插件） | 备份与 Chrome 关闭时的兜底 |

**不做（当前）**：服务器读取插件冷却表去重、或关掉任一通道。  
若双报不可接受，另开需求再做共享降噪（策略 B），不在 v19.3 范围。

## 插件 A+B 摘要

| 路径 | 行为 |
|------|------|
| **A 数量** | `countStatus`；**mallId 绑店**（优先于 DOM 店名）；同一新值 ≥2 次且间隔 ≥3s 才发卡；大幅下降（≥50% 或 ≥3）3 次 + 12s；**归零不发卡**（真清零靠 B）；轮巡切店中静默数量卡 |
| **B 点名** | 扫在售清单；下架立即点名；上架 `pendingOnshelf` 连续两轮确认；`tabCount===0` 允许真清零 |

## 命令（维护者）

```bash
# 插件闸门（Windows）
cd temu-plugin
powershell -NoProfile -File .\check.ps1

# 服务器赛狐
cd temu-monitor
npm run sellfox:probe   # 服务器上亦可用 cli.js probe
npm run sellfox:once
# 生产：systemctl status temu-sellfox

# 本机应急流量（勿与插件同群）
npm run login
npm run once            # config fullRun: false
```

## 配置

| 用途 | 配置 | 发给同事？ |
|------|------|------------|
| 插件飞书 | options 页 webhook | 各人自己的群 |
| 赛狐 | `sellfox.config.json` | **否** |
| Playwright 应急 | `config.json`，`fullRun: false` | **否** |

## 双开禁忌

| 组合 | 结果 |
|------|------|
| 插件 + 服务器赛狐 | **生产标准**；上下架可能双报（策略 A） |
| 插件 + 本机 `npm start` 同 webhook | 流量双报；可能抢登录态 |
| 本机 sellfox + 服务器 sellfox 同凭证狂刷 | 限流 40019；勿 |
| 同事机 `fullRun: true` | 无白名单易失败且双通道混乱 |

## 局限

**插件**

- 需 Chrome 开着且留有 `https://agentseller.temu.com/goods/list`
- 清单/徽标默认约一页 20 条；chip 角标为全量线索
- 空闲轮巡会**会话级切店**（仅 idle）
- 升级须 **关开扩展开关**；popup 应显示 `后台：v19.3-mallId绑店`

**赛狐**

- 与后台 count 不对齐时以后台为准
- 漏拉会 skip 整轮（防假下架）；表现为「这轮没报」而非乱报

## 相关文档

- 总览与历史：`../ROADMAP.md`
- 告警 SLO：`../SLO.md`
- 赛狐：`SELLFOX.md` · `deploy/README-SERVER.md`
- 同事向：`../temu-plugin/使用说明.txt`
