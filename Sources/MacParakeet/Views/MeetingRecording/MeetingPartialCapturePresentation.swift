import MacParakeetCore

struct MeetingPartialCapturePresentation: Equatable {
    let badgeText: String
    let title: String
    let message: String

    static func make(for transcription: Transcription) -> MeetingPartialCapturePresentation? {
        guard transcription.sourceType == .meeting,
            let report = transcription.meetingCaptureReport,
            report.quality == .partial
        else {
            return nil
        }

        return MeetingPartialCapturePresentation(
            badgeText: "Partial audio",
            title: "Partial meeting audio",
            message: "\(durationMessage(for: report)) \(sourceMessage(for: report))"
        )
    }

    private static func durationMessage(for report: MeetingCaptureReport) -> String {
        if report.capturedDurationMs == report.elapsedDurationMs {
            return "This \(report.elapsedDurationMs.formattedDuration) session contains partial audio."
        }
        return
            "Playback is \(report.capturedDurationMs.formattedDuration) from a \(report.elapsedDurationMs.formattedDuration) session."
    }

    private static func sourceMessage(for report: MeetingCaptureReport) -> String {
        var messages: [String] = []
        if let fallbackSource = report.playbackFallbackSource {
            let sourceLabel = fallbackSource == .microphone ? "microphone" : "system audio"
            messages.append(
                "Playback contains only \(sourceLabel) because the combined recording could not be built."
            )
        }
        messages.append(
            contentsOf: report.sources
                .filter { $0.status != .complete }
                .map { sourceMessage(for: $0) })

        return messages.isEmpty
            ? "The recording is incomplete."
            : messages.joined(separator: " ")
    }

    private static func sourceMessage(
        for source: MeetingCaptureReport.SourceReport
    ) -> String {
        let label = source.source == .microphone ? "Microphone" : "System audio"
        let duration = source.writtenDurationMs.formattedDuration
        switch source.status {
        case .complete:
            return ""
        case .coverageShortfall:
            return "\(label) captured \(duration)."
        case .interrupted:
            return "\(label) capture was interrupted after \(duration)."
        case .unavailable:
            let audioLabel = source.source == .microphone ? "microphone audio" : "system audio"
            return "No \(audioLabel) was captured."
        case .captureFailed:
            return "\(label) capture failed after \(duration)."
        }
    }
}
