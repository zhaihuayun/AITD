#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"
TMP_DIR="${ROOT_DIR}/.tmp"
SCRIPT_JSON="${ROOT_DIR}/script.json"
SRT_IN="${ROOT_DIR}/subtitles.srt"

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
import json, os, sys, textwrap, re

script_path, txt_dir = sys.argv[1], sys.argv[2]
with open(script_path, "r", encoding="utf-8") as f:
    data = json.load(f)

def safe(s: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9_-]+", "_", s)
    return s.strip("_") or "seg"

segments = data["segments"]

manifest_path = os.path.join(txt_dir, "manifest.tsv")
with open(manifest_path, "w", encoding="utf-8") as mf:
    for seg in segments:
        sid = safe(seg["id"])
        dur = float(seg["duration_sec"])
        title = seg.get("title", "").strip()
        lines = seg.get("lines", [])
        body = "\n".join([l.rstrip() for l in lines]).strip()

        title_path = os.path.join(txt_dir, f"{sid}_title.txt")
        body_path = os.path.join(txt_dir, f"{sid}_body.txt")
        with open(title_path, "w", encoding="utf-8") as tf:
            tf.write(title + "\n")
        with open(body_path, "w", encoding="utf-8") as bf:
            bf.write(body + "\n")

        mf.write("\t".join([sid, f"{dur:.3f}", title_path, body_path]) + "\n")
print(manifest_path)
PY

MANIFEST_TSV="$(python3 -c "import sys; print(open('${TXT_DIR}/manifest.tsv','r',encoding='utf-8').read().strip().splitlines()[0] if False else '${TXT_DIR}/manifest.tsv')")"

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
drawtext=fontfile='${FONT_FILE}':textfile='${body_file}':reload=1:fontcolor=white:fontsize=44:line_spacing=18:x=160:y=320,\
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

cp -f "${SRT_IN}" "${OUT_DIR}/family-ai-edu-v1-5min.srt"

# Also copy to artifacts folder if available (Cursor Cloud).
if [[ -d "/opt/cursor/artifacts" ]]; then
  cp -f "${FINAL_MP4}" "/opt/cursor/artifacts/family-ai-edu-v1-5min.mp4"
  cp -f "${OUT_DIR}/family-ai-edu-v1-5min.srt" "/opt/cursor/artifacts/family-ai-edu-v1-5min.srt"
  echo "Artifacts:"
  echo "  /opt/cursor/artifacts/family-ai-edu-v1-5min.mp4"
  echo "  /opt/cursor/artifacts/family-ai-edu-v1-5min.srt"
fi

echo "Done:"
echo "  ${FINAL_MP4}"
echo "  ${OUT_DIR}/family-ai-edu-v1-5min.srt"

