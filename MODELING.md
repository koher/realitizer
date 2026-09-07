# Modeling Workflow and Supported Domains

## Build a recipe, not an editor transcript

Start with named dimensions, a coordinate system, part/joint identifiers and a small parameter domain. Create the silhouette with profiles and surfaces, then apply shape operations where needed. Finish normals, UVs and material slots before binding skin or defining morph deltas. Keep collision geometry independent from visual detail. The user edits source code; polygon topology is temporary computation data, not an interactive editor's source of truth.

```swift
let outline = Profile2D(outer: [
    [-0.5,-0.5], [0.5,-0.5], [0.5,0], [0,0], [0,0.5], [-0.5,0.5]
])
let solid = try MeshBuilder.extrude(outline, depth: 0.25)
let mirrored = solid.mirrored(across: .x)
let repeated = try mirrored.linearArray(count: 3, offset: [1.2,0,0])
let finished = try repeated
    .projectingUV(.planar(horizontal: .x, vertical: .y, scale: [1,1]))
    .recalculatingNormals(smoothingAngle: .pi / 3)
    .generatingTangents()
```

For a local polygon-processing step:

```swift
let box = try MeshBuilder.box(size: [1,1,1])
let renderMesh = try box.modifyingTopology(welding: .exactPositions) { topology in
    let top = topology.selectFaces { $0.normal.y > 0.99 }
    try topology.extrude(faces: top, offset: [0,0.5,0])
}
```

The region operation creates walls around the selection boundary, not between its triangles. Queries are evaluated during each generation. Low-level face/vertex IDs are local to that topology value, not cross-build semantic asset identifiers. Choose `.exactPositions` welding for a connected surface with render seams, or `.none` when coincident render vertices must remain separate. Neither is a universal reconstruction policy; directly construct `EditableMesh(positions:polygons:)` when original polygon connectivity matters.

Subtraction is also an ordinary expression:

```swift
let outside = try MeshBuilder.cylinder(radius: 0.5, height: 1, segments: 24)
let cutter = try MeshBuilder.cylinder(radius: 0.3, height: 1.2, segments: 24)
let pipe = try outside.boolean(.subtraction, with: cutter, resolution: 20)
```

This boolean resamples a distance field. For a precise straight-sided hollow extrusion, use `Profile2D` with an outer ring and a hole instead. The API does not label an approximate voxel operation as an exact CAD boolean.

## Geometry domains

| Operation | Supported input and behavior |
| --- | --- |
| Profile triangulation / extrusion | Simple nonintersecting rings; concave outer boundary and disjoint contained holes; winding normalized; extrusion along positive z |
| Revolution | Ordered (radius, height) profile around y; nonnegative radius; zero-radius endpoints close the surface |
| Sweep | One simple profile without holes along an open path; parallel-transport frames, scale and twist; zero spans and exact reversals rejected |
| Loft | Matching ordered profile vertex counts; explicit section transforms; optional end caps |
| Parametric surface | Explicit u/v grid and a finite position function; callers choose seams and avoid singular/degenerate cells |
| Editable topology | Edge-manifold oriented polygons with per-corner UVs/colors; local vertex/face IDs; planar n-gons, including nonplanar quads after subdivision |
| Region extrusion / inset | Explicit region translation with boundary-only walls, or a single face's normal/scale extrusion; inset uses a centroid fraction, not a constant metric offset |
| Solidify | Open oriented polygon surfaces, averaged vertex normals, metric thickness, centered/inside/outside offset and optional rim slot; not a self-intersection repair solver |
| Chamfer | Closed convex topology only; face-relative fraction, not an arbitrary concave-edge bevel or constant-width CAD operation |
| Metric bevel | `beveled(edges:width:segments:material:)` on closed planar-faced manifolds, including concave shapes; selected edges or all noncoplanar edges; circular bands with mitered/triangulated corner patches; collapsed/crossing output rejected, not width-clamped |
| Catmull-Clark | Whole-mesh subdivision with boundary rules and bounded iterations; corner UVs and colors interpolate, normals are regenerated; perform before binding |
| Convex hull | 4...4096 finite points enclosing volume; duplicate/interior points allowed; coplanar sets rejected |
| Implicit extraction | Enclosing bounds outside the surface, finite nonzero surface gradients, bounded grid and output |
| Mesh booleans / remeshing | Closed manifold inputs; approximate signed-distance resampling; resolution controls precision; original UV/material/skin correspondence is not retained; colored input is rejected unless explicitly cleared first |
| UV projection | Planar, cylindrical or spherical projection with angular seam splitting; not a general atlas unwrapping/packing solver |
| Automatic UV atlas | `unwrappingUV(_:)` with `UVUnwrapOptions`; connected angle-bounded, nonoverlapping projected charts and padded square-atlas rectangle packing; uniform projected scale; not a conformal solver or optimal packer |
| Vertex coloring | `coloring(_:)` samples render vertices into sRGB colors with linear alpha; `ModelGeometry.coloring` preserves bindings; opt into rendering using `MaterialDefinition.vertexColorMode = .multiply` |
| LOD | Explicit geometry levels or the same recipe evaluated at lower quality; not automatic edge-collapse decimation |

Bevel, chamfer, subdivision, solidification and boolean resampling are shape-stage operations. Bind skin and define morphs afterward. Normal rebuilding, UV projection and automatic atlas charting also change render vertices, but their `MeshProcessor` results carry exact correspondence. `ModelGeometry` applies these operations while transferring skin and morph arrays. It never merges distinct source indices just because positions match.

Bevel widths are model-local face offsets in meters, not the final world's scaled radius. `selectEdges(where:)` exposes the edge center, length, adjacent face IDs and unsigned dihedral angle. `edges: nil` selects noncoplanar edges; an empty array leaves the topology unchanged. Coplanar faces with matching edge attributes/materials are merged before mitering, eliminating triangulation diagonals. Bevel output gets new local IDs. Rounded corner patches are not spherical fillets, and the operation does not repair arbitrary self-intersecting input.

`MeshProcessor.unwrapUV(of:options:)` returns a `UVAtlas` with `islands`, a shared `scale` and a checked `processing` result. `UVIsland.triangles` refers to original triangle indices; triangle order and material slots remain unchanged. `maximumNormalDeviation` is in radians within [0, pi/2); `padding` is the normalized gutter on each side of each island. Charts preserve material boundaries by default; `.exactPositions` welding may connect touching shells, so choose `.none` when render indices define the intended connectivity. Packing throws when padding alone cannot fit, or a work budget is exceeded. Changing the atlas invalidates previously UV-authored texture placement; atlas after shape changes, before generating dependent textures.

Author vertex colors after resampling. Other topology operations retain corner colors, and subdivision interpolates added samples in linear light while preserving discontinuities. A color is a sampled vertex attribute: detail below the vertex spacing needs more geometry or a texture. There is no hidden per-frame color generation.

`MeshVertexMap` supports positive weighted source contributions. Skin interpolation rejects output that exceeds the declared influence limit instead of silently pruning joints. Morph delta vectors interpolate as authored; this does not recompute target-surface normals or provide automatic correspondence across arbitrary remeshing. Use a newly authored `ModelGeometry` when rebinding is the intended operation.

## Materials and style

Assign one material index per triangle and declare each part's material slots. Use `TextureImage.generate`, checker/noise generation or tangent-space normal maps for code-generated textures. Color images are RGBA8/sRGB; normal/roughness/metallic maps are data textures. The adapter supports base color, normal, roughness, metallic, emissive, opacity and face culling. Unlit materials intentionally support only base color and opacity. Set `MaterialDefinition.alphaMode` explicitly: `.opaque` (default), `.blend`, or `.mask(cutoff: 0.5)`. Texture alpha does not select a mode automatically. Opacity animation requires blend or mask mode.

A style profile can replace materials with matching semantic IDs. Its normal policy uses the geometry processing path, retaining skin/morph correspondence at every LOD. Supply a custom RealityKit material through `setMaterial(_:for:)` when a game's art direction needs a custom shader.

Vertex-colored materials use `vertexColorMode: .multiply`, explicitly combining base tint, texture and vertex RGB in linear sRGB. Blend/mask modes also multiply their alpha; opaque mode ignores alpha. Emission is independent of vertex color. The adapter handles RealityKit's working color space and explicit shader cutout. `ModelRenderingResources.shared()` loads Xcode's bundled shaders; inject `ModelRenderingResources(library:)` through the compiler or cache initializer when using a non-Xcode build system. Shader resource failures throw; colors do not force native skins or position-only morphs onto the CPU path.

## Rig, poses and clips

Use explicit weights when deformation quality matters. `SkinBinding.automatic` provides a deterministic distance-to-bone starting point, not production-quality weight painting for every anatomy.

```swift
let root = AnyRealitizerID("root")
let tip = AnyRealitizerID("tip")
let rig = RigDefinition(id: AnyRealitizerID("arm"), joints: [
    JointDefinition(id: root),
    JointDefinition(id: tip, parent: root,
                    restTransform: ModelTransform(translation: [0,1,0]))
])
let binding = try SkinBinding.automatic(mesh: finished, rig: rig)
try binding.validate(vertexCount: finished.vertices.count, rig: rig)
let geometry = try ModelGeometry(mesh: finished)
    .binding(binding, to: rig)
    .addingMorph(id: AnyRealitizerID("expand")) { $0.position * 1.1 }
let part = ModelPartDefinition(id: AnyRealitizerID("body"),
    geometry: geometry, material: AnyRealitizerID("surface"))
```

Author complete rest/bind conventions, then sparse named poses. `keyPoses` and `bake` reduce manual channel bookkeeping. Give graph layers explicit masks, choose a single event-producing reference clip per state, and assign root movement either to the animator or the game's movement controller.

`RigConstraint` carries typed `InverseKinematicsConstraint`, `LookAtConstraint` or `TwoBoneIKConstraint` definitions. A `RigConstraintTarget` supplies the runtime rig-space position and, for two-bone IK, an explicit pole position determining the bend plane. Constraints without targets are inactive; unknown target IDs, unused poles and ambiguous pole axes are errors. Both IK solvers report reachability, including when joint limits prevent reaching the target. The two-bone solver preserves bone lengths and is not a stretching or whole-body solver.

Feed terrain/contact queries from the game into `setConstraintTarget(_:position:polePosition:)`; the portable solver does not perform world physics queries. `clearConstraintTarget` disables a target without changing the rig. Use `RetargetMap` for explicitly mapped rigs, and `SpringMotion` for caller-owned secondary motion.

## Runtime recipe boundary

```swift
let recipe = ModelingRecipe(seed: 42, root:
    .noise(.sphere(radius: 0.5), amplitude: 0.04, frequency: 3)
)
let mesh = try recipe.evaluate(
    quality: ModelQualityProfile(curveSegments: 24, surfaceSegments: 16)
).mesh
```

The JSON operation set is deliberately narrower than trusted Swift authoring: primitives, profile surfaces, transforms, groups/references, arrays, normals, UVs and deformations. It does not deserialize arbitrary closures or import external assets. Topology/boolean authoring remains available through the trusted Swift API.

## Verification

Check dimensions, signed volume where applicable, triangle winding, normals, tangent frames and material slots. Test parameter extremes and multiple seeds. Compare rest skinning to source geometry, verify LOD morph/rig contracts, and test loop/transition boundaries. Use Preview diagnostic modes on the actual asset, then measure the consuming game's workload on target devices.
