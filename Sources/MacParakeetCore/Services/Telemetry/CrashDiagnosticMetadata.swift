import Foundation

/// Optional, validated crash-time evidence. The upload envelope belongs to the
/// new process; `crash_session` belongs to the process that failed. Detailed
/// breadcrumbs, image lists, paths and free-form messages remain local.
public struct CrashDiagnosticMetadata: Sendable, Equatable {
    let props: [String: String]

    init(fields: [String: String]) {
        var result: [String: String] = [:]
        for key in ["crash_id", "crash_session", "shared_cache_uuid"] {
            if let value = fields[key], value.utf8.count == 36, let uuid = UUID(uuidString: value) {
                result[key] = uuid.uuidString.lowercased()
            }
        }
        if let value = fields["crash_os_build"], !value.isEmpty, value.utf8.count <= 31,
            value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        {
            result["crash_os_build"] = value
        }
        if let value = fields["shared_cache_slide"], value.hasPrefix("0x"),
            (3...18).contains(value.utf8.count),
            value.dropFirst(2).utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        {
            result["shared_cache_slide"] = value.lowercased()
        }
        if fields["crash_context_version"] == "1" {
            result["crash_context_version"] = "1"
            let consumers = ["0": "none", "1": "dictation", "2": "meeting", "3": "both"]
            if let value = fields["crash_registered_consumers"], let label = consumers[value] {
                result["crash_registered_consumers"] = label
            }
            for (key, maximum) in [
                ("crash_breadcrumbs_dropped", UInt32.max), ("crash_breadcrumbs_incomplete", UInt32(32)),
            ] {
                if let value = fields[key], let number = UInt32(value), number <= maximum, String(number) == value {
                    result[key] = value
                }
            }
        }
        props = result
    }
}
