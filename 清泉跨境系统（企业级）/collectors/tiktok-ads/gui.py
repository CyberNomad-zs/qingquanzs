# -*- coding: utf-8 -*-
"""TK 整站采集 · 图形启动器（广告日报 17:20 + 早上整站 08:10 串行5段 + 规则飞书）"""

from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional
from tkinter import (
    BOTH,
    DISABLED,
    END,
    LEFT,
    NORMAL,
    RIGHT,
    WORD,
    Button,
    Canvas,
    Frame,
    Label,
    Scrollbar,
    Text,
    Tk,
    messagebox,
)

ROOT = Path(__file__).resolve().parent
SCRIPTS = ROOT / "scripts"
LOGS = ROOT / "logs"
REPORTS = ROOT / "日报"
CONFIG = ROOT / "config" / "stores.config.json"
# collectors/tiktok-ads → 仓库根
REPO_ROOT = ROOT.parent.parent
POWERSHELL = "powershell.exe"

# 与 install-*-daily-task / 调度划分计划一致：
#   广告日报 17:20（下午跑，需全天数据，不动）
#   整站+订单+商品+内容+联盟 全部并入 08:10 一个任务串行5段（2026-08-21 从夜间挪早上）
T_AD = "17:20"
T_DAILY = "08:10"      # 整站串行5段：shop→orders→products→content→affiliate
# 旧夜间拆分时间常量已废弃（19:45/20:00/20:20/20:40/20:55），不再使用。
# 规则飞书(原 T_POST 21:00)属中心机功能，数据采集机不需要，已从启动器剔除。


def _ps_file(script: Path, *extra: str) -> list[str]:
    cmd = [
        POWERSHELL,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
    ]
    cmd.extend(extra)
    return cmd


class App(Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("TK 整站采集 · 启动器")
        self.geometry("780x720")
        self.minsize(700, 600)
        self.configure(bg="#0f1419")
        self._proc: Optional[subprocess.Popen] = None
        # 事件型补采 loop 是常驻后台任务，单独占一个进程槽，不挤占 self._proc。
        # 这样起完 loop 后仍可点前台短任务(预览/立即跑等)，停止按钮也分两个：
        # 「停止当前任务」杀 self._proc；「停止补采循环」专门杀 self._loop_proc。
        self._loop_proc: Optional[subprocess.Popen] = None
        self._q: queue.Queue[str] = queue.Queue()
        self._log_path: Optional[Path] = None
        self._build()
        self.after(100, self._drain_queue)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        LOGS.mkdir(parents=True, exist_ok=True)

    def _build(self) -> None:
        header = Frame(self, bg="#1a222c", padx=16, pady=12)
        header.pack(fill="x")
        Label(
            header,
            text="TK 整站采集启动器",
            font=("Microsoft YaHei UI", 16, "bold"),
            fg="#f8fafc",
            bg="#1a222c",
        ).pack(anchor="w")
        Label(
            header,
            text=(
                f"广告 {T_AD}  ·  早上整站 {T_DAILY}(串行5段)  ·  "
                f"紫鸟串行 / PG 入库  ·  按钮区可滚轮下滑"
            ),
            font=("Microsoft YaHei UI", 10),
            fg="#cbd5e1",
            bg="#1a222c",
        ).pack(anchor="w", pady=(4, 0))

        # ---- fixed footer first (pack bottom) so log/status stay visible ----
        foot = Frame(self, bg="#0f1419", padx=16, pady=6)
        foot.pack(side="bottom", fill="x")
        Label(
            foot,
            text=f"{ROOT}  |  repo {REPO_ROOT.name}",
            font=("Segoe UI", 8),
            fg="#64748b",
            bg="#0f1419",
            anchor="w",
        ).pack(side=LEFT)

        # ---- status bar (above footer) ----
        status = Frame(self, bg="#0f1419", padx=16, pady=4)
        status.pack(side="bottom", fill="x")
        self.status_var = Label(
            status,
            text="就绪 · 广告先预览店铺；夜间链请确认紫鸟已登录 · 按钮区可滚轮",
            font=("Microsoft YaHei UI", 10),
            fg="#e2e8f0",
            bg="#0f1419",
            anchor="w",
        )
        self.status_var.pack(side=LEFT, fill="x", expand=True)

        # ---- log panel (bottom half, fixed min height) ----
        log_frame = Frame(self, bg="#1a222c", padx=8, pady=6)
        log_frame.pack(side="bottom", fill=BOTH, expand=False)
        log_frame.configure(height=180)
        log_frame.pack_propagate(False)
        Label(
            log_frame,
            text="运行输出",
            font=("Microsoft YaHei UI", 10, "bold"),
            fg="#f1f5f9",
            bg="#1a222c",
            anchor="w",
        ).pack(fill="x", padx=4, pady=(2, 4))
        text_wrap = Frame(log_frame, bg="#1a222c")
        text_wrap.pack(fill=BOTH, expand=True, padx=4, pady=(0, 4))
        log_scroll = Scrollbar(text_wrap)
        log_scroll.pack(side=RIGHT, fill="y")
        self.log = Text(
            text_wrap,
            wrap=WORD,
            font=("Consolas", 9),
            bg="#0b1220",
            fg="#e2e8f0",
            insertbackground="#e2e8f0",
            relief="flat",
            yscrollcommand=log_scroll.set,
            height=8,
        )
        self.log.pack(side=LEFT, fill=BOTH, expand=True)
        log_scroll.config(command=self.log.yview)

        # ---- scrollable button area (takes remaining space) ----
        btn_outer = Frame(self, bg="#0f1419", padx=12, pady=8)
        btn_outer.pack(fill=BOTH, expand=True)

        canvas = Canvas(btn_outer, bg="#0f1419", highlightthickness=0, bd=0)
        btn_scroll = Scrollbar(btn_outer, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=btn_scroll.set)
        btn_scroll.pack(side=RIGHT, fill="y")
        canvas.pack(side=LEFT, fill=BOTH, expand=True)

        grid = Frame(canvas, bg="#0f1419")
        win_id = canvas.create_window((0, 0), window=grid, anchor="nw")

        def _on_grid_configure(_event=None) -> None:
            canvas.configure(scrollregion=canvas.bbox("all"))

        def _on_canvas_configure(event) -> None:  # type: ignore[no-untyped-def]
            canvas.itemconfigure(win_id, width=event.width)

        grid.bind("<Configure>", _on_grid_configure)
        canvas.bind("<Configure>", _on_canvas_configure)

        def _on_mousewheel(event) -> None:  # type: ignore[no-untyped-def]
            # Windows: event.delta is ±120
            if event.delta:
                canvas.yview_scroll(int(-event.delta / 120), "units")

        def _bind_wheel_tree(widget) -> None:  # type: ignore[no-untyped-def]
            # Bind on every child so hover-over-button still scrolls
            # (parent Leave would unbind_all if we used Enter/Leave only).
            widget.bind("<MouseWheel>", _on_mousewheel)
            for child in widget.winfo_children():
                _bind_wheel_tree(child)

        # (section_title|None, button_text, command, color)
        items: list[tuple[Optional[str], str, Callable[[], None], str]] = [
            ("广告日报（同事机常见 · 17:20）", "广告·预览店铺", self.run_ads_list, "#3b82f6"),
            (None, f"广告·立即日报 {T_AD}", self.run_ads_daily, "#0ea5e9"),
            (None, f"广告·安装 {T_AD} 任务", self.install_ads_task, "#8b5cf6"),
            ("早上整站 · 立即跑（需紫鸟）", "整站·立即跑全5段", self.run_shop, "#2563eb"),
            (None, "整站·订单", self.run_orders, "#2563eb"),
            (None, "整站·商品", self.run_products, "#2563eb"),
            (None, "整站·内容+商品卡", self.run_content, "#0891b2"),
            (None, "整站·联盟达人", self.run_affiliate, "#0891b2"),
            (None, "事件型补采(循环)", self.run_shop_daytime, "#f59e0b"),
            (None, "停止补采循环", self.stop_loop, "#dc2626"),
            ("安装计划任务", f"安装·早上整站 {T_DAILY}(串行5段)", self.install_night_split, "#a855f7"),
            ("其它", "打开日志目录", self.open_logs, "#475569"),
            (None, "打开配置 / 日报", self.open_config_reports, "#475569"),
            (None, "环境自检", self.doctor_only, "#f59e0b"),
            (None, "安装环境依赖", self.install_deps, "#f59e0b"),
            (None, "停止当前任务", self.stop_proc, "#dc2626"),
        ]

        row = 0
        col = 0
        for section, text, cmd, color in items:
            if section:
                if col == 1:
                    row += 1
                    col = 0
                sec = Frame(grid, bg="#243044", padx=10, pady=5)
                sec.grid(row=row, column=0, columnspan=2, sticky="ew", padx=4, pady=(12, 4))
                Label(
                    sec,
                    text="▍ " + section,
                    font=("Microsoft YaHei UI", 10, "bold"),
                    fg="#f1f5f9",
                    bg="#243044",
                    anchor="w",
                ).pack(fill="x")
                row += 1
                col = 0
            b = Button(
                grid,
                text=text,
                command=cmd,
                font=("Microsoft YaHei UI", 10),
                fg="#ffffff",
                bg=color,
                activebackground=color,
                activeforeground="#ffffff",
                relief="flat",
                cursor="hand2",
                padx=8,
                pady=8,
            )
            b.grid(row=row, column=col, sticky="ew", padx=4, pady=3)
            col += 1
            if col >= 2:
                col = 0
                row += 1

        grid.columnconfigure(0, weight=1)
        grid.columnconfigure(1, weight=1)

        # After buttons exist, wire wheel on canvas + whole button tree
        _bind_wheel_tree(canvas)
        _bind_wheel_tree(grid)

    def _append(self, line: str) -> None:
        self.log.configure(state=NORMAL)
        self.log.insert(END, line + "\n")
        self.log.see(END)
        self.log.configure(state=DISABLED)

    def _new_run_log_path(self, title: str) -> Path:
        LOGS.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in title)[:40]
        return LOGS / f"gui-{stamp}-{safe}.log"

    def _set_status(self, text: str) -> None:
        self.status_var.configure(text=text)

    def _drain_queue(self) -> None:
        try:
            while True:
                line = self._q.get_nowait()
                self._append(line)
        except queue.Empty:
            pass
        self.after(100, self._drain_queue)

    def _busy(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    @staticmethod
    def _bridge_hint(text: str) -> Optional[str]:
        markers = (
            "127.0.0.1:9481",
            "bridge",
            "无法连接",
            "连不上",
            "store list failed",
            "Bridge down",
        )
        low = text.lower()
        if any(m in text or m in low for m in markers):
            return (
                "无法连接紫鸟 Bridge（本机 127.0.0.1:9481）。\n\n"
                "请按顺序检查：\n"
                "1. 已安装并打开「紫鸟」桌面客户端\n"
                "2. 已登录（不要只开着托盘图标未登录）\n"
                "3. 等客户端完全启动后再点预览/采集\n"
                "4. 启动器点「环境自检」确认 ziniao-cli 正常\n\n"
                "说明：仅装 Node / ziniao-cli 不够，必须本机紫鸟客户端在线。"
            )
        return None

    def _on_task_done(self, title: str, code: int, collected: str, log_path: Path) -> None:
        self._log_path = log_path
        self._set_status(f"完成：{title} (exit={code}) · 日志 {log_path.name}")
        if code == 0:
            return
        hint = self._bridge_hint(collected)
        if hint:
            messagebox.showerror("紫鸟未连接", hint)
        else:
            messagebox.showwarning(
                "任务失败",
                f"{title} 失败 (exit={code})。\n\n完整输出已写入：\n{log_path}\n\n"
                "可点「打开日志目录」把该文件发给运维。",
            )

    def _run(
        self,
        title: str,
        cmd: list[str],
        confirm: str | None = None,
        cwd: Path | None = None,
    ) -> None:
        if self._busy():
            messagebox.showwarning("进行中", "已有任务在运行，请先「停止当前任务」或等待结束。")
            return
        if confirm and not messagebox.askyesno("确认", confirm):
            return
        if "-File" in cmd:
            idx = cmd.index("-File") + 1
            if idx < len(cmd) and not Path(cmd[idx]).exists():
                messagebox.showerror("错误", f"脚本不存在:\n{cmd[idx]}")
                return

        workdir = cwd or ROOT
        log_path = self._new_run_log_path(title)
        self._log_path = log_path
        header = [
            "",
            f"======== {datetime.now():%H:%M:%S} {title} ========",
            f"cwd={workdir}",
            " ".join(cmd),
            f"[log] {log_path}",
        ]
        for h in header:
            self._append(h)

        self._set_status(f"运行中：{title} · 日志 {log_path.name}")

        def worker() -> None:
            collected: list[str] = []
            try:
                with open(log_path, "w", encoding="utf-8", newline="\n") as fp:

                    def emit(s: str) -> None:
                        collected.append(s)
                        self._q.put(s)
                        try:
                            fp.write(s + "\n")
                            fp.flush()
                        except Exception:  # noqa: BLE001
                            pass

                    for h in header:
                        try:
                            fp.write(h + "\n")
                        except Exception:  # noqa: BLE001
                            pass
                    fp.flush()

                    creation = 0
                    if sys.platform == "win32":
                        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
                    self._proc = subprocess.Popen(
                        cmd,
                        cwd=str(workdir),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        encoding="utf-8",
                        errors="replace",
                        creationflags=creation,
                    )
                    assert self._proc.stdout is not None
                    for line in self._proc.stdout:
                        emit(line.rstrip("\r\n"))
                    code = self._proc.wait()
                    emit(f"--- 结束 exit={code} ---")
                    emit(f"[log] saved: {log_path}")
                    blob = "\n".join(collected)
                    self.after(
                        0,
                        lambda c=code, b=blob, p=log_path: self._on_task_done(title, c, b, p),
                    )
            except Exception as e:  # noqa: BLE001
                self._q.put(f"ERROR: {e}")
                self._q.put(f"[log] saved: {log_path}")
                try:
                    with open(log_path, "a", encoding="utf-8") as fp:
                        fp.write(f"ERROR: {e}\n")
                except Exception:  # noqa: BLE001
                    pass
                self.after(0, lambda: self._set_status(f"失败：{title} · 见 {log_path.name}"))
            finally:
                self._proc = None

        threading.Thread(target=worker, daemon=True).start()

    def _run_chain(self, title: str, steps: list[tuple[str, list[str], Path]], confirm: str) -> None:
        """Run multiple PowerShell installs sequentially in one worker."""
        if self._busy():
            messagebox.showwarning("进行中", "已有任务在运行，请先「停止当前任务」或等待结束。")
            return
        if not messagebox.askyesno("确认", confirm):
            return
        for _name, cmd, _cwd in steps:
            if "-File" in cmd:
                idx = cmd.index("-File") + 1
                if idx < len(cmd) and not Path(cmd[idx]).exists():
                    messagebox.showerror("错误", f"脚本不存在:\n{cmd[idx]}")
                    return

        log_path = self._new_run_log_path(title)
        self._log_path = log_path
        self._append("")
        self._append(f"======== {datetime.now():%H:%M:%S} {title} ========")
        self._set_status(f"运行中：{title} · 日志 {log_path.name}")

        def worker() -> None:
            collected: list[str] = []
            final_code = 0
            try:
                with open(log_path, "w", encoding="utf-8", newline="\n") as fp:

                    def emit(s: str) -> None:
                        collected.append(s)
                        self._q.put(s)
                        try:
                            fp.write(s + "\n")
                            fp.flush()
                        except Exception:  # noqa: BLE001
                            pass

                    creation = 0
                    if sys.platform == "win32":
                        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)

                    for step_name, cmd, cwd in steps:
                        emit(f"----- {step_name} -----")
                        emit(" ".join(cmd))
                        self._proc = subprocess.Popen(
                            cmd,
                            cwd=str(cwd),
                            stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT,
                            text=True,
                            encoding="utf-8",
                            errors="replace",
                            creationflags=creation,
                        )
                        assert self._proc.stdout is not None
                        for line in self._proc.stdout:
                            emit(line.rstrip("\r\n"))
                        code = self._proc.wait()
                        emit(f"--- {step_name} exit={code} ---")
                        if code != 0:
                            final_code = code
                    emit(f"--- 链结束 final_exit={final_code} ---")
                    emit(f"[log] saved: {log_path}")
                    blob = "\n".join(collected)
                    self.after(
                        0,
                        lambda c=final_code, b=blob, p=log_path: self._on_task_done(
                            title, c, b, p
                        ),
                    )
            except Exception as e:  # noqa: BLE001
                self._q.put(f"ERROR: {e}")
                self.after(0, lambda: self._set_status(f"失败：{title}"))
            finally:
                self._proc = None

        threading.Thread(target=worker, daemon=True).start()

    def _loop_busy(self) -> bool:
        """事件型补采 loop 是否在跑（独立于 self._proc 的前台任务槽）。"""
        return self._loop_proc is not None and self._loop_proc.poll() is None

    def _run_loop(self, title: str, cmd: list[str], confirm: str) -> None:
        """启动常驻后台任务（事件型补采 loop），用独立槽 self._loop_proc。

        与 _run 的区别：不占 self._proc、不受 _busy() 拦截（起完 loop 仍可点前台短任务）、
        用 _loop_busy() 防重复起 loop。loop 一直跑，worker 线程持续读 stdout 直到被
        stop_loop() 杀掉或关窗口。
        """
        if self._loop_busy():
            messagebox.showwarning("进行中", "补采循环已在运行，请先「停止补采循环」。")
            return
        if not messagebox.askyesno("确认", confirm):
            return
        if "-File" in cmd:
            idx = cmd.index("-File") + 1
            if idx < len(cmd) and not Path(cmd[idx]).exists():
                messagebox.showerror("错误", f"脚本不存在:\n{cmd[idx]}")
                return

        workdir = ROOT
        log_path = self._new_run_log_path(title)
        self._append("")
        self._append(f"======== {datetime.now():%H:%M:%S} {title} ========")
        self._append(" ".join(cmd))
        self._append(f"[log] {log_path}")
        self._set_status(f"后台运行：{title} · 日志 {log_path.name}")

        def worker() -> None:
            collected: list[str] = []
            try:
                with open(log_path, "w", encoding="utf-8", newline="\n") as fp:

                    def emit(s: str) -> None:
                        collected.append(s)
                        self._q.put(s)
                        try:
                            fp.write(s + "\n")
                            fp.flush()
                        except Exception:  # noqa: BLE001
                            pass

                    creation = 0
                    if sys.platform == "win32":
                        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
                    self._loop_proc = subprocess.Popen(
                        cmd,
                        cwd=str(workdir),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        encoding="utf-8",
                        errors="replace",
                        creationflags=creation,
                    )
                    assert self._loop_proc.stdout is not None
                    for line in self._loop_proc.stdout:
                        emit(line.rstrip("\r\n"))
                    code = self._loop_proc.wait()
                    emit(f"--- 补采循环结束 exit={code} ---")
                    emit(f"[log] saved: {log_path}")
                    self.after(
                        0,
                        lambda c=code: self._set_status(
                            f"补采循环已结束 exit={c} · 日志 {log_path.name}"
                        ),
                    )
            except Exception as e:  # noqa: BLE001
                self._q.put(f"ERROR: {e}")
                self.after(0, lambda: self._set_status(f"补采循环失败：{e}"))
            finally:
                self._loop_proc = None

        threading.Thread(target=worker, daemon=True).start()

    def stop_loop(self) -> None:
        """专门停止事件型补采 loop（self._loop_proc），不影响前台 self._proc。"""
        if not self._loop_busy():
            messagebox.showinfo("停止", "补采循环未在运行。")
            return
        try:
            self._kill_proc_tree(self._loop_proc)
            self._append("--- 已请求停止补采循环（含子进程树）---")
            self._set_status("补采循环已停止")
        except Exception as e:  # noqa: BLE001
            messagebox.showerror("停止失败", str(e))

    # ----- 广告 -----
    def run_ads_list(self) -> None:
        self._run("广告·预览店铺", _ps_file(SCRIPTS / "run-multi-store.ps1", "-ListOnly"))

    def run_ads_daily(self) -> None:
        self._run(
            "广告·立即日报",
            _ps_file(SCRIPTS / "run-daily-report.ps1"),
            confirm=f"执行与 {T_AD} 计划任务相同的广告日报（写飞书）。\n继续？",
        )

    def install_ads_task(self) -> None:
        self._run(
            f"安装广告 {T_AD} 任务",
            _ps_file(SCRIPTS / "install-daily-task.ps1", "-Time", T_AD),
            confirm=f"安装/更新 TK-Ad-Daily-Report（每天 {T_AD}）。\n继续？",
        )

    # ----- 整站立即跑 -----
    def run_shop(self) -> None:
        self._run(
            "整站·立即跑全5段",
            _ps_file(SCRIPTS / "run-shop-modules-daily.ps1"),
            confirm="立即跑早上整站全5段串行：店KPI/健康/财务→订单→商品→内容→联盟 → 清泉 Ingest。\n需紫鸟。继续？",
        )

    def run_shop_daytime(self) -> None:
        self._run_loop(
            "事件型补采(一直跑)",
            _ps_file(SCRIPTS / "run-shop-modules-daytime-loop.ps1", "-IntervalSec", "1800"),
            confirm=(
                "启动事件型补采循环：每 30 分钟跑一轮违规/差评/达人健康 → Ingest。\n"
                "全天常驻，避开 08:00~11:30 (早上整站08:10串行5段) + 17:00~21:30 (广告17:20+夜间堆叠)，不抢紫鸟。\n"
                "不碰销量/订单/GMV/广告(白天中间值会和全天累计值冲突)。\n"
                "采到新违规/差评会立即 IM 私信两负责人。需紫鸟。\n"
                "在后台常驻，不影响点其它短任务；点「停止补采循环」可单独停。继续？"
            ),
        )

    def run_orders(self) -> None:
        self._run(
            "整站·订单",
            _ps_file(SCRIPTS / "run-orders-daily.ps1"),
            confirm="立即跑订单全店 → Ingest。需紫鸟。继续？",
        )

    def run_products(self) -> None:
        self._run(
            "整站·商品",
            _ps_file(SCRIPTS / "run-products-daily.ps1"),
            confirm="立即跑商品全店 → Ingest。需紫鸟。继续？",
        )

    def run_content(self) -> None:
        self._run(
            "整站·内容",
            _ps_file(SCRIPTS / "run-content-daily.ps1"),
            confirm="立即跑视频+商品卡（强制入库）。需紫鸟。继续？",
        )

    def run_affiliate(self) -> None:
        self._run(
            "整站·达人",
            _ps_file(SCRIPTS / "run-affiliate-daily.ps1"),
            confirm="立即跑联盟达人（强制入库，含 Pop）。\n投流/寄样不填 0。需紫鸟。继续？",
        )

    def run_day_loop(self) -> None:
        # 2026-08-20 移除：白天空闲轮巡(SkipAds) 会白天反复采订单/商品/店KPI等全天累计指标，
        # 与"白天采累计值会和全天累计值冲突"的风险冲突。改用「事件型补采(循环)」
        # (run_shop_daytime) 只采违规/差评/达人健康事件型模块。此方法保留空壳避免历史引用报错。
        raise RuntimeError("白天空闲轮巡已停用，请改用「事件型补采(循环)」")

    # ----- 安装任务 -----
    def install_night_split(self) -> None:
        # 2026-08-21：原夜间拆分5任务已废弃合并为一个 08:10 串行5段任务。
        # 只装 install-shop-modules-daily-task.ps1（wrapper 内部串行 shop→orders→products→content→affiliate）。
        # 其余 install-*-daily-task.ps1 已标废弃，不再调用。
        steps = [
            (
                f"整站串行5段 {T_DAILY}",
                _ps_file(SCRIPTS / "install-shop-modules-daily-task.ps1", "-Time", T_DAILY),
                ROOT,
            ),
        ]
        self._run_chain(
            f"安装早上整站 {T_DAILY}(串行5段)",
            steps,
            confirm=(
                "将安装/更新计划任务 TK-Shop-Modules-Daily：\n"
                f"  早上 {T_DAILY} 起串行5段 → shop→orders→products→content→affiliate\n\n"
                f"不含广告 {T_AD}（请单独装，下午跑需全天数据）。\n"
                "继续？"
            ),
        )

    def install_deps(self) -> None:
        self._run(
            "安装环境依赖",
            _ps_file(SCRIPTS / "install-deps.ps1"),
            confirm=(
                "将检查/安装 Node.js LTS、ziniao-cli 等。\n"
                "不含紫鸟桌面客户端。继续？"
            ),
        )

    def doctor_only(self) -> None:
        self._run("环境自检", _ps_file(SCRIPTS / "install-deps.ps1", "-DoctorOnly"))

    def open_logs(self) -> None:
        LOGS.mkdir(parents=True, exist_ok=True)
        os.startfile(str(LOGS))  # type: ignore[attr-defined]
        self._set_status("已打开日志目录")

    def open_config_reports(self) -> None:
        REPORTS.mkdir(parents=True, exist_ok=True)
        if CONFIG.exists():
            os.startfile(str(CONFIG))  # type: ignore[attr-defined]
        else:
            example = ROOT / "config" / "stores.config.example.json"
            messagebox.showinfo(
                "配置",
                f"未找到 stores.config.json\n请复制:\n{example}\n为 stores.config.json。",
            )
            if example.parent.exists():
                os.startfile(str(example.parent))  # type: ignore[attr-defined]
        os.startfile(str(REPORTS))  # type: ignore[attr-defined]
        self._set_status("已打开配置 / 日报目录")

    def _kill_proc_tree(self, proc: subprocess.Popen) -> None:
        """Terminate proc and all descendants (Windows needs taskkill /T)."""
        if proc.poll() is not None:
            return
        pid = proc.pid
        if sys.platform == "win32":
            # /T = kill child tree; /F = force. Plain terminate() only kills
            # the top powershell and leaves night-loop collectors running.
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            try:
                proc.wait(timeout=8)
            except Exception:  # noqa: BLE001
                pass
            return
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:  # noqa: BLE001
            try:
                proc.kill()
            except Exception:  # noqa: BLE001
                pass

    def stop_proc(self) -> None:
        if not self._busy() or self._proc is None:
            messagebox.showinfo("停止", "当前没有运行中的任务。")
            return
        try:
            self._kill_proc_tree(self._proc)
            self._append("--- 已请求停止（含子进程树）---")
            self._set_status("已停止")
        except Exception as e:  # noqa: BLE001
            messagebox.showerror("停止失败", str(e))

    def _on_close(self) -> None:
        if self._busy() or self._loop_busy():
            prompt = "任务仍在运行" if self._busy() else "补采循环仍在后台运行"
            if not messagebox.askyesno("退出", f"{prompt}，确定退出并停止？"):
                return
            try:
                if self._proc:
                    self._kill_proc_tree(self._proc)
            except Exception:  # noqa: BLE001
                pass
            try:
                if self._loop_proc:
                    self._kill_proc_tree(self._loop_proc)
            except Exception:  # noqa: BLE001
                pass
        self.destroy()


def main() -> None:
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()
