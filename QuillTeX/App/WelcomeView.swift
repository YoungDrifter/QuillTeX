import SwiftUI
import AppKit

struct WelcomeView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var library: DocumentLibrary
    var isSheet = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                brandMark
                Spacer(minLength: 22)
                // The mark sits in the corner on its own; everything below it is one
                // centred block, so the headline, the note and the entries share a centre.
                VStack(alignment: .center, spacing: 0) {
                    Text("Where ideas\nsettle onto paper.")
                        .font(.system(size: 34, weight: .regular, design: .serif)).lineSpacing(7)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.headline)
                    Text("One document, one stretch of quiet focus.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.top, 16)
                    VStack(spacing: 12) {
                        welcomeAction("Open a Local Document", icon: "folder", primary: true) {
                            store.openPanel(); if store.root != nil { store.showLibrary = false }
                        }
                        welcomeAction("New Document", icon: "square.and.pencil") { store.showTemplateChooser = true }
                    }.padding(.top, 32)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 22)
            }.padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 28)
                // Leading alignment keeps the column flush left now that the action
                // capsules hug their content instead of filling the column.
                // Narrow enough that the launcher itself can stay small; the column
                // still takes its full width when there is room.
                .frame(minWidth: 372, idealWidth: 420, maxWidth: 420, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(Palette.welcomeLeft)
            Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Recent Documents").font(.system(size: 21, weight: .regular, design: .serif))
                        Text("Pick up where you left off.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !library.recents.isEmpty {
                        Button { clearHistory() } label: {
                            Text("Clear History").font(.system(size: 12))
                                .padding(.horizontal, 14).frame(height: 32).quillCapsule()
                        }
                        .buttonStyle(WelcomeHoverButtonStyle())
                        .help("Forget every remembered document")
                        .padding(.trailing, isSheet ? 10 : 0)
                    }
                    if isSheet { ChromeButton(icon: "xmark", label: "Close Library", standalone: true) { store.showLibrary = false } }
                }.padding(.bottom, 22)
                if let error = library.storageError {
                    Text("Local library: \(error)").font(.caption).foregroundStyle(.primary).padding(.bottom, 12)
                }
                if library.recents.isEmpty {
                    // One centred sentence: no mark, no second line of explanation.
                    VStack {
                        Spacer()
                        Text("Your next document starts right here.")
                            .font(.system(size: 15, weight: .regular, design: .serif))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(library.recents) { item in RecentRow(item: item, store: store, library: library) }
                        }
                    }
                }
            }.padding(.horizontal, 26).padding(.top, 44).padding(.bottom, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.welcomeRight)
        }
        .sheet(isPresented: Binding(get: { store.showTemplateChooser && (store.root == nil || isSheet) }, set: { store.showTemplateChooser = $0 })) {
            TemplateChooser(store: store, library: library)
        }
    }

    /// Forgetting the history also forgets which compile settings each project had,
    /// and folders will need to be granted access again, so it asks first.
    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear the document history?"
        alert.informativeText = "QuillTeX will forget the documents you opened and the per-project compile settings. Folders on the Desktop, in Documents or Downloads will ask for access again. Your files are not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear History")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try library.clearRecents()
            BuildSettings.shared.clearProjectChoices()
        } catch {
            store.showError("Could Not Clear History", error.localizedDescription)
        }
    }
}

private extension WelcomeView {
    private var brandMark: some View {
        HStack(spacing: 10) {
            Image("QuillTeXMark").resizable().frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                // The mark hangs into the margin, just outside the text column.
                // `offset` keeps the layout box, so only the icon moves.
                .offset(x: -12)
            Text("QUILLTEX").font(.system(size: 10, weight: .medium)).tracking(3)
                .foregroundStyle(Palette.brandText)
        }
    }
    private func welcomeAction(_ title: String, icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .light)).frame(width: 22)
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 23)
            // Both entries share one width, matched to the headline block above so the
            // left column has a single right edge as well as a single left edge.
            .frame(minWidth: 258, alignment: .leading)
            .frame(height: 64)
            .contentShape(Capsule())
            .quillCapsule(selected: primary)
        }.buttonStyle(WelcomeHoverButtonStyle())
    }
}

private struct RecentRow: View {
    let item: RecentDocument
    @ObservedObject var store: ProjectStore
    @ObservedObject var library: DocumentLibrary
    @State private var hover = false
    var body: some View {
        Button {
            store.openProject(item.url, explicitRoot: true)
            if store.root == item.url.standardizedFileURL { store.showLibrary = false }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text").font(.system(size: 18, weight: .regular)).foregroundStyle(.black)
                    .frame(width: 38, height: 44).background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                Text(item.openedAt, style: .date).font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(12).contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(hover ? 0.035 : 0)))
        }.buttonStyle(.plain).onHover { hover = $0 }.help(item.path)
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Remove from Recents") {
                    do { try library.remove(item) } catch { store.showError("Could Not Update Recents", error.localizedDescription) }
                }
            }
    }
}

struct TemplateChooser: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var library: DocumentLibrary
    @State private var selected: String?
    @State private var preview = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start From a Template").font(.system(size: 23, weight: .regular, design: .serif))
                    Text("Templates are stored on this Mac, and you can add your own .tex files.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                ChromeButton(icon: "xmark", label: "Cancel", standalone: true) { store.showTemplateChooser = false }
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(library.templates) { template in
                            Button { select(template) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(template.displayTitle).font(.system(size: 13, weight: .medium))
                                    Text(template.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(selected == template.id ? Palette.selectionSoft : Color.black.opacity(0.025)))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(selected == template.id ? 0.12 : 0.04)))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 220)
                ScrollView([.vertical, .horizontal]) {
                    Text(preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.02), in: RoundedRectangle(cornerRadius: 12))
            }.frame(height: 320)
            HStack(spacing: 10) {
                capsuleButton("Add Template…") { store.importTemplates() }
                capsuleButton("Templates Folder") { NSWorkspace.shared.open(library.templatesDirectory) }
                capsuleButton("Delete", disabled: selected == nil) { deleteSelected() }
                Spacer()
                capsuleButton("Cancel") { store.showTemplateChooser = false }
                capsuleButton("Create Document…", prominent: true, disabled: selected == nil) {
                    guard let template = library.templates.first(where: { $0.id == selected }) else { return }
                    store.createDocument(from: template)
                }
            }.font(.system(size: 12))
        }.padding(30).frame(width: 720).preferredColorScheme(.light)
            .onAppear {
                library.reloadTemplates()
                if let template = library.templates.first(where: { $0.title == "academic-ctexart" }) ?? library.templates.first { select(template) }
            }
    }
    private func select(_ template: DocumentTemplate) {
        do { preview = try library.source(for: template); selected = template.id }
        catch { selected = nil; preview = "Could not read the template: \(error.localizedDescription)" }
    }
    private func capsuleButton(_ title: String, prominent: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).padding(.horizontal, 16).frame(height: 34).quillCapsule(selected: prominent)
                .opacity(disabled ? 0.35 : 1)
        }.buttonStyle(WelcomeHoverButtonStyle()).disabled(disabled)
    }
    /// Deleting a template removes a file, so it always asks first.
    private func deleteSelected() {
        guard let template = library.templates.first(where: { $0.id == selected }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(template.displayTitle)”?"
        alert.informativeText = "The template file is removed from your library. Documents you already created are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try library.deleteTemplate(template)
            selected = nil; preview = ""
            if let next = library.templates.first { select(next) }
        } catch { store.showError("Could Not Delete Template", error.localizedDescription) }
    }
}

/// The whole action capsule responds to hovering without changing its colour.
private struct WelcomeHoverFeedback: ViewModifier {
    var isPressed: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(!isEnabled || reduceMotion ? 1 : (isPressed ? 0.98 : (hovering ? 1.04 : 1)))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
    }
}

private struct WelcomeHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(WelcomeHoverFeedback(isPressed: configuration.isPressed))
    }
}
