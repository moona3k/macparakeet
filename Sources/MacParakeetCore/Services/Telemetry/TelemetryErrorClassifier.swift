import Foundation

/// Classifies errors into concise, aggregatable telemetry strings.
///
/// Produces strings like "URLError.notConnectedToInternet", "DictationServiceError",
/// "CancellationError" — more useful for grouping than raw `type(of:)` class names.
/// NSError domains are retained only for known platform errors; custom domains
/// become `NSError.<code>` even when their text resembles a technical identifier.
public enum TelemetryErrorClassifier {
    // Keep this finite platform-domain set aligned with the website's numeric
    // categories in functions/lib/public-error-category.mjs. Identifier-shaped
    // custom domains can still be user content and must not cross the boundary.
    private static let knownNSErrorDomains: Set<String> = [
        NSCocoaErrorDomain,
        NSPOSIXErrorDomain,
        NSOSStatusErrorDomain,
        NSURLErrorDomain,
        "AVFoundationErrorDomain",
        "com.apple.coreaudio.avfaudio",
    ]

    public static func classify(_ error: Error) -> String {
        // URLError: include the code name for network diagnosis
        if let urlError = error as? URLError {
            return "URLError.\(urlErrorCodeName(urlError.code))"
        }

        if let audioError = error as? AudioProcessorError,
            case .recordingFailed("interrupted during subscribe") = audioError
        {
            return "AudioProcessorError.recordingFailed.interrupted_subscribe"
        }

        // SharedMicrophoneStream currently crosses its queue boundary with the
        // localized NSError description. Preserve known CoreAudio domain/code
        // pairs without transmitting any of that message's free-form content.
        if let subscribeError = error as? SharedMicrophoneStream.SubscribeError,
            case .engineStartFailed(let reason) = subscribeError,
            let coreAudioCode = coreAudioClassification(in: reason)
        {
            return "SubscribeError.engineStartFailed.\(coreAudioCode)"
        }

        // Swift-native error types (enums, structs, classes) — include case name for enums
        let typeName = String(describing: type(of: error))
        if typeName != "_SwiftNativeNSError" && typeName != "NSError" {
            // For enum errors, extract the case name (e.g., "AudioProcessorError.insufficientSamples")
            let mirror = Mirror(reflecting: error)
            guard mirror.displayStyle == .enum else { return typeName }
            if let caseName = mirror.children.first?.label {
                return "\(typeName).\(caseName)"
            }
            // A custom description can contain user content, even when it looks
            // like a single identifier. Only the compiler's enum description is safe.
            guard !(error is any CustomStringConvertible),
                !(error is any CustomDebugStringConvertible)
            else { return typeName }
            let described = String(describing: error)
            if described != typeName,
                described.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            {
                return "\(typeName).\(described)"
            }
            return typeName
        }

        // Retain only known platform domains. Custom NSError domains are
        // arbitrary strings, so even single-word values must be discarded.
        let nsError = error as NSError
        let safeDomain = knownNSErrorDomains.contains(nsError.domain) ? nsError.domain : "NSError"
        return "\(safeDomain).\(nsError.code)"
    }

    /// Redacts recognizable paths, URLs, emails and credentials, then truncates to 512 chars.
    /// Arbitrary user content cannot be made safe by pattern matching; callers must
    /// omit details from errors that can contain transcripts or provider responses.
    public static func errorDetail(_ error: Error) -> String {
        return String(sanitize(error.localizedDescription).prefix(512))
    }

    /// Strips recognizable private values from a diagnostic string. Idempotent — running
    /// twice produces the same result. Used by `errorDetail(_:)` for defensive
    /// diagnostic scrubbing; network events omit free-form descriptions entirely.
    /// No truncation here — callers enforce their own diagnostic length budget.
    public static func sanitize(_ string: String) -> String {
        var sanitized = string
        // Paths can contain spaces, quotes, or punctuation. Redact through the
        // end of the line: guessing where the path ends leaked meeting names in
        // ffmpeg errors from iCloud Drive and external volumes.
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)\bfile:/[^\r\n]+"#,
            with: "<path>",
            options: .regularExpression
        )
        // Strip URLs before paths so their slashes are not treated as file paths.
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"',)\]]+"#,
            with: "<url>",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"(?<![A-Za-z0-9/])(?:~?/)[^\s/][^\r\n]*"#,
            with: "<path>",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            with: "<email>",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)\bBearer\s+[^\s\"',;<>]+"#,
            with: "Bearer <redacted>",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)\b(?:api[_-]?key|access[_-]?token|token|authorization)\s*[:=]\s*(?:\"(?:\\[^\r\n]|[^\"\\\r\n])*\\?(?:\"|(?=[\r\n]|$))|'(?:\\[^\r\n]|[^'\\\r\n])*\\?(?:'|(?=[\r\n]|$))|[^\s\"',;<>]+)"#,
            with: "credential=<redacted>",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"\b(?:sk-[A-Za-z0-9_-]{12,}|AIza[A-Za-z0-9_-]{20,})\b"#,
            with: "<redacted>",
            options: .regularExpression
        )
        return sanitized
    }

    private static func coreAudioClassification(in reason: String) -> String? {
        let patterns = [
            #"\((com\.apple\.coreaudio\.avfaudio|NSOSStatusErrorDomain|OSStatus) error (-?[0-9]{1,10})\.\)"#,
            #"Error Domain=(com\.apple\.coreaudio\.avfaudio|NSOSStatusErrorDomain) Code=(-?[0-9]{1,10})(?:\s|$)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)),
                let domainRange = Range(match.range(at: 1), in: reason),
                let codeRange = Range(match.range(at: 2), in: reason),
                let code = Int32(reason[codeRange])
            else { continue }
            // Foundation renders NSOSStatusErrorDomain as "OSStatus" in its
            // localized description; retain the canonical domain for grouping.
            let domain = reason[domainRange] == "OSStatus" ? "NSOSStatusErrorDomain" : String(reason[domainRange])
            return "\(domain).\(code)"
        }
        return nil
    }

    private static func urlErrorCodeName(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .timedOut: return "timedOut"
        case .cannotFindHost: return "cannotFindHost"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .networkConnectionLost: return "networkConnectionLost"
        case .cancelled: return "cancelled"
        case .badServerResponse: return "badServerResponse"
        case .secureConnectionFailed: return "secureConnectionFailed"
        default: return "code\(code.rawValue)"
        }
    }
}
