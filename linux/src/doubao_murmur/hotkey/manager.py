"""Hotkey manager: coordinates input methods for triggering recording.

On Wayland, global hotkeys are restricted. We use:
1. PRIMARY: Always-on-top GTK push-to-talk button (OverlayButton)
2. OPTIONAL: evdev /dev/input listener (requires input group)
"""

from __future__ import annotations

import logging
import time

from gi.repository import GLib

from doubao_murmur.config import DEBOUNCE_INTERVAL

logger = logging.getLogger(__name__)


class HotkeyManager:
    """Coordinates input methods for triggering recording."""

    def __init__(self) -> None:
        self.on_toggle = None  # () -> None
        self.on_cancel = None  # () -> None
        self.on_keyboard = None  # () -> None (toggle on-screen keyboard)
        self._overlay_button = None
        self._evdev_listener = None
        self._x11_listener = None
        self._cancel_enabled = False
        self._last_toggle_time = 0.0
        self._last_keyboard_time = 0.0

    def start(
        self, overlay_button=None, evdev_listener=None, x11_listener=None
    ) -> None:
        """Initialize input backends."""
        self._overlay_button = overlay_button
        self._evdev_listener = evdev_listener
        self._x11_listener = x11_listener

        if self._x11_listener:
            if self._x11_listener.start():
                logger.info("X11 key listener active")
            else:
                logger.warning("X11 key listener failed to start")
                self._x11_listener = None

        if self._evdev_listener:
            if self._evdev_listener.start():
                logger.info("evdev listener active")
            else:
                logger.warning("evdev not available (need input group?)")
                self._evdev_listener = None

    def stop(self) -> None:
        """Stop all input backends."""
        if self._x11_listener:
            self._x11_listener.stop()
        if self._evdev_listener:
            self._evdev_listener.stop()

    @property
    def has_global_hotkey(self) -> bool:
        """True when a global hotkey backend is active."""
        return (
            self._evdev_listener is not None
            or self._x11_listener is not None
        )

    def trigger_toggle(self) -> None:
        """Called by input backends, possibly from non-GTK threads.

        Debounced, then marshalled to the GTK main thread — GTK4 is not
        thread-safe and the evdev listener runs on its own thread.
        """
        now = time.monotonic()
        if now - self._last_toggle_time < DEBOUNCE_INTERVAL:
            return
        self._last_toggle_time = now
        GLib.idle_add(self._dispatch_toggle)

    def trigger_cancel(self) -> None:
        """Called by input backends for cancel (ESC)."""
        if self._cancel_enabled:
            GLib.idle_add(self._dispatch_cancel)

    def trigger_keyboard(self) -> None:
        """Called by input backends for the on-screen-keyboard hotkey.

        Debounced so key auto-repeat (holding the chord) toggles once.
        """
        now = time.monotonic()
        if now - self._last_keyboard_time < DEBOUNCE_INTERVAL:
            return
        self._last_keyboard_time = now
        GLib.idle_add(self._dispatch_keyboard)

    def _dispatch_keyboard(self) -> bool:
        if self.on_keyboard:
            self.on_keyboard()
        return GLib.SOURCE_REMOVE

    def _dispatch_toggle(self) -> bool:
        if self.on_toggle:
            self.on_toggle()
        return GLib.SOURCE_REMOVE

    def _dispatch_cancel(self) -> bool:
        if self._cancel_enabled and self.on_cancel:
            self.on_cancel()
        return GLib.SOURCE_REMOVE

    def set_cancel_enabled(self, enabled: bool) -> None:
        self._cancel_enabled = enabled
