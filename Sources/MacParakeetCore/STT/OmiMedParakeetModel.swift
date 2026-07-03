@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Loader for the Omi Med STT v1 CoreML bundle — an English medical
/// fine-tune of NVIDIA Parakeet TDT 0.6B v2 (`omi-health/omi-med-stt-v1`).
///
/// The bundle is architecturally identical to FluidAudio's stock v2 build
/// (same tokenizer, blank id 1024, same component I/O contract), so the
/// loaded models drive the shared TDT `AsrManager` as `AsrModelVersion.v2`.
/// Unlike the stock builds there is no FluidAudio HuggingFace repo to fetch
/// from: the compiled CoreML artifacts are produced offline from the upstream
/// `.nemo` checkpoint (FluidInference `mobius` parakeet-tdt-v2 conversion,
/// FP16 MLProgram, single-step JointDecision) and installed into
/// ``modelDirectory()``.
///
/// Loading is strictly local and never calls FluidAudio's download-or-load
/// helpers. That is deliberate: `DownloadUtils` recovers from missing or
/// corrupt files by re-downloading the *stock* v2 weights, which would
/// silently replace the medical fine-tune. A missing install throws
/// ``STTError/modelNotInstalled(_:)`` instead.
public enum OmiMedParakeetModel {

    /// Leaf directory under FluidAudio's models base holding the compiled
    /// bundle. Sibling of the stock `parakeet-tdt-0.6b-v2` cache so `models
    /// clear`-style maintenance sees every speech model in one place.
    public static let folderName = "omi-med-stt-v1-coreml"

    /// Compiled component bundles, mirroring FluidAudio's v2 layout
    /// (`ModelNames.ASR`): split preprocessor/encoder frontend, RNNT
    /// prediction network, and the fused single-step joint+decision head.
    static let requiredModelFiles: [String] = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
    ]

    /// Token-id → sentencepiece piece map in FluidAudio's dict format.
    static let vocabularyFileName = "parakeet_vocab.json"

    /// `<Application Support>/FluidAudio/Models/omi-med-stt-v1-coreml`.
    public nonisolated static func modelDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public nonisolated static func isInstalled() -> Bool {
        isInstalled(at: modelDirectory())
    }

    /// Directory-parameterized core of ``isInstalled()`` so tests can exercise
    /// the required-file check against a temp dir.
    nonisolated static func isInstalled(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        let allModelsPresent = requiredModelFiles.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let vocabPresent = fileManager.fileExists(
            atPath: directory.appendingPathComponent(vocabularyFileName).path)
        return allModelsPresent && vocabPresent
    }

    /// Removes the installed bundle. Returns `true` only when the directory
    /// existed and is gone afterward; a no-op `false` when nothing was
    /// installed. Reinstalling requires re-running the offline conversion (or
    /// restoring a saved copy) — there is no in-app download.
    @discardableResult
    public nonisolated static func deleteModel() -> Bool {
        let fileManager = FileManager.default
        let directory = modelDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            return false
        }
        return !fileManager.fileExists(atPath: directory.path)
    }

    /// Loads the installed bundle into a FluidAudio `AsrModels` value the
    /// shared TDT `AsrManager` accepts. Compute-unit placement mirrors
    /// `AsrModels.load` for v2: preprocessor pinned to CPU (its ops map to CPU
    /// anyway), everything else on CPU+ANE.
    static func load() async throws -> AsrModels {
        let directory = modelDirectory()
        guard isInstalled(at: directory) else {
            throw STTError.modelNotInstalled(
                "Omi Med STT v1 is not installed. Install the converted CoreML bundle at "
                    + "\(directory.path) (see Sources/MacParakeetCore/STT/README.md)."
            )
        }

        let neuralEngineConfig = AsrModels.defaultConfiguration()
        let cpuOnlyConfig = MLModelConfiguration()
        cpuOnlyConfig.computeUnits = .cpuOnly

        do {
            let preprocessor = try await MLModel.load(
                contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc"),
                configuration: cpuOnlyConfig
            )
            let encoder = try await MLModel.load(
                contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"),
                configuration: neuralEngineConfig
            )
            let decoder = try await MLModel.load(
                contentsOf: directory.appendingPathComponent("Decoder.mlmodelc"),
                configuration: neuralEngineConfig
            )
            let joint = try await MLModel.load(
                contentsOf: directory.appendingPathComponent("JointDecision.mlmodelc"),
                configuration: neuralEngineConfig
            )
            let vocabulary = try loadVocabulary(
                from: directory.appendingPathComponent(vocabularyFileName))

            return AsrModels(
                encoder: encoder,
                preprocessor: preprocessor,
                decoder: decoder,
                joint: joint,
                configuration: neuralEngineConfig,
                vocabulary: vocabulary,
                version: .v2
            )
        } catch let error as STTError {
            throw error
        } catch {
            throw STTError.engineStartFailed(
                "Failed to load Omi Med STT v1 from \(directory.path): \(error.localizedDescription)"
            )
        }
    }

    /// Parses FluidAudio's dict-format vocabulary (`{"<token_id>": "<piece>"}`).
    nonisolated static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw STTError.engineStartFailed(
                "Omi Med vocabulary at \(url.path) is not a {\"id\": \"token\"} JSON dictionary."
            )
        }
        var vocabulary: [Int: String] = [:]
        vocabulary.reserveCapacity(entries.count)
        for (key, value) in entries {
            guard let tokenId = Int(key) else { continue }
            vocabulary[tokenId] = value
        }
        guard !vocabulary.isEmpty else {
            throw STTError.engineStartFailed("Omi Med vocabulary at \(url.path) is empty.")
        }
        return vocabulary
    }
}
