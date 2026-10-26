import SwiftUI

/// Top level: the project library, or the open workspace. Starts the vase tutorial on first launch.
public struct ClayRootView: View {
    @State private var store: ProjectStore
    @State private var themes: StudioThemeStore
    @State private var workspace: WorkspaceState?

    public init(store: ProjectStore? = nil, themes: StudioThemeStore? = nil) {
        _store = State(initialValue: store ?? ProjectStore())
        _themes = State(initialValue: themes ?? StudioThemeStore())
    }

    public var body: some View {
        ZStack {
            if let ws = workspace {
                WorkspaceView(state: ws)
                    .id(ws.document.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
            } else {
                ProjectBrowserView(store: store, theme: themes.current,
                                   onOpen: { id in if let d = store.load(id) { open(d) } },
                                   onNew: { open(store.create(name: "Untitled model")) },
                                   onTutorial: startTutorial)
                    .transition(.opacity)
            }
        }
        .environment(themes)
        .preferredColorScheme(themes.current.isDark ? .dark : .light)
        .task {
            if workspace == nil && !TutorialEngine.hasCompletedOnboarding { startTutorial() }
        }
    }

    private func startTutorial() {
        var cover = ProjectCover()
        cover.material = .matteTerracotta
        cover.tint = CoverMaterial.matteTerracotta.defaultTint
        let doc = store.create(name: "Ceramic Vase", cover: cover)
        open(doc, tutorial: true)
    }

    private func open(_ doc: ClayDocument, tutorial: Bool = false) {
        let ws = WorkspaceState(document: doc)
        ws.theme = themes.current
        ws.onSave = { [store] d, img in store.save(d, thumbnail: img) }
        ws.onClose = { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { workspace = nil } }
        if tutorial {
            let t = TutorialEngine()
            ws.tutorial = t
            t.start(in: ws)
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { workspace = ws }
    }
}
