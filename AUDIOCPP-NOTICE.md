# Local recognition

The bundled native inference library is built from https://github.com/0xShug0/audio.cpp at revision `fb129222ca6f7c7b066c8c70bc99ecd9c6330e8f`, enabling only `vibevoice_asr` and `qwen3_asr` with CPU/Apple Metal. No TTS, eSpeak, cloud server, Python inference environment or telemetry is included.

`NativeAudio/audiocpp.h` is the upstream C API header. The library is rebuilt by `Scripts/build-native.sh`; it is not committed to Git. License copies for the selected runtime and its vendored dependencies are bundled in `Sources/VoiceInput/Resources/NativeLicenses`.

Checkpoint used by default: Microsoft VibeVoice-ASR-Streaming-1.5B, using the community Q8_0 GGUF conversion at https://huggingface.co/christopherthompson81/VibeVoice-ASR-Streaming-1.5B-GGUF. This is a quantized conversion of Microsoft's model, not an official Microsoft Mac runtime. Upstream code/model: https://github.com/microsoft/VibeVoice and https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-1.5B (MIT).

Optional checkpoint: Qwen3-ASR-0.6B Q8_0, https://huggingface.co/audio-cpp/audio.cpp-gguf/tree/main/Qwen3-ASR-0.6B-GGUF. Upstream https://github.com/QwenLM/Qwen3-ASR (Apache-2.0). Both models are invoked in offline mode after recording ends.

Large weights are downloaded separately and verified against fixed size and SHA-256 before installation.
