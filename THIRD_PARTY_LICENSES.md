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
- Used for: WhisperKit model/tokenizer support

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
