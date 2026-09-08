"""执行期限传递、报告预留及主机轮询截止时间的回归测试。"""
import subprocess

import pytest

from binrunner import runner
from binrunner.cli import build_parser


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


@pytest.fixture
def execution(monkeypatch):
    clock = Clock()
    calls = []
    monkeypatch.setattr(runner.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(runner.time, "sleep", clock.sleep)
    monkeypatch.setattr(runner, "new_run_id", lambda: "a1b2c3d4")
    monkeypatch.setattr(runner, "run_hdc", lambda *a, **kw: calls.append(a))
    return clock, calls


def report(exit_code, timed_out, timeout):
    prefix = "x BinRunner: [a1b2c3d4] "
    return "\n".join(prefix + line for line in [
        ">>> exec hello args=[]",
        f"<<< exit={exit_code} timedOut={timed_out} timeoutSec={timeout}",
        "<<< --- stdout ---",
        "<<< hello",
        "<<< --- stderr ---",
        "<<< END",
    ])


@pytest.mark.parametrize("seconds,exit_code,timed_out,arrival", [
    (1800, 42, "false", 45),  # 运行超过旧的 30 秒限制
    (1800, -1, "true", 1802),  # 执行超时后的报告仍可在预留窗口内收到
    (60, 0, "false", 1),
    (1, -1, "true", 2),
])
def test_execution_timeout_and_report_grace(
    execution, monkeypatch, capsys, seconds, exit_code, timed_out, arrival,
):
    clock, calls = execution
    monkeypatch.setattr(
        runner, "_dump_hilog",
        lambda *a: report(exit_code, timed_out, seconds) if clock.now >= arrival else "",
    )
    assert runner.cmd_run("device", "hello", seconds) == exit_code
    assert f"--ps timeout_sec {seconds}" in calls[1][2]
    assert "--ps run_id a1b2c3d4" in calls[1][2]
    assert "--ps cmd 'hello'" in calls[1][2]
    captured = capsys.readouterr()
    assert f"exit={exit_code} timedOut={timed_out} timeoutSec={seconds}" in captured.out
    assert captured.err == ""


@pytest.mark.parametrize("stalled", [False, True])
def test_missing_report_respects_total_deadline(execution, monkeypatch, capsys, stalled):
    clock, _ = execution
    poll_timeouts = []

    def dump(udid, timeout):
        poll_timeouts.append(timeout)
        if stalled:
            clock.sleep(timeout)
            raise subprocess.TimeoutExpired("hilog", timeout)
        return ""

    monkeypatch.setattr(runner, "_dump_hilog", dump)
    assert runner.cmd_run("device", "hello", 2) == 1
    assert clock.now == 32
    assert all(0 < t <= 5 for t in poll_timeouts)
    error = capsys.readouterr().err
    assert "32s" in error and "设备执行期限 2s" in error and "预留 30s" in error
    assert "设备是否已结束未知" in error


@pytest.mark.parametrize("value", ["0", "-1", "1.5", "nan", "2147483648", "oops"])
def test_cli_rejects_invalid_timeout(value):
    with pytest.raises(SystemExit) as exc:
        build_parser().parse_args(["run", "hello", "--timeout", value])
    assert exc.value.code == 2


def test_cli_timeout_default_and_boundaries():
    parser = build_parser()
    assert parser.parse_args(["run", "hello"]).timeout == 60
    for seconds in (1, 1800, 2147483647):
        assert parser.parse_args(["run", "--timeout", str(seconds), "hello"]).timeout == seconds


@pytest.mark.parametrize("value", [0, -1, 1.5, True, 2147483648])
def test_direct_call_rejects_invalid_timeout_before_device_access(execution, value):
    _, calls = execution
    with pytest.raises(ValueError):
        runner.cmd_run("device", "hello", value)
    assert calls == []
