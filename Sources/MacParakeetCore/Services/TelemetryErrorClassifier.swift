import Foundation

/// Classifies errors into concise, aggregatable telemetry strings.
///
/// Produces strings like "URLError.notConnectedToInternet", "DictationServiceError",
/// "CancellationError" — more useful for grouping than raw `type(of:)` class names.
public enum TelemetryErrorClassifier {
    public static func classify(_ error: Error) -> String {
        // URLError: include the code name for network diagnosis
        if let urlError = error as? URLError {
            return "URLError.\(urlErrorCodeName(urlError.code))"
        }

        // Swift-native error types (enums, structs, classes) — use the type name
        let typeName = String(describing: type(of: error))
        if typeName != "_SwiftNativeNSError" && typeName != "NSError" {
            return typeName
        }

        // Bridged NSError with a specific domain — include domain + code
        let nsError = error as NSError
        return "\(nsError.domain).\(nsError.code)"
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
