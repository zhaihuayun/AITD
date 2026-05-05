from __future__ import annotations

import re
import shutil
import subprocess
import threading
import time
import uuid
import wave
from pathlib import Path
from typing import Any

import torch
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from TTS.api import TTS
from TTS.tts.configs.xtts_config import XttsConfig

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
REFERENCE_DIR = BASE_DIR / "references"
GENERATED_DIR = BASE_DIR / "generated"

for folder in (REFERENCE_DIR, GENERATED_DIR):
    folder.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Voice Reader", version="1.0.0")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
app.mount("/generated", StaticFiles(directory=GENERATED_DIR), name="generated")

_reference_registry: dict[str, dict[str, Any]] = {}
_tts_model: TTS | None = None
_tts_lock = threading.Lock()


class SynthesizeRequest(BaseModel):
    reference_id: str = Field(..., min_length=1)
    text: str = Field(..., min_length=1)
    language: str = Field(default="zh-cn", min_length=2, max_length=10)


def _ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def _run_ffmpeg(command: list[str]) -> None:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"ffmpeg 执行失败: {result.stderr.strip() or result.stdout.strip()}",
        )


def _convert_to_wav(input_path: Path, output_path: Path) -> None:
    _run_ffmpeg(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-ac",
            "1",
            "-ar",
            "24000",
            str(output_path),
        ]
    )


def _audio_duration_seconds(wav_path: Path) -> float:
    with wave.open(str(wav_path), "rb") as wav_file:
        frames = wav_file.getnframes()
        rate = wav_file.getframerate()
    if rate <= 0:
        return 0.0
    return round(frames / float(rate), 2)


def _cleanup_old_references(ttl_seconds: int = 60 * 60 * 6) -> None:
    now = time.time()
    expired_ids: list[str] = []
    for reference_id, meta in _reference_registry.items():
        if now - float(meta.get("created_at", now)) > ttl_seconds:
            expired_ids.append(reference_id)
    for reference_id in expired_ids:
        ref_path = Path(str(_reference_registry[reference_id]["path"]))
        if ref_path.exists():
            ref_path.unlink(missing_ok=True)
        _reference_registry.pop(reference_id, None)


def _split_text(text: str, max_chars: int = 180) -> list[str]:
    normalized = re.sub(r"\s+", " ", text).strip()
    if not normalized:
        return []
    units = re.split(r"(?<=[。！？!?\.])\s+", normalized)
    chunks: list[str] = []
    current = ""
    for unit in units:
        if not unit:
            continue
        if len(unit) > max_chars:
            if current:
                chunks.append(current.strip())
                current = ""
            start = 0
            while start < len(unit):
                part = unit[start : start + max_chars].strip()
                if part:
                    chunks.append(part)
                start += max_chars
            continue
        candidate = f"{current} {unit}".strip() if current else unit
        if len(candidate) <= max_chars:
            current = candidate
        else:
            chunks.append(current.strip())
            current = unit
    if current:
        chunks.append(current.strip())
    return chunks


def _get_tts_model() -> TTS:
    global _tts_model
    if _tts_model is None:
        # Torch 2.6+ 将 torch.load 默认切到 weights_only=True，需要显式允许 XTTS 配置类反序列化。
        torch.serialization.add_safe_globals([XttsConfig])
        # 兼容 Torch 2.6+ 的默认行为变化，避免 XTTS checkpoint 被 weights_only 模式拒绝。
        if not getattr(_get_tts_model, "_torch_load_patched", False):
            original_torch_load = torch.load

            def _torch_load_compat(*args: Any, **kwargs: Any) -> Any:
                kwargs.setdefault("weights_only", False)
                return original_torch_load(*args, **kwargs)

            torch.load = _torch_load_compat  # type: ignore[assignment]
            setattr(_get_tts_model, "_torch_load_patched", True)
        model = TTS(model_name="tts_models/multilingual/multi-dataset/xtts_v2")
        if torch.cuda.is_available():
            model.to("cuda")
        _tts_model = model
    return _tts_model


def _concat_wavs(inputs: list[Path], output_file: Path) -> None:
    if len(inputs) == 1:
        shutil.copy2(inputs[0], output_file)
        return
    concat_list = output_file.with_suffix(".txt")
    concat_lines = []
    for path in inputs:
        safe_path = str(path).replace("'", "'\\''")
        concat_lines.append(f"file '{safe_path}'\n")
    concat_list.write_text(
        "".join(concat_lines),
        encoding="utf-8",
    )
    _run_ffmpeg(
        [
            "ffmpeg",
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_list),
            "-c:a",
            "pcm_s16le",
            str(output_file),
        ]
    )
    concat_list.unlink(missing_ok=True)


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "ffmpeg_available": _ffmpeg_available(),
        "model_loaded": _tts_model is not None,
        "references_cached": len(_reference_registry),
    }


@app.post("/api/reference")
async def upload_reference(file: UploadFile = File(...)) -> dict[str, Any]:
    if not _ffmpeg_available():
        raise HTTPException(status_code=500, detail="系统未检测到 ffmpeg。")
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="参考音频为空。")
    if len(content) > 30 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="参考音频过大（最大 30MB）。")

    suffix = Path(file.filename or "recording.webm").suffix or ".webm"
    temp_source = REFERENCE_DIR / f"{uuid.uuid4().hex}{suffix}"
    temp_source.write_bytes(content)

    reference_id = uuid.uuid4().hex
    reference_wav = REFERENCE_DIR / f"{reference_id}.wav"
    _convert_to_wav(temp_source, reference_wav)
    temp_source.unlink(missing_ok=True)

    _reference_registry[reference_id] = {
        "path": str(reference_wav),
        "created_at": time.time(),
    }
    _cleanup_old_references()

    return {
        "reference_id": reference_id,
        "duration_sec": _audio_duration_seconds(reference_wav),
        "message": "参考音上传成功。",
    }


@app.post("/api/synthesize")
async def synthesize(request: SynthesizeRequest) -> dict[str, Any]:
    if not _ffmpeg_available():
        raise HTTPException(status_code=500, detail="系统未检测到 ffmpeg。")
    ref_meta = _reference_registry.get(request.reference_id)
    if not ref_meta:
        raise HTTPException(status_code=404, detail="未找到参考音，请重新录制并上传。")

    reference_path = Path(str(ref_meta["path"]))
    if not reference_path.exists():
        raise HTTPException(status_code=404, detail="参考音文件丢失，请重新上传。")

    chunks = _split_text(request.text)
    if not chunks:
        raise HTTPException(status_code=400, detail="待合成文本为空。")

    job_id = uuid.uuid4().hex
    chunk_paths: list[Path] = []

    with _tts_lock:
        tts = _get_tts_model()
        for index, chunk in enumerate(chunks):
            chunk_path = GENERATED_DIR / f"{job_id}_part_{index:03d}.wav"
            try:
                tts.tts_to_file(
                    text=chunk,
                    speaker_wav=str(reference_path),
                    language=request.language,
                    file_path=str(chunk_path),
                )
            except Exception as exc:  # noqa: BLE001
                raise HTTPException(status_code=500, detail=f"语音合成失败: {exc}") from exc
            chunk_paths.append(chunk_path)

    output_path = GENERATED_DIR / f"{job_id}.wav"
    _concat_wavs(chunk_paths, output_path)
    for path in chunk_paths:
        path.unlink(missing_ok=True)

    return {
        "audio_url": f"/generated/{output_path.name}",
        "chunks": len(chunks),
        "message": "语音合成成功。",
    }
