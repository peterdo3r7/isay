import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel


# MARK: - Configuration

WHISPER_URL = os.getenv("WHISPER_URL", "http://10.0.0.11:9000")


# MARK: - Lifespan

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http = httpx.AsyncClient(base_url=WHISPER_URL, timeout=60)
    yield
    await app.state.http.aclose()


# MARK: - App

app = FastAPI(
    title="Isay Transcription Server",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["POST"],
    allow_headers=["*"],
)


# MARK: - Response model

class TranscriptionResponse(BaseModel):
    text: str


# MARK: - Routes

@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/transcribe", response_model=TranscriptionResponse)
async def transcribe(audio: UploadFile = File(...)):
    """
    Nhận file audio (m4a/wav/mp3) qua multipart/form-data,
    gửi lên Whisper local, trả về văn bản nhận dạng.

    Field name phải là 'audio' — khớp với TranscriptionService.swift.
    """
    allowed = {"audio/m4a", "audio/wav", "audio/mpeg", "audio/mp4",
               "audio/x-m4a", "application/octet-stream"}
    if audio.content_type and audio.content_type not in allowed:
        raise HTTPException(
            status_code=415,
            detail=f"Định dạng không hỗ trợ: {audio.content_type}",
        )

    max_size = 25 * 1024 * 1024
    audio_bytes = await audio.read(max_size + 1)
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="File audio rỗng.")
    if len(audio_bytes) > max_size:
        raise HTTPException(status_code=413, detail="File vượt quá giới hạn 25 MB.")

    filename = audio.filename or "recording.m4a"

    try:
        response = await app.state.http.post(
            "/asr",
            params={"encode": "true", "task": "transcribe", "language": "vi", "output": "txt"},
            files={"audio_file": (filename, audio_bytes, audio.content_type or "audio/m4a")},
        )
        if response.status_code != 200:
            raise HTTPException(status_code=502, detail=f"Whisper trả về lỗi {response.status_code}.")
        return TranscriptionResponse(text=response.text.strip())

    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Không kết nối được Whisper: {e}")
