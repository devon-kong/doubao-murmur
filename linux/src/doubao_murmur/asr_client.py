"""WebSocket client for Doubao's streaming ASR service.

Mirrors DoubaoASRClient.swift.

Design decisions:
- `websockets` library (pure Python, asyncio-native) replaces URLSessionWebSocketTask
- Runs on a dedicated asyncio event loop in a background thread to avoid blocking
  GTK's GLib main loop
- Callbacks are invoked on the asyncio thread; callers MUST use GLib.idle_add()
  to marshal back to GTK's main thread
- Audio buffering matches macOS behavior: buffer until connected, then flush
- send_audio uses asyncio.run_coroutine_threadsafe for thread-safe sends
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import threading
import uuid
from typing import Any
from urllib.parse import urlencode

from doubao_murmur.config import (
    AUDIO_SAMPLE_RATE,
    AUTH_ERROR_CODE,
    AUTH_ERROR_KEYWORDS,
    FIXED_QUERY_PARAMS,
    ORIGIN,
    STOP_TRAILING_SILENCE_MS,
    WSS_BASE_URL,
)
from doubao_murmur.params_store import ASRParams

logger = logging.getLogger(__name__)


class ASRClient:
    """WebSocket client for Doubao's streaming ASR service."""

    def __init__(self) -> None:
        self._ws: Any | None = None
        self._connected = False
        self._pending_audio: list[bytes] = []
        self._lock = threading.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None

        # Callbacks (called from asyncio thread - must use GLib.idle_add for GTK)
        self.on_open = None  # () -> None
        self.on_result = None  # (text: str) -> None
        self.on_finish = None  # () -> None
        self.on_error = None  # (error: Exception | None) -> None
        self.on_auth_error = None  # () -> None

    @property
    def is_connected(self) -> bool:
        return self._connected

    def connect(self, params: ASRParams) -> None:
        """Start WebSocket connection on a background asyncio loop."""
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(
            target=self._run_loop, args=(params,), daemon=True
        )
        self._thread.start()

    def _run_loop(self, params: ASRParams) -> None:
        """Run asyncio event loop in background thread."""
        asyncio.set_event_loop(self._loop)
        self._loop.run_until_complete(self._connect_and_listen(params))

    async def _connect_and_listen(self, params: ASRParams) -> None:
        """Build URL, connect, receive messages."""
        url = self._build_url(params)
        headers = {
            "Cookie": params.cookie_header,
            "Origin": ORIGIN,
        }

        logger.info("Connecting to ASR WebSocket...")
        try:
            websockets = _load_websockets()
            header_kwargs = _websocket_header_kwargs(
                websockets.connect, headers
            )
            connect_kwargs = dict(
                open_timeout=5,
                close_timeout=3,
                max_size=2**20,
                **header_kwargs,
            )
            # Race IPv4/IPv6 (happy eyeballs). Without this, a blackholed
            # IPv6 path (common on mobile hotspots) stalls the connect for
            # seconds before falling back to IPv4. Older websockets/Python
            # don't forward the kwarg, hence the TypeError fallback.
            try:
                ws = await websockets.connect(
                    url, happy_eyeballs_delay=0.25, **connect_kwargs
                )
            except TypeError:
                ws = await websockets.connect(url, **connect_kwargs)
            try:
                self._ws = ws
                self._connected = True
                logger.info("Connected")

                # Flush buffered audio
                self._flush_audio_buffer()

                if self.on_open:
                    self.on_open()

                # Receive loop
                async for message in ws:
                    self._handle_message(message)
            finally:
                await ws.close()

        except Exception as e:
            if _is_connection_closed_error(e):
                logger.warning("WebSocket closed: %s", e)
                if self._connected:
                    self._connected = False
                    if self.on_error:
                        self.on_error(e)
            else:
                logger.error("WebSocket error: %s", e)
                self._connected = False
                if self.on_error:
                    self.on_error(e)

    def _build_url(self, params: ASRParams) -> str:
        """Construct the full WSS URL with query parameters."""
        query = dict(FIXED_QUERY_PARAMS)
        query["device_id"] = params.device_id
        query["web_id"] = params.web_id
        query["tea_uuid"] = params.web_id
        query["web_tab_id"] = str(uuid.uuid4())
        return f"{WSS_BASE_URL}?{urlencode(query)}"

    def send_audio(self, data: bytes) -> None:
        """Send PCM audio data. Thread-safe. Buffers if not connected."""
        with self._lock:
            if self._connected and self._ws:
                if self._loop and self._loop.is_running():
                    asyncio.run_coroutine_threadsafe(
                        self._ws.send(data), self._loop
                    )
            else:
                self._pending_audio.append(data)

    def finish_sending(
        self, trailing_silence_ms: int = STOP_TRAILING_SILENCE_MS
    ) -> None:
        """Signal no more mic audio; keep WS open for the final results.

        Flushes a short tail of digital silence first. The service emits exactly
        one result per audio message it receives and withholds the last word until
        further audio arrives, so a stream that simply stops never gets its tail
        transcribed. The padding is queued at once rather than paced in real time,
        so it costs no extra wall-clock time.
        """
        with self._lock:
            self._pending_audio.clear()
            ws = self._ws
            was_connected = self._connected
            self._connected = False

        if was_connected and ws and trailing_silence_ms > 0:
            if self._loop and self._loop.is_running():
                chunk_ms = 100
                silence = bytes(AUDIO_SAMPLE_RATE * 2 * chunk_ms // 1000)
                for _ in range(max(1, trailing_silence_ms // chunk_ms)):
                    asyncio.run_coroutine_threadsafe(ws.send(silence), self._loop)

        logger.info(
            "Finished sending audio (+%dms silence), waiting for final results",
            trailing_silence_ms,
        )

    def disconnect(self) -> None:
        """Close the WebSocket."""
        self._connected = False
        with self._lock:
            self._pending_audio.clear()
        if self._ws and self._loop and self._loop.is_running():
            asyncio.run_coroutine_threadsafe(
                self._ws.close(1000, "1000-"), self._loop
            )
        self._ws = None
        logger.info("Disconnected")

    def _flush_audio_buffer(self) -> None:
        with self._lock:
            buffered = list(self._pending_audio)
            self._pending_audio.clear()
        if buffered:
            logger.info("Flushing %d buffered audio chunks", len(buffered))
            for chunk in buffered:
                if self._ws and self._loop and self._loop.is_running():
                    asyncio.run_coroutine_threadsafe(
                        self._ws.send(chunk), self._loop
                    )

    def _handle_message(self, message) -> None:
        """Parse JSON message from server."""
        if isinstance(message, bytes):
            message = message.decode("utf-8", errors="replace")

        try:
            data = json.loads(message)
        except json.JSONDecodeError:
            return

        code = data.get("code", 0)
        event = data.get("event", "")
        msg = data.get("message", "")

        # Detect auth errors
        if code != 0:
            lower_msg = msg.lower()
            if code == AUTH_ERROR_CODE or any(
                kw in lower_msg for kw in AUTH_ERROR_KEYWORDS
            ):
                logger.warning(
                    "Auth error detected: code=%d, message=%s", code, msg
                )
                self._connected = False
                if self.on_auth_error:
                    self.on_auth_error()
                return

        if event == "result":
            result = data.get("result") or {}
            text = result.get("Text", "")
            if text and self.on_result:
                self.on_result(text)
        elif event == "finish":
            logger.info("Received finish event")
            if self.on_finish:
                self.on_finish()


def _load_websockets():
    try:
        import websockets
    except Exception as e:
        raise RuntimeError(
            "websockets is not available; install the Python websockets "
            "package before recording"
        ) from e
    return websockets


def _websocket_header_kwargs(connect_func, headers: dict[str, str]) -> dict:
    """Return the correct header kwarg for installed websockets version."""
    try:
        params = inspect.signature(connect_func).parameters
    except (TypeError, ValueError):
        return {"additional_headers": headers}
    if "additional_headers" in params:
        return {"additional_headers": headers}
    return {"extra_headers": headers}


def _is_connection_closed_error(error: Exception) -> bool:
    return error.__class__.__name__.startswith("ConnectionClosed")
