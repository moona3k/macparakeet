import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MacParakeet

@MainActor
final class BranchingRecordingCoverViewTests: XCTestCase {
    func testNativeCanvasProducesDistinctSyntheticCoverPNGs() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let secondID = try XCTUnwrap(UUID(uuidString: "11112233-4455-6677-8899-AABBCCDDEEFF"))

        let first = try rasterizedPNG(for: firstID)
        let repeated = try rasterizedPNG(for: firstID)
        let second = try rasterizedPNG(for: secondID)

        XCTAssertGreaterThan(first.count, 300)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
    }

    func testReportsNativeSyntheticGalleryRenderMeasurements() throws {
        guard ProcessInfo.processInfo.environment["MACPARAKEET_RECORDING_COVER_MEASURE"] == "1" else {
            throw XCTSkip("Set MACPARAKEET_RECORDING_COVER_MEASURE=1 to run the manual native rendering measurement.")
        }
        guard let outputDirectoryPath = ProcessInfo.processInfo.environment["MACPARAKEET_RECORDING_COVER_OUTPUT_DIR"]
        else {
            throw XCTSkip("Set MACPARAKEET_RECORDING_COVER_OUTPUT_DIR to save the manual native PNG gallery.")
        }

        let ids = try (0..<24).map { value in
            try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value)))
        }

        // This creates a fresh native renderer for every cover. It is a
        // reproducible synthetic cost check, not a scrolling-frame profile or
        // a cache decision by itself.
        let cold = try ids.map { id in
            try measure { _ = try rasterizedPNG(for: id) }
        }
        let warm = try ids.map { id in
            try measure { _ = try rasterizedPNG(for: id) }
        }
        let flatPlaceholder = try ids.map { _ in
            try measure { _ = try rasterizedPNG(content: FlatRecordingPlaceholderView()) }
        }
        let twelveCardGrid = try measure {
            for id in ids.prefix(12) {
                _ = try rasterizedPNG(for: id)
            }
        }
        let flatTwelveCardGrid = try measure {
            for _ in ids.prefix(12) {
                _ = try rasterizedPNG(content: FlatRecordingPlaceholderView())
            }
        }

        print(
            "Branching cover native synthetic 320x180pt @2x (640x360px), combined SwiftUI ImageRenderer recipe + Canvas raster + PNG encoding: cold p50 \(format(percentile(cold, 0.50))) ms, "
                + "p95 \(format(percentile(cold, 0.95))) ms; warm p50 \(format(percentile(warm, 0.50))) ms, "
                + "p95 \(format(percentile(warm, 0.95))) ms; 12 sequential covers \(format(twelveCardGrid)) ms. "
                + "Flat waveform placeholder in the same harness: p50 \(format(percentile(flatPlaceholder, 0.50))) ms, "
                + "p95 \(format(percentile(flatPlaceholder, 0.95))) ms; 12 covers \(format(flatTwelveCardGrid)) ms."
        )

        let outputDirectory = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (index, id) in ids.prefix(12).enumerated() {
            let data = try rasterizedPNG(for: id)
            let output = outputDirectory.appendingPathComponent(
                String(format: "%02d-%@.png", index + 1, id.uuidString.lowercased())
            )
            try data.write(to: output, options: .atomic)
        }
        print("Branching cover native synthetic PNG gallery: \(outputDirectory.path)")
    }

    private func rasterizedPNG(for id: UUID) throws -> Data {
        try rasterizedPNG(content: BranchingRecordingCoverView(recordingID: id))
    }

    private func rasterizedPNG<Content: View>(content: Content) throws -> Data {
        let size = NSSize(width: 320, height: 180)
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let representation = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func measure(_ work: () throws -> Void) rethrows -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        try work()
        return (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func percentile(_ values: [TimeInterval], _ quantile: Double) -> TimeInterval {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * quantile).rounded(.up)))
        return sorted[index]
    }

    private func format(_ milliseconds: TimeInterval) -> String {
        String(format: "%.2f", milliseconds)
    }
}

private struct FlatRecordingPlaceholderView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
