from __future__ import annotations

import asyncio
import shutil
from pathlib import Path

from playwright.async_api import TimeoutError as PlaywrightTimeoutError
from playwright.async_api import async_playwright


BASE_URL = "http://127.0.0.1:8765"
ASSETS_DIR = Path(__file__).resolve().parent
FAKE_AUDIO = ASSETS_DIR / "fake-mic.wav"
VIDEO_NAME = "voice-reader-e2e-demo.webm"
RENAMED_MP4 = "voice-reader-e2e-demo.mp4"


async def run() -> None:
    if not FAKE_AUDIO.exists():
        raise FileNotFoundError(f"未找到虚拟麦克风音频: {FAKE_AUDIO}")

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--use-fake-ui-for-media-stream",
                "--use-fake-device-for-media-stream",
                f"--use-file-for-fake-audio-capture={FAKE_AUDIO}",
                "--no-sandbox",
            ],
        )
        context = await browser.new_context(
            viewport={"width": 1280, "height": 720},
            record_video_dir=str(ASSETS_DIR),
            record_video_size={"width": 1280, "height": 720},
        )
        page = await context.new_page()
        await page.goto(BASE_URL, wait_until="networkidle")

        await page.get_by_role("button", name="开始录音").click()
        await page.wait_for_timeout(3000)
        await page.get_by_role("button", name="停止录音").click()
        await page.wait_for_timeout(500)
        await page.get_by_role("button", name="上传参考音").click()

        ref_status = page.locator("#refStatus")
        await ref_status.wait_for(timeout=60_000)
        await page.wait_for_timeout(1000)
        ref_text = await ref_status.inner_text()
        if "上传成功" not in ref_text:
            raise RuntimeError(f"参考音上传未成功: {ref_text}")

        text = (
            "这是一次 Voice Reader 的自动化端到端测试。"
            "系统会先上传参考音，再把这段文本合成为语音。"
            "如果你能听到播放结果，说明项目整体流程是可用的。"
        )
        await page.locator("#textInput").fill(text)
        await page.get_by_role("button", name="合成并播放").click()

        synth_status = page.locator("#synthStatus")
        try:
            await synth_status.filter(has_text="合成成功").wait_for(timeout=240_000)
        except PlaywrightTimeoutError as exc:
            current = await synth_status.inner_text()
            raise RuntimeError(f"合成超时或失败，当前状态: {current}") from exc

        await page.wait_for_timeout(5000)
        video_path = await page.video.path()
        await context.close()
        await browser.close()

    target_webm = ASSETS_DIR / VIDEO_NAME
    shutil.move(video_path, target_webm)
    print(f"WEBM 视频已生成: {target_webm}")

    target_mp4 = ASSETS_DIR / RENAMED_MP4
    ffmpeg_cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(target_webm),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        str(target_mp4),
    ]
    process = await asyncio.create_subprocess_exec(
        *ffmpeg_cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(f"ffmpeg 转码失败: {stderr.decode('utf-8', errors='ignore')}")
    print(f"MP4 视频已生成: {target_mp4}")


if __name__ == "__main__":
    asyncio.run(run())
