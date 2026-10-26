import SwiftUI
import simd

/// Cover studio: pick a material, a colour, an emblem, and doodle on the cover by hand.
public struct CoverLibraryView: View {
    @State private var cover: ProjectCover
    let thumbnail: CGImage?
    let title: String
    let theme: StudioTheme
    let onSave: (ProjectCover) -> Void
    let onCancel: () -> Void
    @State private var currentStroke: [Vec2] = []

    public init(cover: ProjectCover, thumbnail: CGImage?, title: String, theme: StudioTheme,
                onSave: @escaping (ProjectCover) -> Void, onCancel: @escaping () -> Void) {
        _cover = State(initialValue: cover)
        self.thumbnail = thumbnail; self.title = title; self.theme = theme; self.onSave = onSave; self.onCancel = onCancel
    }

    static let swatches: [RGBA] = [
        RGBA(hex: 0xC2643C), RGBA(hex: 0x6E9FB5), RGBA(hex: 0x1E5390), RGBA(hex: 0x24211F), RGBA(hex: 0xA9AFB5),
        RGBA(hex: 0x7A8F5A), RGBA(hex: 0xE3B23C), RGBA(hex: 0xB04A5A), RGBA(hex: 0xEDE6DA), RGBA(hex: 0x5B4B8A),
    ]
    static let emblems = ["cup.and.saucer.fill", "leaf.fill", "star.fill", "hammer.fill", "wrench.and.screwdriver.fill", "cube.fill",
                          "flame.fill", "drop.fill", "moon.stars.fill", "gearshape.fill", "paintbrush.pointed.fill", "sparkles"]

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 12) {
                    CoverArtView(cover: cover, title: title, subtitle: "Clay model", thumbnail: thumbnail)
                        .frame(width: 230, height: 230 / 0.76)
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                        .overlay(doodlePad)
                    HStack {
                        Label("Draw on the cover", systemImage: "scribble").font(.caption).foregroundStyle(theme.secondaryInk.color)
                        Spacer()
                        Button("Clear doodle") { cover.doodle = [] }.font(.caption).disabled(cover.doodle.isEmpty)
                    }
                    .frame(width: 230)
                }
                VStack(alignment: .leading, spacing: 16) {
                    group("Cover library") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                            ForEach(CoverMaterial.allCases) { m in
                                Button {
                                    withAnimation(.spring(response: 0.3)) { cover.material = m; cover.tint = m.defaultTint }
                                } label: {
                                    VStack(spacing: 4) {
                                        Canvas { ctx, size in CoverMaterialPainter.paint(&ctx, size: size, material: m, tint: m.defaultTint) }
                                            .frame(height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cover.material == m ? theme.accent.color : .clear, lineWidth: 2.5))
                                        Text(m.title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }
                    group("Colour") {
                        HStack(spacing: 8) {
                            ForEach(Self.swatches, id: \.self) { s in
                                Button { withAnimation { cover.tint = s } } label: {
                                    Circle().fill(s.color).frame(width: 24, height: 24)
                                        .overlay(Circle().strokeBorder(cover.tint == s ? theme.accent.color : .black.opacity(0.15), lineWidth: cover.tint == s ? 3 : 1))
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }
                    group("Emblem") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                            Button { cover.emblem = nil } label: {
                                Image(systemName: "nosign").frame(width: 32, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(cover.emblem == nil ? theme.accent.color.opacity(0.25) : .clear))
                            }.buttonStyle(.plain)
                            ForEach(Self.emblems, id: \.self) { e in
                                Button { cover.emblem = e } label: {
                                    Image(systemName: e).frame(width: 32, height: 32)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(cover.emblem == e ? theme.accent.color.opacity(0.25) : .clear))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Toggle("Show 3D thumbnail", isOn: $cover.showThumbnail)
                }
                .frame(width: 330)
            }
            .padding(22)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save cover") { onSave(cover) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent.color)
            }
            .padding(16)
        }
        .foregroundStyle(theme.ink.color)
        .background(theme.panel.color)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private var doodlePad: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard currentStroke.count > 1 else { return }
                var p = Path()
                p.addLines(currentStroke.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) })
                ctx.stroke(p, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let n = Vec2(Float(g.location.x / geo.size.width), Float(g.location.y / geo.size.height))
                currentStroke.append(simd_clamp(n, Vec2(0, 0), Vec2(1, 1)))
            }.onEnded { _ in
                if currentStroke.count > 1 { cover.doodle.append(currentStroke) }
                currentStroke = []
            })
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(theme.secondaryInk.color)
            content()
        }
    }
}
