import AudioToolbox
import CoreAudio
import Foundation

private let unknownAudioObject = kAudioObjectUnknown
private let systemAudioObject = AudioObjectID(kAudioObjectSystemObject)

private enum ProbeError: Error, CustomStringConvertible {
    case badArguments
    case osStatus(stage: String, status: OSStatus)
    case unsupportedFormat(AudioStreamBasicDescription)
    case noFrames
    case signalTooQuiet(rms: Double, targetAmplitude: Double)

    var description: String {
        switch self {
        case .badArguments:
            return
                "usage: process-tap-probe --output RESULT.json --tone TONE.wav "
                + "[--cycles N] [--tone-duration-seconds N]"
        case let .osStatus(stage, status):
            return "\(stage) failed: OSStatus \(status) (\(fourCC(status)))"
        case let .unsupportedFormat(format):
            return
                "unsupported tap format: id=\(format.mFormatID) "
                + "flags=\(format.mFormatFlags) bits=\(format.mBitsPerChannel)"
        case .noFrames:
            return "the process tap delivered no audio frames"
        case let .signalTooQuiet(rms, targetAmplitude):
            return "captured signal did not contain the expected tone: rms=\(rms) target_amplitude=\(targetAmplitude)"
        }
    }
}

private func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return "non-printable" }
    return String(bytes: bytes, encoding: .ascii) ?? "non-printable"
}

private func requireNoError(_ status: OSStatus, stage: String) throws {
    guard status == noErr else {
        throw ProbeError.osStatus(stage: stage, status: status)
    }
}

private func defaultSystemOutputDevice() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(unknownAudioObject)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try requireNoError(
        AudioObjectGetPropertyData(systemAudioObject, &address, 0, nil, &size, &deviceID),
        stage: "read default system output"
    )
    return deviceID
}

private func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &uid) { pointer in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    try requireNoError(status, stage: "read default system output UID")
    return uid as String
}

private func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try requireNoError(
        AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
        stage: "read process tap format"
    )
    return format
}

private final class SignalAccumulator: @unchecked Sendable {
    let sampleRate: Double
    let targetFrequency: Double
    private(set) var callbacks: UInt64 = 0
    private(set) var frames: UInt64 = 0
    private(set) var analyzedSamples: UInt64 = 0
    private(set) var sumSquares = 0.0
    private(set) var peak = 0.0
    private(set) var targetReal = 0.0
    private(set) var targetImaginary = 0.0

    init(sampleRate: Double, targetFrequency: Double) {
        self.sampleRate = sampleRate
        self.targetFrequency = targetFrequency
    }

    // Called only on the serial Core Audio IO queue. No locks, logging, file IO,
    // allocation, async work, or model work is performed in this callback path.
    func ingest(_ input: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !buffers.isEmpty else { return }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, format.mBitsPerChannel == 32 else { return }

        let channelCount = max(Int(format.mChannelsPerFrame), 1)
        let first = buffers[0]
        guard let data = first.mData else { return }
        let scalarCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = isNonInterleaved ? scalarCount : scalarCount / channelCount
        guard frameCount > 0 else { return }

        let samples = data.assumingMemoryBound(to: Float.self)
        let startFrame = frames
        callbacks += 1
        frames += UInt64(frameCount)
        analyzedSamples += UInt64(frameCount)

        for frame in 0..<frameCount {
            let index = isNonInterleaved ? frame : frame * channelCount
            let sample = Double(samples[index])
            let absolute = abs(sample)
            sumSquares += sample * sample
            if absolute > peak { peak = absolute }

            let phase =
                2.0 * Double.pi * targetFrequency
                * Double(startFrame + UInt64(frame)) / sampleRate
            targetReal += sample * cos(phase)
            targetImaginary -= sample * sin(phase)
        }
    }

    var rms: Double {
        guard analyzedSamples > 0 else { return 0 }
        return sqrt(sumSquares / Double(analyzedSamples))
    }

    var targetAmplitude: Double {
        guard analyzedSamples > 0 else { return 0 }
        return 2.0 * hypot(targetReal, targetImaginary) / Double(analyzedSamples)
    }
}

private final class AudioOnlyProcessTapProbe: @unchecked Sendable {
    private let ioQueue = DispatchQueue(
        label: "com.macparakeet.process-tap-audio-only-probe",
        qos: .userInitiated
    )
    private var tapID = AudioObjectID(unknownAudioObject)
    private var aggregateDeviceID = AudioObjectID(unknownAudioObject)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private(set) var outputUID = ""
    private(set) var accumulator: SignalAccumulator?

    func start(targetFrequency: Double) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        let tapUUID = UUID()
        description.uuid = tapUUID
        description.muteBehavior = .unmuted

        try requireNoError(
            AudioHardwareCreateProcessTap(description, &tapID),
            stage: "create audio-only process tap"
        )
        format = try tapFormat(tapID)

        guard format.mFormatID == kAudioFormatLinearPCM,
            (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            format.mBitsPerChannel == 32,
            format.mSampleRate > 0
        else {
            throw ProbeError.unsupportedFormat(format)
        }

        let outputDevice = try defaultSystemOutputDevice()
        outputUID = try deviceUID(outputDevice)
        let aggregateUID = "com.macparakeet.process-tap-probe.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacParakeet Audio-Only Tap Probe",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]
        try requireNoError(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            stage: "create private aggregate tap device"
        )

        let accumulator = SignalAccumulator(
            sampleRate: format.mSampleRate,
            targetFrequency: targetFrequency
        )
        self.accumulator = accumulator
        let callback: AudioDeviceIOBlock = { _, inputData, _, _, _ in
            accumulator.ingest(inputData, format: self.format)
        }
        try requireNoError(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDeviceID,
                ioQueue,
                callback
            ),
            stage: "create process tap IO callback"
        )
        try requireNoError(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            stage: "start process tap IO"
        )
    }

    func stop() {
        if aggregateDeviceID != unknownAudioObject, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
            ioQueue.sync {}
        }
        if aggregateDeviceID != unknownAudioObject {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = unknownAudioObject
        }
        if tapID != unknownAudioObject {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = unknownAudioObject
        }
    }

    var streamFormat: AudioStreamBasicDescription { format }
}

private func writeDeterministicTone(
    to url: URL,
    sampleRate: Int = 48_000,
    durationSeconds: Double = 2.0,
    frequency: Double = 997.0,
    amplitude: Double = 0.35
) throws {
    let channels = 2
    let frameCount = Int(Double(sampleRate) * durationSeconds)
    let bytesPerSample = 2
    let dataSize = frameCount * channels * bytesPerSample

    var data = Data()
    func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
    func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    appendASCII("RIFF")
    appendUInt32(UInt32(36 + dataSize))
    appendASCII("WAVEfmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(UInt16(channels))
    appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * channels * bytesPerSample))
    appendUInt16(UInt16(channels * bytesPerSample))
    appendUInt16(16)
    appendASCII("data")
    appendUInt32(UInt32(dataSize))

    for frame in 0..<frameCount {
        let envelopeFrames = min(frame, frameCount - 1 - frame)
        let envelope = min(Double(envelopeFrames) / 480.0, 1.0)
        let value =
            sin(2.0 * Double.pi * frequency * Double(frame) / Double(sampleRate))
            * amplitude * envelope
        let sample = Int16(clamping: Int(value * Double(Int16.max)))
        for _ in 0..<channels { appendUInt16(UInt16(bitPattern: sample)) }
    }
    try data.write(to: url, options: .atomic)
}

private struct Arguments {
    let output: URL
    let tone: URL
    let cycles: Int
    let toneDurationSeconds: Double

    init(_ arguments: [String]) throws {
        var output: URL?
        var tone: URL?
        var cycles = 1
        var toneDurationSeconds = 2.0
        var index = 1

        while index < arguments.count {
            guard index + 1 < arguments.count else { throw ProbeError.badArguments }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--output":
                output = URL(fileURLWithPath: value)
            case "--tone":
                tone = URL(fileURLWithPath: value)
            case "--cycles":
                guard let parsed = Int(value), parsed > 0, parsed <= 100 else {
                    throw ProbeError.badArguments
                }
                cycles = parsed
            case "--tone-duration-seconds":
                guard let parsed = Double(value), parsed >= 0.25, parsed <= 300 else {
                    throw ProbeError.badArguments
                }
                toneDurationSeconds = parsed
            default:
                throw ProbeError.badArguments
            }
            index += 2
        }

        guard let output, let tone else { throw ProbeError.badArguments }
        self.output = output
        self.tone = tone
        self.cycles = cycles
        self.toneDurationSeconds = toneDurationSeconds
    }
}

private func writeResult(_ result: [String: Any], to output: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output, options: .atomic)
}

@main
private enum Main {
    static func main() {
        let targetFrequency = 997.0
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let arguments: Arguments
        do {
            arguments = try Arguments(CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(64)
        }

        var result: [String: Any] = [
            "schemaVersion": 2,
            "startedAt": startedAt,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "targetFrequencyHz": targetFrequency,
            "requestedCycles": arguments.cycles,
            "toneDurationSeconds": arguments.toneDurationSeconds,
            "microphoneRequested": false,
            "screenPixelsRequested": false,
            "captureAPI": "CoreAudio AudioHardwareCreateProcessTap",
        ]

        do {
            try writeDeterministicTone(
                to: arguments.tone,
                durationSeconds: arguments.toneDurationSeconds,
                frequency: targetFrequency
            )

            var cycleResults: [[String: Any]] = []
            var totalCallbacks: UInt64 = 0
            var totalFrames: UInt64 = 0
            var totalAnalyzedSamples: UInt64 = 0
            var minimumRMS = Double.greatestFiniteMagnitude
            var minimumTargetAmplitude = Double.greatestFiniteMagnitude
            var maximumPeak = 0.0

            for cycle in 1...arguments.cycles {
                let probe = AudioOnlyProcessTapProbe()
                do {
                    try probe.start(targetFrequency: targetFrequency)
                    Thread.sleep(forTimeInterval: 0.25)

                    let player = Process()
                    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                    player.arguments = [arguments.tone.path]
                    try player.run()
                    player.waitUntilExit()
                    guard player.terminationStatus == 0 else {
                        throw ProbeError.osStatus(
                            stage: "play deterministic tone in cycle \(cycle)",
                            status: OSStatus(player.terminationStatus)
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                    probe.stop()
                } catch {
                    probe.stop()
                    throw error
                }

                guard let metrics = probe.accumulator, metrics.frames > 0 else {
                    throw ProbeError.noFrames
                }
                guard metrics.rms >= 0.005, metrics.targetAmplitude >= 0.005 else {
                    throw ProbeError.signalTooQuiet(
                        rms: metrics.rms,
                        targetAmplitude: metrics.targetAmplitude
                    )
                }

                let format = probe.streamFormat
                cycleResults.append([
                    "cycle": cycle,
                    "defaultOutputUID": probe.outputUID,
                    "sampleRateHz": format.mSampleRate,
                    "channels": format.mChannelsPerFrame,
                    "formatFlags": format.mFormatFlags,
                    "callbacks": metrics.callbacks,
                    "capturedFrames": metrics.frames,
                    "analyzedSamples": metrics.analyzedSamples,
                    "rms": metrics.rms,
                    "peak": metrics.peak,
                    "targetAmplitude": metrics.targetAmplitude,
                ])
                totalCallbacks += metrics.callbacks
                totalFrames += metrics.frames
                totalAnalyzedSamples += metrics.analyzedSamples
                minimumRMS = min(minimumRMS, metrics.rms)
                minimumTargetAmplitude = min(minimumTargetAmplitude, metrics.targetAmplitude)
                maximumPeak = max(maximumPeak, metrics.peak)
            }

            result.merge([
                "status": "PASS",
                "permissionOutcome": "process_tap_created",
                "completedCycles": cycleResults.count,
                "callbacks": totalCallbacks,
                "capturedFrames": totalFrames,
                "analyzedSamples": totalAnalyzedSamples,
                "minimumCycleRMS": minimumRMS,
                "peak": maximumPeak,
                "minimumCycleTargetAmplitude": minimumTargetAmplitude,
                "cycles": cycleResults,
            ]) { _, new in new }
            try writeResult(result, to: arguments.output)
            print(arguments.output.path)
        } catch {
            result.merge([
                "status": "FAIL",
                "permissionOutcome": "unknown_or_denied",
                "error": String(describing: error),
            ]) { _, new in new }
            try? writeResult(result, to: arguments.output)
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
