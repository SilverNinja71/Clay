# Clay — notes for Claude

Clay is a SwiftUI + Metal app for Mac and iPad: sketch a front and a side silhouette → loft them into a
watertight 3D body → sculpt it with Blender-style brushes → drive exact dimensions through a
Fusion-style non-destructive timeline. **The full product brief is in `docs/SPEC.md` — read it first.**
The README has a status table.

## Working with this user

- They are new to coding and want to learn: explain what you do in plain language, define jargon briefly.
- Test without disturbing them: **no pop-up windows and no sound**. Don't launch the app window to
  check your work; verify headlessly (see below). Use Claude's built-in browser pane if a browser is
  ever needed, never their own Chrome.
- They watch their weekly usage: aim to stop around 45% of the weekly limit, and leave the repo in a
  pushed, buildable state before then.
- Commit and push to `origin main` (github.com/SilverNinja71/Clay) when a chunk of work is done and tested.

## Build, test, verify

```bash
swift build
swift test                          # Swift Testing; 18 tests cover geometry, sculpt, CAD, timeline
swift run ClaySnapshots <out-dir>   # renders the vase off-screen to <out-dir>/vase.png — look at it with Read
```

- Package: `swift-tools-version: 5.10` (Swift 5 language mode, on purpose: avoids strict-concurrency
  noise around Metal/MTKView). Platforms macOS 14, iOS 17.
- The first machine had only the Command Line Tools: no iOS SDK, no offline `metal` compiler. So the
  shaders are an MSL string in `Core3D/Metal/Shaders.swift`, compiled at runtime. If this machine has
  full Xcode, also build for iPad (an Xcode "App" project that links the `ClayKit` package).
- Planned headless checks for the UI: extend `ClaySnapshots` to render SwiftUI screens with
  `ImageRenderer` (pass the Metal viewport in as a pre-rendered image, since `ImageRenderer` can't draw
  an `MTKView`) and check the PNGs.

## What exists (Sources/ClayKit)

- `Core3D/Geometry`: `MathUtil` (Vec2/Vec3/Mat4 aliases, matrices, ray/triangle, AABB, dense solver),
  `CurveNetwork` (CubicBezier, BezierAnchor with relative handles, SketchPath, Sketch, SketchPlane
  mapping, Schneider `BezierFitter` with corner detection), `ClayMesh` (indexed mesh; positions/normals
  are SIMD3<Float> = Metal float3; lazy topology; raycast; watertight check; `compacted()`),
  `LoftEngine` (SilhouetteProfile, superellipse cross-loft, ExtrudeEngine + ear clipping),
  `MeshOperations` (offset, shell w/ open top, split + cap, chamfer/fillet, subdivide, transform).
- `Core3D/Sculpting`: `SculptBrush` (10 kernels, falloffs, BrushSettings), `SculptEngine` (spatial hash,
  dab spacing, X symmetry, grab, pressure), `SculptLayer` (displacements in local frames so sculpting
  survives upstream edits), `VoxelRemesher` (parity voxelisation + naive surface nets + Taubin).
- `Core3D/CAD`: `DimensionSolver` (LengthUnit, `UnitExpression` parser, `SketchConstraint`,
  Levenberg–Marquardt `ConstraintSolver`, `ProfileDimensionSolver` for height/width/depth/base Ø/rim Ø),
  `HistoryTimeline` (Feature/FeatureKind, Timeline with rollback marker, `TimelineEvaluator` that caches
  per feature and re-runs from the first changed `revision`).
- `Core3D/Metal`: `OrbitCamera` (yaw/pitch turntable, presets, ray/project, `CameraAnimator`),
  `Shaders`, `ClayRenderer` (`RenderPipelines.shared()` compiled once; one `ClayRenderer` per view;
  `RenderScene`; `renderImage` off-screen; MTKViewDelegate with `sceneProvider` / `onFrame`).
- `Personalization/StudioThemeStore` (RGBA sRGB→linear, themes Ceramic / Dark Slate / Blueprint,
  `floatingPanel`, `ToolButton`), `Library/ProjectStore` (ClayDocument JSON + PNG thumbnails + index),
  `Sketch2D/PaperGridPattern` (PaperStyle, SketchViewTransform, paper drawing),
  `Sketch2D/SilhouetteMatcher` (base/top/widest/waist guides, height match), `Tutorial/VaseGuide`
  (ghost vase: base Ø50 mm, height 120 mm, side is 86% depth).

## Remaining plan (in order)

1. `App/KeyboardShortcutManager.swift`: platform-neutral `KeyStroke`, `KeyCommand`, pure
   `BlenderKeymap.resolve(stroke, context)` (unit-test it), `ModalTransform` state machine (G/R/S, X/Y/Z
   axis, Shift+axis = plane lock, typed numbers, `-` negate, Enter/click confirm, Esc/right-click
   cancel; grab via ray–plane / closest-point-on-axis, rotate via screen angle around pivot, scale via
   distance ratio). macOS: `NSEvent.addLocalMonitorForEvents(.keyDown)`, skip when a text field is
   first responder; numpad keyCodes 0x52–0x5C. iPad: SwiftUI `.onKeyPress` (+ `.numericPad` modifier).
   "Emulate numpad" on by default (top-row 1/3/7/5), since Mac keyboards often lack one.
   Keys: Tab/Shift+Tab cycle modes; Cmd/Ctrl+Z undo, Cmd+Shift+Z redo; numpad 1/3/7 (Ctrl = opposite),
   5 ortho, `.`/Home frame; Model: G R S E, Shift+D, X/Delete, W wireframe; Sculpt brush hotkeys are in
   `BrushKind.hotkey`, `[`/`]` radius, Shift+`[`/`]` strength, M mirror, Shift held = smooth,
   Ctrl held = invert; Sketch: P pencil, L line, C circle, B rectangle, V edit, D dimension,
   E = extrude selected closed path (else eraser), 1/3 = front/side plane, Enter finishes a polyline.
2. `App/WorkspaceState.swift` (`@MainActor @Observable`): document + timeline, evaluator, mode
   (sketch/model/sculpt/dimension), active plane, tools, BrushSettings, camera + animator, selection,
   modal, radial menu, measurements, loft reveal animation, toasts, undo/redo as `Timeline` snapshots,
   autosave (debounced) with an off-screen thumbnail. Sculpt mode continues the last Sculpt feature or
   appends one; strokes run on `SculptEngine`, and on stroke end `SculptLayer.capture(base:sculpted:)` +
   `evaluator.overrideResult`. `tick(dt)` from the renderer drives camera glides and the reveal.
   `renderScene()` builds the RenderScene (sketch curves drawn on their planes).
3. Viewport: `PointerInput` (NSView/UIView event translation: pressure, pencil vs finger, scroll
   precise vs wheel, magnify, 2-finger pan/pinch, 2-finger tap undo, 3-finger tap redo,
   `UIPencilInteraction` double-tap → toggle Smooth/Eraser, hover → brush cursor), `ClayViewportView`
   (MTKView, 4× MSAA, depth32Float, bgra8Unorm_srgb), `GizmoOverlayView` (move arrows, rotate rings,
   scale handles, nav-axes widget), `DimensionCalloutLayer` (driving profile dims, feature parameters
   like chamfer size/shell thickness, measure-two-points reference dims; tap → numeric field accepting
   `UnitExpression` + scrub), `RadialMenuView` (Extrude, Fillet, Chamfer, Offset, Shell, Split, Dimension).
   Navigation: MMB orbit, Shift+MMB pan, wheel zoom, trackpad scroll orbit, Alt+LMB orbit, drag on
   empty space orbits. iPad: Pencil = tool, finger = navigate (finger acts as tool until a Pencil is seen).
4. Sketch: `OrthoSketchCanvas` (SwiftUI Canvas + pointer view; paper, axis, guides from the other
   plane, tutorial ghost, paths, anchors/handles, constraint glyphs, live stroke), interaction for
   pencil (fit → auto-close within snap radius, join endpoints, snap to centre axis), line, circle,
   rectangle, edit (drag anchors/handles, re-solve constraints), eraser, dimension. Split view shows
   front and side side by side; plane switch animates with a 90° `rotation3DEffect`.
5. Workspace chrome (Shapr3D-style floating panels): top bar (library, name, mode switcher, undo/redo,
   export, theme), left tool palette per mode, right inspector (brush radius/strength/falloff/symmetry,
   loft rings/segments/squareness, paper style, constraints), bottom timeline chips (edit, suppress,
   delete, rollback marker), "Generate 3D Clay" button, hold-to-smooth button for touch.
6. Library: `ProjectBrowserView` (grid of notebook cards, new / tutorial / rename / duplicate / delete),
   `ProjectCardView` + `CoverLibraryView` (five procedural materials, tint swatches, SF Symbol emblems,
   doodle pad, 3D thumbnail), `ExportSheet` via `.fileExporter`: OBJ, binary STL, USDZ (ModelIO), STEP
   as faceted B-rep (AP214 `FACETED_BREP`; be honest that it's a mesh, not true NURBS), SVG drawing sheet
   of both sketches with dimensions (Parchment's own format isn't public), and the `.clay` JSON.
7. Tutorial: `TutorialEngine` + `InteractiveOnboardingView` following SPEC §5, with a "Show me" button
   that performs each step (also used by headless checks). User strokes within ~7 mm of the ghost snap
   to it, so the base reads exactly 50 mm. Haptics via `.sensoryFeedback`.
8. `Sources/ClayMac/ClayApp.swift` (cross-platform `App`; set activation policy `.regular` when run
   unbundled), a script to assemble `Clay.app` (Info.plist, ad-hoc codesign, icon rendered by
   ClaySnapshots), and iPad app instructions in the README.

## Gotchas learned

- Swift's type checker times out on long SIMD expressions mixing literals: split them and annotate types.
- `Uniforms` in `ClayRenderer.swift` must match the MSL struct field-for-field (all float4x4 / float4).
- Theme colours are sRGB; convert with `RGBA.linear` before handing them to Metal.
- Call `compacted()` after operations that drop triangles, or unused vertices skew bounds and exports.
- Tests import Foundation explicitly (UUID). Test-name filters use type/function names, not suite titles.
