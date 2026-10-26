import Foundation
import ModelIO
import simd

/// Writes Clay geometry to interchange formats. Model space is millimetres, Y up.
public enum MeshExporter {

    /// Y-up → Z-up (what CAD tools and slicers expect), keeping right-handedness.
    static func zUp(_ p: Vec3) -> Vec3 { Vec3(p.x, -p.z, p.y) }

    // MARK: OBJ

    public static func obj(_ m: ClayMesh, name: String) -> Data {
        var s = "# Clay — \(name)\n# units: millimetres, Y up\no \(name.replacingOccurrences(of: " ", with: "_"))\n"
        s.reserveCapacity(m.vertexCount * 70 + m.triangleCount * 40)
        for p in m.positions { s += String(format: "v %.4f %.4f %.4f\n", p.x, p.y, p.z) }
        for n in m.normals { s += String(format: "vn %.4f %.4f %.4f\n", n.x, n.y, n.z) }
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = m.indices[t] + 1, b = m.indices[t + 1] + 1, c = m.indices[t + 2] + 1
            s += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
        }
        return Data(s.utf8)
    }

    // MARK: STL (binary)

    public static func stl(_ m: ClayMesh, name: String) -> Data {
        var d = Data(capacity: 84 + m.triangleCount * 50)
        var header = Array("Clay \(name) (mm, Z up)".utf8.prefix(80))
        header += [UInt8](repeating: 0, count: 80 - header.count)
        d.append(contentsOf: header)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(m.triangleCount).littleEndian)
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = zUp(m.positions[Int(m.indices[t])]), b = zUp(m.positions[Int(m.indices[t + 1])]), c = zUp(m.positions[Int(m.indices[t + 2])])
            let n = simd_cross(b - a, c - a).safeNormalized
            for v in [n, a, b, c] { put(v.x.bitPattern.littleEndian); put(v.y.bitPattern.littleEndian); put(v.z.bitPattern.littleEndian) }
            put(UInt16(0))
        }
        return d
    }

    // MARK: USDZ (Model I/O)

    /// Returns the file data and its extension. Model I/O writes binary USD (usdc); it is then
    /// wrapped into a .usdz package, which is all AR Quick Look needs.
    public static func usd(_ m: ClayMesh, name: String, color: Vec4) throws -> (Data, String) {
        if MDLAsset.canExportFileExtension("usdz") { return (try modelIOExport(m, name: name, color: color, ext: "usdz"), "usdz") }
        let ext = MDLAsset.canExportFileExtension("usdc") ? "usdc" : "usda"
        let data = try modelIOExport(m, name: name, color: color, ext: ext)
        return (USDZPackager.package(data, fileName: "\(name.replacingOccurrences(of: " ", with: "_")).\(ext)"), "usdz")
    }

    static func modelIOExport(_ m: ClayMesh, name: String, color: Vec4, ext: String) throws -> Data {
        let allocator = MDLMeshBufferDataAllocator()
        var interleaved: [Float] = []
        interleaved.reserveCapacity(m.vertexCount * 6)
        for i in 0..<m.vertexCount {
            let p = m.positions[i] * 0.001, n = m.normals[i]   // metres, so AR Quick Look shows real size
            interleaved += [p.x, p.y, p.z, n.x, n.y, n.z]
        }
        let vb = allocator.newBuffer(with: interleaved.withUnsafeBufferPointer { Data(buffer: $0) }, type: .vertex)
        let ib = allocator.newBuffer(with: m.indices.withUnsafeBufferPointer { Data(buffer: $0) }, type: .index)
        let material = MDLMaterial(name: "Clay", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: Vec3(color.x, color.y, color.z)))
        material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.65))
        let sub = MDLSubmesh(indexBuffer: ib, indexCount: m.indices.count, indexType: .uInt32, geometryType: .triangles, material: material)
        let desc = MDLVertexDescriptor()
        desc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        desc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        desc.layouts[0] = MDLVertexBufferLayout(stride: 24)
        let mesh = MDLMesh(vertexBuffer: vb, vertexCount: m.vertexCount, descriptor: desc, submeshes: [sub])
        mesh.name = name
        let asset = MDLAsset()
        asset.add(mesh)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clay-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try asset.export(to: url)
        return try Data(contentsOf: url)
    }

    // MARK: STEP (faceted B-rep, AP214)

    /// A faceted boundary representation: every triangle becomes a planar STEP face. CAD apps
    /// (Fusion, FreeCAD, Onshape) import it as a solid made of flat facets — not as NURBS.
    public static func step(_ m: ClayMesh, name: String) -> Data {
        var lines: [String] = []
        var id = 0
        func add(_ s: String) -> Int { id += 1; lines.append("#\(id)=\(s);"); return id }
        let safe = name.replacingOccurrences(of: "'", with: "")
        let ctx = add("APPLICATION_CONTEXT('automotive design')")
        _ = add("APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#\(ctx))")
        let pctx = add("PRODUCT_CONTEXT('',#\(ctx),'mechanical')")
        let product = add("PRODUCT('\(safe)','\(safe)','',(#\(pctx)))")
        let form = add("PRODUCT_DEFINITION_FORMATION('','',#\(product))")
        let dctx = add("PRODUCT_DEFINITION_CONTEXT('part definition',#\(ctx),'design')")
        let pdef = add("PRODUCT_DEFINITION('design','',#\(form),#\(dctx))")
        let shapeDef = add("PRODUCT_DEFINITION_SHAPE('','',#\(pdef))")
        let lenUnit = add("(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.))")
        let angUnit = add("(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.))")
        let solUnit = add("(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.)SOLID_ANGLE_UNIT())")
        let unc = add("UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-05),#\(lenUnit),'distance_accuracy_value','')")
        let gctx = add("(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#\(unc)))GLOBAL_UNIT_ASSIGNED_CONTEXT((#\(lenUnit),#\(angUnit),#\(solUnit)))REPRESENTATION_CONTEXT('',''))")
        let origin = add("CARTESIAN_POINT('',(0.,0.,0.))")
        let axis = add("AXIS2_PLACEMENT_3D('',#\(origin),$,$)")
        var pointIDs: [Int] = []
        pointIDs.reserveCapacity(m.vertexCount)
        for p in m.positions {
            let q = zUp(p)
            pointIDs.append(add(String(format: "CARTESIAN_POINT('',(%.4f,%.4f,%.4f))", q.x, q.y, q.z)))
        }
        var faces: [Int] = []
        faces.reserveCapacity(m.triangleCount)
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = pointIDs[Int(m.indices[t])], b = pointIDs[Int(m.indices[t + 1])], c = pointIDs[Int(m.indices[t + 2])]
            let loop = add("POLY_LOOP('',(#\(a),#\(b),#\(c)))")
            let bound = add("FACE_OUTER_BOUND('',#\(loop),.T.)")
            faces.append(add("FACE('',(#\(bound)))"))
        }
        let shell = add("CLOSED_SHELL('',(" + faces.map { "#\($0)" }.joined(separator: ",") + "))")
        let brep = add("FACETED_BREP('\(safe)',#\(shell))")
        let rep = add("FACETED_BREP_SHAPE_REPRESENTATION('',(#\(axis),#\(brep)),#\(gctx))")
        _ = add("SHAPE_DEFINITION_REPRESENTATION(#\(shapeDef),#\(rep))")
        _ = add("PRODUCT_RELATED_PRODUCT_CATEGORY('part',$,(#\(product)))")

        let stamp = ISO8601DateFormatter().string(from: Date())
        var out = """
        ISO-10303-21;
        HEADER;
        FILE_DESCRIPTION(('Clay faceted solid'),'2;1');
        FILE_NAME('\(safe).step','\(stamp)',('Clay'),(''),'Clay','Clay','');
        FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));
        ENDSEC;
        DATA;

        """
        out += lines.joined(separator: "\n")
        out += "\nENDSEC;\nEND-ISO-10303-21;\n"
        return Data(out.utf8)
    }

    // MARK: Clean vector SVG

    /// Just the sketch curves as exact cubic Bézier paths, 1:1 in millimetres — no paper, labels
    /// or dimensions. Each plane is its own group, laid out left to right on a shared baseline.
    public static func vectorSVG(_ sketches: [(SketchPlane, Sketch)], name: String) -> Data? {
        let used = sketches.filter { !$0.1.isEmpty && $0.1.bounds != nil }
        guard !used.isEmpty else { return nil }
        let margin: Float = 2, gap: Float = 20
        let top = used.map { $0.1.bounds!.max.y }.max()!
        let bottom = used.map { $0.1.bounds!.min.y }.min()!
        var x = margin
        var groups: [String] = []
        for (plane, sketch) in used {
            let b = sketch.bounds!
            let dx = x - b.min.x
            func pt(_ p: Vec2) -> String { String(format: "%.3f %.3f", p.x + dx, top - p.y + margin) }
            var paths: [String] = []
            for path in sketch.paths {
                guard let first = path.anchors.first else { continue }
                var d = "M\(pt(first.position))"
                for seg in path.segments { d += " C\(pt(seg.p1)) \(pt(seg.p2)) \(pt(seg.p3))" }
                if path.closed { d += " Z" }
                paths.append("    <path d=\"\(d)\"/>")
            }
            groups.append("  <g id=\"\(plane.rawValue)\">\n\(paths.joined(separator: "\n"))\n  </g>")
            x += (b.max.x - b.min.x) + gap
        }
        let w = x - gap + margin, h = top - bottom + margin * 2
        let title = name.replacingOccurrences(of: "&", with: "and").replacingOccurrences(of: "<", with: "")
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(String(format: "%.2f", w))mm" height="\(String(format: "%.2f", h))mm" viewBox="0 0 \(String(format: "%.3f", w)) \(String(format: "%.3f", h))">
        <title>\(title)</title>
        <g fill="none" stroke="#000000" stroke-width="0.35" stroke-linecap="round" stroke-linejoin="round">
        \(groups.joined(separator: "\n"))
        </g>
        </svg>
        """
        return Data(svg.utf8)
    }

    // MARK: SVG drawing sheet

    /// Front and side elevations side by side, at 1:1 in millimetres, with key dimensions.
    public static func drawingSheet(front: Sketch, side: Sketch?, name: String, units: LengthUnit) -> Data {
        let margin: Float = 20, gap: Float = 30
        let fb = front.bounds ?? (Vec2(-40, 0), Vec2(40, 100))
        let sb = side?.bounds ?? fb
        let height = max(fb.max.y, sb.max.y) - min(fb.min.y, sb.min.y)
        let baseY = min(fb.min.y, sb.min.y)
        let fw = fb.max.x - fb.min.x, sw = sb.max.x - sb.min.x
        let W = margin * 2 + fw + gap + sw + 40, H = margin * 2 + height + 50
        func path(_ s: SketchPath, dx: Float) -> String {
            guard let first = s.anchors.first else { return "" }
            func pt(_ p: Vec2) -> String { String(format: "%.3f,%.3f", p.x + dx, margin + 20 + (height - (p.y - baseY))) }
            var d = "M\(pt(first.position))"
            for seg in s.segments { d += " C\(pt(seg.p1)) \(pt(seg.p2)) \(pt(seg.p3))" }
            if s.closed { d += " Z" }
            return "<path d=\"\(d)\" fill=\"none\" stroke=\"#2B2420\" stroke-width=\"0.5\"/>"
        }
        let fdx = margin - fb.min.x, sdx = margin + fw + gap - sb.min.x
        var body = ""
        body += front.paths.map { path($0, dx: fdx) }.joined(separator: "\n")
        body += side.map { $0.paths.map { path($0, dx: sdx) }.joined(separator: "\n") } ?? ""
        let groundY = margin + 20 + height
        func label(_ x: Float, _ y: Float, _ t: String) -> String {
            String(format: "<text x=\"%.2f\" y=\"%.2f\" font-family=\"Helvetica\" font-size=\"3.5\" text-anchor=\"middle\" fill=\"#C2643C\">%@</text>", x, y, t)
        }
        body += String(format: "<line x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" stroke=\"#999\" stroke-width=\"0.25\"/>", margin - 5, groundY, W - margin + 5, groundY)
        body += label(margin + fw / 2, groundY + 9, "FRONT  ·  width \(units.format(fw))")
        if side != nil { body += label(margin + fw + gap + sw / 2, groundY + 9, "SIDE  ·  depth \(units.format(sw))") }
        body += label(W - 22, margin + 20 + height / 2, "H \(units.format(height))")
        body += label(W / 2, H - 6, "\(name) — Clay drawing sheet, 1:1")
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(W))mm" height="\(Int(H))mm" viewBox="0 0 \(W) \(H)">
        <rect width="100%" height="100%" fill="#F7F2E8"/>
        \(body)
        </svg>
        """
        return Data(svg.utf8)
    }
}

// MARK: - USDZ packaging

/// A .usdz file is an uncompressed zip whose file data starts on 64-byte boundaries.
enum USDZPackager {
    static func package(_ data: Data, fileName: String) -> Data {
        let name = Array(fileName.utf8)
        let crc = crc32(data)
        // Pad the local header's extra field so the file data is 64-byte aligned.
        let pad = (64 - (30 + name.count + 4) % 64) % 64
        let extra: [UInt8] = [0x86, 0x19] + le16(UInt16(pad)) + [UInt8](repeating: 0, count: pad)

        var out = Data()
        out += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21)
        out += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
        out += le16(UInt16(name.count)) + le16(UInt16(extra.count))
        out += name + extra
        out += data
        let cdOffset = UInt32(out.count)
        var cd = Data()
        cd += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21)
        cd += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
        cd += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0)
        cd += name
        out += cd
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(1) + le16(1)
        out += le32(UInt32(cd.count)) + le32(cdOffset) + le16(0)
        return out
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for b in raw { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private func + (lhs: Data, rhs: [UInt8]) -> Data { var d = lhs; d.append(contentsOf: rhs); return d }
private func += (lhs: inout Data, rhs: [UInt8]) { lhs.append(contentsOf: rhs) }
