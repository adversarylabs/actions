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


if __name__ == "__main__":
    unittest.main()
