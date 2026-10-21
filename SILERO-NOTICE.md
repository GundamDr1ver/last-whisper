# Local speech gate

Model: Silero VAD v6.0.0, compiled CoreML artifact obtained from https://github.com/paean-ai/silero-vad-swift at `9f03b552e8131b37498495cbc6f0a6e2a47e58c8`.

The upstream model originated from https://huggingface.co/FluidInference/silero-vad-coreml and https://github.com/snakers4/silero-vad . Licenses are included in SILERO-LICENSE.txt and SILERO-THIRD-PARTY-NOTICES.txt and in the application resource bundle.

CoreML feature names and recurrent-state handling in SpeechGate.swift are adapted from the MIT-licensed wrapper. Our frame stepping includes 64 samples of context plus 512 new samples at 16 kHz, with fresh zeroed recurrent state for each recording. Our temporal evidence and padding policy are independent.

ESC-50 environmental samples are downloaded only to the intermediate work directory for local evaluation, with per-file provenance, and are not distributed in the app. See https://github.com/karolpiczak/ESC-50 for attribution and dataset terms.
