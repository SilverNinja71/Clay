# Clay
Clay is an intuitive 2D-to-3D modeling, CAD, and digital sculpting studio for iPad &amp; Mac.

**Sketch in 2D, form in 3D, sculpt like clay, measure with precision.**
Draw a front silhouette and a side silhouette, loft them into a watertight 3D body, sculpt it with
Blender-style brushes, then drive exact dimensions Fusion-style through a non-destructive timeline.

## Status (work in progress)

The geometry engine and the Metal renderer are done and tested. The app's screens are next.
The original brief is in [`docs/SPEC.md`](docs/SPEC.md); the build plan for what remains is in [`CLAUDE.md`](CLAUDE.md).

| Area | State |
|---|---|
| Bézier curves, freehand stroke → Bézier fitting (Schneider), primitives | ✅ done, tested |
| Dual-silhouette cross-loft → watertight mesh, extrude | ✅ done, tested |
| Sculpt brushes (Clay, Clay Strips, Draw, Grab, Smooth, Crease, Pinch, Flatten, Scrape, Inflate), X symmetry, pressure | ✅ done, tested |
| Voxel remesh (surface nets), subdivide | ✅ done, tested |
| Shell, split, offset, chamfer/fillet | ✅ done, tested |
| Constraint solver (distance, horizontal/vertical, parallel, perpendicular, angle, radius…), unit expressions (`6.5cm + 2mm`) | ✅ done, tested |
| Parametric history timeline (sculpt layers survive upstream dimension edits) | ✅ done, tested |
| Metal viewport renderer (clay shading, grid, contact shadow, wireframe, thick curves, off-screen render) | ✅ done |
| Themes (Ceramic, Dark Slate, Blueprint), project storage, paper patterns, alignment guides | ✅ written |
| Workspace state, Blender keymap + modal G/R/S, viewport input | 🚧 in progress |
| Sketch canvas, toolbars, timeline bar, dimension callouts, radial menu | ⏳ next |
| Project library + covers, export (OBJ/STL/USDZ/STEP/SVG), first-run vase tutorial | ⏳ next |
| Mac app shell, iPad app project | ⏳ next (`Sources/ClayMac` is a placeholder for now) |

## Layout

```
Sources/ClayKit/          everything shared by Mac and iPad
  Core3D/Geometry/        math, curves, mesh, loft, mesh operations
  Core3D/Sculpting/       brushes, sculpt engine + layers, voxel remesher
  Core3D/CAD/             constraint solver, dimensions, history timeline
  Core3D/Metal/           camera, shaders (compiled at runtime), renderer
  Sketch2D/  Personalization/  Library/  Tutorial/
Sources/ClayMac/          Mac app entry point (placeholder)
Sources/ClaySnapshots/    headless tool: renders the model to PNG without opening a window
Tests/ClayKitTests/       geometry / sculpt / CAD tests
```

## Build and test (macOS 14+)

Needs Swift 5.10+ (Xcode, or just the Command Line Tools: `xcode-select --install`).

```bash
swift build
swift test
swift run ClaySnapshots /tmp     # writes /tmp/vase.png
```

The iPad app needs the full Xcode app (it will be an Xcode "App" project that links `ClayKit`).
Shaders live in `Core3D/Metal/Shaders.swift` as a string and compile at runtime, so no offline
Metal compiler is required.

## License

Mozilla Public License 2.0 — see `LICENSE`.
