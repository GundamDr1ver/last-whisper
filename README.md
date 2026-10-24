# speakeasy

macOS 菜单栏语音输入。按 F13（F5 映射）开始录音，再按一次停止；结束后识别完整录音，再向当前光标位置输入一次。录音时只显示小型音量指示条，不显示实时识别文字。无 Dock 图标、订阅、历史记录或遥测。

## 设置

“模型选择”可在本地和云端之间切换，窗口尺寸、下面的润色区和保存按钮位置保持固定。本地提供 Qwen3-ASR 1.7B Q8（2.47 GB）、VibeVoice 1.5B 和 Whisper Large v3 Turbo Q8（874 MB），列表超出固定高度时可滚动；模型下载具有进度、校验、取消和重试。新安装默认选择并自动下载 Qwen3-ASR 1.7B Q8，其他两个模型仅在点击下载后安装，后台准备所选模型。

云端预设为 Qwen ASR 和 MiMo ASR，直接显示并允许编辑名称、完整接口地址、模型名称和密钥；“添加”可保存多个自定义模型，“删除”移除当前自定义模型，点击保存后生效；预设不可删除，已有钥匙串密钥保留。支持兼容 OpenAI 的音频 chat/completions 接口，以及以 `/audio/transcriptions` 结尾的 multipart 音频转写接口。自定义服务仍需提供对应接口格式。

预设地址与模型：

| 预设 | 接口地址 | 模型名称 |
| --- | --- | --- |
| Qwen ASR | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` | `qwen3-asr-flash` |
| MiMo ASR | `https://api.xiaomimimo.com/v1/chat/completions` | `mimo-v2.5-asr` |

API 润色是独立设置，适用于本地和云端识别，默认关闭。启用后把原始转写交给文本转换器，结合四组示例清理口头禅、改口和结巴，修正明确的 ASR 错字及术语，规范中英间距、数字、标点和列表，不回答或执行转写里的请求。

润色服务以流式接收，完整成功后一次性输入；15 秒超时、断流、截断、拒绝或异常空结果都回退原文。纯停顿词过滤、明确短答可本地直通。润色会参考已知应用场景，以及当前输入框光标前最多 300 字（若可读取）；这段文本会随转写发送给配置的润色 API。未知应用或浏览器页面保持通用风格，上下文不可读就省略。识别 API 与润色 API 分别测试、分别存储密钥。完整规则、实现范围与保守处理见 [润色说明](Docs/Polishing.md)。

密钥输入后自动保存到系统钥匙串服务 `local.voiceinput.api`。预设账号继续使用 `asr-qwen`、`asr-mimo`，自定义模型使用各自的 UUID 账号，润色使用 `polish-key`。切换模型会保留各自的密钥；非空新密钥会更新，清空输入框不会删除已存条目。其他配置保存在 UserDefaults；“保存设置”仅在有修改时可用，成功后恢复不可用，下次录音生效。系统首次访问钥匙串仍可能要求用户授权。

## 录音和输入

使用 macOS 自带的 `dt-begin.caf` / `dt-confirm.caf` 原始听写提示音，在本机运行时读取，不复制或分发系统声音；旧系统资源缺失时才使用附带的 CC0 音效。AVAudioPlayer 提前准备，不重采样、不合成、不放大声音。开始音播放结束后才写入录音，停止收音后才播放结束音，避免提示音进入识别音频。请在开始音结束后讲话。

临时录音为私有目录中的 16 kHz 单声道 WAV，结束处理后删除。停止后先进行本地 Silero 人声检测；没有有效人声则不运行识别、也不调用云端或润色 API。本地识别不上传音频，云端识别只在录音结束且存在有效人声时上传一次完整音频。极轻、极短发音可能被过滤，广播人声也可能被识别。

输入位置在停止时捕获；处理中移动光标、编辑文本或切换应用会取消自动粘贴，保留已识别文字至剪贴板。不会选中或替换已有文字。原剪贴板在粘贴后恢复，期间用户复制的新内容会保留。首次使用需要麦克风和辅助功能权限；开发临时签名更新可能需要重新授权。

“测试识别 API”上传固定中英测试录音；“测试润色 API”发送固定测试文字。测试不会使用麦克风或自动输入文字，会产生服务商费用。

## 下载排查

旧千问 0.6B 下载曾完整核对成功；当前默认已升级为 1.7B Q8，固定 2,473,017,600 字节并校验 SHA-256。旧下载调用没有触发进度回调，容易一直显示“正在连接”；现改用 URLSessionDownloadTask 的原生下载委托，并在委托返回前接管临时文件。真实网络诊断已确认可获得进度更新；当前完整模型校验和旧模型清理结果见 `Download-validation.json`。

针对临时网络错误、过期下载跳转和服务端限流，最多自动重试三次并重新获取下载跳转；每次忽略旧缓存，避免复用失效响应。HTTP 错误会显示状态码。下载成功后校验大小和 SHA-256，校验通过才安装；取消或失败不安装半成品。模型默认位于 `~/Library/Application Support/VoiceInput/Models`；开发版若已有项目 `Models/` 则优先使用。

## 构建与检查

需要 Apple Silicon、macOS 15+、Xcode 工具链、CMake 3.20+ 和 Git。应用运行不需要 Python；预先下载默认模型的脚本需要 Python 3。

```sh
git clone https://github.com/GundamDr1ver/last-whisper.git
cd last-whisper
./Scripts/build-native.sh
./Scripts/build-whisper.sh
python3 Scripts/download-model.py
./Scripts/build-app.sh
swift test
open 'build/speakeasy.app'
```

Qwen 和 VibeVoice 复用已固定版本的 audio.cpp，通过 Apple Metal 识别。Whisper 使用固定版本 whisper.cpp v1.8.3 的独立本机程序，避免两套 ggml 符号冲突；自动检测语言且不开启翻译，临时音频仅本机处理并删除。Whisper 在停止录音后载入模型，暂不常驻预热；来源、实际模型文件和许可见 `AUDIOCPP-NOTICE.md`。模型及原生构建产物不提交至 Git。BetterWispr、Silero 和旧 CC0 备用提示音的来源许可继续保留。

`--recognition-smoke` 使用固定中英录音验证已安装本地模型，不使用麦克风、付费 API 或文本输入；结果见 `Recognition-validation.json`。`--download-smoke` 下载千问文件的 1 MB 范围用于验证真实进度回调，不额外下载完整模型。旧版 Whisper、收音延迟等报告为历史检查，不代表当前模型性能。
