import SwiftUI

/// A text field that edits a draft and commits on Return or when focus leaves —
/// one undo step per edit, and a chance to parse/validate the text (e.g. "3FS+2d").
struct CommitTextField: View {
    let value: String
    let placeholder: String
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void

    @State private var draft = ""
    /// The value the draft was loaded from; a commit only fires when the draft differs from it.
    @State private var baseline = ""
    @FocusState private var focused: Bool

    init(value: String, placeholder: String, axis: Axis = .horizontal, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.placeholder = placeholder
        self.axis = axis
        self.onCommit = onCommit
    }

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { draft = value; baseline = value }
            .onChange(of: value) { draft = value; baseline = value }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            #if os(macOS)
            .onExitCommand { draft = baseline; focused = false }
            #endif
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != baseline.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        onCommit(text)
        // If the commit is accepted `value` changes and resets the draft; if rejected, show the old value.
        draft = baseline
    }
}
