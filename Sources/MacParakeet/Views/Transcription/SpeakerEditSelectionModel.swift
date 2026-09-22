import MacParakeetCore

/// Pure selection state for the timed transcript's speaker-editing mode.
///
/// Keeping modifier-key semantics outside SwiftUI makes selection predictable
/// and lets the view reconcile its state after a correction changes segment
/// identities (for example after a split, merge, undo, or redo).
struct SpeakerEditSelectionModel: Equatable {
    enum Intent: Equatable {
        case replacing
        case toggling
        case extendingRange
    }

    private(set) var selectedIDs: Set<SpeakerEditableSegmentID> = []
    private(set) var anchorID: SpeakerEditableSegmentID?

    var isEmpty: Bool { selectedIDs.isEmpty }
    var count: Int { selectedIDs.count }

    mutating func select(
        _ id: SpeakerEditableSegmentID,
        intent: Intent,
        orderedIDs: [SpeakerEditableSegmentID]
    ) {
        guard orderedIDs.contains(id) else { return }

        switch intent {
        case .replacing:
            selectedIDs = [id]
            anchorID = id

        case .toggling:
            if selectedIDs.remove(id) == nil {
                selectedIDs.insert(id)
            }
            anchorID = id

        case .extendingRange:
            guard let anchorID,
                let anchorIndex = orderedIDs.firstIndex(of: anchorID),
                let selectedIndex = orderedIDs.firstIndex(of: id)
            else {
                selectedIDs = [id]
                anchorID = id
                return
            }
            let bounds = min(anchorIndex, selectedIndex)...max(anchorIndex, selectedIndex)
            selectedIDs.formUnion(bounds.map { orderedIDs[$0] })
        }
    }

    /// Toggle one contiguous rendered speaker turn as a single selection unit.
    /// Existing selections outside the turn are preserved.
    mutating func toggleTurn(
        _ ids: [SpeakerEditableSegmentID],
        orderedIDs: [SpeakerEditableSegmentID]
    ) {
        let available = Set(orderedIDs)
        let turnIDs = ids.filter(available.contains)
        guard !turnIDs.isEmpty else { return }

        if turnIDs.allSatisfy(selectedIDs.contains) {
            selectedIDs.subtract(turnIDs)
            if let anchorID, !selectedIDs.contains(anchorID) {
                self.anchorID = orderedIDs.first(where: selectedIDs.contains)
            }
        } else {
            selectedIDs.formUnion(turnIDs)
            anchorID = turnIDs.last
        }
    }

    mutating func clear() {
        selectedIDs.removeAll(keepingCapacity: true)
        anchorID = nil
    }

    /// Drops identities that disappeared from the latest effective projection.
    /// The first surviving item in transcript order becomes the next range anchor
    /// when the old anchor no longer exists.
    mutating func reconcile(with orderedIDs: [SpeakerEditableSegmentID]) {
        let available = Set(orderedIDs)
        selectedIDs.formIntersection(available)

        if let anchorID, available.contains(anchorID) {
            return
        }
        anchorID = orderedIDs.first(where: selectedIDs.contains)
    }

    func selectedSegments(
        from segments: [SpeakerEditableSegment]
    ) -> [SpeakerEditableSegment] {
        segments.filter { selectedIDs.contains($0.id) }
    }
}

enum TimedTranscriptMergeDirection: Hashable {
    case previous
    case next
}

/// Resolves the only safe line merge offered by the timed transcript UI:
/// two neighboring effective segments with the same current assignment.
enum TimedTranscriptMergeModel {
    static func availability(
        in segments: [SpeakerEditableSegment]
    ) -> [SpeakerEditableSegmentID: Set<TimedTranscriptMergeDirection>] {
        guard segments.count > 1 else { return [:] }
        var result: [SpeakerEditableSegmentID: Set<TimedTranscriptMergeDirection>] = [:]
        for (first, second) in zip(segments, segments.dropFirst())
        where first.assignment == second.assignment
            && first.wordRange.endIndexExclusive == second.wordRange.startIndex
        {
            result[first.id, default: []].insert(.next)
            result[second.id, default: []].insert(.previous)
        }
        return result
    }

    static func pair(
        for segmentID: SpeakerEditableSegmentID,
        direction: TimedTranscriptMergeDirection,
        in segments: [SpeakerEditableSegment]
    ) -> [SpeakerEditableSegment]? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else {
            return nil
        }
        let neighborIndex = direction == .previous ? index - 1 : index + 1
        guard segments.indices.contains(neighborIndex) else { return nil }

        let firstIndex = min(index, neighborIndex)
        let secondIndex = max(index, neighborIndex)
        let first = segments[firstIndex]
        let second = segments[secondIndex]
        guard first.assignment == second.assignment,
              first.wordRange.endIndexExclusive == second.wordRange.startIndex
        else {
            return nil
        }
        return [first, second]
    }
}

enum TimedTranscriptSplitModel {
    static func canSplit(_ segment: SpeakerEditableSegment?) -> Bool {
        guard let segment, !segment.hasTextOverride else { return false }
        return segment.wordRange.endIndexExclusive - segment.wordRange.startIndex > 1
    }
}
