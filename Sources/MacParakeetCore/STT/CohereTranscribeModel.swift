import Foundation

enum CohereTranscribePins {
    static let upstreamRepository = "handy-computer/transcribe.cpp"
    static let upstreamTag = "v0.1.3"
    static let upstreamTagObject = "d503d6a239e2a290a03ab72dbd3b40460d87acb0"
    static let upstreamCommit = "a94e021ef658dc7c788837341a13f6acea3baf3c"
    static let swiftWrapperVersion = "0.1.3"

    static let ownedForkRepository = "DudeMeister23/transcribe.cpp"
    static let ownedForkCommit = "51aa23592167cc32f8f3c5d2155d9f9937324c8d"
    static let ownedReleaseTag = "macparakeet-v0.1.3-arm64.1"
    static let ownedArtifactFileName =
        "TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip"
    static let ownedArtifactURL =
        "https://github.com/dudemeister23/transcribe.cpp/releases/download/macparakeet-v0.1.3-arm64.1/TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip"
    static let ownedArtifactSHA256 =
        "caad2e1ce80801e5d0adb7e2bb9bcf8e7d1fd295657af281d8260d5dcc629350"

    // Development reference only. Shipping uses the owned artifact pin above.
    static let upstreamReferenceArtifactSHA256 =
        "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"

    static var requiredRuntimeCommit: String {
        ownedForkCommit.isEmpty ? upstreamCommit : ownedForkCommit
    }

    static let modelRepository = "handy-computer/cohere-transcribe-03-2026-gguf"
    static let modelRevision = "dfa4adebb64f3076b7b6b90b721275cc069cb421"
    static let modelFileName = "cohere-transcribe-03-2026-Q5_K_M.gguf"
    static let modelSizeBytes: UInt64 = 1_770_270_208
    static let modelSHA256 =
        "14d02f1ad6dd77b3a60f82639879012c3adb4fe25c50a5a47a2c4c661daf1558"

    static let modelArchitecture = "cohere_asr"
    static let modelVariant = "cohere-transcribe-03-2026"
}

enum CohereTranscribeModelCatalog {
    static let manifest = InProcessLocalModelManifest(
        modelID: "\(CohereTranscribePins.modelRepository)@\(CohereTranscribePins.modelRevision)",
        displayName: "Cohere Transcribe 03-2026 Q5_K_M",
        repositoryID: CohereTranscribePins.modelRepository,
        revision: CohereTranscribePins.modelRevision,
        files: [
            InProcessLocalModelFile(
                path: CohereTranscribePins.modelFileName,
                sizeBytes: CohereTranscribePins.modelSizeBytes,
                sha256: CohereTranscribePins.modelSHA256
            )
        ]
    )

    static func cacheBaseDirectory() -> URL {
        URL(fileURLWithPath: AppPaths.cohereModelsDir, isDirectory: true)
    }

    static func modelDirectory(
        cacheBase: URL = cacheBaseDirectory()
    ) -> URL {
        InProcessLocalModelCatalog.modelDirectory(
            for: manifest.modelID,
            cacheRoot: cacheBase
        )
    }

    static func modelFileURL(
        directory: URL = modelDirectory()
    ) throws -> URL {
        guard let file = manifest.files.first else {
            throw CohereNativeBackendError.nativeFailure("The Cohere model manifest is empty.")
        }
        return try InProcessLocalModelCatalog.fileURL(for: file, in: directory)
    }

    static func isVerified(
        directory: URL = modelDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        (try? InProcessLocalModelCatalog.hasValidVerificationMarker(
            for: manifest,
            in: directory,
            fileManager: fileManager
        )) == true
    }

    static func hasArtifacts(
        directory: URL = modelDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func requireVerifiedModel(
        directory: URL = modelDirectory()
    ) throws -> URL {
        guard isVerified(directory: directory) else {
            throw STTError.engineStartFailed(
                "Cohere Transcribe is not downloaded or failed verification. Run `macparakeet-cli models download cohere-transcribe` first."
            )
        }
        return try modelFileURL(directory: directory)
    }

    static func makeDownloader(
        cacheBase: URL = cacheBaseDirectory(),
        transport: any InProcessModelDownloadTransport = URLSessionInProcessModelDownloadTransport(),
        fileManager: FileManager = .default
    ) -> InProcessModelDownloader {
        InProcessModelDownloader(
            manifest: manifest,
            cacheRoot: cacheBase,
            transport: transport,
            fileManager: fileManager
        )
    }
}
