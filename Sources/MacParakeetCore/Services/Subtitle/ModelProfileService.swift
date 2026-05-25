import Foundation
import OSLog

// MARK: - ModelProfileService

/// Fetches, merges, and caches model profiles for subtitle refinement.
///
/// On every connection test or config save the ViewModel calls
/// `fetchProfile(modelName:providerConfig:)`. The service:
///   1. Refreshes the remote behavioral catalog (once per 24h, cached to disk)
///   2. For Ollama/LM Studio: calls POST /api/show to get structural metadata
///      (parameter count, context window, architecture, quantization)
///   3. Merges structural + behavioral data into a `ModelProfile`
///   4. Caches the result in memory so the Settings card can read it instantly
///
/// The remote catalog is hosted at:
///   https://raw.githubusercontent.com/justingonz96-creator/macparakeet/main/Resources/model-profiles.json
///
/// On fetch failure the service falls back to the bundled catalog encoded
/// in `ModelProfileService.bundledCatalogJSON` — no network required.
public actor ModelProfileService {

    public static let shared = ModelProfileService()

    private static let logger = Logger(subsystem: "com.macparakeet.core", category: "ModelProfileService")

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/justingonz96-creator/macparakeet/main/Resources/model-profiles.json")!

    private var cachedEntry: (modelName: String, profile: ModelProfile)?
    private var remoteCatalog: RemoteProfileCatalog?
    private var lastRemoteFetch: Date?

    // MARK: - Public API

    /// Returns a `ModelProfile` for the given model, refreshing remote data if stale.
    public func fetchProfile(
        modelName: String,
        providerConfig: LLMProviderConfig
    ) async -> ModelProfile {
        await refreshCatalogIfNeeded()

        var ollamaMeta: OllamaModelMetadata?
        if providerConfig.id == .ollama || providerConfig.id == .lmstudio {
            ollamaMeta = await fetchOllamaMetadata(modelName: modelName, baseURL: providerConfig.baseURL)
        }

        let catalog = remoteCatalog ?? (try? decodeBundled()) ?? RemoteProfileCatalog(version: 1, updated: nil, profiles: [])
        let profile = buildProfile(modelName: modelName, meta: ollamaMeta, catalog: catalog)
        cachedEntry = (modelName: modelName, profile: profile)
        return profile
    }

    /// The last successfully resolved profile, or nil if none fetched yet.
    public var currentProfile: ModelProfile? { cachedEntry?.profile }

    /// Forces an immediate remote catalog refresh (bypasses the 24h gate).
    public func forceRefreshCatalog() async {
        await fetchRemoteCatalog()
    }

    // MARK: - Catalog refresh

    private func refreshCatalogIfNeeded() async {
        if remoteCatalog != nil, let last = lastRemoteFetch,
           Date().timeIntervalSince(last) < 86_400 { return }

        if remoteCatalog == nil, let cached = loadDiskCachedCatalog() {
            remoteCatalog = cached
        }

        await fetchRemoteCatalog()
    }

    private func fetchRemoteCatalog() async {
        do {
            var request = URLRequest(url: Self.remoteURL)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            let catalog = try JSONDecoder().decode(RemoteProfileCatalog.self, from: data)
            remoteCatalog = catalog
            lastRemoteFetch = Date()
            saveDiskCachedCatalog(catalog)
            Self.logger.debug("model_profile_catalog_refreshed profiles=\(catalog.profiles.count, privacy: .public)")
        } catch {
            Self.logger.debug("model_profile_catalog_fetch_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Ollama /api/show

    private func fetchOllamaMetadata(modelName: String, baseURL: URL) async -> OllamaModelMetadata? {
        // /api/show lives at the Ollama server root, not under /v1
        let base = baseURL.absoluteString
        let serverRoot = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
        guard let url = URL(string: serverRoot + "/api/show") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": modelName])
            let (data, _) = try await URLSession.shared.data(for: request)
            let meta = OllamaModelMetadata(from: data)
            if let p = meta?.parameterCount {
                Self.logger.debug("ollama_model_metadata model=\(modelName, privacy: .public) params=\(p, privacy: .public)")
            }
            return meta
        } catch {
            Self.logger.debug("ollama_model_metadata_fetch_failed model=\(modelName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Profile construction

    private func buildProfile(
        modelName: String,
        meta: OllamaModelMetadata?,
        catalog: RemoteProfileCatalog
    ) -> ModelProfile {
        let lower = modelName.lowercased()

        // Best matching catalog entry: longest matching pattern wins
        let match = catalog.profiles
            .filter { entry in entry.patterns.contains { lower.contains($0.lowercased()) } }
            .max { a, b in
                let aMax = a.patterns.filter { lower.contains($0.lowercased()) }.map(\.count).max() ?? 0
                let bMax = b.patterns.filter { lower.contains($0.lowercased()) }.map(\.count).max() ?? 0
                return aMax < bMax
            }

        let sizeClass = ModelProfile.SizeClass(parameterCount: meta?.parameterCount)

        let batchSize: Int
        if let match {
            batchSize = match.batchSizes[sizeClass.rawValue] ?? match.batchSizes["unknown"] ?? 5
        } else {
            switch sizeClass {
            case .small: batchSize = 3
            case .medium: batchSize = 5
            case .large: batchSize = 8
            case .unknown: batchSize = 5
            }
        }

        let displayName: String
        let baseName = match?.displayName ?? modelName.components(separatedBy: ":").first ?? modelName
        if let sizeStr = meta.flatMap({ OllamaModelMetadata.parameterSizeString(from: $0.parameterCount) }) {
            displayName = "\(baseName) (\(sizeStr))"
        } else {
            displayName = baseName
        }

        return ModelProfile(
            displayName: displayName,
            architectureFamily: meta?.architecture ?? match?.architectureHint,
            parameterCount: meta?.parameterCount,
            contextWindow: meta?.contextWindow,
            sizeClass: sizeClass,
            suggestedBatchSize: batchSize,
            promptHint: match?.promptHint ?? .standard,
            parserLeniency: match?.parserLeniency ?? .normal,
            quirks: Set(match?.quirks ?? [])
        )
    }

    // MARK: - Disk cache

    private static var cacheURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MacParakeet/model-profiles-cache.json")
    }

    private func loadDiskCachedCatalog() -> RemoteProfileCatalog? {
        guard let url = Self.cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RemoteProfileCatalog.self, from: data)
    }

    private func saveDiskCachedCatalog(_ catalog: RemoteProfileCatalog) {
        guard let url = Self.cacheURL,
              let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Bundled fallback

    private func decodeBundled() throws -> RemoteProfileCatalog {
        guard let data = Self.bundledCatalogJSON.data(using: .utf8) else {
            throw CocoaError(.fileReadUnknown)
        }
        return try JSONDecoder().decode(RemoteProfileCatalog.self, from: data)
    }

    // Bundled catalog — mirrors Resources/model-profiles.json in the repo.
    // Update the repo file; the app picks it up on next remote fetch.
    // This literal is the offline safety net only.
    static let bundledCatalogJSON = """
    {
      "version": 1,
      "updated": "2026-05-25",
      "profiles": [
        {
          "patterns": ["gemma4", "gemma3:27b", "gemma3:12b", "gemma3:4b", "gemma3", "gemma-4", "gemma-3"],
          "displayName": "Gemma",
          "architectureHint": "gemma",
          "promptHint": "explicitJSON",
          "parserLeniency": "lenient",
          "quirks": ["addsLineComments", "skipsWordIndices"],
          "batchSizes": {"small": 3, "medium": 5, "large": 8, "unknown": 5}
        },
        {
          "patterns": ["llama4", "llama3.3", "llama3.2", "llama3.1", "llama3", "llama-4", "llama-3", "meta-llama"],
          "displayName": "Llama",
          "architectureHint": "llama",
          "promptHint": "standard",
          "parserLeniency": "normal",
          "quirks": [],
          "batchSizes": {"small": 3, "medium": 7, "large": 10, "unknown": 5}
        },
        {
          "patterns": ["mistral-large", "mistral-nemo", "mistral-small", "mixtral", "mistral"],
          "displayName": "Mistral",
          "architectureHint": "llama",
          "promptHint": "standard",
          "parserLeniency": "normal",
          "quirks": [],
          "batchSizes": {"small": 3, "medium": 7, "large": 10, "unknown": 5}
        },
        {
          "patterns": ["deepseek-v4", "deepseek-v3", "deepseek-v2", "deepseek-r2", "deepseek-r1", "deepseek"],
          "displayName": "DeepSeek",
          "architectureHint": "deepseek",
          "promptHint": "standard",
          "parserLeniency": "normal",
          "quirks": [],
          "batchSizes": {"small": 3, "medium": 8, "large": 10, "unknown": 7}
        },
        {
          "patterns": ["qwen3.5", "qwen3", "qwen2.5", "qwen2", "qwen"],
          "displayName": "Qwen",
          "architectureHint": "qwen2",
          "promptHint": "standard",
          "parserLeniency": "normal",
          "quirks": [],
          "batchSizes": {"small": 3, "medium": 7, "large": 10, "unknown": 5}
        },
        {
          "patterns": ["phi4", "phi3.5", "phi3", "phi-4", "phi-3"],
          "displayName": "Phi",
          "architectureHint": "phi3",
          "promptHint": "explicitJSON",
          "parserLeniency": "normal",
          "quirks": [],
          "batchSizes": {"small": 3, "medium": 6, "large": 8, "unknown": 4}
        },
        {
          "patterns": ["claude-haiku-4", "claude-haiku-3", "claude-haiku"],
          "displayName": "Claude Haiku",
          "architectureHint": null,
          "promptHint": "standard",
          "parserLeniency": "strict",
          "quirks": [],
          "batchSizes": {"small": 5, "medium": 10, "large": 10, "unknown": 8}
        },
        {
          "patterns": ["claude-sonnet-4", "claude-sonnet-3", "claude-opus-4", "claude-opus-3", "claude-sonnet", "claude-opus"],
          "displayName": "Claude Sonnet/Opus",
          "architectureHint": null,
          "promptHint": "standard",
          "parserLeniency": "strict",
          "quirks": [],
          "batchSizes": {"small": 5, "medium": 10, "large": 10, "unknown": 10}
        },
        {
          "patterns": ["gpt-5-nano", "gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini"],
          "displayName": "GPT Mini",
          "architectureHint": null,
          "promptHint": "standard",
          "parserLeniency": "strict",
          "quirks": [],
          "batchSizes": {"small": 5, "medium": 10, "large": 10, "unknown": 8}
        },
        {
          "patterns": ["gpt-5.4", "gpt-5.3", "gpt-5", "gpt-4.1", "gpt-4o", "gpt-4"],
          "displayName": "GPT-4",
          "architectureHint": null,
          "promptHint": "standard",
          "parserLeniency": "strict",
          "quirks": [],
          "batchSizes": {"small": 5, "medium": 10, "large": 10, "unknown": 10}
        },
        {
          "patterns": ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3-flash", "gemini-3.1", "gemini"],
          "displayName": "Gemini",
          "architectureHint": null,
          "promptHint": "standard",
          "parserLeniency": "normal",
          "quirks": [],
          "batchSizes": {"small": 3, "medium": 7, "large": 10, "unknown": 7}
        }
      ]
    }
    """
}

// MARK: - OllamaModelMetadata helpers

extension OllamaModelMetadata {
    static func parameterSizeString(from count: Int?) -> String? {
        guard let p = count else { return nil }
        let b = Double(p) / 1_000_000_000.0
        if b >= 1 { return String(format: "%.0fB", b) }
        let m = Double(p) / 1_000_000.0
        return String(format: "%.0fM", m)
    }
}
