"""Query the active window's class on KDE Plasma Wayland via KWin scripting.

On Wayland there is no _NET_ACTIVE_WINDOW: xdotool can only see XWayland
windows and its ``getactivewindow`` fails outright under KWin. KWin's
scripting API is the supported way to ask the compositor. We load a
one-shot script that prints the active window's resourceClass, run it,
and read the line back from the user journal (KWin scripts can only
"print", which lands in kwin_wayland's log).

Inside Flatpak the session-bus name org.kde.KWin is not in our talk
list, so the whole probe runs on the host via ``flatpak-spawn --host``
(already granted for the paste tooling).
"""

from __future__ import annotations

import logging
import subprocess

from doubao_murmur.host_tools import command_candidates

logger = logging.getLogger(__name__)

_MARKER = "MURMUR_ACTIVE_CLASS="
_PLUGIN = "murmur-activewin"

# Single host-side shell script: write the KWin JS to a temp file, load +
# run + unload it, then fish the printed line out of the user journal.
_PROBE = r"""
set -e
f=$(mktemp /tmp/murmur-activewin-XXXXXX.js)
trap 'rm -f "$f"' EXIT
printf '%s' 'let c = workspace.activeWindow; print("MURMUR_ACTIVE_CLASS=" + (c ? c.resourceClass : ""));' > "$f"
qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript MURMUR_PLUGIN >/dev/null 2>&1 || true
n=$(qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$f" MURMUR_PLUGIN)
qdbus org.kde.KWin "/Scripting/Script$n" org.kde.kwin.Script.run
sleep 0.3
qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript MURMUR_PLUGIN >/dev/null 2>&1 || true
journalctl --user -n 100 --no-pager -o cat 2>/dev/null | grep -F MURMUR_MARKER | tail -1
""".replace("MURMUR_PLUGIN", _PLUGIN).replace("MURMUR_MARKER", _MARKER)


def active_window_class() -> str:
    """Lowercased resourceClass of the focused window, or "" on failure."""
    for command in command_candidates("sh"):
        try:
            result = subprocess.run(
                command + ["-c", _PROBE],
                capture_output=True,
                timeout=5,
            )
            for line in result.stdout.decode().splitlines():
                if _MARKER in line:
                    value = line.rsplit(_MARKER, 1)[1].strip().lower()
                    if value:
                        return value
        except Exception as e:  # noqa: BLE001 - fall through to next candidate
            logger.debug("KWin active window probe failed: %s", e)
    return ""
