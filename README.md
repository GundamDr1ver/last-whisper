# speakeasy

macOS 菜单栏语音输入。按 F13（F5 映射）开始录音，再按一次停止；结束后识别完整录音，再向当前光标位置输入一次。录音时显示音量悬浮条，前端是圆圈内实心方块的停止图标，不显示实时识别文字。点击整条悬浮窗或长按 F13 约 0.6 秒可取消，丢弃本次录音，不输入或复制文字；准备和识别阶段也可取消。短按 F13 在松开时停止并输入，避免长按时提前提交。悬浮条取消后立即隐藏，不能拖动。无 Dock 图标、订阅、历史记录或遥测。

## 设置

“模型选择”可切换本地和云端，窗口与模型区域大小保持固定。不提供在线润色，识别结果直接输入。

本地提供 Qwen3-ASR 1.7B Q8（默认）、VibeVoice 1.5B 和 Whisper Large v3 Turbo Q8。下载支持进度、校验、取消和重试；已下载模型旁有“删除”按钮，删除前卸载，录音和识别期间不可删除。删除后可重新下载，手动删除默认千问后不会自动下载回来。本地模型选择继续保留，删除所选模型不会自动换模型，需重新下载或手动选择其他模型。

云端提供 Qwen ASR（`qwen3-asr-flash`）与 MiMo ASR（`mimo-v2.5-asr`），显示可编辑的完整接口地址与模型名，可添加、删除自定义模型。支持 OpenAI 兼容的音频 `/chat/completions` 和 `/audio/transcriptions` 接口；测试按钮发送固定测试音频并显示结果，可能产生服务商费用。录音结束且检测到人声后才上传一次录音，不调用文字润色服务。

预设接口：千问 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`，MiMo `https://api.xiaomimimo.com/v1/chat/completions`。千问支持将旧域名替换为业务空间专属域名，详见[千问官方文档](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)；MiMo 参数见[官方文档](https://mimo.mi.com/docs/zh-CN/api/audio/Speech-Recognition)。

密钥输入后自动保存/更新至系统钥匙串服务 `local.voiceinput.api`，各模型分别保存，兼容原有 `asr-qwen`、`asr-mimo`、自定义 `asr-UUID` 账号。仅云端模式读取对应密钥，清空输入框不删除原密钥；删除自定义模型也保留钥匙串条目。旧润色设置和 `polish-key` 不读取。升级后默认保持本地，需主动选择云端并保存，才会上传录音。

“保存设置”仅在配置修改时可用，成功后恢复不可用，下次录音生效；密钥单独自动保存。

## 录音和输入

使用 macOS 自带的 `dt-begin.caf` / `dt-confirm.caf` 原始听写提示音，在本机运行时读取，不复制或分发系统声音；旧系统资源缺失时才使用附带的 CC0 音效。AVAudioPlayer 提前准备，不重采样、不合成、不放大声音。开始音播放结束后才写入录音，停止收音后才播放结束音，避免提示音进入识别音频。请在开始音结束后讲话。

临时录音为私有目录中的 16 kHz 单声道 WAV，结束处理后删除。停止后先进行本地 Silero 人声检测；没有有效人声则不运行识别。本地识别不上传音频。极轻、极短发音可能被过滤，广播人声也可能被识别。

输入位置在停止时捕获；处理中移动光标、编辑文本或切换应用会取消自动粘贴，保留已识别文字至剪贴板。不会选中或替换已有文字。原剪贴板在粘贴后恢复，期间用户复制的新内容会保留。首次使用需要麦克风和辅助功能权限；开发临时签名更新可能需要重新授权。

## 数字格式

本地与云端识别后，使用内置 WeTextProcessing C++ 引擎在本机转换明确的中文数字：`八 → 8`、`零点五 → 0.5`、`零点零五 → 0.05`、`零点三点八 → 0.3.8`、`百分之三十 → 30%`。已有阿拉伯数字不重复改写，保留原标点、空格与 Whisper 分段换行。

仅处理边界、单位、小数点或数字标签明确的片段。使用上游保护词表保留“一起”“三心二意”等表达；“一点意见”“一定”“一方面”等词语，以及“三五百”“十五六”这种模糊范围保持原样，网址和反引号代码片段不转换。没有明确数字语境的表达可能保留中文；暂不转换英文数字词。

小数及版本号按点分段，保留小数位前后零，避免上游时间规则把“零点零五”解释为“00:05”。整数部分复用现成解析器。失败时输入原识别结果并提示，不阻断输入。规则随应用内置，无 Python、联网或在线润色开销。来源、固定版本和许可证见 [WETEXT-NOTICE.md](WETEXT-NOTICE.md)。

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
./Scripts/build-text-normalizer.sh
python3 Scripts/download-model.py
./Scripts/build-app.sh
swift test
open 'build/speakeasy.app'
```

Qwen 和 VibeVoice 复用已固定版本的 audio.cpp，通过 Apple Metal 识别。Whisper 使用固定版本 whisper.cpp v1.8.3 的独立本机程序，避免两套 ggml 符号冲突；自动检测语言且不开启翻译，临时音频仅本机处理并删除。Whisper 在停止录音后载入模型，暂不常驻预热；来源、实际模型文件和许可见 `AUDIOCPP-NOTICE.md`。模型及原生构建产物不提交至 Git。BetterWispr、Silero 和旧 CC0 备用提示音的来源许可继续保留。

`--recognition-smoke` 使用固定中英录音验证已安装本地模型，不使用麦克风或文本输入；结果见 `Recognition-validation.json`。`--download-smoke` 下载千问文件的 1 MB 范围用于验证真实进度回调，不额外下载完整模型。旧版 Whisper、收音延迟等报告为历史检查，不代表当前模型性能。
