# Local number normalization

Uses [WeTextProcessing](https://github.com/wenet-e2e/WeTextProcessing) revision
`0c9395098e122e60e649250877637b7c332dc433` under Apache-2.0.
The unmodified upstream C API header is in `NativeText/`; the build script pins
and builds the upstream C++ runtime, with OpenFST, glog and gflags linked statically.
Their license texts are bundled in `Resources/NativeLicenses`.

Chinese ITN graphs are the official `WeTextProcessing` release assets:

- `zh_itn_tagger.fst`: SHA-256 `ae9f5389aa65c1d24dc7bc761fe0b9c751bb76a152cc917af5bc52bb93b76563`
- `zh_itn_verbalizer.fst`: SHA-256 `6aead1b68211a2bb56b6805e7840034e076b17b176d703cea153d15262680f53`

`protected-words.tsv` is copied from the pinned upstream Chinese ITN whitelist.
The Swift caller only processes numeric spans with clear boundaries, decimal
points, units or number labels. Protected phrases, URLs and backtick literals
are not modified. Unclear Chinese phrases and approximate ranges are retained.
This avoids observed whole-sentence mistakes such as `一点意见` -> `1点意见`.

Decimal/version segments preserve digit-by-digit fractional zeros instead of
using the complete time/number grammar: the official graph reads `零点零五`
as the time `00:05`. Integer components still use WeText's number parser.
English words are not normalized. Punctuation and line breaks are unchanged.
There is no Python runtime, network request or LLM polishing step.
