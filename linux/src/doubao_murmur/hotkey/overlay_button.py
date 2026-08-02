"""Always-on-top push-to-talk button (GTK4).

CURRENTLY UNUSED. Removed from the UI in 6555ffa as Steam-Deck-specific
clutter on a desktop; app.py passes overlay_button=None. Kept because it is
the one trigger that works on a Wayland session without /dev/input access —
if Wayland support is taken further, start here.

Design:
- Positioned at bottom-center of screen (near game UI on Steam Deck)
- Semi-transparent, minimal footprint (60x60px)
- Shows only when app is logged in
- Click/tap to toggle recording
- Contains a small cancel area when recording is active
"""

from __future__ import annotations

import logging

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gtk

from doubao_murmur.config import PTT_BUTTON_SIZE
from doubao_murmur.ui.windowing import (
    OverlayRole,
    apply_overlay_window_hints,
    present_overlay,
)

logger = logging.getLogger(__name__)

_PTT_CSS = b"""
.ptt-window {
    background: transparent;
}
.ptt-button {
    background: rgba(40, 40, 40, 0.85);
    border-radius: 35px;
    border: 2px solid rgba(255, 255, 255, 0.3);
    color: white;
    font-size: 24px;
    min-width: 60px;
    min-height: 60px;
    padding: 0;
}
.ptt-button:hover {
    background: rgba(60, 60, 60, 0.9);
}
.ptt-button.recording {
    background: rgba(200, 40, 40, 0.85);
    border-color: rgba(255, 100, 100, 0.6);
}
"""


class OverlayButton:
    """Small always-on-top push-to-talk button."""

    def __init__(self, on_press, on_cancel) -> None:
        self.on_press = on_press
        self.on_cancel = on_cancel
        self._window: Gtk.Window | None = None
        self._button: Gtk.Button | None = None

    def create(self) -> None:
        """Create the GTK window and button."""
        self._window = Gtk.Window()
        self._window.set_title("Doubao Murmur PTT")
        self._window.set_decorated(False)
        self._window.set_default_size(PTT_BUTTON_SIZE + 10, PTT_BUTTON_SIZE + 10)
        self._window.set_resizable(False)
        self._window.add_css_class("ptt-window")
        apply_overlay_window_hints(self._window, OverlayRole.PTT)

        # Create circular button
        self._button = Gtk.Button()
        self._button.add_css_class("ptt-button")
        self._button.set_label("\U0001f3a4")  # 🎤
        self._button.connect("clicked", self._on_clicked)
        self._window.set_child(self._button)

        # Key press handler for ESC
        key_controller = Gtk.EventControllerKey()
        key_controller.connect("key-pressed", self._on_key_pressed)
        self._window.add_controller(key_controller)

        # Apply CSS
        display = Gdk.Display.get_default()
        if display:
            provider = Gtk.CssProvider()
            provider.load_from_data(_PTT_CSS)
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def _on_clicked(self, _button) -> None:
        self.on_press()

    def _on_key_pressed(self, controller, keyval, keycode, state) -> bool:
        if keyval == Gdk.KEY_Escape:
            self.on_cancel()
            return True
        return False

    def show(self) -> None:
        if self._window:
            present_overlay(self._window, OverlayRole.PTT)

    def hide(self) -> None:
        if self._window:
            self._window.set_visible(False)

    def set_recording_state(self, is_recording: bool) -> None:
        """Update button visual state."""
        if self._button:
            if is_recording:
                self._button.add_css_class("recording")
                self._button.set_label("⏹")  # ⏹
            else:
                self._button.remove_css_class("recording")
                self._button.set_label("\U0001f3a4")  # 🎤
