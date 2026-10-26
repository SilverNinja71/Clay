# Clay — notes for Claude

Clay is a SwiftUI + Metal app for Mac and iPad: sketch a front and a side silhouette → loft them into a
watertight 3D body → sculpt it with Blender-style brushes → drive exact dimensions through a
Fusion-style non-destructive timeline. **The full product brief is in `docs/SPEC.md`.** The README
describes features, controls and known limits.

## Working with this user

- They are new to coding and want to learn: explain what you do in plain language, define jargon briefly.
- Test without disturbing them: **no pop-up windows and no sound**. Don't launch the app window to
  check your work; verify headlessly (below). Use Claude's built-in browser pane if a browser is
  ever needed, never their own Chrome.
- They watch their weekly usage: aim to stop around 45% of the weekly limit, and leave the repo in a
  pushed, buildable state before then.
- Commit and push to `origin main` (github.com/SilverNinja71/Clay) when a chunk of work is done and tested.

## Build, test, verify

```bash
swift build
swift test                                  # 28 Swift Testing tests
swift build -c release --product ClaySnapshots && .build/release/ClaySnapshots <dir>
Scripts/build-app.sh                        # Clay.app (do not `open` it while testing)
```

- `ClaySnapshots <dir>` drives the whole tutorial through `WorkspaceState`, checks ~45 behaviours
  (prints ✓ / ✗ FAIL), writes exports, and saves screenshots of every screen. Screens are captured by
  drawing an `NSHostingView` in a window that is never put on screen (SwiftUI's `ImageRenderer`
  can't draw native controls); the Metal viewport is swapped for an off-screen render through the
  `viewportSnapshot` environment value. Look at the PNGs with Read.
- Package: `swift-tools-version: 5.10` (Swift 5 mode on purpose). Platforms macOS 14, iOS 17.
  `ClayMac` needs `-parse-as-library` because its only file uses `@main`.
- The machine this started on has only the Command Line Tools: no iOS SDK and no offline `metal`
  compiler. Shaders are an MSL string in `Core3D/Metal/Shaders.swift`, compiled at runtime. Model I/O
  there can't write .usdz, so `USDZPackager` zips the .usdc itself (64-byte aligned, stored).

## Architecture in one breath

`WorkspaceState` (`@MainActor @Observable`) owns the `ClayDocument` (timeline of `Feature`s), a
`TimelineEvaluator` (caches each step's mesh, re-runs from the first changed `revision`), mode/tool
state, camera + `CameraAnimator`, undo/redo as `Timeline` snapshots, and autosave through `onSave`.
Extensions add viewport input (`Viewport/ClayViewportView.swift`), sketch tools
(`Sketch2D/SketchInteraction.swift`) and dimension callouts (`Viewport/DimensionCalloutLayer.swift`).
Sculpting runs on `SculptEngine`; each finished stroke is stored as a `SculptLayer` (displacements in
local frames) so upstream sketch/dimension edits rebuild the loft and re-apply the sculpt.
`PointerCaptureView` (NSView / UIView) turns mouse, trackpad, Pencil and touch into `PointerEvent`s.
`KeyboardShortcutManager` holds the pure `BlenderKeymap.resolve` and the `ModalTransform` state machine.

## Status

Everything in SPEC.md has a working implementation on macOS, checked headlessly. Not yet verified:

1. **Hands-on use of the live app** (real mouse/trackpad/keyboard events in the Metal view, hover
   brush cursor, gizmo drags, file export dialogs). Only logic and layout were checked automatically.
2. **iPad build**: iOS code paths (`#if os(iOS)` in PointerInput, KeyboardShortcutManager,
   ClayViewportView, WorkspaceView) were never compiled. Needs full Xcode; see README "iPad".

## Ideas for next steps

- Boolean union for extrude/duplicate bodies; Dyntopo-style local refinement while sculpting.
- PencilKit-backed ink preview for sketch strokes; pressure-varying sketch line width.
- Camera framing that leaves room for the tutorial card; per-callout leader lines when labels are nudged.
- Unit tests for `WorkspaceState` flows (currently covered by ClaySnapshots).

## Gotchas learned

- Swift's type checker times out on long SIMD expressions mixing literals: split them and annotate types.
- `Uniforms` in `ClayRenderer.swift` must match the MSL struct field-for-field (all float4x4 / float4).
- Theme colours are sRGB; convert with `RGBA.linear` before handing them to Metal.
- Floating panels use `.ultraThinMaterial`; force `.environment(\.colorScheme, …)` from the Clay theme
  or dark themes get white panels.
- Call `compacted()` after operations that drop triangles, or unused vertices skew bounds and exports.
- `MTKView.delegate` is weak — keep the `ClayRenderer` alive in the representable's coordinator.
- Tests import Foundation explicitly (UUID). Test-name filters use type/function names, not suite titles.
