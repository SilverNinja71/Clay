import SwiftUI

/// The floating tutorial card: step progress, the prompt, and "Show me" / "Skip" controls.
public struct InteractiveOnboardingView: View {
    let state: WorkspaceState
    let tutorial: TutorialEngine
    let theme: StudioTheme

    public var body: some View {
        if tutorial.minimized {
            Button { withAnimation(.spring(response: 0.35)) { tutorial.minimized = false } } label: {
                Label("Tutorial · step \(tutorial.stepNumber) of \(tutorial.stepCount)", systemImage: "graduationcap.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(theme.onAccent.color)
                    .background(Capsule().fill(theme.accent.color))
            }
            .buttonStyle(PressableStyle())
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: tutorial.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.accent.color))
                VStack(alignment: .leading, spacing: 1) {
                    if tutorial.phase != .welcome && tutorial.phase != .done {
                        Text("STEP \(tutorial.stepNumber) OF \(tutorial.stepCount)")
                            .font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(theme.accent.color)
                    }
                    Text(tutorial.title).font(.system(size: 16, weight: .bold)).foregroundStyle(theme.ink.color)
                }
                Spacer()
                Button { withAnimation(.spring(response: 0.35)) { tutorial.minimized = true } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryInk.color).help("Minimise")
                Button { tutorial.finish(in: state) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryInk.color).help("End tutorial")
            }
            Text(tutorial.prompt)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = tutorial.hint {
                Label(hint, systemImage: "lightbulb").font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
            }
            HStack(spacing: 8) {
                progressDots
                Spacer()
                if tutorial.phase != .welcome && tutorial.phase != .done {
                    Button("Skip") { tutorial.skip(in: state) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.secondaryInk.color)
                }
                Button { tutorial.showMe(in: state) } label: {
                    Text(primaryTitle)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(theme.onAccent.color)
                        .background(Capsule().fill(theme.accent.color))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        .frame(width: 420)
        .floatingPanel(theme, radius: 18)
        .id(tutorial.phase)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private var primaryTitle: String {
        switch tutorial.phase {
        case .welcome: "Start"
        case .done: "Finish"
        default: "Show me"
        }
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(1...tutorial.stepCount, id: \.self) { i in
                Capsule()
                    .fill(i <= tutorial.stepNumber ? theme.accent.color : theme.panelStroke.color)
                    .frame(width: i == tutorial.stepNumber ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4), value: tutorial.stepNumber)
    }
}
