import XCTest
@testable import MacParakeetCore

final class CrashDiagnosticMetadataTests: XCTestCase {
    func testOnlyFiniteCrashEvidenceReachesEventProps() {
        let metadata = CrashDiagnosticMetadata(fields: [
            "crash_id": "ABCDEF12-1234-1234-1234-123456789ABC",
            "crash_session": "12345678-1234-1234-1234-123456789abc",
            "crash_os_build": "25A123", "shared_cache_slide": "0xABC",
            "crash_context_version": "1", "crash_registered_consumers": "3",
            "crash_breadcrumbs_dropped": "4294967295", "crash_breadcrumbs_incomplete": "32",
            "breadcrumb": "private", "reason": "private", "device_name": "private",
        ])
        let event = TelemetryEventSpec.crashOccurred(
            crashType: "signal", signal: "6", name: "SIGABRT", crashTimestamp: "1",
            crashAppVer: "0.8.7", crashOsVer: "26", uuid: "uuid", slide: "0x0",
            reason: nil, stackTrace: "", diagnosticMetadata: metadata
        )
        XCTAssertEqual(event.props?["crash_id"], "abcdef12-1234-1234-1234-123456789abc")
        XCTAssertEqual(event.props?["crash_registered_consumers"], "both")
        XCTAssertEqual(event.props?["shared_cache_slide"], "0xabc")
        XCTAssertEqual(event.props?["crash_breadcrumbs_dropped"], "4294967295")
        for key in ["breadcrumb", "reason", "device_name"] { XCTAssertNil(event.props?[key]) }
    }

    func testMalformedOptionalFieldsAndUnsupportedSchemaAreDropped() {
        let metadata = CrashDiagnosticMetadata(fields: [
            "crash_id": "not a UUID", "crash_session": "12345678-1234-1234-1234-123456789abc\n",
            "crash_os_build": "my Mac", "shared_cache_slide": "0x123456789abcdef00",
            "shared_cache_uuid": "filename", "crash_context_version": "2",
            "crash_registered_consumers": "3", "crash_breadcrumbs_dropped": "1",
        ])
        XCTAssertTrue(metadata.props.isEmpty)
        for invalid in ["-1", "+1", "01", "1\n", "4294967296", "1.0"] {
            let result = CrashDiagnosticMetadata(fields: [
                "crash_context_version": "1", "crash_breadcrumbs_dropped": invalid,
            ])
            XCTAssertNil(result.props["crash_breadcrumbs_dropped"], invalid)
        }
        let invalidBounds = CrashDiagnosticMetadata(fields: [
            "crash_context_version": "1", "crash_registered_consumers": "4", "crash_breadcrumbs_incomplete": "33",
        ])
        XCTAssertEqual(invalidBounds.props, ["crash_context_version": "1"])
    }
}
