import CoreGraphics

/// Clay's logo, in the same style as Parchment's: a terracotta squircle with a tilted
/// sheet of paper, sketched with a ceramic vase (front and side profile, rim, base and a
/// dashed cross-contour showing the 3D loft).
public enum ClayLogo {
    /// Draws the logo filling `rect`. Expects a top-left-origin context (y grows downward),
    /// like a flipped Core Graphics or UIKit context.
    public static func draw(in rect: CGRect, context: CGContext) {
        let side = min(rect.width, rect.height)
        let scale = side / 1024.0
        context.saveGState()
        context.translateBy(x: rect.midX - side / 2, y: rect.midY - side / 2)
        context.scaleBy(x: scale, y: scale)

        // 1. Signature Parchment terracotta squircle base
        let baseRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        context.addPath(CGPath(roundedRect: baseRect, cornerWidth: 230, cornerHeight: 230, transform: nil))
        context.setFillColor(CGColor(red: 0.55, green: 0.29, blue: 0.18, alpha: 1.0)) // #8B4A2E
        context.fillPath()

        // 2. Tilted parchment sheet (tilted -0.10 rad like Parchment)
        context.saveGState()
        context.translateBy(x: 512, y: 530)
        context.rotate(by: -0.10)

        let paperRect = CGRect(x: -300, y: -370, width: 600, height: 740)
        // Soft shadow under the paper
        context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
        context.addPath(CGPath(roundedRect: paperRect, cornerWidth: 36, cornerHeight: 36, transform: nil))
        context.setFillColor(CGColor(red: 0.99, green: 0.98, blue: 0.96, alpha: 1.0)) // Warm parchment white
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil) // reset shadow

        // 3. Faint blueprint / paper lines
        context.setStrokeColor(CGColor(red: 0.77, green: 0.67, blue: 0.51, alpha: 0.45))
        context.setLineWidth(3)
        for line in -4...4 {
            let y = CGFloat(line) * 70
            context.move(to: CGPoint(x: -240, y: y))
            context.addLine(to: CGPoint(x: 240, y: y))
        }
        context.strokePath()

        // 4. Ceramic vase silhouette (2D sketch + 3D cross-contour)
        context.setStrokeColor(CGColor(red: 0.23, green: 0.13, blue: 0.09, alpha: 1.0)) // Deep ink brown
        context.setLineWidth(22)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Left profile of the vase
        context.move(to: CGPoint(x: -60, y: -190)) // Rim
        context.addCurve(to: CGPoint(x: -40, y: -90), control1: CGPoint(x: -55, y: -150), control2: CGPoint(x: -35, y: -120)) // Neck
        context.addCurve(to: CGPoint(x: -150, y: 80), control1: CGPoint(x: -45, y: -40), control2: CGPoint(x: -150, y: 0)) // Belly
        context.addCurve(to: CGPoint(x: -60, y: 220), control1: CGPoint(x: -150, y: 160), control2: CGPoint(x: -100, y: 220)) // Base

        // Right profile of the vase
        context.move(to: CGPoint(x: 60, y: -190))
        context.addCurve(to: CGPoint(x: 40, y: -90), control1: CGPoint(x: 55, y: -150), control2: CGPoint(x: 35, y: -120))
        context.addCurve(to: CGPoint(x: 150, y: 80), control1: CGPoint(x: 45, y: -40), control2: CGPoint(x: 150, y: 0))
        context.addCurve(to: CGPoint(x: 60, y: 220), control1: CGPoint(x: 150, y: 160), control2: CGPoint(x: 100, y: 220))
        context.strokePath()

        // Rim ellipse (top)
        context.setLineWidth(14)
        context.strokeEllipse(in: CGRect(x: -60, y: -205, width: 120, height: 30))

        // Base ellipse (bottom)
        context.strokeEllipse(in: CGRect(x: -60, y: 205, width: 120, height: 30))

        // 3D cross-loft contour ring (middle waist showing the 3D loft)
        context.setLineWidth(10)
        context.setLineDash(phase: 0, lengths: [14, 10])
        context.setStrokeColor(CGColor(red: 0.85, green: 0.45, blue: 0.25, alpha: 0.85)) // Clay terracotta accent
        context.strokeEllipse(in: CGRect(x: -150, y: 65, width: 300, height: 42))

        context.restoreGState() // Exit tilted paper
        context.restoreGState() // Exit main canvas
    }
}
