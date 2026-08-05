"""State machine orchestrator for the recording lifecycle.

Mirrors TranscriptionManager.swift.

Key design decisions:
- GLib.idle_add() marshals callbacks from the asyncio thread to GTK main thread
- GLib.timeout_add() replaces DispatchQueue.main.asyncAfter for delayed execution
- State machine exactly mirrors macOS: idle -> starting -> recording -> stopping -> idle
"""

from __future__ import annotations

import logging

from gi.repository import GLib

from doubao_murmur.app_state import AppState, LoginStatus, RecordingState
from doubao_murmur.asr_client import ASRClient
from doubao_murmur.audio_capture import AudioCapture
from doubao_murmur.config import AUTH_EXPIRY_DELAY, STOP_SAFETY_TIMEOUT
from doubao_murmur.params_store import ASRParams, ParamsStore

logger = logging.getLogger(__name__)


def _is_http_auth_rejection(error) -> bool:
    """True if the WebSocket handshake was rejected with HTTP 401/403.

    Covers both websockets>=13 (InvalidStatus with .response.status_code)
    and older releases (InvalidStatusCode with .status_code). Anything
    else -- timeouts, DNS failures, connection resets -- is a network
    problem, not an auth problem.
    """
    status = getattr(error, "status_code", None)
    if status is None:
        response = getattr(error, "response", None)
        status = getattr(response, "status_code", None)
    return status in (401, 403)


class TranscriptionManager:
    """Orchestrates the recording lifecycle."""

    def __init__(self, app_state: AppState) -> None:
        self.app_state = app_state
        self.asr_client = ASRClient()
        self.audio_capture = AudioCapture()

        self.using_cached_params = False
        self.awaiting_final_result = False
        self.safety_timer_id: int | None = None

        # Pre-warmed WebSocket kept ready while idle so the hotkey can
        # start recognition instantly instead of paying the connect cost.
        self._warm_client: ASRClient | None = None
        self._warm_backoff = 2.0

        # Callbacks set by app.py
        self.on_auth_expired = None  # () -> None
        self.on_show_login = None  # () -> None
        self.on_params_needed = None  # (callback: (ASRParams|None)->None) -> None
        self.on_overlay_show = None  # () -> None
        self.on_overlay_hide = None  # () -> None
        self.on_overlay_update = None  # (text: str) -> None
        self.on_paste = None  # (text: str) -> None
        self.on_cancel_enabled_changed = None  # (enabled: bool) -> None

        self._wire_asr_callbacks()

    def _wire_asr_callbacks(self) -> None:
        """Wire ASR client callbacks to marshal from asyncio to GTK thread."""
        self.asr_client.on_open = lambda: GLib.idle_add(self._on_asr_open)
        self.asr_client.on_result = lambda text: GLib.idle_add(
            self._on_asr_result, text
        )
        self.asr_client.on_finish = lambda: GLib.idle_add(self._on_asr_finish)
        self.asr_client.on_error = lambda err: GLib.idle_add(
            self._on_asr_error, err
        )
        self.asr_client.on_auth_error = lambda: GLib.idle_add(
            self._on_auth_error
        )

    # --- Pre-connection ---

    def prewarm(self) -> None:
        """Open a standby WebSocket while idle (no-op if not possible)."""
        if self._warm_client is not None:
            return
        if self.app_state.recording_state != RecordingState.IDLE:
            return
        if self.app_state.login_status != LoginStatus.LOGGED_IN:
            return
        params = ParamsStore.load()
        if not params:
            return

        logger.info("Pre-warming ASR connection")
        client = ASRClient()
        client.on_open = lambda: GLib.idle_add(self._on_warm_open, client)
        client.on_error = lambda err: GLib.idle_add(
            self._on_warm_dead, client
        )
        client.on_auth_error = lambda: GLib.idle_add(self._on_auth_error)
        self._warm_client = client
        client.connect(params)

    def _on_warm_open(self, client: ASRClient) -> bool:
        if client is self._warm_client:
            self._warm_backoff = 2.0
            logger.info("Pre-warmed connection ready")
        return GLib.SOURCE_REMOVE

    def _on_warm_dead(self, client: ASRClient) -> bool:
        """Standby connection failed or was closed by the server."""
        if client is not self._warm_client:
            return GLib.SOURCE_REMOVE
        self._warm_client = None
        delay = self._warm_backoff
        self._warm_backoff = min(self._warm_backoff * 2, 300.0)
        logger.info("Pre-warmed connection lost, retrying in %.0fs", delay)
        GLib.timeout_add(int(delay * 1000), self._prewarm_cb)
        return GLib.SOURCE_REMOVE

    def _prewarm_cb(self) -> bool:
        self.prewarm()
        return GLib.SOURCE_REMOVE

    def _take_warm_client(self) -> ASRClient | None:
        """Adopt the standby connection if it is ready, else None."""
        client = self._warm_client
        if client is None or not client.is_connected:
            return None
        self._warm_client = None
        return client

    def _discard_warm_client(self) -> None:
        client = self._warm_client
        self._warm_client = None
        if client is not None:
            client.on_error = None
            client.disconnect()

    # --- Toggle ---

    def handle_toggle(self) -> None:
        """Called on GTK main thread from hotkey manager."""
        state = self.app_state.recording_state
        if state == RecordingState.IDLE:
            self._start_recording()
        elif state in (RecordingState.STARTING, RecordingState.RECORDING):
            self._stop_recording()
        # STOPPING: ignore

    def _start_recording(self) -> None:
        if self.app_state.login_status != LoginStatus.LOGGED_IN:
            logger.warning("Not logged in, showing login window")
            if self.on_show_login:
                self.on_show_login()
            return

        logger.info("Starting recording...")
        self._set_state(RecordingState.STARTING)
        self.app_state.transcription_text = ""
        self.app_state.error_message = None
        if self.on_overlay_show:
            self.on_overlay_show()

        # Adopt the pre-warmed connection if one is ready: recognition
        # starts immediately, no connect latency.
        warm = self._take_warm_client()
        if warm is not None:
            logger.info("Using pre-warmed ASR connection")
            self.asr_client = warm
            self._wire_asr_callbacks()
            self.using_cached_params = True
            try:
                self.audio_capture.start(
                    on_audio_data=self.asr_client.send_audio
                )
            except Exception as e:
                logger.error("Audio capture failed: %s", e)
                self.app_state.error_message = "麦克风启动失败"
                GLib.timeout_add(
                    int(AUTH_EXPIRY_DELAY * 1000), self._reset_to_idle
                )
                return
            self._set_state(RecordingState.RECORDING)
            return

        # Start audio immediately (buffered in ASR client until WS connects)
        try:
            self.audio_capture.start(on_audio_data=self.asr_client.send_audio)
        except Exception as e:
            logger.error("Audio capture failed: %s", e)
            self.app_state.error_message = "麦克风启动失败"
            GLib.timeout_add(
                int(AUTH_EXPIRY_DELAY * 1000), self._reset_to_idle
            )
            return

        # Try cached params first, fall back to WebView extraction
        cached = ParamsStore.load()
        if cached:
            logger.info("Using cached ASR params")
            self.using_cached_params = True
            self.asr_client.connect(cached)
        elif self.on_params_needed:
            self.using_cached_params = False
            self.on_params_needed(self._on_params_extracted)
        else:
            self.app_state.error_message = "无法获取连接参数，请重新登录"
            GLib.timeout_add(
                int(AUTH_EXPIRY_DELAY * 1000), self._reset_to_idle
            )

    def _stop_recording(self) -> None:
        logger.info("Stopping recording...")
        self._set_state(RecordingState.STOPPING)
        self.audio_capture.stop()
        self.asr_client.finish_sending()
        self.awaiting_final_result = True

        # Safety timeout
        self.safety_timer_id = GLib.timeout_add(
            int(STOP_SAFETY_TIMEOUT * 1000), self._safety_timeout
        )

    def _safety_timeout(self) -> bool:
        if self.app_state.recording_state == RecordingState.STOPPING:
            logger.info("Safety timeout, completing with current text")
            self.awaiting_final_result = False
            self._complete_transcription()
        self.safety_timer_id = None
        return GLib.SOURCE_REMOVE

    # --- ASR callbacks (on GTK main thread via GLib.idle_add) ---

    def _on_asr_open(self) -> bool:
        if self.app_state.recording_state == RecordingState.STARTING:
            self._set_state(RecordingState.RECORDING)
        return GLib.SOURCE_REMOVE

    def _on_asr_result(self, text: str) -> bool:
        self.app_state.transcription_text = text
        if self.on_overlay_update:
            self.on_overlay_update(text)
        if self.app_state.recording_state == RecordingState.STARTING:
            self._set_state(RecordingState.RECORDING)
        if self.awaiting_final_result:
            self.awaiting_final_result = False
            self._complete_transcription()
        return GLib.SOURCE_REMOVE

    def _on_asr_finish(self) -> bool:
        self.awaiting_final_result = False
        if self.app_state.recording_state in (
            RecordingState.STOPPING,
            RecordingState.RECORDING,
        ):
            self._complete_transcription()
        return GLib.SOURCE_REMOVE

    def _on_asr_error(self, error) -> bool:
        if self.app_state.recording_state == RecordingState.IDLE:
            return GLib.SOURCE_REMOVE
        logger.error("ASR error: %s", error)
        # Only treat the error as an auth problem when the server actively
        # rejected the handshake (HTTP 401/403). Network failures (timeouts,
        # DNS, resets) used to be lumped in here, which cleared perfectly
        # valid cached credentials and forced a re-login after every
        # transient connectivity hiccup. Real in-band auth errors arrive
        # via _on_auth_error instead.
        if self.using_cached_params and _is_http_auth_rejection(error):
            self._handle_auth_failure()
            return GLib.SOURCE_REMOVE
        self.app_state.error_message = "连接出错"
        GLib.timeout_add(int(AUTH_EXPIRY_DELAY * 1000), self._reset_to_idle)
        return GLib.SOURCE_REMOVE

    def _on_auth_error(self) -> bool:
        self._handle_auth_failure()
        return GLib.SOURCE_REMOVE

    # --- Completion & Reset ---

    def _complete_transcription(self) -> None:
        text = self.app_state.transcription_text.strip()
        logger.info("Completing transcription: '%s'", text[:50])
        if text and self.on_paste:
            self.on_paste(text)
        self._reset_to_idle()

    def _reset_to_idle(self) -> bool:
        self.awaiting_final_result = False
        self.audio_capture.stop()
        self.asr_client.disconnect()
        self._set_state(RecordingState.IDLE)
        self.app_state.error_message = None
        if self.on_overlay_hide:
            self.on_overlay_hide()
        self.using_cached_params = False
        # Clear text after short delay
        GLib.timeout_add(
            200, lambda: setattr(self.app_state, "transcription_text", "")
            or GLib.SOURCE_REMOVE
        )
        # Stand up the next warm connection for the following recording.
        GLib.timeout_add(500, self._prewarm_cb)
        return GLib.SOURCE_REMOVE

    def handle_cancel(self) -> None:
        if self.app_state.recording_state == RecordingState.IDLE:
            return
        logger.info("Cancelling transcription")
        self.awaiting_final_result = False
        self.audio_capture.stop()
        self.asr_client.disconnect()
        self._reset_to_idle()

    def _handle_auth_failure(self) -> None:
        logger.warning("Auth failure, clearing cached params")
        ParamsStore.clear()
        self._discard_warm_client()
        self.using_cached_params = False
        self.audio_capture.stop()
        self.asr_client.disconnect()
        self._reset_to_idle()
        self.app_state.login_status = LoginStatus.NOT_LOGGED_IN
        if self.on_auth_expired:
            self.on_auth_expired()

    def _set_state(self, new_state: RecordingState) -> None:
        self.app_state.recording_state = new_state
        if self.on_cancel_enabled_changed:
            self.on_cancel_enabled_changed(new_state != RecordingState.IDLE)

    def _on_params_extracted(self, params: ASRParams | None) -> None:
        """Called when WebView param extraction completes."""
        if params:
            ParamsStore.save(params)
            self.asr_client.connect(params)
        else:
            self.app_state.error_message = "无法获取连接参数，请重新登录"
            GLib.timeout_add(
                int(AUTH_EXPIRY_DELAY * 1000), self._reset_to_idle
            )
