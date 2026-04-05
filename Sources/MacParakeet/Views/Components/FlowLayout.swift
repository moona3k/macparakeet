import SwiftUI

/// A layout that arranges views in horizontal rows, wrapping to the next line when needed.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.height }.max() ?? 0
            height += rowHeight
            if index < rows.count - 1 { height += spacing }
            let rowWidth = row.map { $0.width }.reduce(0, +) + CGFloat(max(row.count - 1, 0)) * spacing
            width = max(width, rowWidth)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        var subviewIndex = 0
        for (rowIndex, row) in rows.enumerated() {
            var x = bounds.minX
            let rowHeight = row.map { $0.height }.max() ?? 0
            for size in row {
                subviews[subviewIndex].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
                subviewIndex += 1
            }
            y += rowHeight
            if rowIndex < rows.count - 1 { y += spacing }
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[CGSize]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spaceNeeded = currentRowWidth > 0 ? size.width + spacing : size.width

            if currentRowWidth + spaceNeeded > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([size])
                currentRowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                currentRowWidth += spaceNeeded
            }
        }
        return rows
    }
}
