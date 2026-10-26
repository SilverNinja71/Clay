import SwiftUI
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case stl, obj, usdz, step, vector, svg, clay
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .stl: "STL"
        case .obj: "OBJ"
        case .usdz: "USDZ"
        case .step: "STEP"
        case .vector: "Vector curves (SVG)"
        case .svg: "Drawing sheet (SVG)"
        case .clay: "Clay project"
        }
    }
    public var detail: String {
        switch self {
        case .stl: "3D printing and slicers. Binary, millimetres, Z up."
        case .obj: "Blender, Maya, game engines. Positions and normals."
        case .usdz: "AR Quick Look, Reality Composer, Keynote. Real-world scale."
        case .step: "Fusion, SolidWorks, FreeCAD — as a faceted solid (flat triangles, not NURBS)."
        case .vector: "Only your sketch curves as clean Bézier paths at real size — for Illustrator, Inkscape, Figma, Cricut or a laser cutter."
        case .svg: "Front and side elevations at 1:1 with dimensions — a Parchment-style sketch sheet."
        case .clay: "The full editable project: sketches, timeline, sculpt layers."
        }
    }
    public var symbol: String {
        switch self {
        case .stl: "printer"
        case .obj: "cube"
        case .usdz: "arkit"
        case .step: "gearshape.2"
        case .vector: "scribble.variable"
        case .svg: "doc.richtext"
        case .clay: "shippingbox"
        }
    }
    var needsMesh: Bool { self != .svg && self != .vector && self != .clay }
    var fileExtension: String { self == .vector || self == .svg ? "svg" : rawValue }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Export picker: choose a format, then the system save dialog / Files picker.
struct ExportSheet: View {
    let state: WorkspaceState
    let theme: StudioTheme
    @Environment(\.dismiss) private var dismiss
    @State private var file: ExportFile?
    @State private var type: UTType = .data
    @State private var filename = "Clay"
    @State private var presenting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export “\(state.document.name)”").font(.title3.bold())
                    Text(state.stats.triangles > 0 ? "\(state.stats.triangles.formatted()) triangles · \(state.stats.watertight ? "watertight" : "not watertight")" : "No 3D body yet — sketches only")
                        .font(.caption).foregroundStyle(theme.secondaryInk.color)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            ForEach(ExportFormat.allCases) { f in
                let disabled = f.needsMesh && state.mesh == nil
                Button { export(f) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: f.symbol).font(.system(size: 18)).frame(width: 30).foregroundStyle(theme.accent.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.system(size: 14, weight: .semibold))
                            Text(f.detail).font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(theme.secondaryInk.color)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.canvas.color.opacity(0.5)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(width: 460)
        .foregroundStyle(theme.ink.color)
        .background(theme.panel.color)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .fileExporter(isPresented: $presenting, document: file, contentType: type, defaultFilename: filename) { result in
            if case .failure(let e) = result { error = e.localizedDescription } else { dismiss() }
        }
    }

    private func export(_ f: ExportFormat) {
        let name = state.document.name.isEmpty ? "Clay" : state.document.name
        error = nil
        do {
            var data = Data()
            var ext = f.fileExtension
            switch f {
            case .stl: data = MeshExporter.stl(state.mesh!, name: name)
            case .obj: data = MeshExporter.obj(state.mesh!, name: name)
            case .usdz: (data, ext) = try MeshExporter.usd(state.mesh!, name: name, color: theme.clay.linear)
            case .step: data = MeshExporter.step(state.mesh!, name: name)
            case .vector:
                let planes: [(SketchPlane, Sketch)] = [SketchPlane.front, .side].compactMap { p in state.timeline.sketch(p).map { (p, $0) } }
                guard let svg = MeshExporter.vectorSVG(planes, name: name) else { error = "Draw something in Sketch mode first."; return }
                data = svg
            case .svg:
                guard let front = state.timeline.sketch(.front), !front.isEmpty else { error = "Draw a front sketch first."; return }
                data = MeshExporter.drawingSheet(front: front, side: state.timeline.sketch(.side).flatMap { $0.isEmpty ? nil : $0 }, name: name, units: state.units)
            case .clay:
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted]
                data = try enc.encode(state.document)
            }
            type = UTType(filenameExtension: ext) ?? .data
            filename = "\(name).\(ext)"
            file = ExportFile(data: data)
            presenting = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
