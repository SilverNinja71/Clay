import SwiftUI

/// The studio library: an overview of your work, the project you were last in, and every project.
public struct ProjectBrowserView: View {
    let store: ProjectStore
    let theme: StudioTheme
    let onOpen: (UUID) -> Void
    let onNew: () -> Void
    let onTutorial: () -> Void
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
            VStack(alignment: .leading, spacing: 24) {
                header
                if !store.projects.isEmpty {
                    LibraryStats(projects: store.projects, theme: theme)
                }
                if let recent = store.projects.first {
                    FeaturedProjectView(summary: recent, thumbnail: store.thumbnail(recent.id), theme: theme,
                                        onOpen: { onOpen(recent.id) }, onCover: { editingCover = recent })
                }
                sectionTitle(store.projects.isEmpty ? "Start something" : "All projects")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 22, alignment: .top)], alignment: .leading, spacing: 22) {
                    actionCard(title: "New project", subtitle: "Start from a blank sheet", symbol: "plus", action: onNew)
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
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clay Studio").font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(theme.ink.color)
                Text("Sketch in 2D · Form in 3D · Sculpt like clay · Measure with precision")
                    .font(.system(size: 13)).foregroundStyle(theme.secondaryInk.color)
            }
            Spacer()
            ThemePicker()
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(theme.secondaryInk.color)
    }

    private func actionCard(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(theme.accent.color.opacity(0.07))
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(theme.panel.color))
                        .overlay(Circle().strokeBorder(theme.accent.color.opacity(0.35), lineWidth: 1.5))
                }
                .frame(height: 158)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.ink.color)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.panel.color.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.secondaryInk.color.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }
        .buttonStyle(PressableStyle())
    }
}
