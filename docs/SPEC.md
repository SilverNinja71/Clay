# Clay — Architectural Specification

This is the original product brief Clay is built from (kept verbatim apart from formatting).

## 1. Executive overview & product vision

You are tasked with architecting and implementing **Clay**, a professional, universal Apple-platform application (iPadOS 17+ and macOS 14+ Sonoma/Sequoia) built in **SwiftUI**, **Metal**, and **PencilKit / SceneKit / RealityKit**.

### The core philosophy: "Sketch in 2D, Form in 3D, Sculpt like Clay, Measure with Precision"

Existing 3D software is split between intimidating desktop suites (Blender) and rigid mobile CAD apps (Shapr3D). **Clay** unifies four creative paradigms into one seamless, tactile workspace:

1. **Parchment DNA**: Tactile organic feel, 2D sketch-first mindset, customizable project covers, hand-drawn personalization kit, and high-aesthetic clean UI.
2. **Shapr3D DNA**: Fluid Apple Pencil interaction, gesture-driven direct manipulation, clean modern floating toolbars, contextual snap guides, and intuitive interactive onboarding.
3. **Blender DNA**: Full keyboard workflow parity on macOS and iPad with Magic Keyboard (`G` Grab/Move, `R` Rotate, `S` Scale, `E` Extrude, `Tab` Edit/Object/Sculpt toggle, Numpad `1`/`3`/`7` viewports), dedicated modeling & sculpting workspaces, and dynamic digital clay brushes.
4. **Autodesk Fusion DNA**: Parametric dimensioning engine, exact numeric inputs, constraints (distance, angle, diameter, perpendicular, tangent), and a non-destructive feature timeline.

## 2. The signature 5-step modeling pipeline

```
[ Step 1: Front Sketch ] ──> [ Step 2: Side Sketch ] ──> [ Step 3: Connect & Loft (Mesh) ]
                                                                     │
[ Step 5: Precision CAD Dimensioning ] <── [ Step 4: Digital Clay Sculpting ]
```

### Step 1: Front-image orthographic sketch
- The user enters the **Front Plane** (XY).
- The canvas behaves like **Parchment**: an organic paper grid (Ruled, Grid, Dotted, or Blank) rendered on the orthographic plane.
- The user sketches the front silhouette or cross-section using Apple Pencil or stylus/mouse. Strokes automatically smooth into vectorized cubic Bézier curves or closed boundary loops with auto-snapping endpoints.

### Step 2: Side-image orthographic sketch
- With a 90° smooth camera transition (or split viewport), the user activates the **Right/Side Plane** (ZY).
- Ghosted reference lines (bounding box height, waist, feature marks) project across from the Front Sketch to maintain exact anatomical/mechanical alignment.
- The user draws the complementary profile silhouette.

### Step 3: Curve-cross reconstruction & 3D skinning
- The app reconciles the two orthogonal silhouettes:
  - **Skinning / Coons Patch / Cross-Loft**: Computes the 3D volume by intersecting the extruded volumes or lofting elliptic cross-sections through the synchronized curves.
  - Generates a watertight manifold 3D polygonal mesh (`ClayMesh`) or Signed Distance Field (SDF) volume ready for manipulation.

### Step 4: Digital clay sculpting (Blender-style brushes)
- The user seamlessly switches to **Sculpt Mode** (tap toolbar or press `Tab` / `Ctrl+Tab`).
- Sculpting brushes with dynamic remeshing / Dyntopo or voxel deformation:
  - **Clay Strip / Clay**: Builds up strips of volume with tactile resistance.
  - **Grab / Move**: Elastic deformation of shapes and silhouettes.
  - **Smooth**: Holding `Shift` while using any brush instantly relaxes vertices.
  - **Crease / Pinch**: Carves sharp seams, folds, and definition.
  - **Flatten / Scrape**: Plans out hard-surface transitions.
  - **Inflate / Deflate**: Uniform volumetric expansion.
- Apple Pencil pressure controls brush strength and stroke radius.

### Step 5: Sophisticated precision & CAD dimensions (Fusion-style)
- For technical objects requiring engineering tolerance:
  - Toggle **Dimension Mode**: Tap any edge, vertex pair, or curve to expose real-time dimensions (mm, cm, m, inches).
  - **Direct Numeric Editing**: Tap a dimension callout to open a numeric keypad or scrub slider (e.g., set height to exactly `120.0 mm`).
  - **Parametric Constraints**: Fix lengths, radii, perpendicularity, parallelism, and concentric alignments.
  - **Parametric History Tree**: Bottom timeline shows [Front Sketch] -> [Side Sketch] -> [Loft] -> [Sculpt] -> [Chamfer]. Editing early sketches recalculates downstream geometry non-destructively.

## 3. Dual-platform controls: Blender parity + Shapr3D touch

### A. macOS controls (Blender keyboard & mouse standard)
- **Viewport navigation**:
  - Middle Mouse Drag: Orbit 3D viewport.
  - `Shift` + Middle Mouse Drag: Pan.
  - Scroll Wheel: Dolly / Zoom.
  - Numpad `1`: Front View, Numpad `3`: Right Side View, Numpad `7`: Top View, Numpad `5`: Perspective / Orthographic toggle.
- **Modal transform keys**:
  - `G`: Grab / Translate (`G` then `X` / `Y` / `Z` to lock axis, followed by numeric keyboard input).
  - `R`: Rotate (`R` then `X` / `Y` / `Z`).
  - `S`: Scale.
  - `E`: Extrude selected sketch curve or polygon face.
  - `Tab`: Cycle modes (Sketch -> Model -> Sculpt -> Dimension).
  - `Shift + D`: Duplicate.
  - `X` or `Delete`: Delete element.
  - `Ctrl + Z` / `Cmd + Z`: Undo, `Cmd + Shift + Z`: Redo.

### B. iPadOS direct manipulation (Shapr3D ergonomics)
- **Apple Pencil**:
  - Primary tool for drawing sketches, pulling geometry, and applying sculpt strokes.
  - Double-tap Pencil barrel: Toggle between current brush and Smooth/Eraser, or open contextual radial menu.
- **Finger gestures**:
  - 1 Finger Drag: Rotate / Orbit scene.
  - 2 Finger Drag: Pan viewport.
  - Pinch: Zoom.
  - Two-Finger Tap: Undo.
  - Three-Finger Tap: Redo.
- **Contextual radial menu**:
  - Tapping a face, curve, or edge spawns a Shapr3D-style radial quick-action ring: Extrude, Fillet, Chamfer, Offset, Shell, Split, Dimension.

## 4. Architectural & component design

Design the app with clean, decoupled modular Swift architecture:

```
Clay/
├── App/
│   ├── ClayApp.swift                    // Universal SwiftUI App entry
│   ├── WorkspaceState.swift             // Active mode, tool, camera, selection state
│   └── KeyboardShortcutManager.swift    // Blender hotkey event monitor
├── Core3D/
│   ├── Geometry/
│   │   ├── ClayMesh.swift               // Half-edge or index buffer mesh structure
│   │   ├── CurveNetwork.swift           // 2D/3D cubic Bézier spline math
│   │   └── LoftEngine.swift             // 2D orthogonal silhouette cross-lofting
│   ├── Sculpting/
│   │   ├── SculptEngine.swift           // Vertex displacement & spatial octree / KD-tree
│   │   ├── SculptBrush.swift            // Clay, Grab, Smooth, Crease, Inflate algorithms
│   │   └── VoxelRemesher.swift          // Dynamic topology & uniform remesh
│   ├── CAD/
│   │   ├── DimensionSolver.swift        // Constraint solver & parametric bindings
│   │   └── HistoryTimeline.swift        // Non-destructive operation DAG
│   └── Metal/
│       ├── ClayRenderer.swift           // Metal-based viewport renderer with PBR shading
│       └── Shaders.metal                // Clay matcap, wireframe overlay, grid shaders
├── Viewport/
│   ├── ClayViewportView.swift           // Platform-abstracted 3D interactive viewport
│   ├── GizmoOverlayView.swift           // 3D transform arrows, rotation rings, scale handles
│   └── DimensionCalloutLayer.swift      // Floating CAD dimension labels and arrows
├── Sketch2D/
│   ├── OrthoSketchCanvas.swift          // PencilKit / CoreGraphics sketch surface
│   ├── SilhouetteMatcher.swift          // Height alignment guides between Front & Side
│   └── PaperGridPattern.swift           // Parchment-style ruled/grid/dotted ground plane
├── Personalization/
│   ├── ProjectCardView.swift            // Custom notebook/model card covers
│   ├── CoverLibraryView.swift           // Built-in studio cover templates & textures
│   └── StudioThemeStore.swift           // Workspace colorway (Ceramic, Dark Slate, Blueprint)
├── Tutorial/
│   ├── TutorialEngine.swift             // Guided step-by-step state machine
│   └── InteractiveOnboardingView.swift  // Interactive hands-on walkthrough
└── Library/
    ├── ProjectBrowserView.swift         // Model repository grid with customizable covers
    └── ExportSheet.swift                // Export to OBJ, STL, USDZ, STEP, Parchment format
```

## 5. Interactive first-arrival tutorial ("The Ceramic Vase")

When a user launches **Clay** for the first time, guide them into an interactive onboarding experience inspired by Shapr3D's celebrated tutorial:

1. **Phase 1: Front Sketch**:
   - The camera glides into the Front Orthographic View.
   - A ghosted outline guides the user: *"Draw the front silhouette of this vase with your Apple Pencil or cursor."*
   - Once closed, the curve snaps smooth with a gentle haptic buzz.
2. **Phase 2: Side Profile**:
   - The viewport pivots 90° into the Side View. Alignment guide markers tether to the front silhouette.
   - The user sketches the depth profile.
3. **Phase 3: Connect & Generate 3D Shape**:
   - A single prominent action button: *"Generate 3D Clay"*.
   - The curves illuminate and a 3D volumetric mesh seamlessly lofts between them.
4. **Phase 4: Sculpt the Details**:
   - The prompt asks the user to select the **Clay** brush and indent the neck or flange: *"Push and sculpt details like real pottery clay."*
   - Prompt them to hold `Shift` (or two-finger hold) to smooth rough edges.
5. **Phase 5: Precision Dimensioning**:
   - Tap the vase base: A dimension label appears (`50 mm`).
   - Guide the user to tap and change it to `65 mm`, demonstrating live parametric updating.
6. **Completion**:
   - The user finishes the model, selects a custom studio cover from the Cover Library, and saves it to their workspace.

## 6. Personalization & aesthetics (Parchment integration)

Clay adopts Parchment's acclaimed aesthetic principles:
- **Project Covers**: Every 3D project has an editable notebook-style project binder cover in the library, complete with custom leather/ceramic/paper textures, color swatches, and 3D thumbnail previews.
- **Cover Library**: Built-in curated materials (Glazed Ceramic, Matte Terracotta, Industrial Aluminum, Blueprint Cardstock, Obsidian Leather).
- **2D Paper Viewports**: Orthographic drawing planes render genuine paper backgrounds (Grid, Ruled, Dotted, Blank) to make 2D technical sketching feel natural and artistic.

## 7. Implementation requirements & deliverables

When implementing Clay:
1. Provide **complete, compilable, idiomatic Swift code** (no `// TODO: implement later` placeholders for core algorithms).
2. Implement cross-platform support cleanly using `#if os(macOS)` and `#if os(iOS)`.
3. Include the actual 3D math logic for:
   - Cubic Bézier curve sampling and silhouette interpolation.
   - Dual-silhouette lofting into a watertight triangle mesh.
   - The vertex deformation brush logic (radius falloff, normal displacement, Laplacian smoothing).
   - Blender keyboard event mapping for macOS.
4. Ensure the UI feels ultra-premium, dynamic, and responsive with high-framerate Metal rendering and smooth spring animations.
