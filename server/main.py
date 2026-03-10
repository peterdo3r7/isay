import os
import tempfile
from contextlib import asynccontextmanager

import openai
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel


# MARK: - Lifespan

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Kiểm tra API key khi khởi động
    if not os.getenv("OPENAI_API_KEY"):
        raise RuntimeError("OPENAI_API_KEY chưa được thiết lập trong file .env")
    openai.api_key = os.getenv("OPENAI_API_KEY")
    yield


# MARK: - App

app = FastAPI(
    title="Isay Transcription Server",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Thu hẹp lại khi deploy production
    allow_methods=["POST"],
    allow_headers=["*"],
)


# MARK: - Response model

class TranscriptionResponse(BaseModel):
    text: str


# MARK: - Routes

@app.get("/health")
async def health():
    """Kiểm tra server đang chạy."""
    return {"status": "ok"}


@app.post("/transcribe", response_model=TranscriptionResponse)
async def transcribe(audio: UploadFile = File(...)):
    """
    Nhận file audio (m4a/wav/mp3) qua multipart/form-data,
    gửi lên OpenAI Whisper, trả về văn bản nhận dạng.

    Field name phải là 'audio' — khớp với TranscriptionService.swift.
    """
    # Kiểm tra định dạng file được chấp nhận
    allowed = {"audio/m4a", "audio/wav", "audio/mpeg", "audio/mp4",
               "audio/x-m4a", "application/octet-stream"}
    if audio.content_type and audio.content_type not in allowed:
        raise HTTPException(
            status_code=415,
            detail=f"Định dạng không hỗ trợ: {audio.content_type}",
        )

    # Đọc dữ liệu upload
    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="File audio rỗng.")

    # Lưu vào file tạm để gửi lên Whisper API
    suffix = os.path.splitext(audio.filename or "recording.m4a")[1] or ".m4a"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(audio_bytes)
        tmp_path = tmp.name

    try:
        client = openai.AsyncOpenAI()
        with open(tmp_path, "rb") as f:
            response = await client.audio.transcriptions.create(
                model="whisper-1",
                file=f,
                language="vi",          # Nhận dạng tiếng Việt
                response_format="text", # Trả về plain text thay vì JSON verbose
            )
        # response là string khi response_format="text"
        text = response.strip() if isinstance(response, str) else response.text.strip()
        return TranscriptionResponse(text=text)

    except openai.APIError as e:
        raise HTTPException(status_code=502, detail=f"Lỗi Whisper API: {e.message}")
    finally:
        os.unlink(tmp_path)  # Luôn xóa file tạm
