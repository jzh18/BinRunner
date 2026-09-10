"""命令执行与日志跟踪。

依赖：config, hdc, hilog。

设备侧 stdout/stderr 经 hilog 回传，故这里用 `hilog -x` 轮询收集：
流式 `hilog` 在 pipe 模式下可能全缓冲导致小量输出读不到（历史 bug）。
"""
from __future__ import annotations

import codecs
import random
import subprocess
import sys
import time

from binrunner.config import ABILITY, BUNDLE, TAG
from binrunner.hdc import hdc_cmd, run_hdc
from binrunner.hilog import StreamOutput, parse_exit_code, parse_output, report_is_complete

# App 冷启动 + 设备侧 300ms setTimeout + 命令执行的预留时间
_STARTUP_WAIT = 1.0
# 轮询间隔
_POLL_INTERVAL = 0.5
# 启动、调度及报告回传的额外等待时间
_REPORT_GRACE = 30
# 单次 hilog -x 的最大超时
_MAX_POLL_TIMEOUT = 5
# br logs 的轮询间隔
_LOGS_INTERVAL = 1


def new_run_id() -> str:
    """生成 8 位十六进制执行 ID，用于多终端并发时隔离各自输出。"""
    return "".join(random.choices("0123456789abcdef", k=8))


def _dump_hilog(udid: str, timeout: float) -> str:
    """非阻塞 dump 设备日志。宽容解码：其他进程的日志可能含非 UTF-8 字节。"""
    r = subprocess.run(
        hdc_cmd(udid, "shell", "hilog -x"), capture_output=True, timeout=timeout
    )
    return r.stdout.decode("utf-8", errors="replace")


def cmd_run(udid: str, cmdline: str, timeout: int) -> int:
    """在设备上执行命令，实时转发输出并返回目标二进制的退出码。"""
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 2147483647:
        raise ValueError("执行超时必须为 1–2147483647 的整数秒")
    run_id = new_run_id()

    # run_id 隔离旧日志；不要清空其他并发任务的日志。
    run_hdc(
        udid,
        "shell",
        f"aa start -b {BUNDLE} -a {ABILITY} --ps run_id {run_id} --ps stream 1 --ps timeout_sec {timeout} --ps cmd '{cmdline}'",
    )

    started = False
    done = False
    report_lines: list[str] = []
    parts: dict[int, str] = {}  # 超长行的 [i/n] 分段缓存，跨轮次复用

    stream = StreamOutput(run_id)
    decoders = {name: codecs.getincrementaldecoder("utf-8")("replace")
                for name in ("stdout", "stderr")}

    def emit(channel: str, payload: bytes, final: bool = False) -> None:
        target = sys.stdout if channel == "stdout" else sys.stderr
        target.write(decoders[channel].decode(payload, final=final))
        target.flush()

    wait_timeout = timeout + _REPORT_GRACE
    deadline = time.monotonic() + wait_timeout
    time.sleep(_STARTUP_WAIT)

    while not done:
        remain = deadline - time.monotonic()
        if remain <= 0:
            for channel in decoders:
                emit(channel, b"", final=True)
            if stream.expected is not None:
                print(f"[binrunner] 输出数据不完整（收到连续 {stream.next_sequence}/"
                      f"{stream.expected} 块）", file=sys.stderr)
            print(
                f"[binrunner] 等待执行报告超时（{wait_timeout}s；设备执行期限 {timeout}s，"
                f"启动和报告预留 {_REPORT_GRACE}s），设备是否已结束未知",
                file=sys.stderr,
            )
            return 1

        try:
            output = _dump_hilog(udid, min(remain, _MAX_POLL_TIMEOUT))
        except subprocess.TimeoutExpired:
            continue
        output = stream.consume(output, emit)
        # Sequenced records already identify this run even if the start log was lost.
        started = started or stream.next_sequence > 0 or stream.expected is not None
        started, done = parse_output(output, started, report_lines, parts, run_id)
        if stream.expected is not None:
            # Summary is emitted after all pipe chunks, and also survives a lost END.
            if stream.next_sequence == stream.expected:
                break
            done = False
        elif stream.next_sequence or stream.pending:
            # END alone cannot replace the exit status / total chunk count.
            done = False
        elif done:
            break
        # <<< END 可能被 hilog socket 丢弃 → 用报告结构完整性兜底
        if started and report_is_complete(report_lines):
            break
        time.sleep(min(_POLL_INTERVAL, max(0, deadline - time.monotonic())))

    if not done and not report_lines:
        print(
            "[binrunner] 没收到执行报告（App 未运行或 cmd 未触发？）", file=sys.stderr
        )
        return 1

    for channel in decoders:
        emit(channel, b"", final=True)
    report = "\n".join(report_lines)
    # Keep execution metadata separate from the program's stdout.
    print(report, file=sys.stderr if stream.expected is not None else sys.stdout,
          flush=True)
    return parse_exit_code(report)


def cmd_logs(udid: str) -> int:
    """持续跟踪设备 BinRunner 日志（Ctrl+C 退出）。

    seen 集合去重：hilog -x 每次 dump 整个缓冲区，已打印的行不再重复输出。
    """
    seen: set[str] = set()
    print(
        f"[binrunner] 跟踪设备 {udid} 的 BinRunner 日志，Ctrl+C 退出...",
        file=sys.stderr,
    )
    try:
        while True:
            for line in _dump_hilog(udid, timeout=10).split("\n"):
                if TAG in line and line not in seen:
                    seen.add(line)
                    print(line)
            time.sleep(_LOGS_INTERVAL)
    except KeyboardInterrupt:
        return 0
