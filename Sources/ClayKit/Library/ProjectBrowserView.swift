import SwiftUI

/// The studio library: a grid of notebook covers, plus new-model and tutorial cards.
public struct ProjectBrowserView: View {
    let store: ProjectStore
    let theme: StudioTheme
    let onOpen: (UUID) -> Void
    let onNew: () -> Void
    let onTutorial: () -> Void
    @Environment(StudioThemeStore.self) private var themes
    @State private var renaming: ProjectSummary?
    @State private var newName = ""
    @State private var editingCover: ProjectSummary?
    @State private var deleting: ProjectSummary?

    public init(store: ProjectStore, theme: StudioTheme, onOpen: @escaping (UUID) -> Void,
                onNew: @escaping () -> Void, onTutorial: @escaping () -> Void) {
        self.store = store; self.theme = theme; self.onOpen = onOpen; self.onNew = onNew; self.onTutorial = onTutorial
    }

    public var body: some View {
        let _ = store.thumbnailRevision
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 230), spacing: 26)], alignment: .leading, spacing: 30) {
                    actionCard(title: "New model", subtitle: "Start from a blank sheet", symbol: "plus", action: onNew)
                    actionCard(title: "Ceramic Vase", subtitle: "Interactive tutorial · 5 min", symbol: "graduationcap.fill", action: onTutorial)
                    ForEach(store.projects) { p in
                        Button { onOpen(p.id) } label: {
                            ProjectCardView(summary: p, thumbnail: store.thumbnail(p.id), theme: theme)
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button("Open") { onOpen(p.id) }
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Change cover…") { editingCover = p }
                            Button("Duplicate") { store.duplicate(p.id) }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = p }
                        }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
        }
        .background(theme.canvas.color.ignoresSafeArea())
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .alert("Rename model", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { store.rename(r.id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”? This can't be undone.",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { store.delete(d.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .sheet(item: $editingCover) { p in
            CoverLibraryView(cover: p.cover, thumbnail: store.thumbnail(p.id), title: p.name, theme: theme,
                             onSave: { store.updateCover(p.id, $0); editingCover = nil }, onCancel: { editingCover = nil })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clay Studio").font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(theme.ink.color)
                Text("Sketch in 2D · Form in 3D · Sculpt like clay · Measure with precision")
                    .font(.system(size: 13)).foregroundStyle(theme.secondaryInk.color)
            }
            Spacer()
            Picker("Theme", selection: Binding(get: { themes.current.id }, set: { id in themes.current = StudioTheme.all.first { $0.id == id } ?? .ceramic })) {
                ForEach(StudioTheme.all) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
    }

    private func actionCard(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.secondaryInk.color.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.panel.color.opacity(0.5)))
                    Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(theme.accent.color)
                }
                .aspectRatio(0.76, contentMode: .fit)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink.color)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}
