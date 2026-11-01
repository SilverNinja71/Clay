import Foundation
import Observation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Document model

public enum CoverMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    case glazedCeramic, matteTerracotta, industrialAluminum, blueprintCardstock, obsidianLeather
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .glazedCeramic: "Glazed Ceramic"
        case .matteTerracotta: "Matte Terracotta"
        case .industrialAluminum: "Industrial Aluminum"
        case .blueprintCardstock: "Blueprint Cardstock"
        case .obsidianLeather: "Obsidian Leather"
        }
    }
    public var defaultTint: RGBA {
        switch self {
        case .glazedCeramic: RGBA(hex: 0x6E9FB5)
        case .matteTerracotta: RGBA(hex: 0xC2643C)
        case .industrialAluminum: RGBA(hex: 0xA9AFB5)
        case .blueprintCardstock: RGBA(hex: 0x1E5390)
        case .obsidianLeather: RGBA(hex: 0x24211F)
        }
    }
}

public struct ProjectCover: Codable, Equatable, Sendable {
    public var material: CoverMaterial = .matteTerracotta
    public var tint: RGBA = CoverMaterial.matteTerracotta.defaultTint
    public var emblem: String? = "cup.and.saucer.fill"
    /// Hand-drawn doodle strokes in normalised cover coordinates (0…1).
    public var doodle: [[Vec2]] = []
    public var showThumbnail = true
    public init() {}
}

public struct ClayDocument: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
    public var cover: ProjectCover
    public var units: LengthUnit
    public var paper: PaperStyle
    public var timeline: Timeline
    public var camera: OrbitCamera?
    /// Body measurements at the last save, for the library overview.
    public var stats: ProjectStats?

    public init(name: String, cover: ProjectCover = ProjectCover()) {
        id = UUID(); self.name = name; created = Date(); modified = Date()
        self.cover = cover; units = .mm; paper = .grid; timeline = .starter()
    }
}

/// What the library shows about a project's 3D body.
public struct ProjectStats: Codable, Equatable, Sendable {
    public var size: Vec3
    public var triangles: Int
    public var volume: Float
    public var watertight: Bool
    public init(size: Vec3, triangles: Int, volume: Float, watertight: Bool) {
        self.size = size; self.triangles = triangles; self.volume = volume; self.watertight = watertight
    }
}

/// One timeline step, as shown in a project's overview.
public struct ProjectStepInfo: Codable, Equatable, Sendable {
    public var name: String
    public var symbol: String
}

public struct ProjectSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var modified: Date
    public var cover: ProjectCover
    public var featureCount: Int
    public var stats: ProjectStats?
    public var steps: [ProjectStepInfo]?
    public var units: LengthUnit?
    /// 2 = transparent-background thumbnail with stats filled in.
    public var overviewVersion: Int?

    public var isSculpted: Bool { steps?.contains { $0.symbol == FeatureKind.sculptSymbol } ?? false }
}

// MARK: - Store

/// Projects live as JSON documents (`<id>.clay`) with PNG thumbnails, plus a small index.
@MainActor @Observable
public final class ProjectStore {
    public private(set) var projects: [ProjectSummary] = []
    @ObservationIgnored public let root: URL
    @ObservationIgnored private var thumbnailCache: [UUID: CGImage] = [:]
    public private(set) var thumbnailRevision = 0

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            #if os(macOS)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clay", isDirectory: true)
            #else
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            #endif
            self.root = base.appendingPathComponent("Projects", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        loadIndex()
    }

    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private func docURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).clay") }
    private func thumbURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).png") }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([ProjectSummary].self, from: data) {
            projects = list.filter { FileManager.default.fileExists(atPath: docURL($0.id).path) }
        }
        projects.sort { $0.modified > $1.modified }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(projects) { try? data.write(to: indexURL, options: .atomic) }
    }

    public func load(_ id: UUID) -> ClayDocument? {
        guard let data = try? Data(contentsOf: docURL(id)) else { return nil }
        return try? JSONDecoder().decode(ClayDocument.self, from: data)
    }

    /// Saves the document. `touch: false` keeps the modified date (background upgrades).
    public func save(_ doc: ClayDocument, thumbnail: CGImage? = nil, touch: Bool = true) {
        var d = doc
        if touch { d.modified = Date() }
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: docURL(d.id), options: .atomic) }
        if let thumbnail { writeThumbnail(thumbnail, id: d.id) }
        let steps = d.timeline.features.filter { f in
            if case .sketch(let s) = f.kind { return !s.sketch.isEmpty }
            return true
        }.map { ProjectStepInfo(name: $0.name, symbol: $0.kind.symbol) }
        let summary = ProjectSummary(id: d.id, name: d.name, modified: d.modified, cover: d.cover, featureCount: d.timeline.features.count,
                                     stats: d.stats, steps: steps, units: d.units, overviewVersion: 2)
        if let i = projects.firstIndex(where: { $0.id == d.id }) { projects[i] = summary } else { projects.insert(summary, at: 0) }
        projects.sort { $0.modified > $1.modified }
        saveIndex()
    }

    /// Projects saved before the overview existed (no stats, opaque thumbnail).
    public var projectsNeedingOverview: [UUID] { projects.filter { ($0.overviewVersion ?? 0) < 2 }.map(\.id) }

    public func create(name: String, cover: ProjectCover = ProjectCover()) -> ClayDocument {
        let doc = ClayDocument(name: name, cover: cover)
        save(doc)
        return doc
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: docURL(id))
        try? FileManager.default.removeItem(at: thumbURL(id))
        projects.removeAll { $0.id == id }
        thumbnailCache[id] = nil
        saveIndex()
    }

    public func duplicate(_ id: UUID) {
        guard var doc = load(id) else { return }
        doc.id = UUID(); doc.name += " copy"; doc.created = Date()
        save(doc, thumbnail: thumbnail(id))
    }

    public func rename(_ id: UUID, to name: String) {
        guard var doc = load(id) else { return }
        doc.name = name
        save(doc)
    }

    public func updateCover(_ id: UUID, _ cover: ProjectCover) {
        guard var doc = load(id) else { return }
        doc.cover = cover
        save(doc)
    }

    public func thumbnail(_ id: UUID) -> CGImage? {
        if let t = thumbnailCache[id] { return t }
        guard let src = CGImageSourceCreateWithURL(thumbURL(id) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        thumbnailCache[id] = img
        return img
    }

    private func writeThumbnail(_ img: CGImage, id: UUID) {
        thumbnailCache[id] = img
        thumbnailRevision += 1
        guard let dest = CGImageDestinationCreateWithURL(thumbURL(id) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
