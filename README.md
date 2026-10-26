# Clay
Clay is an intuitive 2D-to-3D modeling, CAD, and digital sculpting studio for iPad &amp; Mac.

**Sketch in 2D, form in 3D, sculpt like clay, measure with precision.**
Draw a front silhouette and a side silhouette, loft them into a watertight 3D body, sculpt it with
Blender-style brushes, then drive exact dimensions Fusion-style through a non-destructive timeline.
The original brief is in [`docs/SPEC.md`](docs/SPEC.md); notes for continuing the work are in [`CLAUDE.md`](CLAUDE.md).

## Run it on a Mac (macOS 14+)

Needs Swift 5.10+ — Xcode, or just the Command Line Tools (`xcode-select --install`).

```bash
Scripts/build-app.sh      # builds Clay.app in this folder
open Clay.app
```

Or run straight from the package with `swift run Clay`. The first launch opens the
**Ceramic Vase** tutorial; after that you land in the project library.

## What's in it

| Area | What you get |
|---|---|
| **Sketch** (Parchment) | Grid / ruled / dotted / blank paper sheets for the front and side planes, split view, 90° page-turn between planes. Pencil strokes become clean Bézier curves (corners kept), auto-close, snap to the centre axis and join open ends. Illustrator-style pen tool (click for corners, drag for curves, ⌥-drag to break a handle, click the first point to close). Line, circle, rectangle, point editing, eraser. Guides (base, top, widest, waist, feature marks) carried across from the other view. |
| **Constraints** (Fusion) | Distance, horizontal/vertical distance, horizontal, vertical, parallel, perpendicular, angle, equal, coincident, fix, radius, concentric, tangent — solved with Levenberg–Marquardt. |
| **Loft** | Dual-silhouette cross-loft into a watertight mesh (superellipse sections, adjustable squareness); open half-profiles revolve. Extrude for flat shapes. |
| **Sculpt** (Blender) | Clay, Clay Strips, Draw, Grab, Smooth, Crease, Pinch, Flatten, Scrape, Inflate/Deflate; X symmetry, pressure, falloffs, hold Shift to smooth, Ctrl to invert, voxel remesh, subdivide. |
| **Dimensions** | Driving height / width / depth / base ⌀ / rim ⌀ and feature sizes as tappable callouts; type `65`, `6.5 cm` or `50 + 15`, or drag to scrub; measure any two points. |
| **Timeline** | Front Sketch → Side Sketch → Loft → Sculpt → Chamfer…: edit, suppress, roll back or delete any step; sculpting survives upstream edits. |
| **Model ops** | Radial menu: Extrude, Fillet, Chamfer, Offset, Shell (open top), Split, Dimension. G/R/S modal transforms with axis locks and typed values, transform gizmo, duplicate. |
| **Viewport** | Metal renderer with studio clay shading, cavity darkening, ground grid, contact shadow, wireframe, glowing loft reveal, orientation widget. |
| **Personalise** | Notebook covers in Glazed Ceramic, Matte Terracotta, Industrial Aluminum, Blueprint Cardstock, Obsidian Leather; colours, emblems, hand-drawn doodles, 3D thumbnails. Themes: Ceramic, Dark Slate, Blueprint. |
| **Export** | STL (Z up), OBJ, USDZ (real-world scale, AR Quick Look), STEP (faceted solid), clean vector SVG (just your curves, 1:1 mm), SVG drawing sheet, `.clay` project. |

## Controls

| Mac | iPad |
|---|---|
| Middle-drag orbit · ⇧ pan · Ctrl zoom (or ⌥ + drag); wheel zooms; trackpad swipe orbits | 1 finger orbits, 2 fingers pan, pinch zooms |
| Tab cycles Sketch → Model → Sculpt → Dimension | Mode switcher at the top |
| Numpad (or top-row) 1 / 3 / 7 views, 5 ortho, Home frame | Orientation widget |
| G / R / S, then X/Y/Z and a number, Enter | Transform gizmo; radial menu on tap |
| ⌘Z / ⇧⌘Z | Two-finger tap undo, three-finger tap redo |
| Shift while sculpting = smooth | "Hold to Smooth" button; Pencil double-tap toggles Smooth / Eraser |

The full list is under the keyboard button in the top bar.

## Develop and check

```bash
swift build
swift test                          # 28 tests: geometry, sculpt, CAD, timeline, keymap, sketch tools
swift run ClaySnapshots /tmp/clay   # drives the whole tutorial headlessly; writes screenshots + exports
```

`ClaySnapshots` never opens a window: it renders every screen off-screen to PNG and prints a pass/fail report.

## iPad

All iPad code paths (touch, Apple Pencil pressure, hover, pinch, multi-finger taps, hardware
keyboard) are written, but they **have not been compiled yet** — the Mac this was built on has no
iOS SDK. To build for iPad you need the full Xcode app:

1. Xcode → File → New → Project → iOS **App** named `Clay` (SwiftUI, iPadOS 17+).
2. File → Add Package Dependencies → **Add Local…** → choose this folder, and add `ClayKit` to the app target.
3. Replace the generated `ClayApp.swift` with `Sources/ClayMac/ClayApp.swift`, then run on an iPad or simulator.

## Known limits

- STEP export is a faceted solid (flat triangles), not NURBS surfaces.
- Detail-adding uses voxel remesh + subdivide rather than dynamic topology (Dyntopo).
- Extruded and duplicated bodies sit alongside each other; there are no boolean unions yet.
- Parchment's own file format isn't public, so the "Parchment-style" export is an SVG drawing sheet.
- Vector curves are outlines only (no fills or line styles yet).

## Layout

```
Sources/ClayKit/
  App/            WorkspaceState, keymap + modal transforms, workspace views, inspector
  Core3D/         Geometry (curves, mesh, loft, mesh ops) · Sculpting · CAD · Metal
  Viewport/       Metal view, pointer input, gizmos, dimension callouts, radial menu
  Sketch2D/       sketch canvas + tools, alignment guides, paper patterns
  Personalization/ covers, cover library, themes
  Tutorial/       vase guide, tutorial engine + card
  Library/        project store, library grid, exporters
Sources/ClayMac/        app entry point (shared with iPad)
Sources/ClaySnapshots/  headless checks and icon rendering
Scripts/build-app.sh    builds Clay.app
```

## License

Mozilla Public License 2.0 — see `LICENSE`.
