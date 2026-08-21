# Third-Party Software Attributions

This project bundles or downloads third-party software components. The following attributions summarize the relevant source, license, and usage information for those components.

## FFmpeg

- Version: 8.0.1
- License: GPL-2.0-or-later
- Build/source: Static builds from `ffmpeg.martin-riedl.de`
- Official source: <https://ffmpeg.org/>
- Notes: Compiled with `--enable-gpl` and includes `libx264` and `libx265`
- Used for: Audio/video format conversion

## yt-dlp

- License: The Unlicense (public domain)
- Download source: <https://github.com/yt-dlp/yt-dlp>
- Used for: YouTube audio extraction

## Node.js

- License: MIT License
- Source: <https://nodejs.org/>
- Used for: Bundled runtime for yt-dlp JavaScript extractors

## LocalVQE

- License: Apache License 2.0
- Source: <https://github.com/localai-org/LocalVQE>
- Model source: <https://huggingface.co/LocalAI-io/LocalVQE>
- Used for: Optional bundled meeting echo suppression runtime and GGUF model

## ggml

- License: MIT License
- Source: <https://github.com/ggml-org/ggml>
- Used for: LocalVQE runtime backend linked into the meeting echo suppression runtime

## Swift Package Dependencies

### GRDB.swift

- License: MIT License
- Source: <https://github.com/groue/GRDB.swift>

### FluidAudio

- License: MIT License
- Source/notes: Speech recognition SDK for Parakeet, Nemotron, and diarization

### transcribe.cpp

- Version: v0.1.3 upstream baseline
- Annotated tag object: `d503d6a239e2a290a03ab72dbd3b40460d87acb0`
- Upstream commit: `a94e021ef658dc7c788837341a13f6acea3baf3c`
- Swift wrapper version: 0.1.3
- License: MIT License
- Upstream source: <https://github.com/handy-computer/transcribe.cpp>
- Owned source: <https://github.com/DudeMeister23/transcribe.cpp>
- Owned implementation commit: `51aa23592167cc32f8f3c5d2155d9f9937324c8d`
- Immutable release: `macparakeet-v0.1.3-arm64.1`
- Release artifact: `TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip`
- Artifact SHA-256: `caad2e1ce80801e5d0adb7e2bb9bcf8e7d1fd295657af281d8260d5dcc629350`
- Release attestation: GitHub Sigstore release attestation verified 2026-07-25
- Build scope: Cohere Transcribe only, through an owned self-built macOS arm64 XCFramework
- Distribution: The XCFramework archive must include the transcribe.cpp, ggml, and miniz license files. Release builds verify the owned commit and archive SHA-256 before embedding it.
- Retained notice: `LICENSES/transcribe.cpp-MIT.txt`

### ggml in transcribe.cpp

- Commit: `707321c4cf6d21cb4bc831aa8b687dbf01a521ce`
- License: MIT License
- Source: <https://github.com/ggml-org/ggml>
- Used for: Native tensor runtime linked into the Cohere transcribe.cpp framework
- Retained notice: `LICENSES/transcribe.cpp-ggml-MIT.txt`

### miniz in transcribe.cpp

- Version: 3.1.1
- Commit: `d10b03cc73475af673df40f06e5cefd1d5f940d9`
- License: MIT License
- Source: <https://github.com/richgel999/miniz>
- Used for: Compression support linked into the Cohere transcribe.cpp framework
- Retained notice: `LICENSES/transcribe.cpp-miniz-MIT.txt`

### WhisperKit

- License: MIT License
- Source: <https://github.com/argmaxinc/argmax-oss-swift>
- Used for: Optional multilingual speech recognition engine

### swift-transformers

- License: Apache License 2.0
- Source: <https://github.com/huggingface/swift-transformers>
- Used for: WhisperKit model/tokenizer support. In `MACPARAKEET_ENABLE_MLX_LOCAL_LLM` builds, MacParakeet also uses the `Tokenizers` product for local-directory tokenizer loading.
- Local MLX pin: `Package.swift` allows `1.1.6..<1.2.0`; the current lockfile resolves `1.1.9`.

### mlx-swift-lm

- Version: 3.31.4
- License: MIT License
- Source: <https://github.com/ml-explore/mlx-swift-lm>
- Build scope: Only present in `MACPARAKEET_ENABLE_MLX_LOCAL_LLM` builds
- Used for: Developer-gated in-process Local MLX model loading and generation (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`)

### mlx-swift

- Version: 0.31.4
- License: MIT License
- Source: <https://github.com/ml-explore/mlx-swift>
- Build scope: Only present in `MACPARAKEET_ENABLE_MLX_LOCAL_LLM` builds
- Used for: MLX tensor/runtime support for the developer-gated in-process Local MLX path; directly pinned so `mlx-swift-lm` resolves the Swift-5.9-compatible MLX version

### swift-jinja

- License: Apache License 2.0
- Source: <https://github.com/huggingface/swift-jinja>
- Used for: Transitive dependency of swift-transformers

### swift-collections

- License: Apache License 2.0
- Source: <https://github.com/apple/swift-collections>
- Used for: Transitive dependency of swift-transformers

### swift-crypto

- License: Apache License 2.0
- Source: <https://github.com/apple/swift-crypto>
- Used for: Transitive dependency of swift-transformers

### swift-asn1

- License: Apache License 2.0
- Source: <https://github.com/apple/swift-asn1>
- Used for: Transitive dependency of swift-crypto

### yyjson

- License: MIT License
- Source: <https://github.com/ibireme/yyjson>
- Used for: Transitive dependency of swift-transformers

### swift-argument-parser

- License: Apache License 2.0
- Source: <https://github.com/apple/swift-argument-parser>

### Sparkle

- License: MIT License
- Source: <https://github.com/sparkle-project/Sparkle>

## Parakeet TDT Model

- License: CC-BY-4.0
- Provider: NVIDIA
- Download source: Hugging Face
- Bundling status: Not bundled in the app; downloaded at runtime

## Whisper Models

- License: MIT License
- Provider: OpenAI Whisper model family, distributed through WhisperKit model downloads
- Bundling status: Not bundled in the app; downloaded at runtime when the user installs a Whisper model

## Cohere Transcribe 03-2026 Q5_K_M Model

- License: Apache License 2.0
- Provider: Cohere
- Repository: `handy-computer/cohere-transcribe-03-2026-gguf`
- Revision: `dfa4adebb64f3076b7b6b90b721275cc069cb421`
- File: `cohere-transcribe-03-2026-Q5_K_M.gguf`
- Size: 1,770,270,208 bytes
- SHA-256: `14d02f1ad6dd77b3a60f82639879012c3adb4fe25c50a5a47a2c4c661daf1558`
- Bundling status: Not bundled in the app; explicitly downloaded at runtime, verified before loading, and used locally afterward
- License text: `LICENSES/Apache-2.0.txt`, also copied into distribution artifacts
- Notice status: The pinned model repository does not contain a separate `NOTICE` file

## Qwen3 4B Instruct DDWQ Local MLX Model

- License: Apache License 2.0
- Provider/source: `mlx-community/Qwen3-4B-Instruct-2507-DDWQ` on Hugging Face
- Base model: `Qwen/Qwen3-4B-Instruct-2507`
- Pinned revision: `88033de44951ebedb96e0adb68cc037443aab93a`
- Bundling status: Not bundled in the app; downloaded from Hugging Face at setup time by the developer-gated Local MLX setup flow, verified against MacParakeet's SHA-256 manifest, and run locally afterward
- Used for: Default model for the developer-gated in-process Local MLX provider
