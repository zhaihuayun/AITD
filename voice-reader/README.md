# Voice Reader

本项目提供一个本地网页：

1. 浏览器录制参考音频
2. 用 Coqui XTTS v2 做少样本语音克隆
3. 粘贴长文本并合成语音
4. 直接在网页里播放结果

## 技术栈

- 后端：FastAPI
- 前端：`static/index.html`（原生 HTML/CSS/JS）
- TTS：`TTS==0.22.0`（XTTS v2）
- 默认端口：`8765`
- 依赖系统命令：`ffmpeg`

## 运行环境

- Python `3.11`
- Linux/macOS

## 安装 ffmpeg

请先确认系统已安装 ffmpeg：

```bash
ffmpeg -version
```

如果没有安装：

- Ubuntu/Debian: `sudo apt-get update && sudo apt-get install -y ffmpeg`
- macOS (Homebrew): `brew install ffmpeg`

## 启动

```bash
cd voice-reader
./run.sh
```

脚本会自动：

- 创建并使用 `.venv`（Python 3.11）
- 安装 `requirements.txt`
- 启动 `http://127.0.0.1:8765`

## 页面使用流程

1. 点击“开始录音”，说一段 8~20 秒参考音
2. 点击“停止录音”后再点“上传参考音”
3. 粘贴长文本，选择语言，点击“合成并播放”

## 接口说明

- `GET /api/health`：服务状态检查
- `POST /api/reference`：上传参考音（form-data，字段 `file`）
- `POST /api/synthesize`：合成语音（JSON：`reference_id`, `text`, `language`）

## 注意事项

- 首次合成会加载 XTTS 模型，耗时可能较长。
- 使用 CPU 也可运行，但速度会较慢；有 CUDA 时会自动使用 GPU。
