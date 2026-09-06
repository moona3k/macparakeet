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
- Source/notes: Speech recognition SDK

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

### SwiftStreamingMarkdown

- Version: 0.7.0 compatibility fork, pinned at `1f10d5286985349b63145e1193f4f6ad5f7fdfe1`
- License: MIT License
- Source: <https://github.com/microsoft/SwiftStreamingMarkdown>
- Compatibility source: <https://github.com/alfred-sa/SwiftStreamingMarkdown>
- Used for: Rich Markdown rendering in Prompt Results, Chat, and live Ask

### swift-markdown

- Version: 0.7.3
- License: Apache License 2.0
- Source: <https://github.com/swiftlang/swift-markdown>
- Used for: Markdown parsing through SwiftStreamingMarkdown

### HighlightSwift

- Revision: `99c431b38a1444a5fd6a4978307fbbefe3a7af53`
- License: MIT License
- Source: <https://github.com/appstefan/highlightswift>
- Used for: Fenced-code syntax highlighting through SwiftStreamingMarkdown

### iosMath

- Revision: `ba9ab7729b151329c54fd895a7c1859981d9484c`
- License: MIT License
- Source: <https://github.com/junyan72/iosMath>
- Used for: Transitive math-rendering support in SwiftStreamingMarkdown

### Equatable

- Version: 1.4.1
- License: Apache License 2.0
- Source: <https://github.com/ordo-one/equatable>
- Used for: Transitive SwiftStreamingMarkdown support

### SwiftUI-Shimmer

- Version: 1.5.1
- License: MIT License
- Source: <https://github.com/markiv/SwiftUI-Shimmer>
- Used for: Transitive SwiftStreamingMarkdown support

### swift-cmark

- Version: 0.8.0
- License: BSD 2-Clause License
- Source: <https://github.com/swiftlang/swift-cmark>
- Used for: Transitive CommonMark/GFM parsing through swift-markdown

### swift-syntax

- Version: 603.0.2
- License: Apache License 2.0
- Source: <https://github.com/swiftlang/swift-syntax>
- Used for: Transitive swift-markdown build support

## Parakeet TDT Model

- License: CC-BY-4.0
- Provider: NVIDIA
- Download source: Hugging Face
- Bundling status: Not bundled in the app; downloaded at runtime

## Whisper Models

- License: MIT License
- Provider: OpenAI Whisper model family, distributed through WhisperKit model downloads
- Bundling status: Not bundled in the app; downloaded at runtime when the user installs a Whisper model

## Qwen3 4B Instruct DDWQ Local MLX Model

- License: Apache License 2.0
- Provider/source: `mlx-community/Qwen3-4B-Instruct-2507-DDWQ` on Hugging Face
- Base model: `Qwen/Qwen3-4B-Instruct-2507`
- Pinned revision: `88033de44951ebedb96e0adb68cc037443aab93a`
- Bundling status: Not bundled in the app; downloaded from Hugging Face at setup time by the developer-gated Local MLX setup flow, verified against MacParakeet's SHA-256 manifest, and run locally afterward
- Used for: Default model for the developer-gated in-process Local MLX provider
