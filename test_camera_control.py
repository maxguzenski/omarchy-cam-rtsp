"""Isolated persistence and preview tests; never connect to a real camera."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


class CameraControlTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="camera-test-")
        self.addCleanup(self.temporary.cleanup)
        workspace = Path(self.temporary.name)
        self.root = workspace / "plugin"
        self.root.mkdir()
        self.runtime = workspace / "runtime"
        self.runtime.mkdir()
        source = Path(__file__).resolve().parent
        for filename in ("camera-control", "camera-config.py"):
            shutil.copy2(source / filename, self.root / filename)
        self.legacy = self.root / "camera.json"
        self.config = workspace / "config/omarchy/security-camera/cameras.json"
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(workspace / "config"), XDG_RUNTIME_DIR=str(self.runtime), PATH=f"{self.root}:{os.environ['PATH']}")
        self.addCleanup(lambda: self.run_control("stop"))

    def run_control(self, *args, data=None):
        return subprocess.run(
            [str(self.root / "camera-control"), *args],
            input=json.dumps(data) + "\n" if data is not None else None,
            text=True, capture_output=True, env=self.env, timeout=5,
        )

    def save(self, cameras, active):
        return self.run_control("save", data={"cameras": cameras, "activeId": active})

    def camera(self, camera_id="one", url="rtsp://user:p%40ss@192.0.2.1:554/live"):
        return {"id": camera_id, "name": "Camera " + camera_id, "url": url}

    def test_add_edit_select_and_remove_last_camera(self):
        first, second = self.camera(), self.camera("two", "rtsps://192.0.2.2/live")
        for cameras, active in (([first], "one"), ([first, second], "two")):
            self.assertEqual(self.save(cameras, active).returncode, 0)
            self.assertEqual(json.loads(self.config.read_text()), {"cameras": cameras, "activeId": active})
        first["url"] = "rtsp://new:secret@192.0.2.3:8554/stream?channel=2&subtype=0"
        self.assertEqual(self.save([first, second], "one").returncode, 0)
        self.assertEqual(self.save([second], "two").returncode, 0)
        self.assertEqual(self.save([], "").returncode, 0)
        self.assertEqual(self.run_control("stop").returncode, 0)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_invalid_save_preserves_existing_config(self):
        self.assertEqual(self.save([self.camera()], "one").returncode, 0)
        original = self.config.read_bytes()
        for url in ("https://192.0.2.1/live", "rtsp://", "rtsp://user:secret@host:bad/live", "rtsp://host/a b"):
            result = self.save([self.camera(url=url)], "one")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(url, result.stdout + result.stderr)
            self.assertEqual(self.config.read_bytes(), original)
        self.assertNotEqual(self.save([self.camera(), self.camera()], "one").returncode, 0)
        self.assertNotEqual(self.save([self.camera()], "missing").returncode, 0)
        self.assertEqual(self.config.read_bytes(), original)

    def test_stop_and_snapshot_do_not_require_config(self):
        self.assertEqual(self.run_control("stop").returncode, 0)
        self.assertNotEqual(self.run_control("snapshot", "a").returncode, 0)
        self.assertEqual(self.run_control("snapshot", "invalid").returncode, 2)

    def test_migration_and_saves_do_not_modify_plugin_files(self):
        data = {"cameras": [self.camera()], "activeId": "one"}
        self.legacy.write_text(json.dumps(data))
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.iterdir()}
        self.assertEqual(self.run_control("init").returncode, 0)
        self.assertEqual(json.loads(self.config.read_text()), data)
        second = self.camera("two")
        second["name"] = "Garage"
        self.assertEqual(self.save([self.camera(), second], "two").returncode, 0)
        self.assertEqual(self.run_control("init").returncode, 0)
        self.assertEqual(json.loads(self.config.read_text())["activeId"], "two")
        self.assertEqual(self.save([self.camera(), second], "one").returncode, 0)
        after = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.iterdir()}
        self.assertEqual(before, after)

    def test_preview_uses_legacy_and_selected_urls_and_releases_lock(self):
        ffmpeg = self.root / "ffmpeg"
        ffmpeg.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys, time\n"
            "root = pathlib.Path(os.environ['XDG_RUNTIME_DIR'])\n"
            "(root / 'arguments.json').write_text(json.dumps(sys.argv[1:]))\n"
            "pathlib.Path(sys.argv[-1]).write_bytes(b'test-frame')\n"
            "time.sleep(30)\n"
        )
        ffmpeg.chmod(0o700)
        legacy_url = "rtsp://legacy:secret@192.0.2.1/live"
        self.legacy.write_text(json.dumps({"name": "Existing", "url": legacy_url}))
        for url in (legacy_url, "rtsp://selected:secret@192.0.2.2/live"):
            if url != legacy_url:
                self.assertEqual(self.save([self.camera(), self.camera("two", url)], "two").returncode, 0)
            self.assertEqual(self.run_control("start").returncode, 0)
            arguments = self.runtime / "arguments.json"
            for _ in range(100):
                if arguments.exists() and url in arguments.read_text():
                    break
                time.sleep(0.01)
            values = json.loads(arguments.read_text())
            self.assertEqual(values[values.index("-i") + 1], url)
            self.assertEqual(self.run_control("snapshot", "a").returncode, 0)
            self.assertEqual((self.runtime / "omarchy-security-camera/display-a.jpg").read_bytes(), b"test-frame")
            self.assertEqual(self.run_control("stop").returncode, 0)


if __name__ == "__main__":
    unittest.main()
