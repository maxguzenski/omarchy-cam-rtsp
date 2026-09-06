#!/usr/bin/env python3
"""Validate and atomically save camera settings received over stdin."""

import json
import fcntl
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit


def config_path():
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "omarchy" / "security-camera" / "cameras.json"


def initialize(path):
    if path.exists():
        return
    legacy = Path(__file__).resolve().with_name("camera.json")
    data = json.loads(legacy.read_text()) if legacy.exists() else {"cameras": [], "activeId": ""}
    if "cameras" not in data:
        cameras = [{"id": "legacy", "name": data.get("name") or "Home camera", "url": data["url"]}] if data.get("url") else []
        data = {"cameras": cameras, "activeId": "legacy" if cameras else ""}
    save_config(path, data)


def save_config(path, data):
    cameras = data.get("cameras")
    if not isinstance(cameras, list):
        raise ValueError("Invalid camera list")
    ids = set()
    for camera in cameras:
        camera_id = camera.get("id")
        if not isinstance(camera_id, str) or not camera_id or camera_id in ids:
            raise ValueError("Invalid camera ID")
        ids.add(camera_id)
        url = camera.get("url", "")
        if not isinstance(url, str) or any(c.isspace() for c in url):
            raise ValueError("The RTSP URL cannot contain whitespace")
        try:
            parsed = urlsplit(url)
            valid = parsed.scheme in ("rtsp", "rtsps") and parsed.hostname and parsed.port != 0
        except ValueError:
            valid = False
        if not valid:
            raise ValueError("Enter a complete, valid RTSP URL")
        if not isinstance(camera.get("name"), str) or not camera["name"].strip():
            raise ValueError("Invalid camera name")
    if data.get("activeId") not in (ids if ids else {""}):
        raise ValueError("Select a valid camera")

    fd, temporary = tempfile.mkstemp(prefix=".camera-", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(data, output, ensure_ascii=False, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        path = config_path()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (path.parent / ".config.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if sys.argv[1:] == ["init"]:
                initialize(path)
                print(path)
            else:
                save_config(path, json.loads(sys.stdin.readline()))
    except (ValueError, TypeError, AttributeError, OSError):
        # Never echo a URL: it may contain the camera password.
        print("Could not save cameras. Check the data and configuration folder permissions.", file=sys.stderr)
        sys.exit(1)
