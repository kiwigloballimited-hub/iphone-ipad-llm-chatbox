# LocalAIChat · 本地 AI 聊天

[![iOS Build](https://github.com/kiwigloballimited-hub/iphone-ipad-llm-chatbox/actions/workflows/build.yml/badge.svg)](https://github.com/kiwigloballimited-hub/iphone-ipad-llm-chatbox/actions/workflows/build.yml)
![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS%2017%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

An iPhone / iPad app for chatting with **your own AI server** (Ollama, LM Studio, llama.cpp, vLLM) or cloud APIs (DeepSeek, Anthropic Claude). Multiple agents with their own personalities and memory, image & video understanding, and an AI-driven built-in browser.

一个连接**你自己的 AI 服务器**（Ollama、LM Studio、llama.cpp、vLLM）或云端 API（DeepSeek、Anthropic Claude）的 iPhone / iPad 应用。支持多个拥有独立人格和记忆的助手、图片与视频理解，以及由 AI 操作的内置浏览器。

**[English](#english)** · **[中文说明](#中文说明)**

## Screenshots · 截图

<!--
Add screenshots to docs/screenshots/ and remove these comment markers.
把截图放到 docs/screenshots/ 后，删除这段注释标记即可显示。

| Agents 助手 | Chat 聊天 | Browser 浏览器 |
|---|---|---|
| <img src="docs/screenshots/agents.png" width="240"> | <img src="docs/screenshots/chat.png" width="240"> | <img src="docs/screenshots/browser.png" width="240"> |

| Persona 人格设定 | Video frames 视频抽帧 | iPad |
|---|---|---|
| <img src="docs/screenshots/persona.png" width="240"> | <img src="docs/screenshots/video.png" width="240"> | <img src="docs/screenshots/ipad.png" width="240"> |
-->

*Screenshots coming soon. · 截图即将补充。*

---

## English

> The app’s interface is currently in Simplified Chinese. Button names below are given in English with the Chinese label in brackets where helpful.

### Features

- **Multiple independent agents** – each with its own avatar, persona (role, personality, speaking style, background, rules, example dialogue — or a raw system prompt), greeting, server, model and generation settings, and its own conversation history. Built-in templates included.
- **Memory**
  - *Long-term memory (across conversations)*: every agent has a memory notebook that is included in all of its conversations. Add notes by hand, use “Remember this conversation” (you review before saving), or turn on automatic memory.
  - *Rolling summary*: when a conversation grows past the history limit, older messages are condensed into a summary instead of being forgotten.
- **Images & video**
  - Image compression with ImageIO (HEIC supported, orientation fixed): max dimension, JPEG quality and a size cap.
  - Video decoding with AVFoundation: extract N evenly spaced frames or one frame every X seconds, preview them, pick which frames to send. Timestamps are passed to the model.
- **Browser assistant** – the agent can search, open pages, read long pages in chunks, click, type, choose from drop-downs, scroll and go back in a built-in browser you can watch (side by side on iPad, collapsible on iPhone). Log-in, payment, submit and send actions ask for your confirmation. Requires a model with tool calling (e.g. Qwen3, DeepSeek, Claude, gpt-oss, Llama 3.1+).
- **Model controls** – temperature, max length, context length, thinking level (auto / off / low / medium / high), repetition / frequency / presence penalties.
- Streaming replies, stop, regenerate, copy/select text, collapsible “thinking” for reasoning models.
- **Context engineering** – long-press any message to *pin* it (always sent to the model, never dropped by the history window), *exclude* it (kept on screen but not sent), *start a new context here*, *fork* a new conversation from that point, or *edit & fork* one of your own messages to try a different prompt.
- **Usage & cost** – live token count, context-window usage and estimated cost for each conversation (real numbers from the server when available, otherwise estimated). Built-in Claude prices and DeepSeek reference prices, editable; local models count as free; show in USD, GBP or CNY.
- **Auto-reconnect** – if the connection drops (app sent to background, Wi-Fi switch, server busy), the reply is retried automatically and continues from where it stopped; a “Continue” button appears if all retries fail.
- All data stays on the device.

### Supported servers

| Service | API type in app | Example address |
|---|---|---|
| Ollama | Ollama native, or OpenAI-compatible | `http://192.168.1.10:11434` |
| LM Studio | OpenAI-compatible | `http://192.168.1.10:1234` |
| llama.cpp server | OpenAI-compatible | `http://192.168.1.10:8080` |
| vLLM / other OpenAI-compatible | OpenAI-compatible | `http://192.168.1.10:8000` |
| DeepSeek (cloud) | OpenAI-compatible | `https://api.deepseek.com` (API key) |
| Anthropic Claude (cloud) | Anthropic | `https://api.anthropic.com` (API key) |

For images and video, use a vision model (e.g. `qwen2.5vl`, `gemma3`, `llama3.2-vision`, `minicpm-v`).

**Let your server accept connections from your phone**
- Ollama listens on localhost only by default — set `OLLAMA_HOST=0.0.0.0` and restart Ollama (macOS: `launchctl setenv OLLAMA_HOST "0.0.0.0"`).
- LM Studio: turn on *Serve on Local Network*.
- Allow the port through your computer’s firewall.
- When the app first connects, allow **Local Network** access (Settings › Privacy & Security › Local Network).
- Away from home? Use [Tailscale](https://tailscale.com) and enter your computer’s Tailscale address (`http://100.x.x.x:port`).

### Install on your iPhone / iPad

You need a Mac with **Xcode 16 or later** and a free Apple ID. The device must run iOS / iPadOS 17 or later.

1. **Get the code** – click the green **Code** button on this page › **Download ZIP**, then unzip it. (Or `git clone` the repository.)
2. **Open** `LocalAIChat.xcodeproj` in Xcode.
3. **Signing** – click the blue *LocalAIChat* project at the top of the left sidebar › target *LocalAIChat* › **Signing & Capabilities**:
   - **Team**: choose your Apple ID (Xcode › Settings › Accounts to add one).
   - **Bundle Identifier**: change `com.example.LocalAIChat` to something unique, e.g. `com.yourname.LocalAIChat`.
4. **Connect** your iPhone / iPad with a cable, choose it in the device menu at the top of Xcode, press **▶︎ Run**.
5. **First run only**, on the device:
   - Settings › Privacy & Security › **Developer Mode** › on (the device restarts).
   - Settings › General › VPN & Device Management › trust your developer certificate.

> Apps signed with a free Apple ID expire after 7 days — just press Run in Xcode again. A paid developer account extends this to one year.

### First steps in the app

1. Tap ⚙️ (top left) › your server › enter the address and API type (or use **Quick fill** 「快速填写常用服务」) › **Test connection** 「测试连接并获取模型」 › pick a default model › Save 「保存」.
2. Pick an agent (or tap **+** to create one from a template) and start chatting.
3. Tap ⊕ next to the message box to attach photos or videos.

### Privacy & safety notes

- Conversations, memories and settings are stored only on the device. Messages are sent only to the server you configure.
- API keys are currently stored in the app’s local data file (not the Keychain).
- The browser assistant treats web page text as data, not instructions, and asks before sensitive actions — but always keep an eye on what it does, especially on sites where you are logged in.

---

## 中文说明

### 功能

- **多个独立助手**：每个助手都有自己的头像、人格设定（身份、性格、说话风格、背景故事、行为准则、对话示例，也可以直接写系统提示词）、开场白、服务器、模型、生成参数和对话记录。内置多个模板。
- **记忆**
  - **长期记忆（跨会话）**：每个助手有自己的记忆本，会带入它的所有对话。可以手动添加，也可以「记住这次对话」（确认后保存），或开启自动记忆。
  - **长对话自动摘要**：对话超过设定的历史条数后，早期内容压缩成摘要保留，而不是直接遗忘。
- **图片与视频**
  - 图片压缩：最长边、JPEG 质量、大小上限可调，支持 HEIC，自动校正方向。
  - 视频抽帧：均匀抽取 N 帧或每隔 X 秒一帧，可预览并勾选要发送的帧，会把时间点告诉模型。
- **浏览器助手**：AI 可以在内置浏览器里搜索、打开网页、分段阅读、点击、输入、选择下拉框、滚动、返回。你可以实时看到它的操作（iPad 并排显示，iPhone 可折叠）。登录、付款、提交、发送等操作会先请你确认。需要支持工具调用的模型（如 Qwen3、DeepSeek、Claude、gpt-oss、Llama 3.1+）。
- **模型参数**：温度、最大长度、记忆的历史条数、思考强度（自动 / 关闭 / 低 / 中 / 高）、重复惩罚 / 频率惩罚 / 存在惩罚。
- 流式输出、停止、重新生成、复制 / 选择文本，推理模型的「思考过程」可折叠查看。
- **上下文工程**：长按任意消息可以「置顶到上下文」（始终发送给模型，不会被历史窗口丢弃）、「不发送给模型」（保留显示但不发送）、「从这里开始新的上下文」、「从这里分叉」出新对话；自己发的消息还可以「编辑并分叉」，方便比较不同提示词的效果。
- **用量与费用**：实时显示当前对话的 token 用量、上下文占比和预估费用（优先使用服务器返回的真实数字，否则按字数估算）。内置 Claude 官方价格和 DeepSeek 参考价，可修改；本地模型免费；可以用美元、英镑或人民币显示。
- **断线重传**：网络中断（切到后台、切换 Wi-Fi、服务器繁忙等）时自动重试，并从中断处接着写；重试都失败后可以点「从断点继续」。
- 所有数据只保存在本机。

### 支持的服务器

| 服务 | App 中的接口类型 | 地址示例 |
|---|---|---|
| Ollama | Ollama 原生 或 OpenAI 兼容 | `http://192.168.1.10:11434` |
| LM Studio | OpenAI 兼容 | `http://192.168.1.10:1234` |
| llama.cpp server | OpenAI 兼容 | `http://192.168.1.10:8080` |
| vLLM / 其它 OpenAI 兼容服务 | OpenAI 兼容 | `http://192.168.1.10:8000` |
| DeepSeek（云端） | OpenAI 兼容 | `https://api.deepseek.com`（需要 API Key） |
| Anthropic Claude（云端） | Anthropic | `https://api.anthropic.com`（需要 API Key） |

识别图片或视频需要视觉模型，例如 `qwen2.5vl`、`gemma3`、`llama3.2-vision`、`minicpm-v`。

**让服务器允许手机连接**
- **Ollama** 默认只允许本机访问：设置环境变量 `OLLAMA_HOST=0.0.0.0` 后重启（macOS：`launchctl setenv OLLAMA_HOST "0.0.0.0"`；Windows：在「系统环境变量」中添加）。
- **LM Studio**：打开「Serve on Local Network」。
- 电脑防火墙需要放行对应端口。
- 第一次连接时请**允许**「本地网络」权限（设置 › 隐私与安全性 › 本地网络）。
- 在外面也想用？用 [Tailscale](https://tailscale.com)，地址填电脑的 Tailscale IP（`http://100.x.x.x:端口`）。
- 使用浏览器助手时，网页内容较长，Ollama 建议把上下文长度（Context length）调到 16K 以上。

### 安装到 iPhone / iPad

需要一台装有 **Xcode 16 或更新版本** 的 Mac 和一个 Apple ID（免费的就可以）；设备需要 iOS / iPadOS 17 或更新版本。

1. **下载代码**：点击本页面绿色的 **Code** 按钮 › **Download ZIP**，然后解压。（也可以用 `git clone`。）
2. **打开项目**：双击 `LocalAIChat.xcodeproj`，会用 Xcode 打开。
3. **设置签名**：点击 Xcode 左侧最上方蓝色的 *LocalAIChat* › Target *LocalAIChat* › **Signing & Capabilities**：
   - **Team**：选择你的 Apple ID（没有的话在 Xcode › Settings › Accounts 里添加）。
   - **Bundle Identifier**：把 `com.example.LocalAIChat` 改成独一无二的名字，例如 `com.yourname.LocalAIChat`。
4. **运行**：用数据线连接 iPhone / iPad，在 Xcode 顶部选择你的设备，点击 **▶︎** 运行。
5. **仅第一次**，在设备上：
   - 设置 › 隐私与安全性 › **开发者模式** › 打开（设备会重启）。
   - 设置 › 通用 › VPN 与设备管理 › 信任你的开发者证书。

> 使用免费 Apple ID 安装的 App 7 天后会过期，到时在 Xcode 里再点一次运行即可；付费开发者账号有效期为 1 年。

### 首次使用

1. 点左上角 ⚙️ › 服务器 › 填写地址、选择接口类型（或用「快速填写常用服务」）› **测试连接并获取模型** › 选择默认模型 › 保存。
2. 选择一个助手（或点 **+** 从模板新建），开始聊天。
3. 点输入框左边的 ⊕ 添加图片或视频。

### 隐私与安全

- 对话、记忆和设置只保存在本机，消息只会发送到你自己配置的服务器。
- API Key 目前保存在 App 的本地数据文件中（尚未使用钥匙串）。
- 浏览器助手会把网页文字当作数据而不是指令，敏感操作前会请你确认；但在已登录的网站上使用时，仍请留意它的操作。

---

## Project structure · 项目结构

```
LocalAIChat/
├── App/LocalAIChatApp.swift            App entry · 应用入口
├── Models/
│   ├── Models.swift                    Data models · 数据模型
│   ├── PersonaTemplates.swift          Built-in persona templates · 内置人格模板
│   └── Utilities.swift                 Storage, image cache, helpers · 存储、缓存、工具函数
├── Services/
│   ├── AppStore.swift                  State, persistence, chat generation · 全局状态与对话生成
│   ├── AppStore+Memory.swift           Long-term memory & rolling summary · 长期记忆与摘要
│   ├── AppStore+Agent.swift            Tool-calling agent loop · 工具调用循环
│   ├── AppStore+Context.swift          Pinning, excluding & forking · 置顶、排除与分支
│   ├── LLMClient.swift                 Server APIs (streaming) · 服务器接口（流式）
│   ├── LLMClient+Tools.swift           Tool calling for OpenAI / Ollama / Anthropic · 工具调用
│   ├── RetryPolicy.swift               Auto-reconnect & resume · 断线重传
│   ├── UsageTracking.swift             Tokens, context & cost · 用量、上下文与费用
│   ├── BrowserSession.swift            Built-in browser (WKWebView) · 内置浏览器
│   ├── BrowserTools.swift              Browser tools for the model · 浏览器工具
│   ├── ImageProcessor.swift            Image compression · 图片压缩
│   ├── VideoFrameExtractor.swift       Video frame extraction · 视频抽帧
│   └── MediaImport.swift               Photos / Files import · 相册与文件导入
└── Views/                              SwiftUI views · 界面
Info.plist                              Network permissions · 网络权限
```

## License · 许可证

[MIT](LICENSE) — free to use, modify and share, keeping the copyright notice.
MIT 许可证：可以自由使用、修改和分享，只需保留版权声明。
