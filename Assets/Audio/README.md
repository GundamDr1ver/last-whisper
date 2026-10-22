# 备用提示音素材

作者：Kenney
素材包：Interface Sounds (1.0)
来源：https://kenney.nl/assets/interface-sounds
下载：https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip
作者发布的镜像：https://opengameart.org/content/interface-sounds
许可：CC0，原许可文本随应用保存在 Resources/KENNEY-AUDIO-LICENSE.txt。

开始：maximize_003.ogg → recording-start.wav
结束：minimize_003.ogg → recording-stop.wav

仅使用 ffmpeg 转换为 44.1 kHz 单声道 PCM16 WAV，没有重新合成、增益或压缩。仅在系统听写音资源缺失时作为备用，播放音量为 0.65。

两个音效实际时长均约 0.212 秒，均低于 0.3 秒。

原始文件 SHA256：

- maximize_003.ogg: df16f25d45189f5d44d6a482ab20d5067350ca8525a9affa1f8ce599e31a20a5
- minimize_003.ogg: 400e1041499de85ec8b5529a35ff36787288175c4696cf2018ecff24a3a3fd29

当前默认直接读取 macOS AssistantServices 的 dt-begin.caf 与 dt-confirm.caf，使用 AVAudioPlayer 提前准备并播放原始文件，不复制系统声音到项目。开始提示音结束后才写入录音，结束音在停止收音后播放。
