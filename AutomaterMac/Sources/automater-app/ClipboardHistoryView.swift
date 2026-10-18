import SwiftUI
import AppKit
import AutomaterKit

struct ClipboardHistoryView: View {
    @EnvironmentObject var pocket: PocketController
    @ObservedObject var clipboard: ClipboardMonitor
    @State private var query = ""
    @State private var pinnedOnly = false
    @State private var kind: ClipboardEntry.Kind?
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool
    private var items: [ClipboardEntry] {
        clipboard.history.entries.filter { entry in
            (!pinnedOnly || entry.isPinned) && (kind == nil || kind == entry.kind) &&
            (query.isEmpty || entry.text.localizedCaseInsensitiveContains(query) || entry.title.localizedCaseInsensitiveContains(query) || entry.sourceName.localizedCaseInsensitiveContains(query))
        }.sorted { $0.isPinned != $1.isPinned ? $0.isPinned : $0.copiedAt > $1.copiedAt }
    }
    private var selected: ClipboardEntry? { clipboard.history.entries.first { $0.id == clipboard.selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search clipboard", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { if let selected { copy(selected) } }
                }.padding(8).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                Button { clipboard.isPaused.toggle() } label: { Image(systemName: clipboard.isPaused ? "play" : "pause") }
                    .buttonStyle(.borderless).help(clipboard.isPaused ? "Resume clipboard history" : "Pause clipboard history")
                    .accessibilityLabel(clipboard.isPaused ? "Resume clipboard history" : "Pause clipboard history")
                Menu {
                    Button("Clear Unpinned Items") { clipboard.clear(keepingPinned: true) }
                    Button("Clear All History…", role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .help("Clipboard options")
                    .accessibilityLabel("Clipboard options")
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 15)
            HStack(spacing: 7) {
                filter("All", kind: nil)
                filter("Text", kind: .text)
                filter("Images", kind: .image)
                filter("Files", kind: .files)
                Spacer()
                Button { pinnedOnly.toggle() } label: { Label("Pinned", systemImage: pinnedOnly ? "pin.fill" : "pin") }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(pinnedOnly ? Color.accentColor : .secondary)
            }.padding(.horizontal, 20).padding(.bottom, 13)
            Divider()
            HSplitView {
                ScrollViewReader { scroll in
                    List(selection: Binding(get: { clipboard.selectedID }, set: { clipboard.selectedID = $0 })) {
                        ForEach(items) { item in
                            row(item).tag(item.id).id(item.id).contextMenu {
                                Button("Copy") { copy(item) }
                                Button("Paste to Previous App") { pocket.pasteClipboard(item) }.disabled(pocket.isRunning)
                                Button(item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
                                Divider()
                                Button("Delete", role: .destructive) { clipboard.remove(item) }
                            }
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .overlay { if items.isEmpty { ClipboardEmpty(icon: "clipboard", title: query.isEmpty ? "Your next copy starts here" : "No matches", detail: query.isEmpty ? "Text, images, and files stay within reach." : "") } }
                    .onChange(of: clipboard.selectedID) { _, id in if let id { scroll.scrollTo(id) } }
                }.frame(minWidth: 230, idealWidth: 290, maxWidth: 350)
                preview.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(clipboard.isPaused ? Color.orange : Color.green).frame(width: 5, height: 5)
                Text(pocket.isRunning ? pocket.runStatus : (pocket.toast ?? (clipboard.isPaused ? "History paused" : "\(clipboard.history.entries.count) of \(clipboard.limit) items")))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if pocket.isRunning {
                    Button("Cancel") { pocket.stop() }.controlSize(.small)
                } else if let selected {
                    Button { copy(selected) } label: { Label("Copy", systemImage: "doc.on.doc") }.controlSize(.small)
                    Button { pocket.pasteClipboard(selected) } label: { Label("Paste", systemImage: "arrow.turn.down.left") }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(pocket.isRunning)
                        .help("Paste to \(pocket.lastExternalApp?.localizedName ?? "the previous app") after 2 seconds")
                }
            }.padding(.horizontal, 20).frame(height: 46)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .automaterFindClipboard)) { _ in searchFocused = true }
        .onChange(of: query) { _, _ in selectVisibleItem() }
        .onChange(of: kind) { _, _ in selectVisibleItem() }
        .onChange(of: pinnedOnly) { _, _ in selectVisibleItem() }
        .alert("Clipboard", isPresented: Binding(get: { clipboard.error != nil }, set: { if !$0 { clipboard.error = nil } })) {
            Button("OK") { clipboard.error = nil }
        } message: { Text(clipboard.error ?? "") }
        .confirmationDialog("Clear all clipboard history, including pinned items?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { clipboard.clear(keepingPinned: false) }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func filter(_ title: String, kind value: ClipboardEntry.Kind?) -> some View {
        Button { kind = value } label: {
            Text(title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(kind == value ? Color.primary : Color.secondary)
                .background(kind == value ? Color.primary.opacity(0.065) : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }
    private func row(_ item: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                HStack(spacing: 5) {
                    Text(item.sourceName.isEmpty ? item.subtitle : item.sourceName)
                    Text("·")
                    Text(item.copiedAt, style: .time)
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
        }.padding(.vertical, 8)
    }
    @ViewBuilder private var preview: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(item.kind.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
                    Spacer()
                    Button { clipboard.togglePin(item) } label: { Image(systemName: item.isPinned ? "pin.fill" : "pin") }
                        .buttonStyle(.borderless).help(item.isPinned ? "Unpin" : "Pin").accessibilityLabel(item.isPinned ? "Unpin item" : "Pin item")
                }.padding(20)
                switch item.kind {
                case .text:
                    ScrollView { Text(item.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 20).padding(.bottom, 20) }
                case .image:
                    if let url = clipboard.imageURL(for: item), let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { ClipboardEmpty(icon: "photo", title: "Image unavailable") }
                case .files:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(item.paths, id: \.self) { path in
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium))
                                        Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "arrow.up.right") }
                                        .buttonStyle(.borderless).help("Reveal in Finder")
                                }
                            }
                        }.padding(.horizontal, 20)
                    }
                }
                Spacer(minLength: 0)
                Divider().padding(.horizontal, 20)
                HStack {
                    Text(item.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { clipboard.remove(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete item")
                }.padding(20)
            }.background(Color(nsColor: .textBackgroundColor))
        } else { ClipboardEmpty(icon: "doc.on.clipboard", title: "Select an item") }
    }
    private func copy(_ item: ClipboardEntry) {
        do { try clipboard.copy(item); pocket.flash("Copied") } catch { clipboard.error = error.localizedDescription }
    }
    private func selectVisibleItem() {
        if !items.contains(where: { $0.id == clipboard.selectedID }) { clipboard.selectedID = items.first?.id }
    }
}

struct ClipboardSettingsPane: View {
    @ObservedObject var clipboard: ClipboardMonitor
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Clipboard History").font(.headline)
            Toggle("Remember copied items", isOn: Binding(get: { !clipboard.isPaused }, set: { clipboard.isPaused = !$0 }))
                .toggleStyle(.switch).controlSize(.small)
            Text("Keeps your last 100 text, image, and file copies on this Mac. Pin up to 30 items to keep them in reach.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("Saved items").font(.callout)
                Spacer()
                Text("\(clipboard.history.entries.count)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Items marked private by another app are skipped. Pause recording at any time.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear Unpinned") { clipboard.clear(keepingPinned: true) }
                Button("Clear All…", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("Clear all clipboard history, including pinned items?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { clipboard.clear(keepingPinned: false) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ClipboardEmpty: View {
    var icon: String
    var title: String
    var detail: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}
