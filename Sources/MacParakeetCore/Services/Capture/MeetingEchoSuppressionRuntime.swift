import CryptoKit
import Darwin
import Foundation
import OSLog

public enum MeetingEchoSuppressionMode: String, Sendable, Equatable {
    case automatic
    case off
    case dynamicLibrary
}

public struct MeetingEchoSuppressionConfiguration: Sendable, Equatable {
    public static let modeEnvironmentKey = "MACPARAKEET_MEETING_ECHO_SUPPRESSION"
    public static let libraryPathEnvironmentKey = "MACPARAKEET_MEETING_ECHO_LIBRARY"
    public static let modelPathEnvironmentKey = "MACPARAKEET_MEETING_ECHO_MODEL"
    public static let modelSHA256EnvironmentKey = "MACPARAKEET_MEETING_ECHO_MODEL_SHA256"
    public static let frameSizeEnvironmentKey = "MACPARAKEET_MEETING_ECHO_FRAME_SIZE"
    public static let sampleRateEnvironmentKey = "MACPARAKEET_MEETING_ECHO_SAMPLE_RATE"

    public static let defaultSampleRate = 16_000
    public static let defaultFrameSize = 256

    public var mode: MeetingEchoSuppressionMode
    public var libraryURL: URL?
    public var modelURL: URL?
    public var modelSHA256: String?
    public var sampleRate: Int
    public var frameSize: Int

    public init(
        mode: MeetingEchoSuppressionMode = .automatic,
        libraryURL: URL? = nil,
        modelURL: URL? = nil,
        modelSHA256: String? = nil,
        sampleRate: Int = Self.defaultSampleRate,
        frameSize: Int = Self.defaultFrameSize
    ) {
        self.mode = mode
        self.libraryURL = libraryURL
        self.modelURL = modelURL
        self.modelSHA256 = modelSHA256
        self.sampleRate = max(1, sampleRate)
        self.frameSize = max(1, frameSize)
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingEchoSuppressionConfiguration {
        let mode = environment[modeEnvironmentKey]
            .flatMap(MeetingEchoSuppressionMode.init(environmentValue:)) ?? .automatic
        let libraryURL = environment[libraryPathEnvironmentKey]
            .flatMap { Self.fileURL(from: $0) }
        let modelURL = environment[modelPathEnvironmentKey]
            .flatMap { Self.fileURL(from: $0) }
        let modelSHA256 = environment[modelSHA256EnvironmentKey]
            .flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return trimmed.isEmpty ? nil : trimmed
            }
        let sampleRate = environment[sampleRateEnvironmentKey]
            .flatMap(Self.integerValue(from:)) ?? defaultSampleRate
        let frameSize = environment[frameSizeEnvironmentKey]
            .flatMap(Self.integerValue(from:)) ?? defaultFrameSize

        return MeetingEchoSuppressionConfiguration(
            mode: mode,
            libraryURL: libraryURL,
            modelURL: modelURL,
            modelSHA256: modelSHA256,
            sampleRate: sampleRate,
            frameSize: frameSize
        )
    }

    private static func fileURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("file://") {
            if let url = URL(string: trimmed), url.isFileURL {
                return url
            }
            return URL(fileURLWithPath: String(trimmed.dropFirst("file://".count)))
        }
        return URL(fileURLWithPath: trimmed)
    }

    private static func integerValue(from value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension MeetingEchoSuppressionMode {
    init?(environmentValue: String) {
        switch environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto", "automatic":
            self = .automatic
        case "off", "none", "disabled", "passthrough":
            self = .off
        case "dynamic", "dynamic-library", "dynamic_library", "localvqe":
            self = .dynamicLibrary
        default:
            return nil
        }
    }
}

enum MeetingEchoSuppressionFactory {
    static let processorName = "localvqe"
    static let defaultLibraryName = "liblocalvqe.dylib"
    static let defaultModelDirectoryName = "MeetingEchoSuppression"
    static let defaultModelName = "localvqe-v1.2-1.3M-f32.gguf"
    private static let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "MeetingEchoSuppression"
    )

    static func makeConditioner(
        configuration: MeetingEchoSuppressionConfiguration,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> any MicConditioning {
        switch configuration.mode {
        case .off:
            return PassthroughMicConditioner()
        case .automatic:
            guard let resolved = resolveDynamicAssets(
                configuration: configuration,
                bundle: bundle,
                fileManager: fileManager
            ) else {
                return PassthroughMicConditioner()
            }
            return makeDynamicConditioner(
                resolved: resolved,
                configuration: configuration,
                fileManager: fileManager
            )
        case .dynamicLibrary:
            guard let resolved = resolveDynamicAssets(
                configuration: configuration,
                bundle: bundle,
                fileManager: fileManager
            ) else {
                return unavailableDynamicConditioner(reason: "assets_missing")
            }
            return makeDynamicConditioner(
                resolved: resolved,
                configuration: configuration,
                fileManager: fileManager
            )
        }
    }

    static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct DynamicAssets {
        let libraryURL: URL
        let modelURL: URL
    }

    private static func resolveDynamicAssets(
        configuration: MeetingEchoSuppressionConfiguration,
        bundle: Bundle,
        fileManager: FileManager
    ) -> DynamicAssets? {
        let libraryURL = existingFile(
            candidates: [
                configuration.libraryURL,
                bundle.privateFrameworksURL?.appendingPathComponent(defaultLibraryName),
                bundle.resourceURL?.appendingPathComponent(defaultLibraryName),
            ],
            fileManager: fileManager
        )
        let modelURL = existingFile(
            candidates: [
                configuration.modelURL,
                bundle.resourceURL?
                    .appendingPathComponent(defaultModelDirectoryName)
                    .appendingPathComponent(defaultModelName),
            ],
            fileManager: fileManager
        )

        guard let libraryURL, let modelURL else { return nil }
        return DynamicAssets(libraryURL: libraryURL, modelURL: modelURL)
    }

    private static func existingFile(
        candidates: [URL?],
        fileManager: FileManager
    ) -> URL? {
        candidates.compactMap { $0 }.first { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private static func makeDynamicConditioner(
        resolved: DynamicAssets,
        configuration: MeetingEchoSuppressionConfiguration,
        fileManager: FileManager
    ) -> any MicConditioning {
        do {
            if let expectedSHA = configuration.modelSHA256 {
                let actualSHA = try sha256Hex(for: resolved.modelURL)
                guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                    return unavailableDynamicConditioner(reason: "checksum_mismatch")
                }
            }

            guard fileManager.isReadableFile(atPath: resolved.libraryURL.path),
                  fileManager.isReadableFile(atPath: resolved.modelURL.path)
            else {
                return unavailableDynamicConditioner(reason: "assets_not_readable")
            }

            let processor = try DynamicLibraryMeetingEchoProcessor(
                libraryURL: resolved.libraryURL,
                modelURL: resolved.modelURL,
                sampleRate: configuration.sampleRate,
                frameSize: configuration.frameSize
            )
            return StreamingMeetingEchoSuppressor(processor: processor)
        } catch {
            return unavailableDynamicConditioner(reason: "load_failed", error: error)
        }
    }

    private static func unavailableDynamicConditioner(
        reason: String,
        error: (any Error)? = nil
    ) -> any MicConditioning {
        if let error {
            logger.warning(
                "meeting_echo_processor_unavailable reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
        } else {
            logger.warning(
                "meeting_echo_processor_unavailable reason=\(reason, privacy: .public)"
            )
        }
        return PassthroughMicConditioner(processorName: processorName, loaded: false)
    }
}

private enum DynamicLibraryMeetingEchoProcessorError: Error, CustomStringConvertible {
    case libraryLoadFailed(String)
    case missingSymbol(String)
    case createFailed(String)
    case invalidFrameSize(expected: Int, microphone: Int, reference: Int)
    case processingFailed(code: Int32, message: String)

    var description: String {
        switch self {
        case .libraryLoadFailed(let message):
            return "library load failed: \(message)"
        case .missingSymbol(let symbol):
            return "missing symbol: \(symbol)"
        case .createFailed(let message):
            return "create failed: \(message)"
        case let .invalidFrameSize(expected, microphone, reference):
            return "invalid frame size: expected=\(expected) microphone=\(microphone) reference=\(reference)"
        case let .processingFailed(code, message):
            return "processing failed: code=\(code) message=\(message)"
        }
    }
}

final class DynamicLibraryMeetingEchoProcessor: MeetingEchoSuppressing, @unchecked Sendable {
    private typealias ContextHandle = UInt
    private typealias NewFunction = @convention(c) (UnsafePointer<CChar>) -> ContextHandle
    private typealias ProcessFunction = @convention(c) (
        ContextHandle,
        UnsafePointer<Float>,
        UnsafePointer<Float>,
        Int32,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias ResetFunction = @convention(c) (ContextHandle) -> Void
    private typealias FreeFunction = @convention(c) (ContextHandle) -> Void
    private typealias IntegerGetterFunction = @convention(c) (ContextHandle) -> Int32
    private typealias LastErrorFunction = @convention(c) (ContextHandle) -> UnsafePointer<CChar>?

    let name = MeetingEchoSuppressionFactory.processorName
    let sampleRate: Int
    let frameSize: Int

    private let handle: UnsafeMutableRawPointer
    private let context: ContextHandle
    private let processFunction: ProcessFunction
    private let resetFunction: ResetFunction
    private let freeFunction: FreeFunction
    private let lastErrorFunction: LastErrorFunction?
    private let lock = NSLock()

    init(libraryURL: URL, modelURL: URL, sampleRate: Int, frameSize: Int) throws {
        let loadedHandle = libraryURL.withUnsafeFileSystemRepresentation { path -> UnsafeMutableRawPointer? in
            guard let path else { return nil }
            return dlopen(path, RTLD_NOW | RTLD_LOCAL)
        }
        guard let handle = loadedHandle else {
            throw DynamicLibraryMeetingEchoProcessorError.libraryLoadFailed(Self.lastDLError())
        }

        do {
            let create: NewFunction = try Self.loadSymbol("localvqe_new", from: handle)
            let process: ProcessFunction = try Self.loadSymbol("localvqe_process_frame_f32", from: handle)
            let reset: ResetFunction = try Self.loadSymbol("localvqe_reset", from: handle)
            let free: FreeFunction = try Self.loadSymbol("localvqe_free", from: handle)
            let sampleRateGetter: IntegerGetterFunction? = Self.loadOptionalSymbol(
                "localvqe_sample_rate",
                from: handle
            )
            let hopLengthGetter: IntegerGetterFunction? = Self.loadOptionalSymbol(
                "localvqe_hop_length",
                from: handle
            )
            let lastError: LastErrorFunction? = Self.loadOptionalSymbol(
                "localvqe_last_error",
                from: handle
            )
            let context: ContextHandle = modelURL.withUnsafeFileSystemRepresentation { modelPath -> ContextHandle in
                guard let modelPath else { return 0 }
                return create(modelPath)
            }
            guard context != 0 else {
                throw DynamicLibraryMeetingEchoProcessorError.createFailed(
                    "context allocation returned null"
                )
            }

            self.handle = handle
            self.context = context
            self.processFunction = process
            self.resetFunction = reset
            self.freeFunction = free
            self.lastErrorFunction = lastError
            self.sampleRate = Self.validPositiveInt(sampleRateGetter?(context)) ?? sampleRate
            self.frameSize = Self.validPositiveInt(hopLengthGetter?(context)) ?? frameSize
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        freeFunction(context)
        dlclose(handle)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        resetFunction(context)
    }

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
        guard microphone.count == frameSize,
              reference.count == frameSize,
              output.count == frameSize
        else {
            throw DynamicLibraryMeetingEchoProcessorError.invalidFrameSize(
                expected: frameSize,
                microphone: microphone.count,
                reference: reference.count
            )
        }

        lock.lock()
        defer { lock.unlock() }
        let result = microphone.withUnsafeBufferPointer { microphoneBuffer in
            reference.withUnsafeBufferPointer { referenceBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    processFunction(
                        context,
                        microphoneBuffer.baseAddress!,
                        referenceBuffer.baseAddress!,
                        Int32(frameSize),
                        outputBuffer.baseAddress!
                    )
                }
            }
        }
        guard result == 0 else {
            let message = Self.lastLocalVQEError(
                context: context,
                lastErrorFunction: lastErrorFunction
            )
            throw DynamicLibraryMeetingEchoProcessorError.processingFailed(
                code: result,
                message: message
            )
        }
    }

    private static func loadSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw DynamicLibraryMeetingEchoProcessorError.missingSymbol(name)
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func loadOptionalSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func lastDLError() -> String {
        guard let error = dlerror() else { return "unknown" }
        return String(cString: error)
    }

    private static func lastLocalVQEError(
        context: ContextHandle,
        lastErrorFunction: LastErrorFunction?
    ) -> String {
        guard let pointer = lastErrorFunction?(context) else {
            return "unknown"
        }
        let message = String(cString: pointer)
        return message.isEmpty ? "unknown" : message
    }

    private static func validPositiveInt(_ value: Int32?) -> Int? {
        guard let value, value > 0 else { return nil }
        return Int(value)
    }
}
