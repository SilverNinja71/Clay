import SwiftUI

/// The modelling workspace: the sketch sheet or 3D viewport, with Shapr3D-style floating chrome.
public struct WorkspaceView: View {
    @Bindable var state: WorkspaceState
    @Environment(StudioThemeStore.self) private var themes
    #if os(macOS)
    @State private var keys = KeyboardShortcutManager()
    #else
    @FocusState private var keyFocus: Bool
    #endif

    public init(state: WorkspaceState) { self.state = state }

    public var body: some View {
        let theme = themes.current
        ZStack {
            theme.canvas.color.ignoresSafeArea()
            stage(theme)
            chrome(theme)
        }
        .onAppear {
            state.theme = theme
            installKeyboard()
        }
        .onDisappear {
            #if os(macOS)
            keys.uninstall()
            #endif
        }
        .onChange(of: themes.current) { _, t in state.theme = t }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .sheet(isPresented: $state.exportPresented) { ExportSheet(state: state, theme: theme) }
        .sheet(isPresented: $state.coverEditorPresented) {
            CoverLibraryView(cover: state.document.cover, thumbnail: state.thumbnail(), title: state.document.name, theme: theme,
                             onSave: { state.saveCover($0) }, onCancel: { state.coverEditorPresented = false })
        }
        .sensoryFeedback(.impact(weight: .light), trigger: state.hapticTick)
        .sensoryFeedback(.success, trigger: state.successTick)
        #if os(iOS)
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let k = KeyStroke(press: press) else { return .ignored }
            return state.handleKey(k) ? .handled : .ignored
        }
        #endif
    }

    private func installKeyboard() {
        #if os(macOS)
        keys.handler = { [weak state] k in state?.handleKey(k) ?? false }
        keys.install()
        #else
        keyFocus = true
        #endif
    }

    // MARK: Stage

    @ViewBuilder private func stage(_ theme: StudioTheme) -> some View {
        if state.mode == .sketch {
            Group {
                if state.splitSketch {
                    HStack(spacing: 3) {
                        OrthoSketchCanvas(state: state, plane: .front, theme: theme)
                        OrthoSketchCanvas(state: state, plane: .side, theme: theme)
                    }
                    .background(theme.panelStroke.color)
                } else {
                    ZStack {
                        OrthoSketchCanvas(state: state, plane: state.activePlane, theme: theme)
                            .id(state.activePlane)
                            .transition(.asymmetric(insertion: .modifier(active: PlaneFlip(angle: -90), identity: PlaneFlip(angle: 0)),
                                                    removal: .modifier(active: PlaneFlip(angle: 90), identity: PlaneFlip(angle: 0))))
                    }
                    .animation(.spring(response: 0.6, dampingFraction: 0.86), value: state.activePlane)
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
        } else {
            ZStack {
                ClayViewportView(state: state)
                DimensionCalloutLayer(state: state, theme: theme)
                GizmoOverlayView(state: state, theme: theme)
                RadialMenuView(state: state, theme: theme)
            }
            .coordinateSpace(name: "viewport")
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    // MARK: Chrome

    private func chrome(_ theme: StudioTheme) -> some View {
        VStack(spacing: 0) {
            TopBar(state: state, theme: theme)
                .padding(.horizontal, 14).padding(.top, 10)
            HStack(alignment: .top, spacing: 12) {
                ToolPalette(state: state, theme: theme)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 12) {
                    if state.mode != .sketch { NavigationGizmoView(state: state, theme: theme) }
                    if state.showInspector {
                        InspectorPanel(state: state, theme: theme)
                            .frame(width: 272)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12)
            Spacer(minLength: 0)
            bottomArea(theme)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                if let t = state.tutorial {
                    InteractiveOnboardingView(state: state, tutorial: t, theme: theme)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let toast = state.toast {
                    ToastView(toast: toast, theme: theme)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .padding(.top, 70)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.toast)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.showInspector)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.mode)
    }

    private func bottomArea(_ theme: StudioTheme) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom) {
                StatusReadout(state: state, theme: theme)
                Spacer()
                if let id = state.editingCallout {
                    DimensionEditor(state: state, theme: theme, id: id)
                        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            if state.canGenerate {
                GenerateButton(state: state, theme: theme)
                    .transition(.scale.combined(with: .opacity))
            }
            if state.mode == .sculpt { HoldToSmoothButton(state: state, theme: theme) }
            TimelineBar(state: state, theme: theme)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.editingCallout)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: state.canGenerate)
    }
}

/// 90° page-turn used when switching between the front and side sketch planes.
struct PlaneFlip: ViewModifier {
    var angle: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .opacity(abs(angle) > 75 ? 0 : 1)
    }
}

struct ToastView: View {
    let toast: Toast
    let theme: StudioTheme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).foregroundStyle(theme.accent.color)
            Text(toast.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink.color)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .floatingPanel(theme, radius: 20)
        .allowsHitTesting(false)
    }
}
