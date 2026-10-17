import Foundation

/// Model choices for the online speech service: what the server says it
/// offers, sorted into file-transcription and realtime models, with a short
/// built-in list as a fallback when the server cannot be asked.
public struct CloudSTTModelCatalog: Equatable, Sendable {
    /// Models for the file transcription endpoint (`audio/transcriptions`).
    public var fileModels: [String]
    /// Models for realtime (streaming) transcription sessions.
    public var realtimeModels: [String]
    /// True when the lists came from the server rather than the fallback.
    public var isFromServer: Bool

    public init(fileModels: [String], realtimeModels: [String], isFromServer: Bool) {
        self.fileModels = fileModels
        self.realtimeModels = realtimeModels
        self.isFromServer = isFromServer
    }

    /// Well-known models, used until the server's own list is loaded and
    /// whenever it cannot be (no key yet, offline, or no `/models` endpoint).
    public static let fallback = CloudSTTModelCatalog(
        fileModels: [
            "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-large-v3", "whisper-large-v3-turbo",
        ],
        realtimeModels: ["gpt-realtime-whisper", "gpt-live-transcribe", "gpt-transcribe"],
        isFromServer: false
    )

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSTTError.invalidResponse }
        return (data, http)
    }

    /// Asks the server for its models (`GET <server>/models`) and keeps the
    /// speech-to-text ones. Throws when the server cannot be reached or
    /// rejects the key, so the caller can keep showing the fallback.
    public static func load(config: CloudSTTConfig, fetch: Fetch = urlSessionFetch) async throws -> CloudSTTModelCatalog
    {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.transcriptionsURL != nil, let base = URL(string: trimmed) else {
            throw CloudSTTError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 20
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(request)
        } catch let error as CloudSTTError {
            throw error
        } catch {
            throw CloudSTTError.network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw CloudSTTError.unauthorized
        default:
            throw CloudSTTError.server(
                status: response.statusCode, message: CloudTranscribeEngine.errorMessage(from: data))
        }

        guard let ids = modelIDs(from: data) else { throw CloudSTTError.invalidResponse }
        return classify(ids)
    }

    /// Reads `{"data":[{"id":"…"}]}` (OpenAI shape) or a bare array of ids.
    static func modelIDs(from data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [Any]
        if let object = json as? [String: Any], let list = object["data"] as? [Any] {
            entries = list
        } else if let list = json as? [Any] {
            entries = list
        } else {
            return nil
        }
        return entries.compactMap { entry in
            (entry as? [String: Any])?["id"] as? String ?? entry as? String
        }
    }

    /// Sorts model ids into the two speech-to-text groups by name, since the
    /// models endpoint does not say what a model is for. Anything that is not
    /// recognisably speech-to-text (chat, embeddings, text-to-speech, …) is
    /// left out; the user can still type any name by hand.
    static func classify(_ ids: [String]) -> CloudSTTModelCatalog {
        var file: [String] = []
        var realtime: [String] = []
        for id in Set(ids).sorted() {
            let name = id.lowercased()
            let isSpeechToText =
                name.contains("whisper") || name.contains("transcribe") || name.contains("transcription")
            guard isSpeechToText, !name.contains("tts") else { continue }
            if name.contains("realtime") || name.contains("live") {
                realtime.append(id)
            } else {
                file.append(id)
            }
        }
        // `gpt-transcribe` serves realtime sessions as well as being a plain name.
        if file.contains("gpt-transcribe"), !realtime.contains("gpt-transcribe") {
            realtime.append("gpt-transcribe")
        }
        return CloudSTTModelCatalog(fileModels: file, realtimeModels: realtime, isFromServer: true)
    }
}
