#!/usr/bin/env python3
"""Wyoming TTS server wrapping macOS `say` command.

Serves Wyoming protocol on TCP (default port 10200).
Receives Synthesize events, renders audio via `say`, streams back PCM.

Usage:
  python wyoming-say.py [--uri tcp://0.0.0.0:10200] [--voice Alex] [--rate 220]
"""

import argparse
import asyncio
import json
import logging
import os
import re
import subprocess
import tempfile
import wave
from functools import partial
from pathlib import Path
from typing import Optional

from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import Synthesize

_LOGGER = logging.getLogger(__name__)

# Audio format: 16kHz 16-bit signed LE mono (what Wyoming/HA expects)
RATE = 16000
WIDTH = 2  # bytes per sample
CHANNELS = 1
CHUNK_FRAMES = 1024  # frames per AudioChunk

# --- Text normalization (ported from claude-speak) ---

_rules = None
_rules_mtime = 0
_rules_file = None


def _init_rules(rules_path: str) -> None:
    global _rules_file
    _rules_file = rules_path


def _load_rules():
    global _rules, _rules_mtime
    if _rules_file is None or not os.path.exists(_rules_file):
        return []
    try:
        mtime = os.path.getmtime(_rules_file)
    except OSError:
        mtime = 0
    if _rules is not None and mtime == _rules_mtime:
        return _rules
    _LOGGER.info(
        "%s rules from %s",
        "Loading" if _rules is None else "Reloading",
        _rules_file,
    )
    _rules_mtime = mtime
    try:
        with open(_rules_file) as f:
            _rules = [r for r in json.load(f) if r.get("type")]
    except Exception as e:
        _LOGGER.warning("Rules load error: %s", e)
        _rules = []
    return _rules


def _spell_out(word):
    return " ".join(c.upper() for c in word if c.isalnum())


def _munge_path(m):
    path = m.group(0)
    path = re.sub(r"^[~/]+", "", path)
    path = path.replace(".", " dot ")
    path = path.replace("/", " ")
    return path.strip()


def filter_text(text: str) -> str:
    for rule in _load_rules():
        if not rule.get("enabled", True):
            continue
        t = rule.get("type")
        try:
            if t == "strip_re":
                text = re.sub(rule["pattern"], "", text, flags=re.IGNORECASE)
            elif t == "munge_path":
                text = re.sub(rule["pattern"], _munge_path, text)
            elif t == "replace":
                text = text.replace(rule["find"], rule["replacement"])
            elif t == "replace_re":
                flags = re.IGNORECASE if rule.get("ignore_case", False) else 0
                text = re.sub(
                    rule["pattern"], rule["replacement"], text, flags=flags
                )
            elif t == "spell_out":
                word = rule["word"]
                spoken = rule.get("spoken") or _spell_out(word)
                text = re.sub(
                    r"\b" + re.escape(word) + r"\b",
                    spoken,
                    text,
                    flags=re.IGNORECASE,
                )
        except Exception as e:
            _LOGGER.warning("Rule error (%s): %s", rule.get("description", t), e)
    return re.sub(r"  +", " ", text).strip()


# --- Available macOS voices ---


def _get_macos_voices() -> "list[TtsVoice]":
    """Parse `say -v '?'` to get available voices."""
    apple_attr = Attribution(name="Apple", url="https://apple.com")
    voices = []

    # Always include the system default as a named entry
    voices.append(
        TtsVoice(
            name="System Default",
            description="macOS System Default (current system voice)",
            attribution=apple_attr,
            version=None,
            languages=["en"],
            installed=True,
        )
    )

    try:
        result = subprocess.run(
            ["/usr/bin/say", "-v", "?"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in result.stdout.strip().splitlines():
            # Format: "Alex                en_US    # Most people ..."
            match = re.match(r"^(\S+)\s+(\S+)", line)
            if match:
                name = match.group(1)
                lang_code = match.group(2).replace("_", "-")
                lang = lang_code.split("-")[0]  # "en-US" -> "en"
                voices.append(
                    TtsVoice(
                        name=name,
                        description=f"macOS {name}",
                        attribution=apple_attr,
                        version=None,
                        languages=[lang],
                        installed=True,
                    )
                )
    except Exception as e:
        _LOGGER.warning("Could not enumerate voices: %s", e)
        voices.append(
            TtsVoice(
                name="default",
                description="macOS default voice",
                attribution=apple_attr,
                version=None,
                languages=["en"],
                installed=True,
            )
        )
    return voices


# --- Wyoming event handler ---


class SayTtsHandler(AsyncEventHandler):
    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        *,
        wyoming_info: Info,
        default_voice: Optional[str],
        speech_rate: int,
    ) -> None:
        super().__init__(reader, writer)
        self.wyoming_info = wyoming_info
        self.default_voice = default_voice
        self.speech_rate = speech_rate
        self._wyoming_info_event = self.wyoming_info.event()

        # Log incoming connection
        peername = writer.get_extra_info("peername")
        if peername:
            _LOGGER.info("Connection from %s:%s", peername[0], peername[1])
        else:
            _LOGGER.info("New connection")

    async def handle_event(self, event: Event) -> bool:
        if Describe.is_type(event.type):
            await self.write_event(self._wyoming_info_event)
            return True

        if not Synthesize.is_type(event.type):
            return True

        synthesize = Synthesize.from_event(event)
        raw_text = synthesize.text
        _LOGGER.info("Synthesize: %s", raw_text[:80])

        # Apply text normalization
        text = filter_text(raw_text)
        if text != raw_text:
            _LOGGER.debug("Normalized: %s", text[:80])

        if not text.strip():
            _LOGGER.warning("Empty text after normalization, skipping")
            return True

        # Determine voice
        voice = self.default_voice
        if synthesize.voice and synthesize.voice.name:
            voice = synthesize.voice.name
        # "System Default" and "Voice1" (HA's internal name) both mean: use system default, no -v
        if voice in ("System Default", "Voice1"):
            voice = None

        # Build say command
        cmd = ["/usr/bin/say"]
        if voice:
            cmd.extend(["-v", voice])
        cmd.extend(["-r", str(self.speech_rate)])

        # Render to temp WAV
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = tmp.name

        try:
            cmd.extend(["-o", tmp_path, f"--data-format=LEI16@{RATE}", text])
            _LOGGER.debug("Running: %s", " ".join(cmd))

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()

            if proc.returncode != 0:
                _LOGGER.error("say failed (%d): %s", proc.returncode, stderr.decode())
                return True

            # Read WAV and stream PCM
            with wave.open(tmp_path, "rb") as wf:
                assert wf.getframerate() == RATE
                assert wf.getsampwidth() == WIDTH
                assert wf.getnchannels() == CHANNELS

                await self.write_event(
                    AudioStart(rate=RATE, width=WIDTH, channels=CHANNELS).event()
                )

                while True:
                    frames = wf.readframes(CHUNK_FRAMES)
                    if not frames:
                        break
                    await self.write_event(
                        AudioChunk(
                            rate=RATE,
                            width=WIDTH,
                            channels=CHANNELS,
                            audio=frames,
                        ).event()
                    )

                await self.write_event(AudioStop().event())
                _LOGGER.info("Sent audio for: %s", raw_text[:60])

        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

        return True


# --- Main ---


def _load_app_config() -> dict:
    """Load shared config.json from project root (one level up from tts/)."""
    path = Path(__file__).parent.parent / "config.json"
    if path.exists():
        try:
            with open(path) as f:
                return json.load(f)
        except Exception as e:
            print(f"WARNING: could not parse {path}: {e}", flush=True)
    return {}


async def main() -> None:
    app_cfg = _load_app_config()
    tts_cfg = app_cfg.get("tts", {})
    cfg_host = app_cfg.get("host", "0.0.0.0")
    cfg_port = tts_cfg.get("port", 10200)
    cfg_voice = tts_cfg.get("voice") or os.environ.get("SAY_VOICE")
    cfg_rate = tts_cfg.get("rate") or int(os.environ.get("SAY_RATE", "220"))

    parser = argparse.ArgumentParser(description="Wyoming TTS server using macOS say")
    parser.add_argument(
        "--uri",
        default=f"tcp://{cfg_host}:{cfg_port}",
        help=f"Server URI (default: tcp://{cfg_host}:{cfg_port})",
    )
    parser.add_argument(
        "--voice",
        default=cfg_voice,
        help="Default macOS voice (default: from config.json or system default)",
    )
    parser.add_argument(
        "--rate",
        type=int,
        default=cfg_rate,
        help=f"Speech rate in WPM (default: {cfg_rate})",
    )
    parser.add_argument(
        "--rules",
        default=None,
        help="Path to speak-rules.json (default: auto-detect next to script)",
    )
    parser.add_argument(
        "--debug", action="store_true", help="Enable debug logging"
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s: %(message)s",
    )

    # Find rules file
    rules_path = args.rules
    if rules_path is None:
        rules_path = str(Path(__file__).parent / "speak-rules.json")
    if os.path.exists(rules_path):
        _init_rules(rules_path)
        _LOGGER.info("Using rules: %s", rules_path)
    else:
        _LOGGER.info("No rules file found, text normalization disabled")

    # Enumerate voices
    voices = _get_macos_voices()
    _LOGGER.info("Found %d macOS voices", len(voices))

    wyoming_info = Info(
        tts=[
            TtsProgram(
                name="apple-say",
                description="macOS native text-to-speech",
                attribution=Attribution(name="Apple", url="https://apple.com"),
                installed=True,
                version="1.0.0",
                voices=voices,
            )
        ],
    )

    server = AsyncServer.from_uri(args.uri)
    _LOGGER.info("Starting Wyoming TTS on %s", args.uri)

    await server.run(
        partial(
            SayTtsHandler,
            wyoming_info=wyoming_info,
            default_voice=args.voice,
            speech_rate=args.rate,
        )
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopping.", flush=True)
