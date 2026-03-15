import SwiftUI

struct ModelSelectorView: View {
    let currentModel: String
    let displayName: String
    let availableModels: [String]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(availableModels, id: \.self) { model in
                Button {
                    onSelect(model)
                } label: {
                    HStack {
                        Text(model)
                        if model == currentModel {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(displayName)
                    .font(DesignSystem.Typography.micro)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
