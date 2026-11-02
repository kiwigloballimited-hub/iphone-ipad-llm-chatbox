# 本地 AI 聊天（iPhone / iPad）

一个连接**局域网本地 AI 服务器**的 SwiftUI 应用，支持 iPhone 和 iPad。

## 功能

### 1. 图片压缩 & 视频解码抽帧
- **图片压缩**：使用 ImageIO 下采样（省内存，支持 HEIC、自动校正方向），然后编码为 JPEG。
  - 可设置：最长边（512–2048 px / 不缩放）、JPEG 质量、单张大小上限（超出时自动继续降质 / 缩小）。
  - 发送前会显示压缩前后的大小。
- **视频抽帧**：使用 AVFoundation 解码视频画面。
  - 两种方式：**均匀抽取 N 帧**，或**每隔 X 秒抽一帧**（可设上限）。
  - 可设置帧分辨率、JPEG 质量。
  - 抽帧后会显示预览网格，可以勾选或取消每一帧，长按查看大图，也可以修改参数后重新抽帧。
  - 发送时自动告诉模型每一帧的时间点，便于模型按时间顺序理解视频。
- 图片和视频可以从相册或「文件」App 中选择，一次最多选 10 个。

### 2. 多个独立 Agent + 人格设定
- 可以创建任意多个助手，每个助手都有**独立的**：
  - 头像（emoji）、名称
  - **人格设定**：身份 / 性格 / 说话风格 / 背景故事 / 行为准则 / 对话示例，也可以直接写完整的系统提示词
  - 开场白
  - 服务器、模型、温度、最大长度、记忆的历史条数、**重复惩罚**（重复惩罚 / 频率惩罚 / 存在惩罚）
  - **思考强度**（自动 / 关闭 / 低 / 中 / 高），适用于 Qwen3、DeepSeek-R1、gpt-oss 等推理模型；聊天界面右上角菜单也可以快速切换
  - 对话记录（每个助手可以有多个对话）
- **记忆**：
  - **长期记忆（跨会话）**：每个助手有自己的记忆本，内容会带入它的所有对话。可以手动添加 / 编辑，也可以在聊天菜单里「记住这次对话」（确认后保存），或开启「自动记住新信息」。
  - **长对话自动摘要**：同一对话超过设定的历史条数后，早期内容会被压缩成摘要继续保留。
- 内置模板：通用助手、写作伙伴、小老师、英语陪练、图像分析师。
- 可以预览由人格设定生成的系统提示词。

### 3. 浏览器助手（AI 操作网页）
- 在助手设置中打开「允许使用浏览器」，或用「浏览器助手」模板新建。
- AI 可以：搜索、打开网址、阅读网页（长页面分段读）、点击、输入文字 / 选择下拉框、滚动、返回。
- 浏览器显示在聊天旁边（iPad）或上方（iPhone，可折叠），你可以看到 AI 的每一步，也可以自己直接操作。
- 登录、付款、提交表单、发送等操作会弹窗请你确认；网页里的文字被当作数据，不会被当作指令执行。
- 需要支持工具调用（function calling）的模型：Qwen3、DeepSeek、Claude、gpt-oss、Llama 3.1+ 等。
- 使用 Ollama 时，网页内容较长，建议把上下文长度调大（例如在 Ollama 设置中把 Context length 设为 16K 以上）。

### 其他
- 流式输出、随时停止、重新生成、复制 / 选择文本
- 支持推理模型（DeepSeek-R1、QwQ、Qwen3 等）的「思考过程」折叠显示
- iPad 上是三栏布局（助手 › 对话 › 聊天），iPhone 上是逐级进入
- 所有数据只保存在本机

## 支持的服务器

| 服务 | 接口类型 | 地址示例 |
|---|---|---|
| Ollama | Ollama 原生 或 OpenAI 兼容 | `http://192.168.1.10:11434` |
| LM Studio | OpenAI 兼容 | `http://192.168.1.10:1234` |
| llama.cpp server | OpenAI 兼容 | `http://192.168.1.10:8080` |
| vLLM / 其它 OpenAI 兼容服务 | OpenAI 兼容 | `http://192.168.1.10:8000` |
| DeepSeek（云端） | OpenAI 兼容 | `https://api.deepseek.com`（需要 API Key） |
| Anthropic Claude（云端） | Anthropic | `https://api.anthropic.com`（需要 API Key） |

地址填到端口即可（填写带 `/v1` 的地址也可以）。

**在外面也想用？** 可以用 [Tailscale](https://tailscale.com)：电脑和 iPhone / iPad 都登录同一个 Tailscale 账号后，把地址填成电脑的 Tailscale IP（`http://100.x.x.x:端口`）或 MagicDNS 名称即可。服务器同样需要允许非本机访问（见下文）。

**要识别图片或视频，需要使用视觉模型**，例如 `qwen2.5vl`、`gemma3`、`llama3.2-vision`、`minicpm-v`。

### 让服务器允许局域网访问
- **Ollama**：默认只监听本机。需要设置环境变量 `OLLAMA_HOST=0.0.0.0` 后重启 Ollama。
  - macOS：`launchctl setenv OLLAMA_HOST "0.0.0.0"`，然后重启 Ollama 应用
  - Windows：在「系统环境变量」中添加 `OLLAMA_HOST` = `0.0.0.0`，然后重启 Ollama
- **LM Studio**：在 Developer / Server 页面打开「Serve on Local Network」。
- 电脑防火墙需要放行对应端口。
- 第一次连接时，iPhone / iPad 会询问是否允许「本地网络」访问，请选择**允许**。如果之前点了拒绝，可以到「设置 › 隐私与安全性 › 本地网络」中打开。

## 如何安装到 iPhone / iPad

需要一台安装了 **Xcode 16 或更新版本** 的 Mac。

1. 用 Xcode 打开 `LocalAIChat.xcodeproj`。
2. 在左侧选中项目 › Target「LocalAIChat」› **Signing & Capabilities**：
   - Team 选择你的 Apple ID（免费的 Apple ID 也可以）；
   - 如果提示 Bundle Identifier 已被占用，把 `com.example.LocalAIChat` 改成你自己的，例如 `com.yourname.LocalAIChat`。
3. 用数据线连接 iPhone / iPad，在 Xcode 顶部选择你的设备，点击 ▶️ 运行。
4. 第一次安装时，需要在设备上打开「设置 › 通用 › VPN 与设备管理」，信任你的开发者证书。
   - iOS 16 以上还需要打开「设置 › 隐私与安全性 › 开发者模式」。

> 使用免费 Apple ID 签名的应用 7 天后会过期，到时用 Xcode 重新运行一次即可；付费开发者账号有效期为 1 年。

## 首次使用
1. 打开应用 › 左上角 ⚙️ 设置 › 点击默认服务器，填写你的服务器地址、选择接口类型。
2. 点击「测试连接并获取模型」，成功后选择默认模型，保存。
3. 回到助手列表，选择一个助手（或点击 + 新建），开始对话。
4. 点击输入框左边的 ⊕ 添加图片或视频。

## 项目结构

```
LocalAIChat/
├── App/LocalAIChatApp.swift          应用入口
├── Models/
│   ├── Models.swift                  数据模型（服务器、助手、人格、消息、媒体设置）
│   ├── PersonaTemplates.swift        内置人格模板
│   └── Utilities.swift               存储、图片缓存、格式化、<think> 解析
├── Services/
│   ├── AppStore.swift                全局状态、持久化、对话生成
│   ├── LLMClient.swift               OpenAI 兼容 / Ollama 原生接口（流式）
│   ├── ImageProcessor.swift          图片压缩
│   ├── VideoFrameExtractor.swift     视频解码抽帧
│   └── MediaImport.swift             相册 / 文件导入
└── Views/                            SwiftUI 界面
Info.plist                            允许局域网 HTTP 连接、本地网络权限说明
```

最低系统要求：iOS / iPadOS 17。
