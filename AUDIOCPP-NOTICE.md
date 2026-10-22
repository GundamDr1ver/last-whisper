# Local recognition

The bundled native inference library is built from https://github.com/0xShug0/audio.cpp at revision `fb129222ca6f7c7b066c8c70bc99ecd9c6330e8f`, enabling only `vibevoice_asr` and `qwen3_asr` with CPU/Apple Metal. No TTS, eSpeak, cloud server, Python inference environment or telemetry is included.

`NativeAudio/audiocpp.h` is the upstream C API header. The library is rebuilt by `Scripts/build-native.sh`; it is not committed to Git. License copies for the selected runtime and its vendored dependencies are bundled in `Sources/VoiceInput/Resources/NativeLicenses`.

Optional checkpoint: Microsoft VibeVoice-ASR-Streaming-1.5B, using the community Q8_0 GGUF conversion at https://huggingface.co/christopherthompson81/VibeVoice-ASR-Streaming-1.5B-GGUF. This is a quantized conversion of Microsoft's model, not an official Microsoft Mac runtime. Upstream code/model: https://github.com/microsoft/VibeVoice and https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-1.5B (MIT).

Default checkpoint: Qwen3-ASR-1.7B Q8_0, https://huggingface.co/audio-cpp/audio.cpp-gguf/tree/main/Qwen3-ASR-1.7B-GGUF. Upstream https://github.com/QwenLM/Qwen3-ASR (Apache-2.0). Both models are invoked in offline mode after recording ends.

Large weights are downloaded separately and verified against fixed size and SHA-256 before installation.

Optional Whisper Large v3 Turbo Q8_0: https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo-q8_0.bin (MIT). Invoked after recording using the bundled whisper.cpp CLI at https://github.com/ggml-org/whisper.cpp revision `2eeeba56e9edd762b4b38467bab96c2517163158` (v1.8.3, MIT), CPU/Apple Metal, automatic language detection with translation disabled. Its static ggml is isolated in a separate executable. Build with `Scripts/build-whisper.sh`; license copies are bundled in NativeLicenses. No weights download unless requested.
