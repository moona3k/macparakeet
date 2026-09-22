import AppKit
import CoreGraphics
import Foundation
import Vision

/// One recognised line of on-screen text, in screen points (top-left origin, same space as AX frames).
public struct ScreenTextBlock: Sendable, Equatable {
    public var text: String
    /// Vision confidence 0…1.
    public var confidence: Float
    public var frame: CGRect
    public init(text: String, confidence: Float, frame: CGRect) {
        self.text = text; self.confidence = confidence; self.frame = frame
    }
}

/// Reads one verified window. Pixels never leave this actor and no image is kept.
public protocol ScreenTextReading: Sendable {
    /// Returns [] when Screen Recording is denied, the window cannot be identified, or the app is no longer frontmost.
    func read(window: CGRect, processID: Int32) async -> [ScreenTextBlock]
}

struct ScreenTextCaptureWindow: Equatable, Sendable {
    let id: CGWindowID
    let processID: Int32
    let frame: CGRect
    let layer: Int
}

struct ScreenTextCapturePlan: Equatable, Sendable {
    let windowID: CGWindowID
    let exclusions: [CGRect]

    /// Window-server order is front to back. Two windows with the same frame fail closed.
    static func resolve(window: CGRect, processID: Int32, windows: [ScreenTextCaptureWindow]) -> Self? {
        guard ScreenTextMerge.validFrame(window), window.width * window.height <= 16_000_000 else { return nil }
        let matches = windows.indices.filter {
            windows[$0].processID == processID && windows[$0].layer == 0 && windows[$0].frame == window
        }
        guard matches.count == 1, let index = matches.first else { return nil }
        let exclusions = windows.prefix(index).map(\.frame).filter { $0.intersects(window) }
        guard exclusions.allSatisfy(ScreenTextMerge.validFrame) else { return nil }
        return Self(windowID: windows[index].id, exclusions: exclusions)
    }
}

/// Every read uses a fresh image of that window id. A rectangle capture would
/// include whatever else is painted on top, and a thumbnail skip can keep a
/// word that has since changed.
public actor VisionScreenTextReader: ScreenTextReading {
    public init() {}

    public static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    public func read(window: CGRect, processID: Int32) async -> [ScreenTextBlock] {
        let started = ContinuousClock.now
        guard Self.hasScreenRecordingAccess else {
            Self.note("screen-text: no Screen Recording grant")
            return []
        }
        guard ScreenTextMerge.validFrame(window) else {
            Self.note("screen-text: invalid window \(Self.rect(window))")
            return []
        }
        let front = await Self.foregroundPID()
        guard front == processID else {
            Self.note("screen-text: foreground \(front.map(String.init) ?? "none") != \(processID)")
            return []
        }
        guard let plan = Self.capturePlan(window: window, processID: processID) else {
            Self.note("screen-text: no unique window for pid \(processID) frame \(Self.rect(window)); \(Self.windowList(processID: processID))")
            return []
        }
        guard let image = CGWindowListCreateImage(
            .null, [.optionIncludingWindow], plan.windowID, [.bestResolution, .boundsIgnoreFraming]),
            image.width > 0, image.height > 0, image.width <= 12_000, image.height <= 12_000,
            image.width * image.height <= 40_000_000
        else {
            Self.note("screen-text: capture failed for window \(plan.windowID)")
            return []
        }
        guard let redacted = Self.redact(image, window: window, excluding: plan.exclusions) else {
            Self.note("screen-text: redact failed exclusions=\(plan.exclusions.count)")
            return []
        }
        guard !Task.isCancelled, await Self.foregroundPID() == processID,
            Self.capturePlan(window: window, processID: processID) == plan
        else {
            Self.note("screen-text: window changed before recognition")
            return []
        }
        let blocks = Self.recognize(redacted, window: window).filter { block in
            !plan.exclusions.contains { $0.intersects(block.frame) }
        }
        // Recognition is the slow part. A window that moved while Vision ran
        // must not contribute targets from the image captured at the start.
        guard !Task.isCancelled, await Self.foregroundPID() == processID,
            Self.capturePlan(window: window, processID: processID) == plan
        else {
            Self.note("screen-text: window changed during recognition")
            return []
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.note(
            "screen-text: \(blocks.count) blocks in \(milliseconds)ms window \(plan.windowID) exclusions \(plan.exclusions.count)"
        )
        return blocks
    }

    /// E2E only. Production stays quiet; the owned-fixture run needs the reason a read returned nothing.
    static func note(_ message: String) {
        guard ProcessInfo.processInfo.environment["MACPARAKEET_NATIVE_VOICE_CONTROL_E2E"] == "1" else { return }
        let line = message + "\n"
        let url = URL(fileURLWithPath: "/tmp/macparakeet-voice-control-e2e.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        print(message)
    }

    private static func rect(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
    }

    private static func windowList(processID: Int32) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return "window list unavailable" }
        let rows = list.compactMap { item -> String? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let bounds = item[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.intValue,
                let y = (bounds["Y"] as? NSNumber)?.intValue,
                let width = (bounds["Width"] as? NSNumber)?.intValue,
                let height = (bounds["Height"] as? NSNumber)?.intValue
            else { return nil }
            return "#\(id) \(x),\(y) \(width)x\(height)"
        }
        return rows.isEmpty ? "no on-screen windows" : rows.joined(separator: "; ")
    }

    private static func foregroundPID() async -> Int32? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    static func capturePlan(window: CGRect, processID: Int32) -> ScreenTextCapturePlan? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        var windows: [ScreenTextCaptureWindow] = []
        for item in list {
            if let alpha = item[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            if let alpha = item[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue == 0 { continue }
            guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let bounds = item[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { return nil }
            windows.append(
                ScreenTextCaptureWindow(
                    id: id, processID: pid,
                    frame: CGRect(x: x, y: y, width: width, height: height), layer: layer))
        }
        return ScreenTextCapturePlan.resolve(window: window, processID: processID, windows: windows)
    }

    /// Paint overlapping windows black before Vision sees the image.
    static func redact(_ image: CGImage, window: CGRect, excluding: [CGRect]) -> CGImage? {
        guard ScreenTextMerge.validFrame(window), excluding.allSatisfy(ScreenTextMerge.validFrame),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let scaleX = CGFloat(image.width) / window.width
        let scaleY = CGFloat(image.height) / window.height
        for frame in excluding {
            let clipped = frame.intersection(window)
            guard ScreenTextMerge.validFrame(clipped) else { continue }
            context.fill(
                CGRect(
                    x: (clipped.minX - window.minX) * scaleX,
                    y: (window.maxY - clipped.maxY) * scaleY,
                    width: clipped.width * scaleX, height: clipped.height * scaleY
                ).integral)
        }
        return context.makeImage()
    }

    private static func recognize(_ image: CGImage, window: CGRect) -> [ScreenTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        var blocks: [ScreenTextBlock] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                candidate.confidence.isFinite, candidate.confidence >= 0.3
            else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            let frame = CGRect(
                x: window.minX + box.minX * window.width,
                y: window.minY + (1 - box.maxY) * window.height,
                width: box.width * window.width, height: box.height * window.height)
            guard ScreenTextMerge.validFrame(frame) else { continue }
            blocks.append(ScreenTextBlock(text: text, confidence: candidate.confidence, frame: frame))
        }
        return blocks
    }
}

/// Pure geometry/text helpers shared by the reader and the adapter.
public enum ScreenTextMerge {
    static func validFrame(_ frame: CGRect) -> Bool {
        !frame.isInfinite && !frame.isNull
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    static let secureWords = [
        "password", "passcode", "one-time", "verification code", "api key", "secret", "credit card",
    ]

    /// Reading order: rows by median block height, then left to right.
    public static func readingOrder(_ blocks: [ScreenTextBlock]) -> [ScreenTextBlock] {
        guard blocks.count > 1 else { return blocks }
        let heights = blocks.map(\.frame.height).sorted()
        let median = max(1, heights[heights.count / 2])
        var rows: [[ScreenTextBlock]] = []
        var rowMidY: [CGFloat] = []
        for block in blocks.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = rowMidY.last, block.frame.midY - last < median * 0.5 {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block]); rowMidY.append(block.frame.midY)
            }
        }
        return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// Merge adjacent lines into blocks: aligned left edge (< 0.6 × height), small
    /// vertical gap (−0.2…0.8 × height), similar height (0.7…1.4).
    public static func mergeLines(_ blocks: [ScreenTextBlock]) -> [ScreenTextBlock] {
        var merged: [ScreenTextBlock] = []
        var lastLine: CGRect = .null
        for block in readingOrder(blocks) {
            let h = lastLine.height
            if var previous = merged.last, h > 0,
                abs(block.frame.minX - lastLine.minX) < 0.6 * h,
                (block.frame.minY - lastLine.maxY) > -0.2 * h, (block.frame.minY - lastLine.maxY) < 0.8 * h,
                block.frame.height / h >= 0.7, block.frame.height / h <= 1.4
            {
                previous.text += " " + block.text
                previous.confidence = min(previous.confidence, block.confidence)
                previous.frame = previous.frame.union(block.frame)
                merged[merged.count - 1] = previous
            } else {
                merged.append(block)
            }
            lastLine = block.frame
        }
        return merged
    }

    /// True when intersection / smaller-area ≥ 0.5 AND texts match (one contains the
    /// other, case/whitespace-insensitive, or ≥ half the words shared).
    public static func matches(_ block: ScreenTextBlock, controlLabel: String, controlFrame: CGRect) -> Bool {
        let overlap = block.frame.intersection(controlFrame)
        guard !overlap.isNull else { return false }
        let smaller = min(area(block.frame), area(controlFrame))
        guard smaller > 0, area(overlap) / smaller >= 0.5 else { return false }
        return textsMatch(block.text, controlLabel)
    }

    static func textsMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        let wa = Set(na.split(separator: " ")), wb = Set(nb.split(separator: " "))
        return wa.intersection(wb).count * 2 >= min(wa.count, wb.count)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isSecureLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return secureWords.contains(where: lower.contains)
    }

    /// Blocks not explained by any AX control, not intersecting `excludedFrames`
    /// (secure fields), and not carrying a secure word.
    public static func unexplained(
        _ blocks: [ScreenTextBlock], controls: [(label: String, frame: CGRect)], excludedFrames: [CGRect]
    ) -> [ScreenTextBlock] {
        blocks.filter { block in
            isAddressable(block.text) && !isSecureLine(block.text)
                && !excludedFrames.contains(where: { $0.intersects(block.frame) })
                && !controls.contains(where: { matches(block, controlLabel: $0.label, controlFrame: $0.frame) })
        }
    }

    /// A single glyph or a run of symbols (`f`, `#`, `•`, `→`) is an icon Vision
    /// read as text; nobody will say it, and it only pads the option list.
    static func isAddressable(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return letters.count >= 2
    }

    private static func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
}
