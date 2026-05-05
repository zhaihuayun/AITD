# Voice Reader 教程与部署指南

本文档面向第一次接触本项目的使用者，目标是帮助你快速完成：

1. 本地启动和使用
2. 常见问题排查
3. 生产部署（Systemd + Nginx 反向代理）

---

## 1. 项目简介

Voice Reader 是一个本地网页工具，支持以下流程：

1. 浏览器录制参考音频
2. 基于 Coqui XTTS v2 做少样本语音克隆
3. 粘贴长文本并自动分段合成
4. 在网页中直接播放结果

技术栈：

- 后端：FastAPI
- 前端：原生 HTML/CSS/JS（`static/index.html`）
- TTS：`TTS==0.22.0`

---

## 2. 环境要求

必须满足：

- Python **3.11**
- `ffmpeg`
- Linux 或 macOS

> 注意：`TTS==0.22.0` 对 Python 版本有要求，推荐固定使用 3.11。

### 2.1 检查 Python 版本

```bash
python3.11 --version
```

如未安装 3.11（以 Ubuntu 为例）：

```bash
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv
```

### 2.2 安装 ffmpeg

```bash
ffmpeg -version
```

若未安装：

- Ubuntu/Debian:
  ```bash
  sudo apt-get update && sudo apt-get install -y ffmpeg
  ```
- macOS (Homebrew):
  ```bash
  brew install ffmpeg
  ```

---

## 3. 本地启动（推荐）

在项目根目录执行：

```bash
cd voice-reader
./run.sh
```

默认监听：

- `http://127.0.0.1:8765`

`run.sh` 会自动执行：

1. 校验 `ffmpeg`
2. 校验 Python 3.11（默认 `python3.11`）
3. 创建并激活 `.venv`
4. 安装 `requirements.txt`
5. 启动 `uvicorn app:app --port 8765`

### 3.1 指定 Python 解释器

如果系统中 `python3.11` 不是默认命令，可临时指定：

```bash
PYTHON_BIN=/path/to/python3.11 ./run.sh
```

---

## 4. 使用教程（网页操作）

1. 打开页面 `http://127.0.0.1:8765`
2. 在「录制并上传参考音频」区域：
   - 点击“开始录音”
   - 录制 8~20 秒
   - 点击“停止录音”
   - 点击“上传参考音”
3. 在「输入长文本并合成」区域：
   - 选择语言（如 `zh-cn`）
   - 粘贴长文本
   - 点击“合成并播放”
4. 等待合成完成后，页面会自动播放结果音频

建议：

- 参考音尽量安静、口齿清晰
- 长文尽量带标点，分段效果会更自然

---

## 5. API 速览

### 5.1 健康检查

- `GET /api/health`

返回示例：

```json
{
  "status": "ok",
  "ffmpeg_available": true,
  "model_loaded": false,
  "references_cached": 0
}
```

### 5.2 上传参考音

- `POST /api/reference`
- `Content-Type: multipart/form-data`
- 字段：`file`

### 5.3 合成语音

- `POST /api/synthesize`
- `Content-Type: application/json`

请求体示例：

```json
{
  "reference_id": "xxxx",
  "text": "这里是要合成的文本",
  "language": "zh-cn"
}
```

---

## 6. 常见问题排查

### 6.1 报错：未检测到 python3.11

原因：系统没有 `python3.11` 命令。

处理：

- 安装 Python 3.11，或
- 启动时指定 `PYTHON_BIN=/你的/python3.11`

### 6.2 报错：未检测到 ffmpeg

原因：系统未安装 ffmpeg，或 PATH 未配置。

处理：

- 安装 ffmpeg
- 重新打开终端后再启动

### 6.3 报错：`No matching distribution found for TTS==0.22.0`

原因：通常是 Python 版本不匹配（例如 3.12）。

处理：

- 删除旧虚拟环境：`rm -rf .venv`
- 使用 Python 3.11 重新启动：
  ```bash
  PYTHON_BIN=/path/to/python3.11 ./run.sh
  ```

### 6.4 首次合成很慢

原因：首次加载 XTTS 模型和依赖。

处理：

- 这是正常现象，后续请求会更快
- 若有 GPU，速度会明显提升

---

## 7. 生产部署（Linux）

本节给出一套常见方案：**Systemd 管理进程 + Nginx 反向代理**。

### 7.1 准备代码与依赖

假设代码目录：

- `/opt/voice-reader`

安装系统依赖（示例）：

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg python3.11 python3.11-venv nginx
```

首次拉起应用（创建 `.venv` 并安装依赖）：

```bash
cd /opt/voice-reader/voice-reader
./run.sh
```

确认可用后，停止前台进程（Ctrl+C）。

### 7.2 创建 Systemd 服务

新建 `/etc/systemd/system/voice-reader.service`：

```ini
[Unit]
Description=Voice Reader FastAPI Service
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/voice-reader/voice-reader
Environment=PYTHON_BIN=/usr/bin/python3.11
ExecStart=/opt/voice-reader/voice-reader/run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启动服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now voice-reader
sudo systemctl status voice-reader
```

查看日志：

```bash
sudo journalctl -u voice-reader -f
```

### 7.3 配置 Nginx 反向代理

新建 `/etc/nginx/sites-available/voice-reader`：

```nginx
server {
    listen 80;
    server_name your-domain.com;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

启用站点并重载：

```bash
sudo ln -s /etc/nginx/sites-available/voice-reader /etc/nginx/sites-enabled/voice-reader
sudo nginx -t
sudo systemctl reload nginx
```

### 7.4 HTTPS（可选）

推荐使用 certbot：

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d your-domain.com
```

---

## 8. 资源与目录说明

项目关键目录：

- `voice-reader/app.py`：FastAPI 后端
- `voice-reader/static/index.html`：网页前端
- `voice-reader/run.sh`：启动脚本
- `voice-reader/references/`：参考音缓存（运行时生成）
- `voice-reader/generated/`：合成音频输出（运行时生成）

---

## 9. 安全与运维建议

1. 生产环境建议加鉴权（避免任意上传/调用）
2. 使用 HTTPS 保护语音数据传输
3. 定期清理 `generated/` 与 `references/`（或挂载到临时盘）
4. 如果是公网服务，建议设置限流和请求体大小限制

