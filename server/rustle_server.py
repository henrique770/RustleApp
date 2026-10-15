"""rustle-server: local transcription + formatting service for RustleApp.

Plays the role of Wispr Flow's cloud TranscriptionService (transcriber -> formatter),
but runs on your machine with an open-source Whisper model.

    POST /v1/dictate  {"audio_wav_b64": "...", "context": {...}}  ->  {"raw", "text", "formatter", "latency_ms"}
    GET  /health
"""

from __future__ import annotations

import base64
import io
import logging
import os
import time
import wave
from typing import Optional

import numpy as np
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from formatter import Formatter, SettingsStore

log = logging.getLogger("rustle")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

WHISPER_MODEL = os.environ.get("RUSTLE_WHISPER_MODEL", "base.en")
WHISPER_DEVICE = os.environ.get("RUSTLE_WHISPER_DEVICE", "cpu")
WHISPER_COMPUTE = os.environ.get("RUSTLE_WHISPER_COMPUTE", "int8")
# Default language, e.g. "pt" or "en"; empty means auto-detect. A request can override it.
WHISPER_LANGUAGE = os.environ.get("RUSTLE_LANGUAGE") or None
MAX_AUDIO_SECONDS = 600
# Bumped when the app/server contract changes; the desktop app restarts older servers.
API_VERSION = 3


class Context(BaseModel):
    appName: Optional[str] = None
    bundleId: Optional[str] = None
    beforeText: Optional[str] = None
    selectedText: Optional[str] = None
    afterText: Optional[str] = None


class DictateRequest(BaseModel):
    audio_wav_b64: str
    context: Optional[Context] = None
    language: Optional[str] = None  # "pt", "en", ... or "auto"


class DictateResponse(BaseModel):
    raw: str
    text: str
    formatter: str
    latency_ms: int


class Transcriber:
    def __init__(self) -> None:
        from faster_whisper import WhisperModel

        log.info("Loading Whisper model %s (%s/%s)", WHISPER_MODEL, WHISPER_DEVICE, WHISPER_COMPUTE)
        self.model = WhisperModel(WHISPER_MODEL, device=WHISPER_DEVICE, compute_type=WHISPER_COMPUTE)

    def transcribe(self, audio: np.ndarray, vocabulary: list[str], language: Optional[str]) -> str:
        # Personal dictionary words bias recognition, like Wispr's StaticVocabulary.
        prompt = ", ".join(vocabulary[:100]) or None
        segments, _ = self.model.transcribe(
            audio,
            beam_size=5,
            language=None if WHISPER_MODEL.endswith(".en") else language,
            vad_filter=True,
            initial_prompt=prompt,
            condition_on_previous_text=False,
        )
        return " ".join(s.text.strip() for s in segments).strip()


def decode_wav(data: bytes) -> np.ndarray:
    try:
        with wave.open(io.BytesIO(data)) as w:
            if w.getsampwidth() != 2 or w.getnchannels() != 1 or w.getframerate() != 16000:
                raise ValueError("expected 16 kHz mono PCM16 WAV")
            if w.getnframes() > MAX_AUDIO_SECONDS * 16000:
                raise ValueError("audio too long")
            frames = w.readframes(w.getnframes())
    except (wave.Error, EOFError) as e:
        raise ValueError(f"invalid WAV: {e}") from e
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


app = FastAPI(title="rustle-server")
formatter = Formatter(SettingsStore())
transcriber: Optional[Transcriber] = None


@app.on_event("startup")
def _load() -> None:
    global transcriber
    transcriber = Transcriber()


@app.get("/health")
def health() -> dict:
    return {"ok": transcriber is not None, "api_version": API_VERSION, "model": WHISPER_MODEL, "language": WHISPER_LANGUAGE or "auto",
            "llm": formatter.llm_enabled}


@app.post("/v1/dictate", response_model=DictateResponse)
def dictate(req: DictateRequest) -> DictateResponse:
    if transcriber is None:
        raise HTTPException(503, "model not loaded")
    started = time.perf_counter()
    try:
        audio = decode_wav(base64.b64decode(req.audio_wav_b64, validate=True))
    except ValueError as e:
        raise HTTPException(400, str(e)) from e

    language = req.language if req.language else WHISPER_LANGUAGE
    if language == "auto":
        language = None
    raw = transcriber.transcribe(audio, formatter.settings.dictionary, language)
    ctx = req.context.model_dump() if req.context else {}
    text, used = formatter.format(raw, ctx)
    latency = int((time.perf_counter() - started) * 1000)
    log.info("dictation app=%s raw_len=%d out_len=%d formatter=%s %dms",
             ctx.get("bundleId"), len(raw), len(text), used, latency)
    return DictateResponse(raw=raw, text=text, formatter=used, latency_ms=latency)


@app.post("/v1/shutdown")
def shutdown() -> dict:
    """Lets the desktop app restart a server it did not launch (e.g. after changing the model)."""
    import threading

    threading.Timer(0.2, lambda: os._exit(0)).start()
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=os.environ.get("RUSTLE_HOST", "127.0.0.1"), port=int(os.environ.get("RUSTLE_PORT", "8765")))
