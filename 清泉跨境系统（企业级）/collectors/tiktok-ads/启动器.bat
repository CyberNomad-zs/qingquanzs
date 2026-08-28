@echo off
chcp 65001 >nul
rem Console menu launcher (no GUI dependency).
cd /d "%~dp0"
title TK整站采集启动器

:menu
cls
echo ============================================================
echo   TK 整站采集 · 控制台启动器
echo   %CD%
echo ============================================================
echo.
echo   ---- 广告日报 (17:20) ----
echo   [1] 预览广告店铺列表   (ListOnly)
echo   [2] 立即跑广告日报     (同 17:20 任务)
echo   [3] 安装广告 17:20 任务
echo.
echo   ---- 早上整站 08:10 · 立即跑 (需紫鸟) ----
echo   [A] 店 KPI/健康/财务
echo   [B] 订单
echo   [C] 商品
echo   [D] 内容+商品卡
echo   [E] 联盟达人
echo   [H] 事件型补采(循环 全天常驻)
echo.
echo   ---- 安装计划任务 ----
echo   [N] 安装早上整站 08:10 (串行5段)
echo.
echo   ---- 其它 ----
echo   [L] 打开日志目录
echo   [O] 打开配置目录
echo   [R] 打开日报目录
echo   [V] 环境自检
echo   [G] 打开图形启动器 (gui.py)
echo   [0] 退出
echo.
set /p choice=请选择:

if "%choice%"=="1" goto ads_list
if "%choice%"=="2" goto ads_daily
if "%choice%"=="3" goto ads_install
if /I "%choice%"=="A" goto shop
if /I "%choice%"=="B" goto orders
if /I "%choice%"=="C" goto products
if /I "%choice%"=="D" goto content
if /I "%choice%"=="E" goto affiliate
if /I "%choice%"=="H" goto daytime
if /I "%choice%"=="N" goto night_install
if /I "%choice%"=="L" goto logs
if /I "%choice%"=="O" goto config
if /I "%choice%"=="R" goto reports
if /I "%choice%"=="V" goto doctor
if /I "%choice%"=="G" goto gui
if "%choice%"=="0" exit /b 0
echo 无效选择
timeout /t 2 >nul
goto menu

:ads_list
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-multi-store.ps1" -ListOnly
goto pause

:ads_daily
echo 执行广告日报（写飞书）。
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-daily-report.ps1"
goto pause

:ads_install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-daily-task.ps1" -Time "17:20"
goto pause

:shop
echo 立即跑店模块 → Ingest
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-shop-modules-daily.ps1"
goto pause

:orders
echo 立即跑订单 → Ingest
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-orders-daily.ps1"
goto pause

:products
echo 立即跑商品 → Ingest
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-products-daily.ps1"
goto pause

:content
echo 立即跑内容+商品卡（强制入库）
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-content-daily.ps1"
goto pause

:affiliate
echo 立即跑联盟达人（强制入库，含 Pop）
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-affiliate-daily.ps1"
goto pause

:night_install
echo 安装早上整站 08:10（串行5段：shop->orders->products->content->affiliate）
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-shop-modules-daily-task.ps1" -Time "08:10"
goto pause

:daytime
echo 事件型补采循环：每30分钟跑违规/差评/达人健康，全天常驻避开 08:00~11:30 + 17:00~21:30
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-shop-modules-daytime-loop.ps1" -IntervalSec 1800
goto pause

:logs
if not exist "%~dp0logs" mkdir "%~dp0logs"
explorer "%~dp0logs"
goto menu

:config
explorer "%~dp0config"
goto menu

:reports
if not exist "%~dp0日报" mkdir "%~dp0日报"
explorer "%~dp0日报"
goto menu

:doctor
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-deps.ps1" -DoctorOnly
goto pause

:gui
call "%~dp0美化启动器.bat"
goto menu

:pause
echo.
echo ---------- 结束 ----------
pause
goto menu
