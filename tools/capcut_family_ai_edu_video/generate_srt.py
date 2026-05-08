import json
import math
import sys
from pathlib import Path


def fmt_ts(sec: float) -> str:
    ms = int(round(sec * 1000))
    h = ms // 3_600_000
    ms %= 3_600_000
    m = ms // 60_000
    ms %= 60_000
    s = ms // 1000
    ms %= 1000
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python3 generate_srt.py <script.json> <out.srt>", file=sys.stderr)
        return 2

    script_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    data = json.loads(script_path.read_text(encoding="utf-8"))

    t = 0.0
    idx = 1
    lines_out = []
    for seg in data["segments"]:
        dur = float(seg["duration_sec"])
        start = t
        end = t + dur
        t = end

        title = (seg.get("title") or "").strip()
        body_lines = [x.rstrip() for x in (seg.get("lines") or []) if x.strip()]

        # Keep subtitles concise: title + up to 2 key lines.
        text_lines = []
        if title:
            text_lines.append(title)
        text_lines.extend(body_lines[:2])

        lines_out.append(str(idx))
        lines_out.append(f"{fmt_ts(start)} --> {fmt_ts(end)}")
        lines_out.extend(text_lines if text_lines else [""])
        lines_out.append("")
        idx += 1

    out_path.write_text("\n".join(lines_out), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

