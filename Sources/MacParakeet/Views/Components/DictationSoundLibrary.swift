import AVFoundation
import Foundation
import MacParakeetCore

/// File I/O and audio validation run off the main actor, never on the capture
/// callback. Imported files are owned copies, so moving the original is safe.
actor DictationSoundLibrary {
    static let maximumBytes = 5 * 1024 * 1024
    static let maximumDuration: TimeInterval = 5

    struct ImportedSound: Sendable {
        let fileName: String
        let displayName: String
        let data: Data
    }

    enum ImportError: LocalizedError {
        case unsupportedFile
        case tooLarge
        case invalidAudio
        case tooLong
        case unsafeFileName

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                "Choose a WAV, AIFF, MP3, M4A, or CAF audio file."
            case .tooLarge:
                "Choose a sound smaller than 5 MB."
            case .invalidAudio:
                "This file is not a playable audio cue. Try another file."
            case .tooLong:
                "Choose a sound no longer than 5 seconds. Short cues work best."
            case .unsafeFileName:
                "The saved sound is unavailable. Choose the file again."
            }
        }
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    func importSound(from source: URL) throws -> ImportedSound {
        guard source.isFileURL,
            DictationSoundConfiguration.supportedExtensions.contains(source.pathExtension.lowercased())
        else { throw ImportError.unsupportedFile }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let data = try Self.readBounded(source)
        try Self.validate(data)
        try Task.checkCancellation()
        let name = "\(UUID().uuidString).\(source.pathExtension.lowercased())"
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = directory.appendingPathComponent(name)
        do {
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return ImportedSound(fileName: name, displayName: source.lastPathComponent, data: data)
    }

    func data(for fileName: String) throws -> Data {
        let url = try managedURL(for: fileName)
        let data = try Self.readBounded(url)
        try Self.validate(data)
        return data
    }

    func remove(_ fileName: String) throws {
        let url = try managedURL(for: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func managedURL(for name: String) throws -> URL {
        guard DictationSoundConfiguration.isManagedFileName(name) else { throw ImportError.unsafeFileName }
        let url = directory.appendingPathComponent(name)
        // A replaced symlink must not turn an owned basename into an arbitrary
        // file read. remove() is conservative for the same reason.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ImportError.unsafeFileName
        }
        return url
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.unsupportedFile }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw ImportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        // Bound the actual read too: a size check alone races a growing file.
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let count = min(65_536, maximumBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        return data
    }

    private static func validate(_ data: Data) throws {
        let player: AVAudioPlayer
        do { player = try AVAudioPlayer(data: data) } catch { throw ImportError.invalidAudio }
        guard player.duration.isFinite, player.duration > 0 else { throw ImportError.invalidAudio }
        guard player.duration <= maximumDuration else { throw ImportError.tooLong }
    }
}
