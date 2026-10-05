import SwiftUI

/// The inline text field used to name a clip, a folder or a section. It takes the place of
/// whatever it's naming. Return saves, Esc cancels, clicking elsewhere saves.
struct NameEditor: View {
    let target: NotchController.Editing
    let font: Font
    let onSave: (String) -> Void

    @Environment(NotchController.self) private var notch
    @State private var draft: String
    @FocusState private var focused: Bool

    init(target: NotchController.Editing, name: String,
         font: Font = .system(size: 11, weight: .medium), onSave: @escaping (String) -> Void) {
        self.target = target
        self.font = font
        self.onSave = onSave
        _draft = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(.primary)
            .focused($focused)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1))
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(save: true) }
            }
            .onAppear {
                notch.focusPanel()
                // Focus on the next run loop, once the panel has become key.
                DispatchQueue.main.async { focused = true }
            }
            .onDisappear { finish(save: true) }
    }

    private func finish(save: Bool) {
        guard notch.editing == target else { return }
        if save { onSave(draft) }
        notch.editing = nil
    }
}
