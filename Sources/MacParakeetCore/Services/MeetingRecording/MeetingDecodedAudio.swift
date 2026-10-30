import Darwin
import Foundation

/// Seekable, disk-backed mono Float32 samples. The private scratch file is
/// unlinked immediately: closing the descriptor (including process exit) frees
/// it, so neither failed renders nor crashes leave another audio artifact.
final class MeetingDecodedAudio {
    private let file: FileHandle
    private(set) var count = 0

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let path = temporaryDirectory.appendingPathComponent("macparakeet-pcm-\(UUID().uuidString)").path
        // Set close-on-exec atomically so a concurrently launched helper cannot
        // inherit ownership of the anonymous recording scratch file.
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard unlink(path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        try file.seek(toOffset: UInt64(count * MemoryLayout<Float>.stride))
        try file.write(contentsOf: Data(buffer: samples))
        count += samples.count
    }

    func read(_ range: Range<Int>) throws -> [Float] {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw MeetingAudioError.storageFailed("decoded audio range out of bounds")
        }
        guard !range.isEmpty else { return [] }
        try file.seek(toOffset: UInt64(range.lowerBound * MemoryLayout<Float>.stride))
        let byteCount = range.count * MemoryLayout<Float>.stride
        var data = Data()
        while data.count < byteCount {
            guard let part = try file.read(upToCount: byteCount - data.count), !part.isEmpty else {
                throw MeetingAudioError.storageFailed("decoded audio read ended early")
            }
            data.append(part)
        }
        var samples = [Float](repeating: 0, count: range.count)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return samples
    }
}

/// The renderer uses bounded reads; small in-memory fixtures exercise the same
/// probe and conditioning implementation without audio codecs or scratch I/O.
struct MeetingAudioSamples {
    let count: Int
    let read: (Range<Int>) throws -> [Float]

    init(count: Int, read: @escaping (Range<Int>) throws -> [Float]) {
        self.count = count
        self.read = read
    }

    init(_ samples: [Float]) {
        count = samples.count
        read = { Array(samples[$0]) }
    }

    init(_ audio: MeetingDecodedAudio) {
        count = audio.count
        read = audio.read
    }
}
