import SwiftUI
import AppKit

struct CompletionShortcutSettings: View {
    @ObservedObject var manager: PluginManager
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(title: "Show candidates", subtitle: "Click the shortcut, then press a key with Command, Control or Option. Esc cancels recording.") {
                ShortcutRecorder(shortcut: manager.completionShortcut) { shortcut in
                    if let conflict = shortcut.conflict(in: NSApp.mainMenu) {
                        message = "Already used by \(conflict). Choose another shortcut."
                        return false
                    }
                    manager.setCompletionShortcut(shortcut); message = nil
                    return true
                }.frame(width: 136, height: 28)
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            Button("Restore Default") { manager.setCompletionShortcut(.standard); message = nil }
                .buttonStyle(SettingsActionStyle()).disabled(manager.completionShortcut == .standard)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: CompletionShortcut
    let save: (CompletionShortcut) -> Bool
    func makeNSView(context: Context) -> ShortcutRecordButton {
        let view = ShortcutRecordButton(title: "", target: nil, action: nil)
        view.bezelStyle = .rounded
        view.target = view; view.action = #selector(ShortcutRecordButton.startRecording)
        view.setAccessibilityLabel("Record shortcut for completion candidates")
        return view
    }
    func updateNSView(_ view: ShortcutRecordButton, context: Context) {
        view.shortcut = shortcut; view.save = save
        if !view.recording { view.title = shortcut.display }
    }
}

private final class ShortcutRecordButton: NSButton {
    var shortcut = CompletionShortcut.standard
    var save: ((CompletionShortcut) -> Bool)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func startRecording() {
        recording = true; title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            recording = false; title = shortcut.display; return
        }
        guard let value = CompletionShortcut(event: event) else { title = "Use ⌘, ⌃ or ⌥"; return }
        if save?(value) == true { shortcut = value; recording = false; title = value.display }
    }
    override func resignFirstResponder() -> Bool {
        recording = false; title = shortcut.display
        return super.resignFirstResponder()
    }
}
