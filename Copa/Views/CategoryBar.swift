import SwiftUI

/// The row of tabs: the ones Copa comes with, then the sections the user made. The blue pill
/// slides between them, and the row scrolls when there are more tabs than fit. "+" sits outside
/// the row (`NewSectionButton`), so it stays reachable however many sections there are.
struct CategoryBar: View {
    let sections: [ClipSection]
    let counts: [ClipCategory: Int]

    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app
    @Namespace private var pill

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(ClipCategory.builtIn) { category in
                        tab(category, title: category.title, symbol: category.symbol)
                    }
                    ForEach(sections) { section in
                        sectionTab(section)
                    }
                }
                .padding(2)
                .background(.white.opacity(0.06), in: .capsule)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Picking a tab from the menu, or making one, can land outside the visible part.
            .onChange(of: notch.category) { _, category in
                guard notch.isExpanded else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(category.id, anchor: .center) }
            }
        }
    }

    // MARK: Tabs

    private func tab<Label: View>(_ category: ClipCategory, @ViewBuilder label: () -> Label) -> some View {
        let isSelected = notch.category == category
        return Button {
            withAnimation(.snappy(duration: 0.3)) { notch.category = category }
        } label: {
            label()
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
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
        .id(category.id)
    }

    private func tab(_ category: ClipCategory, title: String, symbol: String) -> some View {
        tab(category) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                count(for: category)
            }
        }
    }

    @ViewBuilder
    private func count(for category: ClipCategory) -> some View {
        let count = counts[category] ?? 0
        if notch.category == category && count > 0 {
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .transition(.opacity.combined(with: .scale))
        }
    }

    private func sectionTab(_ section: ClipSection) -> some View {
        let category = ClipCategory.section(section.id)
        return Group {
            if notch.editing == .section(section.id) {
                NameEditor(target: .section(section.id), name: section.name) { name in
                    app.store.rename(section, to: name)
                }
                .frame(width: 96)
                .padding(.horizontal, 4)
                .id(category.id)
            } else {
                tab(category) {
                    HStack(spacing: 4) {
                        Image(systemName: section.symbol)
                        Text(section.name)
                        count(for: category)
                    }
                }
                .contextMenu { sectionMenu(section) }
            }
        }
    }

    @ViewBuilder
    private func sectionMenu(_ section: ClipSection) -> some View {
        Button("Rename…", systemImage: "pencil") {
            notch.category = .section(section.id)
            notch.editing = .section(section.id)
        }
        Menu("Icon", systemImage: "square.grid.2x2") {
            ForEach(ClipSection.symbols, id: \.self) { symbol in
                Button(symbol.replacingOccurrences(of: ".", with: " ").capitalized, systemImage: symbol) {
                    app.store.setSymbol(section, to: symbol)
                }
            }
        }
        Divider()
        Button("Move Left", systemImage: "arrow.left") {
            withAnimation(.snappy) { app.store.move(section, by: -1) }
        }
        .disabled(sections.first?.id == section.id)
        Button("Move Right", systemImage: "arrow.right") {
            withAnimation(.snappy) { app.store.move(section, by: 1) }
        }
        .disabled(sections.last?.id == section.id)
        Divider()
        // Spelled out: one of these throws away everything filed in the section.
        Button("Delete Section, Keep Clips", systemImage: "rectangle.badge.minus") {
            delete(section, keepingContents: true)
        }
        Button("Delete Section & Contents", systemImage: "trash", role: .destructive) {
            delete(section, keepingContents: false)
        }
    }

    private func delete(_ section: ClipSection, keepingContents: Bool) {
        withAnimation(.snappy(duration: 0.3)) {
            if notch.category == .section(section.id) { notch.category = .all }
            app.store.delete(section, keepingContents: keepingContents)
        }
    }
}

/// Adds a section. It sits next to the tabs rather than inside them, so it never scrolls away.
struct NewSectionButton: View {
    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            let section = app.store.addSection(name: "New Section")
            withAnimation(.snappy(duration: 0.3)) { notch.category = .section(section.id) }
            notch.editing = .section(section.id)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
                .background(.white.opacity(0.06), in: .circle)
        }
        .buttonStyle(.plain)
        .help("New section")
    }
}
