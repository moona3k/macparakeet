import Foundation

/// Where a voice sample was captured. The same person lands in a different
/// region of the embedding space over a compressed stream than over a local
/// microphone, so matching prefers like-for-like references.
public enum SpeakerCaptureDomain: String, Sendable, Codable, CaseIterable {
    case system
    case microphone
    case file

    /// What to show a user. The raw values are storage tokens and reading
    /// "system" in a list of voice samples explains nothing.
    public var displayName: String {
        switch self {
        case .system: "Meeting audio"
        case .microphone: "Microphone"
        case .file: "Imported file"
        }
    }
}

/// Identifies the representation an embedding was produced in.
///
/// Two ids, not one: FluidAudio returns the VBx clustering centroid, which
/// moves when the clustering configuration moves even if the model does not.
public struct SpeakerModelIdentity: Sendable, Equatable, Hashable, Codable {
    /// A mismatch makes two vectors incomparable.
    public let embeddingModelId: String
    /// A mismatch is comparable but less trusted, so callers tighten tau.
    public let aggregationProfileId: String

    public init(embeddingModelId: String, aggregationProfileId: String) {
        self.embeddingModelId = embeddingModelId
        self.aggregationProfileId = aggregationProfileId
    }
}

/// A speaker voice embedding, L2-normalized on construction.
///
/// Normalization happens here and nowhere else: FluidAudio's centroids are
/// un-normalized, so a bare dot product scales distances by `‖a‖·‖b‖` and
/// silently pushes same-speaker pairs past tau. The centroid norm also shrinks
/// as a cluster gets noisier, making the bias worst where accuracy matters most.
public struct SpeakerEmbedding: Sendable, Equatable {
    public static let dimension = 256
    public static let byteCount = dimension * MemoryLayout<Float32>.size
    /// FluidAudio emits an all-zero centroid when a cluster's responsibility
    /// denominator is zero; below this a vector carries no direction.
    static let minimumNorm: Float = 1e-6
    static let normTolerance: Float = 1e-3

    /// Unit-length, `dimension` values.
    public let vector: [Float]
    public let identity: SpeakerModelIdentity

    /// Returns `nil` for the wrong width, non-finite values, or no direction.
    public init?(rawVector: [Float], identity: SpeakerModelIdentity) {
        guard rawVector.count == Self.dimension else { return nil }
        guard rawVector.allSatisfy(\.isFinite) else { return nil }

        let norm = Self.norm(of: rawVector)
        guard norm.isFinite, norm >= Self.minimumNorm else { return nil }

        self.vector = rawVector.map { $0 / norm }
        self.identity = identity
    }

    /// Rebuilds a vector produced by ``data``. Does not re-normalize — dividing
    /// again by a norm rounding puts at 0.99999994 would make the round trip
    /// lossy — but validates it, so corruption is rejected not rescaled.
    public init?(data: Data, identity: SpeakerModelIdentity) {
        guard data.count == Self.byteCount else { return nil }

        var values = [Float]()
        values.reserveCapacity(Self.dimension)
        for index in 0..<Self.dimension {
            let start = data.startIndex + index * MemoryLayout<Float32>.size
            let bits = data[start..<start + MemoryLayout<Float32>.size]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            values.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }

        guard values.allSatisfy(\.isFinite) else { return nil }
        guard abs(Self.norm(of: values) - 1) <= Self.normTolerance else { return nil }

        self.vector = values
        self.identity = identity
    }

    /// Little-endian Float32, `byteCount` bytes. The stored form.
    public var data: Data {
        var output = Data(capacity: Self.byteCount)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    /// Cosine distance, FluidAudio's convention: 0 identical, 1 unrelated.
    /// `nil` when the embedding models differ, since they share no space; a
    /// differing aggregation profile is left to the caller's threshold policy.
    public func cosineDistance(to other: SpeakerEmbedding) -> Double? {
        guard identity.embeddingModelId == other.identity.embeddingModelId else { return nil }

        var dot: Float = 0
        for index in 0..<Self.dimension {
            dot += vector[index] * other.vector[index]
        }
        return 1 - Double(min(max(dot, -1), 1))
    }

    private static func norm(of values: [Float]) -> Float {
        var sumOfSquares: Float = 0
        for value in values {
            sumOfSquares += value * value
        }
        return sumOfSquares.squareRoot()
    }
}
