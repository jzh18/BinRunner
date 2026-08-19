"""hdc 命令封装与设备选择。

依赖：config。被 push/runner/provision/cli 依赖。
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import time

from binrunner.config import DEVECO_HDC, DEVICE_ENV

_HDC_CACHE: str | None = None


def find_hdc() -> str:
    """定位 hdc：PATH 优先，回退 DevEco Studio 默认路径。"""
    hdc = shutil.which("hdc")
    if hdc:
        return hdc
    if os.path.exists(DEVECO_HDC):
        return DEVECO_HDC
    sys.exit("找不到 hdc：请把 DevEco 工具链加入 PATH，或安装 DevEco Studio")


def hdc_path() -> str:
    """惰性解析 hdc 路径并缓存。

    不在模块顶层解析：import 时不应因缺少 hdc 而退出进程（否则单测无法收集）。
    """
    global _HDC_CACHE
    if _HDC_CACHE is None:
        _HDC_CACHE = find_hdc()
    return _HDC_CACHE


def hdc_cmd(udid: str | None, *args: str) -> list[str]:
    """拼装 hdc 命令行。udid 为空时省略 -t（如 hdc list targets）。"""
    cmd = [hdc_path()]
    if udid:
        cmd += ["-t", udid]
    return cmd + list(args)


def run_hdc(
    udid: str | None,
    *args: str,
    check: bool = True,
    timeout: int = 30,
) -> subprocess.CompletedProcess:
    """同步执行 hdc 命令。check=True 时非零退出即终止进程。"""
    p = subprocess.run(
        hdc_cmd(udid, *args), capture_output=True, text=True, timeout=timeout
    )
    if check and p.returncode != 0:
        sys.exit(f"hdc {' '.join(args)} 失败:\n{p.stdout}{p.stderr}")
    return p


def list_targets() -> list[str]:
    """列出在线设备 UDID。"""
    out = run_hdc(None, "list", "targets").stdout.split()
    return [t for t in out if t and t != "[Empty]"]


def pick_device(udid: str | None, required: bool = True) -> str | None:
    """选择目标设备。优先级：-t 参数 > 环境变量 > 自动检测（仅一台时）。

    required=False 用于 br version —— 无设备也要能显示 CLI 版本。
    """
    if udid:
        return udid
    env = os.environ.get(DEVICE_ENV)
    if env:
        return env

    targets = list_targets()
    if not targets:
        if required:
            sys.exit("没有已连接的设备（hdc list targets 为空）")
        return None
    if len(targets) > 1 and required:
        sys.exit(f"多台设备在线，请用 -t 指定：{', '.join(targets)}")
    return targets[0]


# ---------------- 端口转发 ----------------

def port_open(port: int) -> bool:
    """探测本地端口是否可连接（用于判断 fport 是否已建立）。"""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            return True
    except OSError:
        return False


def _forward_rule(udid: str, port: int) -> str:
    return f"tcp:{port} tcp:{port}"


def _forward_listed(udid: str, port: int) -> bool:
    """用 `hdc fport ls` 确认真实转发规则存在（本地端口探测可能误判）。"""
    try:
        p = run_hdc(udid, "fport", "ls", check=False, timeout=10)
        return _forward_rule(udid, port) in p.stdout
    except Exception:
        return False


def ensure_forward(udid: str, port: int, force: bool = False) -> None:
    """建立 hdc fport 转发，幂等。

    fport 是前台进程，故以脱离会话的后台进程驻留（start_new_session）。
    长传输出错（Connection refused 等）时以 force=True 重建 —— 隧道可能
    被系统回收但本地端口仍被残留进程占用，仅靠 port_open 会误判为健康。
    """
    if not force and (_forward_listed(udid, port) or port_open(port)):
        return
    if force:
        # 先删旧规则再重建，避免残留规则与新隧道打架
        run_hdc(udid, "fport", "rm", _forward_rule(udid, port), check=False, timeout=10)
        time.sleep(0.2)
    subprocess.Popen(
        hdc_cmd(udid, "fport", "tcp:{0}".format(port), "tcp:{0}".format(port)),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    for _ in range(50):
        if port_open(port):
            return
        time.sleep(0.1)
    sys.exit(f"hdc fport 建立失败（127.0.0.1:{port} 一直连不上）")


def wakeup_screen(udid: str) -> None:
    """点亮屏幕。屏幕熄灭后 BinRunner 的 EntryAbility 进后台，8888 监听
    被系统挂起（doc §7.2 记录的已知坑），推送前/推送中需要保持屏幕常亮。"""
    run_hdc(udid, "shell", "power-shell wakeup", check=False, timeout=10)


def restart_app(udid: str, bundle: str, ability: str) -> None:
    """强制重启设备侧 App。多次失败协商后 PushServer 可能卡死，
    重启 App 是兜底手段（实测有效）。"""
    run_hdc(udid, "shell", f"aa force-stop {bundle}", check=False, timeout=10)
    run_hdc(udid, "shell", f"aa start -b {bundle} -a {ability}", check=False, timeout=10)
