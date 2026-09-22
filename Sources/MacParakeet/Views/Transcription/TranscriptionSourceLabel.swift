import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Source attribution for a Library row or card, drawn at the level the
/// surrounding context leaves open.
///
/// Both the grid card and the list row render source the same way, so the
/// decision lives here rather than being restated at each call site.
///
/// The text is dropped only where a real brand mark replaces it. The SF Symbol
/// fallback cannot carry a source on its own — seven of the sources reachable
/// under the Video filter share `play.rectangle.fill` and differ only by tint,
/// which names nothing to a reader who cannot separate those colors — so
/// anything without a bundled mark keeps its word.
///
/// Known gap, pre-existing and not closed here: `resolve` falls back to
/// `.youtube` for a `.youtube` row with no stored `sourceURL`, so such a row
/// draws the YouTube mark whatever its real origin. It already read "YouTube"
/// before this change, and the only creation path always stores the URL, so
/// this needs a legacy or corrupt row. Closing it means changing that fallback
/// to `.mediaURL`, which also moves the transcript detail chip and is its own
/// change.
struct TranscriptionSourceLabel: View {
    let source: TranscriptionSourceDisplay
    let style: LibrarySourceLabelStyle
    var font: Font = DesignSystem.Typography.caption
    var markSize: CGFloat = 11

    /// A brand mark stands in for the text only when we actually ship one for
    /// this source *and* the context has already narrowed the family.
    private var brandMark: MediaPlatform? {
        guard style == .brandMarkOnly else { return nil }
        guard let platform = source.brandedPlatform else { return nil }
        guard BrandGlyphImage.image(for: platform) != nil else { return nil }
        return platform
    }

    var body: some View {
        switch style {
        case .hidden:
            EmptyView()
        case .visible, .brandMarkOnly:
            if let platform = brandMark {
                // `.iconOnly` keeps the title as the element's accessibility
                // text while drawing only the mark, so the name a sighted
                // reader takes from the logo is not lost with the word. The
                // explicit label is belt and braces: PlatformGlyph hides
                // itself, and this must not depend on that flag being
                // overridden from outside.
                Label {
                    Text(source.collapsedText)
                } icon: {
                    PlatformGlyph(platform: platform, color: source.tint)
                        .frame(width: markSize, height: markSize)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(source.collapsedText)
            } else {
                Label(source.collapsedText, systemImage: source.systemImage)
                    .font(font)
                    .foregroundStyle(source.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
