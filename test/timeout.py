import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run/scripts/timeout.py"
spec = importlib.util.spec_from_file_location("review_timeout", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TimeoutTest(unittest.TestCase):
    def test_defaults_and_overrides(self):
        for value, expected in [("", 600), ("5", 300), ("20", 1200), ("0.5", 30)]:
            with self.subTest(value=value):
                self.assertEqual(module.timeout_seconds(value), expected)

    def test_invalid_limits(self):
        for value in ["0", "-1", "nan", "inf", "1e309", "10m", "garbage"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.timeout_seconds(value)

    def test_preserves_exit_codes_and_output(self):
        for code in [0, 1, 2, 3, 4]:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), sys.executable, "-c",
                 f"print('review output'); raise SystemExit({code})"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, code)
            self.assertEqual(result.stdout, "review output\n")

    def test_timeout_kills_stubborn_descendant_after_leader_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "pid"
            child = (
                "import os,signal,time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                f"Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(30)"
            )
            leader = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(30)"
            )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), sys.executable, "-c", leader],
                env={**os.environ, "INPUT_TIMEOUT_MINUTES": "0.02"},
                capture_output=True, text=True, timeout=12,
            )
            self.assertEqual(result.returncode, 124)
            self.assertIn("exceeded timeout-minutes", result.stderr)
            pid = int(pid_file.read_text())
            # Linux may retain a killed orphan as a zombie until init reaps it.
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                   capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith("Z"), state)

    def test_runner_cancellation_is_forwarded(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "ready"
            code = (
                "import time; from pathlib import Path; "
                f"Path({str(marker)!r}).touch(); time.sleep(30)"
            )
            process = subprocess.Popen([sys.executable, str(SCRIPT), sys.executable, "-c", code])
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=8), 143)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_action_shell_cancellation_waits_for_review_before_logout(self):
        for sig, output_format in [(signal.SIGTERM, "text"), (signal.SIGINT, "json")]:
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fake = root / "doomer"
                fake.write_text(f"#!{sys.executable}\n" + '''
import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ["TEST_ROOT"])
args = sys.argv[1:]
if args[0] == "--profile":
    args = args[2:]
if args[0] == "login":
    sys.stdin.read()
elif args[0] == "run":
    child = subprocess.Popen([sys.executable, "-c", """
import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ['TEST_ROOT'], 'child').write_text(str(os.getpid()))
time.sleep(60)
"""])
    while not (root / "child").exists():
        time.sleep(0.01)
    (root / "ready").write_text(f"{os.getpid()} {os.getppid()}")
    time.sleep(60)
elif args[0] == "logout":
    pid = (root / "child").read_text()
    state = subprocess.run(["ps", "-o", "stat=", "-p", pid],
                           capture_output=True, text=True).stdout.strip()
    (root / "logout").write_text(state)
''')
                fake.chmod(0o755)
                env = {key: value for key, value in os.environ.items()
                       if not key.startswith(("INPUT_", "GITHUB_", "ADVERSARY_"))}
                env.update(
                    PATH=f"{root}:{os.environ['PATH']}", TEST_ROOT=str(root),
                    RUNNER_TEMP=str(root), GITHUB_OUTPUT=str(root / "outputs"),
                    INPUT_AUTH_MODE="token", INPUT_TOKEN="adv_sa_test",
                    INPUT_FORMAT=output_format,
                    ADVERSARY_MODEL_PROVIDER="openai",
                    ADVERSARY_MODEL="test-review-model",
                    OPENAI_API_KEY="test-review-key",
                )
                process = subprocess.Popen(
                    ["bash", str(SCRIPT.parent / "run.sh")], env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                try:
                    deadline = time.monotonic() + 5
                    while not (root / "ready").exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue((root / "ready").exists())
                    process.send_signal(sig)
                    stdout, stderr = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 128 + sig, stderr)
                    state_at_logout = (root / "logout").read_text()
                    self.assertTrue(not state_at_logout or state_at_logout.startswith("Z"),
                                    f"review child still running at logout: {state_at_logout}")
                    for pid in (root / "ready").read_text().split():
                        state = subprocess.run(["ps", "-o", "stat=", "-p", pid],
                                               capture_output=True, text=True).stdout.strip()
                        self.assertTrue(not state or state.startswith("Z"), state)
                finally:
                    # Also clean up when exercising the old, leaking implementation.
                    if (root / "ready").exists():
                        leader, wrapper = map(int, (root / "ready").read_text().split())
                        for pid in [wrapper, leader]:
                            try:
                                os.kill(pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                        try:
                            os.killpg(leader, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
