import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.2.3"
LATEST_API = "https://api.github.com/repos/doomerlabs/doomer/releases/latest"
DOWNLOAD_BASE = f"https://github.com/doomerlabs/doomer/releases/download/{VERSION}"


class InstallAuthTest(unittest.TestCase):
    installer = ROOT / "run/scripts/install.sh"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.runner = self.directory / "runner"
        self.runner.mkdir()

        os_name = {"Darwin": "darwin", "Linux": "linux"}[platform.system()]
        arch = {"x86_64": "amd64", "amd64": "amd64",
                "arm64": "arm64", "aarch64": "arm64"}[platform.machine()]
        self.archive_name = f"doomer_{VERSION}_{os_name}_{arch}.tar.gz"
        archive = self.directory / self.archive_name
        binary = b'#!/usr/bin/env bash\nprintf "adversary fixture\\n"\n'
        with tarfile.open(archive, "w:gz") as bundle:
            info = tarfile.TarInfo("doomer")
            info.mode = 0o755
            info.size = len(binary)
            bundle.addfile(info, io.BytesIO(binary))
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.directory / "checksums.txt").write_text(f"{checksum}  {self.archive_name}\n")
        (self.directory / "latest.json").write_text(json.dumps({
            "tag_name": VERSION, "draft": False, "prerelease": False,
        }))

        # Exercise the complete installer while replacing only HTTP transport.
        # Unknown URLs fail instead of making any real network requests.
        curl = self.bin / "curl"
        curl.write_text(f"#!{sys.executable}\n" + '''
import json, os, shutil, sys
from pathlib import Path

root = Path(os.environ["INSTALL_AUTH_TEST_ROOT"])
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith(("https://", "http://", "file://")))
output = args[args.index("--output") + 1]
headers = [args[i + 1] for i, arg in enumerate(args) if arg in ("--header", "-H")]
with (root / "requests.jsonl").open("a") as stream:
    stream.write(json.dumps({"url": url, "headers": headers, "args": args}) + "\\n")
responses = json.loads((root / "responses.json").read_text())
shutil.copyfile(root / responses[url], output)
''')
        curl.chmod(0o755)

    def install(self, *, github_token="test-github-token", gh_token="test-gh-token",
                api=LATEST_API, base=DOWNLOAD_BASE, pinned=False):
        urls = [api, f"{base}/{self.archive_name}", f"{base}/checksums.txt"]
        (self.directory / "responses.json").write_text(json.dumps(dict(zip(
            urls, ["latest.json", self.archive_name, "checksums.txt"],
        ))))
        (self.directory / "requests.jsonl").write_text("")
        github_path = self.directory / "github-path"
        github_path.write_text("")
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "INSTALL_AUTH_TEST_ROOT": str(self.directory),
            "RUNNER_TEMP": str(self.runner),
            "GITHUB_PATH": str(github_path),
            "INPUT_CLI_VERSION": VERSION if pinned else "",
        }
        for name, value in (("GITHUB_TOKEN", github_token), ("GH_TOKEN", gh_token),
                            ("ADVERSARY_LATEST_RELEASE_API", api if api != LATEST_API else None),
                            ("ADVERSARY_DOWNLOAD_BASE", base if base != DOWNLOAD_BASE else None)):
            env.pop(name, None)
            if value is not None:
                env[name] = value
        result = subprocess.run(["bash", str(self.installer)], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("adversary fixture", result.stdout)
        installed = Path(github_path.read_text().strip()) / "doomer"
        self.assertTrue(installed.is_file())
        for token in (github_token, gh_token):
            if token:
                self.assertNotIn(token, result.stdout + result.stderr)
        requests = [json.loads(line) for line in
                    (self.directory / "requests.jsonl").read_text().splitlines()]
        self.assertEqual([request["url"] for request in requests], urls[1:] if pinned else urls)
        for request in requests:
            self.assertNotIn("--location-trusted", request["args"])
        return [request["headers"] for request in requests]

    def test_github_token_authenticates_lookup_and_assets(self):
        self.assertEqual(self.install(gh_token=None),
                         [["Authorization: Bearer test-github-token"]] * 3)

    def test_github_token_takes_precedence(self):
        self.assertEqual(self.install(),
                         [["Authorization: Bearer test-github-token"]] * 3)

    def test_gh_token_fallback(self):
        for github_token in (None, ""):
            with self.subTest(github_token=github_token):
                self.assertEqual(self.install(github_token=github_token),
                                 [["Authorization: Bearer test-gh-token"]] * 3)

    def test_without_tokens_downloads_remain_unauthenticated(self):
        for token in (None, ""):
            with self.subTest(token=token):
                self.assertEqual(self.install(github_token=token, gh_token=token), [[], [], []])

    def test_pinned_version_authenticates_assets_without_release_lookup(self):
        self.assertEqual(self.install(pinned=True),
                         [["Authorization: Bearer test-github-token"]] * 2)

    def test_external_asset_host_receives_no_token(self):
        self.assertEqual(self.install(base="https://downloads.example.test/releases"),
                         [["Authorization: Bearer test-github-token"], [], []])

    def test_unexpected_github_api_paths_receive_no_token(self):
        for api in (
            "https://api.github.com/repos/other/project/releases/latest",
            "https://api.github.com/repos/doomerlabs/other/releases/latest",
            "https://api.github.com/repos/doomerlabs/doomer/issues",
            f"{LATEST_API}/../latest",
            f"{LATEST_API}?redirect=other",
            f"{LATEST_API}#fragment",
        ):
            with self.subTest(api=api):
                self.assertEqual(self.install(api=api),
                                 [[], ["Authorization: Bearer test-github-token"],
                                  ["Authorization: Bearer test-github-token"]])

    def test_unexpected_github_asset_paths_receive_no_token(self):
        for base in (
            f"https://github.com/other/project/releases/download/{VERSION}",
            f"https://github.com/doomerlabs/other/releases/download/{VERSION}",
            "https://github.com/doomerlabs/doomer/releases/download/9.9.9",
            f"{DOWNLOAD_BASE}/../{VERSION}",
            f"{DOWNLOAD_BASE}/%2e%2e/{VERSION}",
            f"https://github.com/doomerlabs/doomer/blob/main/{VERSION}",
        ):
            with self.subTest(base=base):
                self.assertEqual(self.install(base=base),
                                 [["Authorization: Bearer test-github-token"], [], []])

    def test_non_github_and_insecure_urls_receive_no_token(self):
        for origin in ("https://downloads.example.test", "https://github.com.example.test",
                       "https://api.github.com.example.test", "https://github.com@other.example.test",
                       "https://user@api.github.com", "https://github.com:8443",
                       "http://github.com", "http://api.github.com", "file:///fixture"):
            with self.subTest(origin=origin):
                self.assertEqual(self.install(
                    api=f"{origin}/repos/doomerlabs/doomer/releases/latest",
                    base=f"{origin}/doomerlabs/doomer/releases/download/{VERSION}",
                ), [[], [], []])


if __name__ == "__main__":
    unittest.main()
