"""X11 global key listener via the XRecord extension.

Sees BOTH physical keyboard events and XTEST-injected ones — Steam Input's
desktop layout injects controller-mapped keys (e.g. R3 -> Alt_R) via XTEST,
which never appears in /dev/input, so the evdev listener cannot see it.

Passive: does not grab keys or interfere with other clients.

Semantics mirror EvdevListener:
- Right Alt press-and-release with no other key in between -> toggle
- ESC press -> cancel
"""

from __future__ import annotations

import logging
import os
import threading

logger = logging.getLogger(__name__)

# Xlib.XK only exposes this after load_keysym_group("xkb"), which mutates
# module-global state, so spell the keysym out instead.
XK_ISO_LEVEL3_SHIFT = 0xFE03


class X11KeyListener:
    """Global X11 key listener using the XRecord extension."""

    def __init__(self, on_toggle, on_escape, on_keyboard=None) -> None:
        self.on_toggle = on_toggle
        self.on_escape = on_escape
        self.on_keyboard = on_keyboard
        self._thread: threading.Thread | None = None
        self._running = False
        self._record_dpy = None
        self._ctrl_dpy = None
        self._context = None
        self._right_alt_down = False
        self._other_key_pressed = False
        self._kc_toggle: frozenset[int] = frozenset()
        self._kc_escape = 0
        # For the Ctrl+Super+Shift chord that toggles the on-screen keyboard.
        # All modifier keys -> they never emit characters, so the passive
        # XRecord listener can't leak them into a focused terminal.
        self._kc_ctrl_l = 0
        self._kc_ctrl_r = 0
        self._kc_super_l = 0
        self._kc_super_r = 0
        self._kc_shift_l = 0
        self._kc_shift_r = 0
        self._chord_down: set[int] = set()
        self._chord_fired = False

    @staticmethod
    def is_available() -> bool:
        """X11 session with the RECORD extension present."""
        if not os.environ.get("DISPLAY"):
            return False
        try:
            from Xlib.display import Display

            d = Display()
            try:
                return d.has_extension("RECORD")
            finally:
                d.close()
        except Exception:
            return False

    def start(self) -> bool:
        """Start listening. Returns False if setup fails."""
        try:
            from Xlib import XK
            from Xlib.display import Display
            from Xlib.ext import record

            self._record_dpy = Display()
            self._ctrl_dpy = Display()

            self._kc_toggle = self._resolve_toggle_keycodes(XK)
            self._kc_escape = self._ctrl_dpy.keysym_to_keycode(XK.XK_Escape)
            self._kc_ctrl_l = self._ctrl_dpy.keysym_to_keycode(XK.XK_Control_L)
            self._kc_ctrl_r = self._ctrl_dpy.keysym_to_keycode(XK.XK_Control_R)
            self._kc_super_l = self._ctrl_dpy.keysym_to_keycode(XK.XK_Super_L)
            self._kc_super_r = self._ctrl_dpy.keysym_to_keycode(XK.XK_Super_R)
            self._kc_shift_l = self._ctrl_dpy.keysym_to_keycode(XK.XK_Shift_L)
            self._kc_shift_r = self._ctrl_dpy.keysym_to_keycode(XK.XK_Shift_R)

            from Xlib import X

            self._context = self._record_dpy.record_create_context(
                0,
                [record.AllClients],
                [
                    {
                        "core_requests": (0, 0),
                        "core_replies": (0, 0),
                        "ext_requests": (0, 0, 0, 0),
                        "ext_replies": (0, 0, 0, 0),
                        "delivered_events": (0, 0),
                        "device_events": (X.KeyPress, X.KeyRelease),
                        "errors": (0, 0),
                        "client_started": False,
                        "client_died": False,
                    }
                ],
            )
        except Exception as e:
            logger.warning("XRecord setup failed: %s", e)
            self._cleanup()
            return False

        self._running = True
        self._thread = threading.Thread(
            target=self._listen_loop, daemon=True
        )
        self._thread.start()
        return True

    def _resolve_toggle_keycodes(self, XK) -> frozenset[int]:
        """Keycodes for the physical right Alt key.

        Right Alt usually reports Alt_R, but on layouts that provide a
        third level -- us(altgr-intl), fr(azerty), de(nodeadkeys), ... --
        it emits ISO_Level3_Shift instead and nothing is bound to Alt_R
        at all. keysym_to_keycode() then returns 0, which matches no key,
        so dictation could never be toggled. Prefer Alt_R and only fall
        back to AltGr when the layout has no Alt_R, to avoid hijacking
        AltGr on layouts where both exist.

        A bare AltGr tap emits no character, and _handle_key() suppresses
        the toggle once another key is pressed, so AltGr+<key> accented
        input keeps working.
        """
        keycodes = {
            kc for kc, _index
            in self._ctrl_dpy.keysym_to_keycodes(XK.XK_Alt_R)
        }
        if keycodes:
            return frozenset(keycodes)

        keycodes = {
            kc for kc, _index
            in self._ctrl_dpy.keysym_to_keycodes(XK_ISO_LEVEL3_SHIFT)
        }
        if keycodes:
            logger.info(
                "Alt_R is unmapped on this layout; using ISO_Level3_Shift "
                "(AltGr, keycodes %s) to toggle dictation",
                sorted(keycodes),
            )
        else:
            logger.warning(
                "Neither Alt_R nor ISO_Level3_Shift is mapped; the "
                "dictation hotkey will be inactive"
            )
        return frozenset(keycodes)

    def stop(self) -> None:
        self._running = False
        if self._ctrl_dpy and self._context:
            try:
                self._ctrl_dpy.record_disable_context(self._context)
                self._ctrl_dpy.flush()
            except Exception:
                pass
        if self._thread:
            self._thread.join(timeout=2)
        self._cleanup()

    def _cleanup(self) -> None:
        for dpy in (self._record_dpy, self._ctrl_dpy):
            if dpy:
                try:
                    dpy.close()
                except Exception:
                    pass
        self._record_dpy = None
        self._ctrl_dpy = None
        self._context = None

    def _listen_loop(self) -> None:
        try:
            # Blocks until record_disable_context is called
            self._record_dpy.record_enable_context(
                self._context, self._on_record_reply
            )
            self._record_dpy.record_free_context(self._context)
        except Exception as e:
            if self._running:
                logger.warning("XRecord loop ended: %s", e)

    def _on_record_reply(self, reply) -> None:
        from Xlib import X
        from Xlib.ext import record
        from Xlib.protocol import rq

        if reply.category != record.FromServer:
            return
        if reply.client_swapped:
            return
        if not reply.data or reply.data[0] < 2:
            return

        data = reply.data
        while len(data):
            event, data = rq.EventField(None).parse_binary_value(
                data, self._record_dpy.display, None, None
            )
            if event.type == X.KeyPress:
                self._handle_key(event.detail, pressed=True)
            elif event.type == X.KeyRelease:
                self._handle_key(event.detail, pressed=False)

    def _handle_key(self, keycode: int, pressed: bool) -> None:
        # Track the modifier keys that make up the keyboard-toggle chord.
        chord_keys = (
            self._kc_ctrl_l, self._kc_ctrl_r,
            self._kc_super_l, self._kc_super_r,
            self._kc_shift_l, self._kc_shift_r,
        )
        if keycode in chord_keys:
            if pressed:
                self._chord_down.add(keycode)
            else:
                self._chord_down.discard(keycode)

        # Ctrl + Super + Shift (all held) -> toggle the on-screen keyboard.
        # Pure modifiers emit no characters, so nothing leaks to the terminal.
        down = self._chord_down
        chord_complete = (
            (self._kc_ctrl_l in down or self._kc_ctrl_r in down)
            and (self._kc_super_l in down or self._kc_super_r in down)
            and (self._kc_shift_l in down or self._kc_shift_r in down)
        )
        if not chord_complete:
            # Re-arm once the chord is broken so the next press can fire again.
            self._chord_fired = False
        elif pressed and not self._chord_fired and self.on_keyboard:
            self._chord_fired = True
            self.on_keyboard()
            # Don't let a right-Alt-held chord also fire dictation toggle.
            self._other_key_pressed = True
            return

        if keycode in self._kc_toggle:
            if pressed:
                self._right_alt_down = True
                self._other_key_pressed = False
            else:
                if self._right_alt_down and not self._other_key_pressed:
                    self.on_toggle()
                self._right_alt_down = False
        elif pressed:
            if self._right_alt_down:
                self._other_key_pressed = True
            if keycode == self._kc_escape:
                self.on_escape()
