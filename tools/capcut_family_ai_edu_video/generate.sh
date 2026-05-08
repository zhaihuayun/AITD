#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"
TMP_DIR="${ROOT_DIR}/.tmp"
SCRIPT_JSON="${ROOT_DIR}/script.json"
SRT_STATIC="${ROOT_DIR}/subtitles.srt"
SRT_GEN_PY="${ROOT_DIR}/generate_srt.py"
NARRATION_TXT="${ROOT_DIR}/narration.txt"

mkdir -p "${OUT_DIR}" "${TMP_DIR}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

need_cmd ffmpeg
need_cmd ffprobe
need_cmd python3
need_cmd fc-match

pick_font() {
  local f=""
  for name in "Noto Sans CJK SC" "Noto Sans CJK" "Noto Sans SC" "Source Han Sans SC" "WenQuanYi Micro Hei" "Microsoft YaHei" "PingFang SC" "DejaVu Sans"; do
    f="$(fc-match -f '%{file}\n' "$name" 2>/dev/null || true)"
    if [[ -n "${f}" && -f "${f}" ]]; then
      echo "${f}"
      return 0
    fi
  done
  echo "ERROR: cannot find a usable font (need a font with Chinese glyphs)." >&2
  echo "Install one of: Noto Sans CJK SC / Source Han Sans SC / WenQuanYi Micro Hei" >&2
  exit 1
}

FONT_FILE="$(pick_font)"

W=1920
H=1080
FPS=30
BG="#0B0F1A"
ACCENT="#22D3EE"

SEG_DIR="${TMP_DIR}/segments"
TXT_DIR="${TMP_DIR}/text"
mkdir -p "${SEG_DIR}" "${TXT_DIR}"

python3 - "${SCRIPT_JSON}" "${TXT_DIR}" <<'PY'
import json, os, sys, re

script_path, txt_dir = sys.argv[1], sys.argv[2]
with open(script_path, "r", encoding="utf-8") as f:
    data = json.load(f)

def safe(s: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9_-]+", "_", s)
    return s.strip("_") or "seg"

def wrap_zh(line: str, width: int = 26) -> list[str]:
    """
    Simple Chinese-friendly wrapping.
    Prefer breaking on spaces or punctuation; fall back to hard wrap.
    """
    line = (line or "").strip()
    if not line:
        return [""]
    out = []
    buf = ""
    for ch in line:
        buf += ch
        if len(buf) >= width:
            # backtrack to last preferred breakpoint
            break_at = -1
            for i in range(len(buf) - 1, max(-1, len(buf) - 10), -1):
                if buf[i] in " ，。；、/ )】】》》→-+" or buf[i].isspace():
                    break_at = i + 1
                    break
            if break_at == -1:
                out.append(buf)
                buf = ""
            else:
                out.append(buf[:break_at].rstrip())
                buf = buf[break_at:].lstrip()
    if buf:
        out.append(buf)
    return out

segments = data["segments"]

manifest_path = os.path.join(txt_dir, "manifest.tsv")
with open(manifest_path, "w", encoding="utf-8") as mf:
    for seg in segments:
        sid = safe(seg["id"])
        dur = float(seg["duration_sec"])
        title = seg.get("title", "").strip()
        lines = seg.get("lines", [])
        # Wrap each line to avoid clipping in 1080p.
        wrapped_lines: list[str] = []
        for raw in lines:
            raw = raw.rstrip()
            if not raw.strip():
                wrapped_lines.append("")
                continue
            wrapped_lines.extend(wrap_zh(raw, width=26))
        body = "\n".join(wrapped_lines).strip()

        title_path = os.path.join(txt_dir, f"{sid}_title.txt")
        body_path = os.path.join(txt_dir, f"{sid}_body.txt")
        with open(title_path, "w", encoding="utf-8") as tf:
            tf.write(title + "\n")
        with open(body_path, "w", encoding="utf-8") as bf:
            bf.write(body + "\n")

        mf.write("\t".join([sid, f"{dur:.3f}", title_path, body_path]) + "\n")
print(manifest_path)
PY

render_segment() {
  local sid="$1"
  local dur="$2"
  local title_file="$3"
  local body_file="$4"
  local out="${SEG_DIR}/${sid}.mp4"

  # Title and body text are read from files to avoid escaping issues.
  echo "  - ${sid}: ${dur}s"
  ffmpeg -nostdin -y -hide_banner -loglevel error \
    -f lavfi -i "color=c=${BG}:s=${W}x${H}:r=${FPS}:d=${dur}" \
    -vf "\
drawbox=x=120:y=110:w=${W}-240:h=8:color=${ACCENT}@1:t=fill,\
drawtext=fontfile='${FONT_FILE}':textfile='${title_file}':reload=1:fontcolor=${ACCENT}:fontsize=72:x=(w-text_w)/2:y=160,\
drawtext=fontfile='${FONT_FILE}':textfile='${body_file}':reload=1:fontcolor=white:fontsize=40:line_spacing=16:x=150:y=320,\
drawbox=x=120:y=${H}-150:w=${W}-240:h=1:color=white@0.15:t=fill,\
drawtext=fontfile='${FONT_FILE}':text='家庭AI教育系统 V1  ·  口播讲解底片':fontcolor=white@0.65:fontsize=28:x=140:y=${H}-120" \
    -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p -r ${FPS} -g 60 -crf 18 \
    -movflags +faststart \
    "${out}"
}

echo "Rendering segments with font: ${FONT_FILE}"

while IFS=$'\t' read -r sid dur title_file body_file; do
  render_segment "${sid}" "${dur}" "${title_file}" "${body_file}"
done < "${TXT_DIR}/manifest.tsv"

CONCAT_LIST="${TMP_DIR}/concat_list.txt"
rm -f "${CONCAT_LIST}"
while IFS=$'\t' read -r sid dur title_file body_file; do
  echo "file '${SEG_DIR}/${sid}.mp4'" >> "${CONCAT_LIST}"
done < "${TXT_DIR}/manifest.tsv"

FINAL_MP4="${OUT_DIR}/family-ai-edu-v1-5min.mp4"
ffmpeg -nostdin -y -hide_banner -loglevel error \
  -f concat -safe 0 -i "${CONCAT_LIST}" \
  -c copy \
  "${FINAL_MP4}"

FINAL_SRT="${OUT_DIR}/family-ai-edu-v1-5min.srt"

# Prefer generating SRT from script.json to keep timing exact.
if [[ -f "${SRT_GEN_PY}" ]]; then
  python3 "${SRT_GEN_PY}" "${SCRIPT_JSON}" "${FINAL_SRT}"
else
  cp -f "${SRT_STATIC}" "${FINAL_SRT}"
fi

# Optional: generate TTS narration and mux into MP4.
WITH_TTS=1
if [[ "${WITH_TTS}" == "1" ]]; then
  if ! python3 -c "import edge_tts" >/dev/null 2>&1; then
    # Best effort install (user/site). If install fails, we'll keep silent video.
    python3 -m pip install --user -q edge-tts >/dev/null 2>&1 || true
  fi

  if python3 -c "import edge_tts" >/dev/null 2>&1 && [[ -f "${NARRATION_TXT}" ]]; then
    TTS_MP3="${TMP_DIR}/narration.mp3"
    python3 - "${NARRATION_TXT}" "${TTS_MP3}" <<'PY'
import asyncio, sys
from pathlib import Path
import edge_tts

txt_path = Path(sys.argv[1])
out_mp3 = Path(sys.argv[2])
text = txt_path.read_text(encoding="utf-8").strip()

async def run():
    communicate = edge_tts.Communicate(text=text, voice="zh-CN-XiaoxiaoNeural", rate="+0%")
    await communicate.save(str(out_mp3))

asyncio.run(run())
PY

    FINAL_WITH_AUDIO="${OUT_DIR}/family-ai-edu-v1-5min-with-tts.mp4"
    ffmpeg -nostdin -y -hide_banner -loglevel error \
      -i "${FINAL_MP4}" -i "${TTS_MP3}" \
      -c:v copy -c:a aac -b:a 160k -shortest \
      -movflags +faststart \
      "${FINAL_WITH_AUDIO}"
    # Overwrite default output to be the with-audio version.
    mv -f "${FINAL_WITH_AUDIO}" "${FINAL_MP4}"
  fi
fi

# Also copy to artifacts folder if available (Cursor Cloud).
if [[ -d "/opt/cursor/artifacts" ]]; then
  cp -f "${FINAL_MP4}" "/opt/cursor/artifacts/family-ai-edu-v1-5min.mp4"
  cp -f "${FINAL_SRT}" "/opt/cursor/artifacts/family-ai-edu-v1-5min.srt"
  echo "Artifacts:"
  echo "  /opt/cursor/artifacts/family-ai-edu-v1-5min.mp4"
  echo "  /opt/cursor/artifacts/family-ai-edu-v1-5min.srt"
fi

echo "Done:"
echo "  ${FINAL_MP4}"
echo "  ${FINAL_SRT}"

