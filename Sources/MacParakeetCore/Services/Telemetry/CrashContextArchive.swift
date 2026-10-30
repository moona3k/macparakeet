import Foundation

/// Validated, finite crash context for the existing bounded local diagnostic
/// log. No raw report strings, exception descriptions, paths, or stack frames
/// are copied. Archival runs on the report-drain actor, never a capture callback.
struct CrashContextArchive: Sendable, Equatable {
    struct Breadcrumb: Sendable, Equatable {
        let sequence: UInt64
        let packed: UInt64
    }

    let metadata: CrashDiagnosticMetadata
    let timestamp: UInt64?
    let breadcrumbs: [Breadcrumb]

    init?(fields: [String: String], breadcrumbLines: [String]) {
        guard fields["crash_context_version"] == "1" else { return nil }
        let metadata = CrashDiagnosticMetadata(fields: fields)
        var records: [Breadcrumb] = []
        for line in breadcrumbLines.prefix(32) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2,
                parts[0].utf8.count <= 20,
                let sequence = UInt64(parts[0]), sequence > 0, String(sequence) == parts[0],
                parts[1].hasPrefix("0x"), (3...18).contains(parts[1].utf8.count),
                parts[1].dropFirst(2).utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }),
                let packed = UInt64(parts[1].dropFirst(2), radix: 16),
                CrashAudioContext.Record(packed: packed) != nil,
                sequence > (records.last?.sequence ?? 0)
            else { continue }
            records.append(Breadcrumb(sequence: sequence, packed: packed))
        }
        guard !records.isEmpty else { return nil }
        self.metadata = metadata
        if let raw = fields["timestamp"], raw.utf8.count <= 20,
            let value = UInt64(raw), value <= UInt64(Int64.max), String(value) == raw
        {
            timestamp = value
        } else {
            timestamp = nil
        }
        breadcrumbs = records
    }

    var message: String {
        var fields = ["crash_context_recovered"]
        // All props have already passed the closed CrashDiagnosticMetadata
        // schema. Sort for deterministic diagnostics and reproducible tests.
        for (key, value) in metadata.props.sorted(by: { $0.key < $1.key }) {
            fields.append("\(key)=\(value)")
        }
        if let timestamp { fields.append("crash_timestamp=\(timestamp)") }
        fields.append("crash_record_count=\(breadcrumbs.count)")
        fields.append(
            "crash_records="
                + breadcrumbs.map {
                    "\($0.sequence):0x\(String($0.packed, radix: 16))"
                }.joined(separator: ";"))
        return fields.joined(separator: " ")
    }

    /// A successful return means bytes were accepted by the existing bounded
    /// log writer, not fsync/power-loss durability. Never wait on another writer.
    func persist(to logURL: URL) throws {
        let data = AudioCaptureDiagnostics.encodedLogLine(
            message, timestamp: Date(), uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            correlation: nil
        )
        try AudioCaptureDiagnostics.writeLogLine(data, to: logURL, waitForLock: false, allowRotation: false)
    }
}
