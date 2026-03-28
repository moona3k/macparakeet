import AVKit
import SwiftUI

/// NSViewRepresentable wrapping AVPlayerView for macOS with optional subtitle overlay.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var subtitleText: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true

        // Add subtitle label to the content overlay (sits between video and controls)
        if let overlay = view.contentOverlayView {
            let label = SubtitleOverlayLabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -12),
                label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.85),
            ])
            context.coordinator.subtitleLabel = label
        }

        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        context.coordinator.subtitleLabel?.update(text: subtitleText)
    }

    class Coordinator {
        var subtitleLabel: SubtitleOverlayLabel?
    }
}

// MARK: - Subtitle Overlay Label

/// AppKit view for rendering subtitle text over the video player.
/// Uses a dark semi-transparent background with white text, styled for readability.
final class SubtitleOverlayLabel: NSView {
    private let textField: NSTextField

    override init(frame: NSRect) {
        textField = NSTextField(wrappingLabelWithString: "")
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 6

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 15, weight: .medium)
        textField.textColor = .white
        textField.alignment = .center
        textField.isEditable = false
        textField.isSelectable = false
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.maximumNumberOfLines = 3
        textField.lineBreakMode = .byWordWrapping

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pass all clicks through to the player controls beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String?) {
        if let text, !text.isEmpty {
            textField.stringValue = text
            isHidden = false
        } else {
            isHidden = true
        }
    }
}
