# speakeasy

macOS 菜单栏语音输入。按 F13（F5 映射）开始录音，再按一次停止；结束后识别完整录音，再向当前光标位置输入一次。录音时只显示小型音量指示条，不显示实时识别文字。无 Dock 图标、订阅、历史记录或遥测。

## 设置

“模型选择”仅提供本地模型：Qwen3-ASR 1.7B Q8（2.47 GB）、VibeVoice 1.5B 和 Whisper Large v3 Turbo Q8（874 MB）。列表超出固定高度时可滚动；模型下载具有进度、校验、取消和重试。新安装默认选择并自动下载 Qwen3-ASR 1.7B Q8，其他两个模型仅在点击下载后安装，后台准备所选模型。

“保存设置”仅在模型选择发生修改时可用，保存成功后恢复不可用，下次录音生效。旧版本的本地模型选择继续保留；旧云端和润色设置不再读取，无论以前是否启用，都只使用本地模型。识别结果直接输入，不再额外润色、去口头禅或改写。

不再提供云端识别、API 润色或密钥输入，也不再读写系统钥匙串。旧钥匙串条目保留，应用不会主动访问或删除；如不再需要，可在“钥匙串访问”中自行删除服务 `local.voiceinput.api` 的条目。网络仅用于主动下载模型或首次自动下载默认模型；录音及文字不上传。

## 录音和输入

使用 macOS 自带的 `dt-begin.caf` / `dt-confirm.caf` 原始听写提示音，在本机运行时读取，不复制或分发系统声音；旧系统资源缺失时才使用附带的 CC0 音效。AVAudioPlayer 提前准备，不重采样、不合成、不放大声音。开始音播放结束后才写入录音，停止收音后才播放结束音，避免提示音进入识别音频。请在开始音结束后讲话。

临时录音为私有目录中的 16 kHz 单声道 WAV，结束处理后删除。停止后先进行本地 Silero 人声检测；没有有效人声则不运行识别。本地识别不上传音频。极轻、极短发音可能被过滤，广播人声也可能被识别。

输入位置在停止时捕获；处理中移动光标、编辑文本或切换应用会取消自动粘贴，保留已识别文字至剪贴板。不会选中或替换已有文字。原剪贴板在粘贴后恢复，期间用户复制的新内容会保留。首次使用需要麦克风和辅助功能权限；开发临时签名更新可能需要重新授权。

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

`--recognition-smoke` 使用固定中英录音验证已安装本地模型，不使用麦克风或文本输入；结果见 `Recognition-validation.json`。`--download-smoke` 下载千问文件的 1 MB 范围用于验证真实进度回调，不额外下载完整模型。旧版 Whisper、收音延迟等报告为历史检查，不代表当前模型性能。
