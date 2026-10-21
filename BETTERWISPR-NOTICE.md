# BetterWispr reference

Source: https://github.com/opennookorg/betterwispr

Reviewed revision: `4021a0f402bd72eed939e2198d52a93512e56f40`

License: Apache-2.0, included as BETTERWISPR-LICENSE.txt.

This application is independent of BetterWispr. The following implementation ideas/settings were adapted, without importing its full application or feature set:

- `Sources/BetterWisprCore/Speech/WhisperKitProvider.swift`: whole-recording Whisper transcription, automatic language detection, VAD chunking, decoding quality thresholds and temperature fallback settings.
- `Sources/BetterWispr/App/AppModel.swift`: record, stop, recognize, clean, optionally polish, then deliver once.
- `Sources/BetterWisprCore/Integrations/TextOutput.swift`: one paste event directed to the target application, focus checks, 750 ms clipboard restoration delay, and preserving user clipboard changes.
- `Sources/BetterWisprCore/Transcription/TranscriptCleaner.swift`: conservative filler cleanup with protection for meaningful repetitions and units. Our Chinese/mixed-language cleanup rules are independently implemented.

Upstream light cleanup is primarily English. Its stronger text polishing can use a configured local or remote language model. Our optional text-only OpenAI-compatible API path remains separate and disabled by default.
