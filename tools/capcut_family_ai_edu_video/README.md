# 剪映用：家庭AI教育系统 V1（5分钟横屏口播）一键出片

这个目录提供一个**可重复生成**的 16:9 讲解视频底片（MP4）和字幕（SRT）。
你可以直接把生成的 MP4 + SRT 拖进剪映做配乐、加转场、替换更精美的图形素材。

## 依赖

- Linux/macOS（Windows 也可在 WSL 跑）
- `ffmpeg`（需要启用 `drawtext`，大多数发行版自带）
- `fontconfig`（用于自动找中文字体）

本仓库的 Cloud Agent 环境已经包含 `ffmpeg`。

## 生成

在仓库根目录执行：

```bash
bash tools/capcut_family_ai_edu_video/generate.sh
```

输出位置：

- `tools/capcut_family_ai_edu_video/out/family-ai-edu-v1-5min.mp4`
- `tools/capcut_family_ai_edu_video/out/family-ai-edu-v1-5min.srt`

## 导入剪映（CapCut 桌面版）

1. 打开剪映 -> 新建项目（16:9）
2. 拖入 `family-ai-edu-v1-5min.mp4`
3. 字幕 -> 导入字幕 -> 选择 `family-ai-edu-v1-5min.srt`
4. 替换 BGM、加转场、叠加更漂亮的图表/UI 截图即可

## 调整内容

- 分镜与文案在 `script.json`
- 字幕在 `subtitles.srt`（会被脚本复制到 `out/`）
- 你可以先改 `script.json` 再重新运行 `generate.sh`

