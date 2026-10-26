import ClayKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

func save(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
let mesh = try LoftEngine.loft(front: VaseGuide.frontSketch, side: VaseGuide.sideSketch, parameters: LoftParameters(frontSketch: UUID(), sideSketch: UUID()))
var scene = RenderScene()
scene.mesh = mesh
scene.camera = OrbitCamera().framing(mesh.bounds)
scene.curves = [CurveStroke(points: VaseGuide.silhouette().polyline().map { SketchPlane.front.worldPoint($0) }, color: Vec4(0.95, 0.5, 0.2, 1), width: 3, closed: true)]
guard let r = ClayRenderer() else { fatalError("no metal") }
let t0 = Date()
let img = r.renderImage(scene, width: 1000, height: 750)!
print("rendered in", Date().timeIntervalSince(t0))
save(img, out + "/vase.png")
