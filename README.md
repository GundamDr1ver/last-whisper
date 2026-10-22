# 最后的轻语 · 流式听写

macOS 菜单栏语音输入，SwiftUI + AppKit，Apple Silicon、macOS 15+。F5 映射到 F13 后，轻按开始，再按停止。

## 使用流程

录音时识别结果持续显示在可移动的单行半透明字幕条上；文字变长时跟随末尾。字幕条不获取键盘焦点，不修改目标输入框。停止后收齐最后一段，再向停止时的光标位置粘贴一次。处理中移动光标或切换应用会取消自动粘贴，已识别文字保存在剪贴板。

不显示 Dock 图标。开始和结束保留 212 毫秒 CC0 提示音，播放音量 0.55。设置从菜单栏进入，麦克风与辅助功能权限由 macOS 正常请求；请求权限不会自动打开系统设置。

## 模型选择

设置中的“模型选择”分为本地模型和云端模型，默认本地 VibeVoice。两种模式使用固定大小的设置区域和窗口。

### 本地

- **VibeVoice-ASR-Streaming 1.5B Q8_0（默认）**：约 3.34 GB。来自微软流式模型的社区 GGUF 转换，使用 audio.cpp 与 Apple Metal 运行，保持流式解码状态；按训练时的分块和前瞻配置出字幕，不能保证逐字或 0.5 秒延迟。启动应用自动下载默认模型，开发恢复也可提前运行下载脚本。
- **Qwen3-ASR 0.6B Q8_0**：约 1.15 GB，按需下载。当前引擎使用约 2 秒窗口的分块流式识别。
- **StreamSpeech**：研究模型，尚未接入本机中英听写，界面明确显示不可用，不提供虚假下载按钮。

下载界面提供环形进度、失败提示、重试与取消。下载完成先校验大小与 SHA-256，成功后才能选择。取消不安装半成品，重试会重新下载。开发版优先使用已有的项目 `Models/`；否则或移出 `build/` 后从 `~/Library/Application Support/VoiceInput/Models` 下载和加载。

本地保留“API 润色”开关，新安装默认关闭。开启时只发送最终识别文字，由原有兼容 chat/completions 的服务整理标点、口水词、段落和列表；保留英语原语言，失败退回本地文字。云端模式不显示、不执行额外润色。

### 云端

- **Qwen ASR**：`qwen3-asr-flash-realtime`，中国内地（北京）百炼密钥。连接 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`，16 kHz PCM 流式上传；按 `item_id` 分别维护每句的 `text + stash` 和最终 `transcript`，后一句不会覆盖前一句。停止发送 `session.finish`，等待 `session.finished` 后输入。
- **MiMo ASR**：`mimo-v2.5-asr`，`https://api.xiaomimimo.com/v1/chat/completions`。官方接口是音频文件输入、SSE 文字输出，当前接法明确标为“分段流式”：大约每 4 秒或停顿后仅提交新的音频片段，录音期间也能更新字幕。它不等同于 Qwen 的双向实时连接；分段可能影响长句上下文。

云端模式音频会发送至选定服务商。仅在本地人声门检测到有效语音后建立云端识别连接；持续背景噪声和静音不提交 ASR。极轻、极短发音仍有漏检可能，广播声也可能被视为人声。音频只在内存中处理，没有录音历史。排队超过约 32 秒会明确停止并保留已有字幕，不静默丢失音频。

## 设置、密钥与测试

MiMo、Qwen 和润色密钥分别存入系统钥匙串服务 `local.voiceinput.api`，账号 `asr-mimo`、`asr-qwen`、`polish-key`。输入后短暂防抖自动保存/更新，切换服务商从各自记录填充；界面常驻“输入密钥会自动保存/更新至系统钥匙串”。密钥不进入 UserDefaults、日志或 Git；macOS 首次访问仍可能要求系统授权。

普通选项只在有修改时启用“保存设置”，保存成功后恢复不可用，下次录音生效。密钥单独自动保存。清空密钥输入框不会删除现有钥匙串条目，重新输入非空密钥会更新。

“测试 API”使用固定测试文字（本地润色）或固定测试录音（云端识别），显示结果和错误，不使用麦克风、不自动开启润色，会产生服务商费用。

## 构建与恢复

需要 Xcode 工具链、CMake 3.20+、Git；提前下载模型的脚本需要 Python 3，但运行应用不依赖 Python。

```sh
git clone https://github.com/GundamDr1ver/last-whisper.git
cd last-whisper
./Scripts/build-native.sh
python3 Scripts/download-model.py
./Scripts/build-app.sh
swift test
open 'build/最后的轻语.app'
```

`build-native.sh` 固定 audio.cpp 提交，仅编译相关 ASR 模型及 Metal 后端，产物位于忽略的 `.native/`。应用包含原生动态库；大型模型不提交 GitHub。临时签名更新后可能需要重新授予辅助功能权限。

`--stream-smoke` 用附带中英测试录音运行真实默认模型，记录停止前的字幕更新、加载和推理耗时；不使用麦克风、不调用 API、不粘贴文字。可通过 `VOICEINPUT_MODEL_ROOT` 指定模型目录、`VOICEINPUT_SMOKE_REPORT` 指定报告位置。

历史 `Capture-validation.json`、`Whisper-validation.json` 和 `VAD-validation.json` 来自旧版检查，不代表新引擎性能。新的实测另存 `Streaming-validation.json`。真实麦克风、不同应用输入框以及付费云端账号仍需实际验证。

## 来源

- [Microsoft VibeVoice](https://github.com/microsoft/VibeVoice) 与 [流式说明](https://github.com/microsoft/VibeVoice/blob/main/docs/vibevoice-asr-streaming.md)
- [audio.cpp](https://github.com/0xShug0/audio.cpp)，见 `AUDIOCPP-NOTICE.md` 和 `AUDIOCPP-LICENSE.txt`
- [Qwen 实时识别](https://help.aliyun.com/zh/model-studio/qwen-real-time-speech-recognition)
- [MiMo ASR 官方说明](https://mimo.mi.com/docs/en-US/quick-start/usage-guide/audio/Speech-Recognition)
- 既有 BetterWispr、Silero 和 CC0 音效来源及许可继续保留在项目内。

本机正式构建检查：25 项自动测试通过；5.74 秒中英录音在送入约 3.5 秒音频后产生首条字幕，连续 18.23 秒样本产生 6 次更新。纯推理分别约 2.1 秒和 5.1 秒。物理内存峰值约 3.69 GB、最大常驻集约 6.42 GB；这些是文件加速输入测试，不能当作真实麦克风首字延迟，长录音和系统负载还会改变表现。
