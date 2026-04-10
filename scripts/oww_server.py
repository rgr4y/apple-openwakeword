#!/usr/bin/env python3
"""Minimal Wyoming wake word server using openwakeword + onnxruntime.

Works on macOS (no tflite needed — openwakeword uses ONNX automatically
when tflite-runtime is not available).

Wyoming protocol:
  Client sends: audio-start, audio-chunk*, audio-stop  (or just chunks)
  Server sends: detection  when wake word fires
  Server sends: info       in response to describe
"""

import argparse
import asyncio
import logging
import struct
import json
import numpy as np
from functools import partial

_LOGGER = logging.getLogger(__name__)

RATE = 16000
WIDTH = 2       # int16
CHANNELS = 1
CHUNK_MS = 80   # OWW expects 80ms frames
CHUNK_SAMPLES = int(RATE * CHUNK_MS / 1000)  # 1280 samples


# ---------------------------------------------------------------------------
# Wyoming wire codec (no external dep — mirrors WyomingProtocol.swift)
# ---------------------------------------------------------------------------

def encode_event(type_: str, data: dict = None, payload: bytes = None) -> bytes:
    header = {"type": type_, "version": "1.0"}
    data_bytes = b""
    if data:
        data_bytes = json.dumps(data, separators=(",", ":"), sort_keys=True).encode()
        header["data_length"] = len(data_bytes)
    if payload:
        header["payload_length"] = len(payload)
    header_bytes = json.dumps(header, separators=(",", ":"), sort_keys=True).encode()
    return header_bytes + b"\n" + data_bytes + (payload or b"")


def decode_event(buf: bytes):
    """Return (type, data, payload, bytes_consumed) or None if incomplete."""
    nl = buf.find(b"\n")
    if nl < 0:
        return None
    try:
        header = json.loads(buf[:nl])
    except Exception:
        return None
    offset = nl + 1
    data = header.get("data") or {}
    dl = header.get("data_length", 0)
    if dl:
        if len(buf) < offset + dl:
            return None
        data.update(json.loads(buf[offset:offset + dl]))
        offset += dl
    payload = None
    pl = header.get("payload_length", 0)
    if pl:
        if len(buf) < offset + pl:
            return None
        payload = buf[offset:offset + pl]
        offset += pl
    return header["type"], data, payload, offset


# ---------------------------------------------------------------------------
# OWW wrapper
# ---------------------------------------------------------------------------

def load_model(model_name: str):
    import openwakeword
    from openwakeword.model import Model
    _LOGGER.info("Downloading/loading model: %s", model_name)
    openwakeword.utils.download_models(model_names=[model_name])
    return Model(wakeword_models=[model_name], inference_framework="onnx")


def build_info_event(model_name: str) -> bytes:
    info = {
        "wake": [{
            "name": "apple-openwakeword",
            "description": "Apple Mac wake word detection (openWakeWord/ONNX)",
            "attribution": {"name": "dscripka", "url": "https://github.com/dscripka/openWakeWord"},
            "installed": True,
            "version": "1.0.0",
            "models": [{
                "name": model_name,
                "description": model_name.replace("_", " "),
                "attribution": {"name": "dscripka", "url": "https://github.com/dscripka/openWakeWord"},
                "installed": True,
                "version": "1.0.0",
                "languages": ["en"],
                "phrase": model_name.replace("_", " "),
            }]
        }]
    }
    return encode_event("info", info)


# ---------------------------------------------------------------------------
# Per-connection handler
# ---------------------------------------------------------------------------

class Session:
    def __init__(self, reader, writer, model, model_name, threshold):
        self.reader = reader
        self.writer = writer
        self.model = model
        self.model_name = model_name
        self.threshold = threshold
        self._buf = b""
        self._audio_buf = np.array([], dtype=np.int16)
        self._chunks_received = 0
        self._bytes_received = 0
        self._frames_processed = 0
        self._last_stats_time = asyncio.get_event_loop().time()
        peer = writer.get_extra_info("peername")
        _LOGGER.info("Connection from %s:%s", peer[0] if peer else "?", peer[1] if peer else "?")

    async def run(self):
        try:
            while True:
                chunk = await self.reader.read(65536)
                if not chunk:
                    break
                self._buf += chunk
                while True:
                    result = decode_event(self._buf)
                    if result is None:
                        break
                    type_, data, payload, consumed = result
                    self._buf = self._buf[consumed:]
                    await self._handle(type_, data, payload)
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass
        finally:
            self.writer.close()

    async def _handle(self, type_: str, data: dict, payload: bytes):
        if type_ == "describe":
            _LOGGER.debug("← describe")
            info_bytes = build_info_event(self.model_name)
            self.writer.write(info_bytes)
            await self.writer.drain()

        elif type_ == "ping":
            self.writer.write(encode_event("pong"))
            await self.writer.drain()

        elif type_ == "audio-start":
            _LOGGER.info("← audio-start: %s", {k: v for k, v in data.items() if k not in ("type", "version")})
            self._chunks_received = 0
            self._bytes_received = 0
            self._frames_processed = 0
            self._last_stats_time = asyncio.get_event_loop().time()
            if payload:
                self._ingest_audio(payload)

        elif type_ in ("audio-chunk", "audio-stop"):
            if payload:
                self._ingest_audio(payload)

    def _ingest_audio(self, payload: bytes):
        samples = np.frombuffer(payload, dtype=np.int16)
        self._chunks_received += 1
        self._bytes_received += len(payload)
        if self._chunks_received == 1:
            _LOGGER.info("← first audio-chunk: %d bytes, %d samples", len(payload), len(samples))
        self._audio_buf = np.concatenate([self._audio_buf, samples])
        # Process in 80ms frames
        frames_this_batch = 0
        while len(self._audio_buf) >= CHUNK_SAMPLES:
            frame = self._audio_buf[:CHUNK_SAMPLES]
            self._audio_buf = self._audio_buf[CHUNK_SAMPLES:]
            self._frames_processed += 1
            frames_this_batch += 1
            asyncio.get_event_loop().create_task(self._predict(frame))
        # Periodic stats every 5s
        now = asyncio.get_event_loop().time()
        if now - self._last_stats_time >= 5.0:
            kb = self._bytes_received / 1024
            _LOGGER.debug("← audio stats: %d chunks, %.1f KB, %d frames processed",
                          self._chunks_received, kb, self._frames_processed)
            self._last_stats_time = now


    async def _predict(self, frame: np.ndarray):
        # Run in executor so we don't block the event loop
        loop = asyncio.get_event_loop()
        predictions = await loop.run_in_executor(None, self.model.predict, frame)
        for name, score in predictions.items():
            if score >= self.threshold:
                _LOGGER.info("*** WAKE WORD: %s (score=%.3f) ***", name, score)
                det = encode_event("detection", {
                    "name": name,
                    "score": float(score),
                    "timestamp": None,
                })
                self.writer.write(det)
                await self.writer.drain()
                # Reset model state after detection
                self.model.reset()


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=10400)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--model", default="alexa")
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s: %(message)s",
    )

    model = load_model(args.model)
    _LOGGER.info("Model loaded: %s", args.model)

    async def handle(reader, writer):
        session = Session(reader, writer, model, args.model, args.threshold)
        await session.run()

    server = await asyncio.start_server(handle, args.host, args.port)
    _LOGGER.info("apple-openwakeword server listening on %s:%d (model=%s, threshold=%.2f)",
                 args.host, args.port, args.model, args.threshold)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopping.")
