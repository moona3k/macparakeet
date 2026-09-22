# Homebrew formula for macparakeet-cli.
#
# This file is the macparakeet repo's reference copy for review and
# version control. The live tap publishes from a separate repo:
#
#   https://github.com/moona3k/homebrew-tap
#
# Keep this file in sync with:
#
#   <tap-repo>/Formula/macparakeet-cli.rb
#
# See HOWTO.md for CLI release instructions.

require "json"

class MacparakeetCli < Formula
  desc "Local STT, transcription, and prompt automation for Apple Silicon"
  homepage "https://macparakeet.com"
  url "https://github.com/moona3k/macparakeet/releases/download/cli-v3.1.0/macparakeet-cli-3.1.0-darwin-arm64.tar.gz"
  version "3.1.0"
  sha256 "05d0cb95ac4fb26bc18c5adecb7bb19d2a1892a42dd69bd5fce388f2138426bc"
  license "GPL-3.0-or-later"

  # Apple Silicon only — the Neural Engine is the entire performance story
  depends_on arch: :arm64
  # Runtime media deps (bundled inside MacParakeet.app, but the standalone
  # CLI install needs them on PATH).
  depends_on "ffmpeg"
  depends_on :macos
  depends_on "yt-dlp"

  # macOS 14.2+ (Sonoma) — required by FluidAudio + Swift 6 runtime.
  # Homebrew's `depends_on macos:` only accepts major-version symbols, so
  # `:sonoma` covers 14.0+; the patch-level floor (14.2) is enforced at
  # install time via the `odie` check below.
  on_macos do
    depends_on macos: :sonoma
  end

  def install
    odie "macparakeet-cli requires macOS 14.2 or later" if MacOS.version < "14.2"
    bin.install "macparakeet-cli"
  end

  def caveats
    <<~EOS
      Local Parakeet, Nemotron, and Cohere models are cached by FluidAudio at:
        ~/Library/Application Support/FluidAudio/Models/

      Optional Whisper models are stored at:
        ~/Library/Application Support/MacParakeet/models/stt/whisper/

      The CLI shares its database with the macOS app at:
        ~/Library/Application Support/MacParakeet/macparakeet.db

      Verify with:
        macparakeet-cli health --json

      Compatibility policy (semver):
        https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md

      Agent integration docs (OpenClaw, Hermes, generic):
        https://github.com/moona3k/macparakeet/tree/main/integrations
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/macparakeet-cli --version")
    spec = JSON.parse(shell_output("#{bin}/macparakeet-cli spec --json"))
    assert_equal version.to_s, spec.fetch("cliVersion")
  end
end
