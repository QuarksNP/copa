import SwiftUI

/// The row of category tabs. The blue pill slides between tabs.
struct CategoryBar: View {
    let counts: [ClipCategory: Int]
    @Environment(NotchController.self) private var notch
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClipCategory.allCases) { category in
                tab(for: category)
            }
        }
        .padding(2)
        .background(.white.opacity(0.06), in: .capsule)
    }

    private func tab(for category: ClipCategory) -> some View {
        let isSelected = notch.category == category
        let count = counts[category] ?? 0

        return Button {
            withAnimation(.snappy(duration: 0.3)) { notch.category = category }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: category.symbol)
                Text(category.title)
                if isSelected && count > 0 {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .fixedSize()
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
