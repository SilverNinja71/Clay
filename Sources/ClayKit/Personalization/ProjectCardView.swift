import SwiftUI

/// A notebook-style project cover: procedural material, spine, elastic band, title plate,
/// emblem, hand-drawn doodle and a window showing the 3D thumbnail.
public struct CoverArtView: View {
    let cover: ProjectCover
    let title: String
    var subtitle: String?
    var thumbnail: CGImage?

    public init(cover: ProjectCover, title: String, subtitle: String? = nil, thumbnail: CGImage? = nil) {
        self.cover = cover; self.title = title; self.subtitle = subtitle; self.thumbnail = thumbnail
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let tint = cover.tint
            let dark = (tint.r * 0.3 + tint.g * 0.59 + tint.b * 0.11) < 0.5
            let ink: Color = dark ? .white.opacity(0.92) : Color(white: 0.12)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in CoverMaterialPainter.paint(&ctx, size: size, material: cover.material, tint: tint) }

                // Spine
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.11)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1).offset(x: w * 0.11)

                // Elastic band
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(5, w * 0.035))
                    .overlay(Rectangle().fill(.white.opacity(0.12)).frame(width: 1), alignment: .leading)
                    .offset(x: w * 0.84)

                if cover.showThumbnail, let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: w * 0.58, height: w * 0.58)
                        .background(Color.white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: w * 0.05, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: w * 0.05, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .position(x: w * 0.52, y: h * 0.38)
                } else if let emblem = cover.emblem {
                    Image(systemName: emblem)
                        .font(.system(size: w * 0.22, weight: .regular))
                        .foregroundStyle(ink.opacity(0.85))
                        .position(x: w * 0.52, y: h * 0.38)
                }

                if !cover.doodle.isEmpty {
                    Canvas { ctx, size in
                        for stroke in cover.doodle where stroke.count > 1 {
                            var p = Path()
                            p.addLines(stroke.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) })
                            ctx.stroke(p, with: .color(ink.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.5, size.width * 0.012), lineCap: .round, lineJoin: .round))
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Title plate
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: max(11, w * 0.075), weight: .bold, design: .serif))
                        .lineLimit(2)
                        .minimumScaleFactor(0.55)
                    if let subtitle {
                        Text(subtitle).font(.system(size: max(8, w * 0.045), weight: .medium)).opacity(0.75)
                    }
                }
                .foregroundStyle(ink)
                .padding(.horizontal, w * 0.06).padding(.vertical, w * 0.035)
                .background(RoundedRectangle(cornerRadius: 6).fill((dark ? Color.black : Color.white).opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.25), lineWidth: 1))
                .frame(width: w * 0.68, alignment: .leading)
                .position(x: w * 0.52, y: h * 0.8)

                if cover.showThumbnail, thumbnail != nil, let emblem = cover.emblem {
                    Image(systemName: emblem)
                        .font(.system(size: w * 0.07, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.8))
                        .position(x: w * 0.72, y: h * 0.065 + w * 0.04)
                }
            }
        }
        .aspectRatio(0.76, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 1))
    }
}

/// Procedural cover textures (no image assets needed).
enum CoverMaterialPainter {
    static func paint(_ ctx: inout GraphicsContext, size: CGSize, material: CoverMaterial, tint: RGBA) {
        let rect = CGRect(origin: .zero, size: size)
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(material.rawValue.hashValue & 0xFFFF)
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        let base = tint.color
        switch material {
        case .glazedCeramic:
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [tint.mix(RGBA(1, 1, 1), 0.35).color, base, tint.mix(RGBA(0, 0, 0), 0.25).color]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            // Crackle glaze.
            var crackle = Path()
            for _ in 0..<26 {
                var p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                crackle.move(to: p)
                for _ in 0..<5 {
                    p = CGPoint(x: p.x + (rnd() - 0.5) * size.width * 0.22, y: p.y + (rnd() - 0.5) * size.height * 0.16)
                    crackle.addLine(to: p)
                }
            }
            ctx.stroke(crackle, with: .color(.white.opacity(0.18)), lineWidth: 0.7)
            ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.15, y: -size.height * 0.15, width: size.width * 0.9, height: size.height * 0.45)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]), center: CGPoint(x: size.width * 0.6, y: size.height * 0.05),
                                           startRadius: 0, endRadius: size.width * 0.5))
        case .matteTerracotta:
            ctx.fill(Path(rect), with: .color(base))
            var grain = Path()
            for _ in 0..<Int(size.width * size.height / 40) {
                let r = rnd() * 1.4 + 0.3
                grain.addEllipse(in: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: r, height: r))
            }
            ctx.fill(grain, with: .color(.black.opacity(0.13)))
            var light = Path()
            for _ in 0..<Int(size.width * size.height / 90) {
                light.addRect(CGRect(x: rnd() * size.width, y: rnd() * size.height, width: 1, height: 1))
            }
            ctx.fill(light, with: .color(.white.opacity(0.16)))
        case .industrialAluminum:
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [tint.mix(RGBA(1, 1, 1), 0.3).color, base, tint.mix(RGBA(1, 1, 1), 0.15).color, tint.mix(RGBA(0, 0, 0), 0.15).color]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            var brushed = Path()
            var y: CGFloat = 0
            while y < size.height {
                brushed.move(to: CGPoint(x: 0, y: y)); brushed.addLine(to: CGPoint(x: size.width, y: y + (rnd() - 0.5) * 2))
                y += 1.2 + rnd() * 1.4
            }
            ctx.stroke(brushed, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            for (x, yy) in [(0.18, 0.05), (0.92, 0.05), (0.18, 0.95), (0.92, 0.95)] {
                let c = CGPoint(x: size.width * x, y: size.height * yy)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.black.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2.5, width: 3, height: 3)), with: .color(.white.opacity(0.5)))
            }
        case .blueprintCardstock:
            ctx.fill(Path(rect), with: .color(base))
            var minor = Path(), major = Path()
            func line(_ isMajor: Bool, _ a: CGPoint, _ b: CGPoint) {
                if isMajor { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
            }
            let step = size.width / 24
            for i in 0...Int(size.width / step) {
                let x = CGFloat(i) * step
                line(i % 5 == 0, CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height))
            }
            for i in 0...Int(size.height / step) {
                let y = CGFloat(i) * step
                line(i % 5 == 0, CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y))
            }
            ctx.stroke(minor, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            ctx.stroke(major, with: .color(.white.opacity(0.28)), lineWidth: 0.8)
            ctx.stroke(Path(rect.insetBy(dx: 8, dy: 8)), with: .color(.white.opacity(0.4)), lineWidth: 1)
        case .obsidianLeather:
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [tint.mix(RGBA(1, 1, 1), 0.08).color, base, tint.mix(RGBA(0, 0, 0), 0.3).color]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width * 0.4, y: size.height)))
            var pebbles = Path()
            for _ in 0..<Int(size.width * size.height / 26) {
                let r = rnd() * 2.4 + 0.8
                pebbles.addEllipse(in: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: r * 1.3, height: r))
            }
            ctx.stroke(pebbles, with: .color(.white.opacity(0.05)), lineWidth: 0.6)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 7, dy: 7), cornerRadius: 8), with: .color(.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1.1, dash: [4, 3]))
        }
    }
}

/// Library grid card: the cover plus name and date, with a gentle lift on hover/press.
public struct ProjectCardView: View {
    let summary: ProjectSummary
    let thumbnail: CGImage?
    let theme: StudioTheme
    @State private var hovering = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtView(cover: summary.cover, title: summary.name, subtitle: "\(summary.featureCount) steps", thumbnail: thumbnail)
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 16 : 8, y: hovering ? 10 : 4)
                .rotation3DEffect(.degrees(hovering ? -6 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.6)
                .scaleEffect(hovering ? 1.03 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink.color).lineLimit(1)
                Text(summary.modified.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
            }
        }
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hovering = h } }
    }
}
