# Omarchy Cam RTSP

A security camera plugin for the Quickshell-based Omarchy shell. View an RTSP
camera in a bar popup and open a larger live view in MPV.

![Omarchy Cam RTSP popup with camera tabs, a live preview, and camera management controls](docs/camera-preview.png)

## Features

- Add, edit, and remove cameras from the **+** button.
- Give each camera a name and paste its complete RTSP URL into one field.
- Switch between registered cameras in the popup.
- Open the selected camera in MPV from the expand button or by clicking its image.
- Close the popup by clicking outside, pressing Escape, or clicking the bar icon.

The interface is in English. The popup uses periodically
refreshed images; MPV provides the full video view. Audio is disabled.

## Requirements

- Omarchy with the Quickshell shell and its plugin system, including `qs.Ui.KeyboardPanel`.
- `ffmpeg`, `mpv`, `jq`, `python3`, and `flock` (from `util-linux`) on `PATH`.
- Network access to an RTSP camera.

This plugin is for the Quickshell-based shell, not the older Waybar setup.

## Installation

```bash
omarchy plugin add https://github.com/maxguzenski/omarchy-cam-rtsp --enable
```

The plugin ID is `maxguzenski.cam-rtsp`. Click its camera icon in the bar, then
**+ → Add camera**. Enter a name and the URL supplied by your camera, such as:

```text
rtsp://USERNAME:PASSWORD@CAMERA_HOST:554/STREAM_PATH
```

Use the edit icon to change either the name or URL. Removing a camera requires
confirming the removal in its row. Percent-encode reserved characters in URL
credentials where necessary.

To update:

```bash
omarchy plugin update maxguzenski.cam-rtsp
```

When upgrading an installation that used the previous plugin ID, rename its
installed directory to `~/.config/omarchy/plugins/maxguzenski.cam-rtsp` and replace
the old ID in your Omarchy bar configuration with `maxguzenski.cam-rtsp`.
Camera registrations remain in the same location and do not need to be entered again.

## Local data and privacy

Camera registrations are stored in:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/security-camera/cameras.json
```

This file contains names and complete URLs, including any credentials. It is
stored locally with file mode `0600`; it is not encrypted. The configuration lives
outside the plugin directory so changing cameras does not trigger Omarchy's
plugin code reload watcher.

An older `camera.json` inside the plugin directory is imported on first use if
the new configuration does not exist. The original file is kept untouched and
excluded from Git. New installations start with no cameras.

Preview frames, process information, and FFmpeg logs live under
`$XDG_RUNTIME_DIR/omarchy-security-camera`. Avoid sharing these files: images may
show private areas and diagnostic output may include camera connection details.
Stream URLs are passed to FFmpeg and MPV as process arguments, so processes with
permission to inspect those arguments can see them.

No camera registrations, real credentials, or network addresses are included in
this repository. The screenshot above is included with the owner's permission.
Addresses and credentials in the automated tests
are synthetic fixtures; test IPs use the documentation-only `192.0.2.0/24` range.

## Development

```bash
python3 -B test_camera_control.py
bash -n camera-control
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell Panel.qml BarWidget.qml
```

Tests use temporary directories and a simulated FFmpeg process. They do not
connect to real cameras or modify your camera registrations.

Before committing, inspect `git diff --cached` and `git ls-files`. Never force-add
local camera configuration, credentials, logs, or captures. If reporting a bug,
replace camera URLs and network details with placeholders.
