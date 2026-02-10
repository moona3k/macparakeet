import Foundation

/// JSON-RPC 2.0 request
struct JSONRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: [String: JSONRPCValue]
    let id: Int
}

/// JSON-RPC 2.0 response (success or error)
struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let result: TranscribeResult?
    let error: JSONRPCError?
    let id: Int?
}

struct TranscribeResult: Decodable {
    let text: String
    let words: [JSONRPCWord]?
}

struct JSONRPCWord: Decodable {
    let word: String
    let startMs: Int
    let endMs: Int
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case word
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
    }
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
    let data: JSONRPCErrorData?
}

struct JSONRPCErrorData: Decodable {
    let reason: String?
}

/// A simple JSON value type for encoding heterogeneous params
enum JSONRPCValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}

/// JSON-RPC response for ping (returns a string "pong")
struct JSONRPCPingResponse: Decodable {
    let jsonrpc: String
    let result: String?
    let error: JSONRPCError?
    let id: Int?
}
