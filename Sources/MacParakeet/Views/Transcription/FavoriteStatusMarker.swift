import SwiftUI

struct FavoriteStatusMarker: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DesignSystem.Colors.warningAmber)
            .help("Favorite")
            .accessibilityLabel("Favorite")
    }
}
