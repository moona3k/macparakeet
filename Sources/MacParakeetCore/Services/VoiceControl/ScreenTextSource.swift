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

/// Reads the frontmost window's pixels with Vision. Never persists or transmits an image.
public protocol ScreenTextReading: Sendable {
    /// Returns [] when Screen Recording is not granted. `window` is the AX window frame in screen points.
    func read(window: CGRect) async -> [ScreenTextBlock]
}

/// Pixels stay in this actor: captured, recognised, reduced to text and a tiny
/// grayscale thumbnail used only to skip Vision on an unchanged frame.
public actor VisionScreenTextReader: ScreenTextReading {
    private var lastThumbnail: [UInt8] = []
    private var lastWindow: CGRect = .null
    private var lastBlocks: [ScreenTextBlock] = []

    public init() {}

    public static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    public func read(window: CGRect) async -> [ScreenTextBlock] {
        guard Self.hasScreenRecordingAccess, window.width > 0, window.height > 0,
            let image = CGWindowListCreateImage(
                window, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]),
            image.width > 0, image.height > 0
        else { return [] }
        let thumbnail = Self.thumbnail(image)
        if window == lastWindow, Self.meanAbsoluteDifference(thumbnail, lastThumbnail) < 2 { return lastBlocks }
        let blocks = Self.recognize(image, window: window)
        lastThumbnail = thumbnail; lastWindow = window; lastBlocks = blocks
        return blocks
    }

    private static func recognize(_ image: CGImage, window: CGRect) -> [ScreenTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        // Normalized boxes are bottom-left origin; the capture covers `window` at `scale` px/pt.
        let scale = CGFloat(image.width) / window.width
        let pointWidth = CGFloat(image.width) / scale
        let pointHeight = CGFloat(image.height) / scale
        var blocks: [ScreenTextBlock] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            let frame = CGRect(
                x: window.minX + box.minX * pointWidth, y: window.minY + (1 - box.maxY) * pointHeight,
                width: box.width * pointWidth, height: box.height * pointHeight)
            blocks.append(ScreenTextBlock(text: text, confidence: candidate.confidence, frame: frame))
        }
        return blocks
    }

    /// 1/8-scale 8-bit grayscale bytes; never written anywhere.
    private static func thumbnail(_ image: CGImage) -> [UInt8] {
        let width = max(1, image.width / 8), height = max(1, image.height / 8)
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count)
    }
}

/// Pure geometry/text helpers shared by the reader and the adapter.
public enum ScreenTextMerge {
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
