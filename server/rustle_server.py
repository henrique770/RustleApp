"""rustle-server: local transcription + formatting service for RustleApp.

Plays the role of Wispr Flow's cloud TranscriptionService (transcriber -> formatter),
but runs on your machine with an open-source Whisper model.

    POST /v1/dictate     {"audio_wav_b64": "...", "context": {...}}  ->  {"raw", "text", "formatter", "latency_ms"}
    POST /v1/transcribe  {"audio_wav_b64": "...", "language"}        ->  {"segments": [{"start", "end", "text"}]}
    POST /v1/notes       {"transcript": [...], "user_notes", ...}     ->  {"title", "summary", "action_items", "engine"}
    POST /v1/notes/ask   {"question", "transcript", ...}              ->  {"answer", "engine"}
    POST /v1/transform/suggestions {"content", "count"}               ->  {"suggestions": [{"id", "label", "prompt"}]}
    POST /v1/transform   {"content", "prompt", "suggestion_id", ...}  ->  {"text", "engine"}
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
from notes import NotesWriter
from transforms import Transformer

log = logging.getLogger("rustle")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

WHISPER_MODEL = os.environ.get("RUSTLE_WHISPER_MODEL", "base.en")
WHISPER_DEVICE = os.environ.get("RUSTLE_WHISPER_DEVICE", "cpu")
WHISPER_COMPUTE = os.environ.get("RUSTLE_WHISPER_COMPUTE", "int8")
# Default language, e.g. "pt" or "en"; empty means auto-detect. A request can override it.
WHISPER_LANGUAGE = os.environ.get("RUSTLE_LANGUAGE") or None
MAX_AUDIO_SECONDS = 600
# Bumped when the app/server contract changes; the desktop app restarts older servers.
API_VERSION = 5


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


class TranscribeRequest(BaseModel):
    audio_wav_b64: str
    language: Optional[str] = None


class Segment(BaseModel):
    start: float
    end: float
    text: str


class TranscriptLine(BaseModel):
    speaker: str
    start: float = 0
    text: str


class NotesRequest(BaseModel):
    transcript: list[TranscriptLine] = []
    user_notes: str = ""
    title: str = ""
    language: Optional[str] = None


class SummarySection(BaseModel):
    heading: str
    bullets: list[str]


class ActionItem(BaseModel):
    text: str
    owner: str = ""


class NotesResponse(BaseModel):
    title: str
    summary: list[SummarySection]
    action_items: list[ActionItem]
    engine: str


class AskRequest(BaseModel):
    question: str
    transcript: list[TranscriptLine] = []
    user_notes: str = ""
    summary: list[SummarySection] = []


class SuggestionsRequest(BaseModel):
    content: str = ""
    count: int = 6


class TransformRequest(BaseModel):
    content: str
    prompt: str
    suggestion_id: Optional[str] = None
    selection: Optional[str] = None


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

    def segments(self, audio: np.ndarray, vocabulary: list[str], language: Optional[str]) -> list[Segment]:
        """Timed segments for meeting chunks (Notetaker), with the same vocabulary bias."""
        prompt = ", ".join(vocabulary[:100]) or None
        segments, _ = self.model.transcribe(
            audio,
            beam_size=5,
            language=None if WHISPER_MODEL.endswith(".en") else language,
            vad_filter=True,
            initial_prompt=prompt,
            condition_on_previous_text=False,
        )
        return [Segment(start=s.start, end=s.end, text=s.text.strip()) for s in segments if s.text.strip()]


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
notes_writer = NotesWriter()
transformer = Transformer(notes_writer)
transcriber: Optional[Transcriber] = None


@app.on_event("startup")
def _load() -> None:
    global transcriber
    transcriber = Transcriber()


@app.get("/health")
def health() -> dict:
    return {"ok": transcriber is not None, "api_version": API_VERSION, "model": WHISPER_MODEL, "language": WHISPER_LANGUAGE or "auto",
            "llm": formatter.llm_enabled, "notes_llm": notes_writer.claude_available}


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


def _language(requested: Optional[str]) -> Optional[str]:
    language = requested if requested else WHISPER_LANGUAGE
    return None if language == "auto" else language


@app.post("/v1/transcribe")
def transcribe(req: TranscribeRequest) -> dict:
    """Raw timed transcription of one meeting chunk; no formatting (the notes stage does that)."""
    if transcriber is None:
        raise HTTPException(503, "model not loaded")
    started = time.perf_counter()
    try:
        audio = decode_wav(base64.b64decode(req.audio_wav_b64, validate=True))
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    segments = transcriber.segments(audio, formatter.settings.dictionary, _language(req.language))
    latency = int((time.perf_counter() - started) * 1000)
    log.info("meeting chunk %.1fs -> %d segments %dms", len(audio) / 16000, len(segments), latency)
    return {"segments": [s.model_dump() for s in segments], "latency_ms": latency}


@app.post("/v1/notes", response_model=NotesResponse)
def notes(req: NotesRequest) -> dict:
    started = time.perf_counter()
    result = notes_writer.notes([t.model_dump() for t in req.transcript], req.user_notes, req.title, req.language)
    log.info("notes for %d lines via %s in %dms", len(req.transcript), result.get("engine"),
             int((time.perf_counter() - started) * 1000))
    return result


@app.post("/v1/notes/ask")
def ask(req: AskRequest) -> dict:
    return notes_writer.ask(req.question, [t.model_dump() for t in req.transcript], req.user_notes,
                            [s.model_dump() for s in req.summary])


@app.post("/v1/transform/suggestions")
def transform_suggestions(req: SuggestionsRequest) -> dict:
    return transformer.suggestions(req.content, req.count)


@app.post("/v1/transform")
def transform(req: TransformRequest) -> dict:
    started = time.perf_counter()
    result = transformer.apply(req.content, req.prompt, req.suggestion_id, req.selection)
    log.info("transform %s via %s in %dms", req.suggestion_id or "custom", result.get("engine"),
             int((time.perf_counter() - started) * 1000))
    return result


@app.post("/v1/shutdown")
def shutdown() -> dict:
    """Lets the desktop app restart a server it did not launch (e.g. after changing the model)."""
    import threading

    threading.Timer(0.2, lambda: os._exit(0)).start()
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=os.environ.get("RUSTLE_HOST", "127.0.0.1"), port=int(os.environ.get("RUSTLE_PORT", "8765")))
