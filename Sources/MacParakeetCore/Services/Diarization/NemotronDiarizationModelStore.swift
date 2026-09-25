import CryptoKit
import FluidAudio
import Foundation

/// Immutable GA assets in an app-owned cache. Avoids mutating FluidAudio's
/// process-global revision overrides while other speech engines are loading.
enum NemotronDiarizationModelStore {
    static let revision = "1b0b133f6f8820292010afd776d8f9fbc9fca17e"
    private static let downloadPermit = AsyncPermit(value: 1)

    struct Asset: Sendable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    static func directory(base: URL, preset: NemotronDiarizationService.Preset) -> URL {
        base.appendingPathComponent("nemotron-diarization/\(revision)/\(preset.rawValue)", isDirectory: true)
    }

    static func assets(for preset: NemotronDiarizationService.Preset) -> [Asset] {
        let bundle = "\(preset.config.modelFileName)/"
        let offline = preset == .offline
        return [
            Asset(
                path: "learnable_sil_emb.bin", bytes: 2048,
                sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
            Asset(
                path: bundle + "analytics/coremldata.bin", bytes: 243,
                sha256: offline
                    ? "491594df92282a4f2cef65e96d236e210a5c4627063e37e822ec858aaaad416d"
                    : "a71e06616a3ae7bddef06ce5dfc7fe523a286e489f63a8da2fc4f1e940d560a4"),
            Asset(
                path: bundle + "coremldata.bin", bytes: 758,
                sha256: offline
                    ? "8b790c919c65744648c17290a26d3371e0e55db655310e7f8445080757b0bf08"
                    : "ebcca7245d8d774305752b9f2b79433ad1858f8a06df3b326e0ae6305d981d25"),
            Asset(
                path: bundle + "model.mil", bytes: offline ? 505274 : 502794,
                sha256: offline
                    ? "ea5673d9e9ec785e7c8fb628acd82f9f86214c46b6584eaacdb6faddcb3f0277"
                    : "e7c029a46d9f327bec4c47fc34e5d32ee2cec9ce596950af0c403d05146b4ead"),
            Asset(
                path: bundle + "weights/weight.bin", bytes: offline ? 198654080 : 198590592,
                sha256: offline
                    ? "bab76e5f190d0e4a4e174e7fcb1e9beea58c6b2be56e665e2cac8fba6d10f7f1"
                    : "e8c90d2d0e16787a420de6805fd5b7a95c116fac0163208b5bc4d8a9ae459ca4"),
        ]
    }

    /// Fast readiness probe; preparation verifies hashes before loading CoreML.
    static func isCached(base: URL, preset: NemotronDiarizationService.Preset) -> Bool {
        let root = directory(base: base, preset: preset)
        return assets(for: preset).allSatisfy { asset in
            let url = root.appendingPathComponent(asset.path)
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size == asset.bytes
        }
    }

    static func prepare(
        base: URL,
        preset: NemotronDiarizationService.Preset,
        fetch: @Sendable (URL) async throws -> Data = {
            try await ModelHub.fetchFile(from: $0, description: "Nemotron speaker model")
        }
    ) async throws -> URL {
        try await downloadPermit.wait()
        defer { downloadPermit.signal() }
        let root = directory(base: base, preset: preset)
        for asset in assets(for: preset) {
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(asset.path)
            if let data = try? Data(contentsOf: destination, options: .mappedIfSafe), valid(data, asset: asset) {
                continue
            }
            let remotePath =
                asset.path == "learnable_sil_emb.bin"
                ? asset.path : "\(preset.config.hubSubdirectory)/\(asset.path)"
            let url = URL(
                string:
                    "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/resolve/\(revision)/\(remotePath)"
            )!
            let data = try await fetch(url)
            try Task.checkCancellation()
            guard valid(data, asset: asset) else {
                throw NemotronDiarizationError.invalidModelAsset(asset.path)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // A failed/cancelled transfer never replaces an existing artifact.
            try data.write(to: destination, options: .atomic)
        }
        return root
    }

    static func valid(_ data: Data, asset: Asset) -> Bool {
        data.count == asset.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}
