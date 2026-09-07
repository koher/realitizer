---
name: realitizer
description: Create and refine code-first 3D game assets with the Realitizer Swift library, including procedural geometry, materials, rigs, animation, RealityKit integration, and code-controlled previews. Use when a task requests Realitizer modeling or changes to an asset built with it; not for unrelated SwiftUI work or Blender UI automation.
---

# Realitizer asset authoring

Use Swift source as the model's source of truth. This skill contains the workflow, API examples and contracts needed to start authoring without other documents. Use the consumer's installed Realitizer revision; do not silently change its dependency pin. Work in the consuming project unless the task includes changing the library. Keep game-specific shapes, palettes, scenery and gameplay out of the SDK.

## Setup and coordinate contracts

Realitizer requires Swift 6.3 and iOS 26 or macOS 26. Add products to the consuming target's package dependencies as needed:

- `Realitizer`: deterministic geometry, materials, rigs, animation and validation; no RealityKit or SwiftUI dependency.
- `RealitizerRealityKit`: compilation and runtime instances.
- `RealitizerPreview`: the shared SwiftUI/RealityView inspection View.
- `RealitizerEnvironment` and `RealitizerEnvironmentRealityKit`: optional grass/wave definitions and rendering. Ordinary models do not need them.

In a Swift package target, use `.product(name: "Realitizer", package: "realitizer")` and equivalent entries for the selected products, matching the dependency identity in that project. Import the corresponding modules in Swift. No Blender process or MCP modeling session is involved.

The Swift blocks below can be combined in one source file. The Preview uses the `fin` generator defined in this skill; there are no external example files to obtain.

Use meters, positive y up, radians, normalized quaternions and counterclockwise exterior triangles. Parts and joints have parent-local transforms. Skinned vertices use rig space on identity-transform root parts. Move the runtime instance root to position the whole asset in the world. IK targets also use rig space; game code converts world-space targets before supplying them.

Semantic identifiers address parts, joints, sockets, clips and morphs. `AnyRealitizerID("body")` is a convenient explicit ID. Typed enums may conform to `RealitizerID`; use `.joint(id: Joint.tip)` for typed hierarchy/animation references, or `.joint(erasedID)` for `AnyRealitizerID`. Render-vertex indices and face IDs local to a topology calculation are not cross-generation gameplay identifiers.

## Choose the modeling operation

Start with silhouette, proportions and independently controlled parts, then surface detail. Express parameters in a small caller-owned struct and compose ordinary Swift functions. Seed procedural variation explicitly. Do not build an editor document, recorded command language or parameter-adjustment UI.

| Shape or operation | API and important domain |
| --- | --- |
| Basic solids | `MeshBuilder.box(size:)`, `cylinder(radius:height:segments:)`, `cone(radius:height:segments:)`, `sphere(radius:latitudeSegments:longitudeSegments:)` |
| Hollow or concave extrusion | `Profile2D(outer:holes:)` and `MeshBuilder.extrude(_:depth:)`; rings lie in xy, extrusion runs along positive z; holes must be disjoint, contained and not touch boundaries |
| Rotational shape | `MeshBuilder.revolve(profile:segments:)`; profile points are ordered `(radius, height)` around y; zero-radius endpoints close it |
| Curved tube or changing sections | `MeshBuilder.sweep(_:along:scales:twist:capped:)` for a hole-free profile on an open path; `loft(_:capped:)` with `LoftSection(profile:transform:)` and matching profile vertex counts |
| Function-defined surface | `MeshBuilder.surface(uSegments:vSegments:position:)`; a normalized `SIMD2<Float>` parameter maps to a position; avoid degenerate cells and choose seams explicitly |
| Polygon processing | `EditableMesh(positions:polygons:)` or `mesh.modifyingTopology(welding:smoothingAngle:_:)`; choose `.none` or `.exactPositions` deliberately, since welding can join touching shells |
| Face/edge operations | `selectFaces(where:)` queries ID, center, normal and material index; `selectEdges(where:)` queries edge ID, center, length, adjacent faces and optional dihedral angle; `extrude(faces:offset:)` creates boundary-only walls; `inset(face:fraction:)` uses a centroid fraction |
| Chamfer, thickness, subdivision | `chamfered(fraction:)` accepts convex closed topology, not arbitrary constant-width bevels; `solidified(thickness:offset:rimMaterial:)` thickens open surfaces with averaged normals and offset in -1...1; `subdivided(iterations:)` applies Catmull-Clark |
| Metric bevel | `beveled(edges:width:segments:material:)` accepts closed oriented planar-faced topology, including concave shapes; width is a face offset in model-space meters; nil edges selects all noncoplanar edges; one segment is flat, more are circular edge bands with mitered/triangulated corners |
| Repetition and deformation | Mesh methods `mirrored(across:)`, `linearArray(count:offset:)`, `radialArray(count:axis:angle:)`, `twisted(around:radiansPerMeter:)`, `tapered(along:from:to:)`, `bent(curvature:)`, `noiseDisplaced(amplitude:frequency:seed:)`; apply before binding |
| Subtractive/composed solids | `mesh.boolean(.subtraction, with: cutter, resolution: 20)`; also `.union` and `.intersection`; closed-mesh approximate distance-field resampling, not exact CAD operations |
| Surface finishing | `recalculatingNormals(smoothingAngle:)`, `projectingUV(_:)`, `unwrappingUV(_:)`, `coloring(_:)`, `generatingTangents()`; projection supports `.planar(horizontal:vertical:scale:)`, `.cylindrical(axis:scale:)`, `.spherical`; automatic unwrapping charts and packs a square atlas |

For example, a spatial selection survives parameter changes better than assuming a particular triangle number:

```swift
import Realitizer

func raisedBox() throws -> MeshData {
    try MeshBuilder.box(size: [1, 1, 1])
        .modifyingTopology(welding: .exactPositions) { topology in
            let top = topology.selectFaces { $0.normal.y > 0.99 }
            try topology.extrude(faces: top, offset: [0, 0.5, 0])
        }
        .projectingUV(.planar(horizontal: .x, vertical: .z, scale: [1, 1]))
}
```

Prefer a profile with a hole for a straight hollow extrusion. Use a boolean when the intersection itself matters; it is expensive even on modest meshes. Shape operations, remeshing and subdivision precede binding. Finish normals, UVs and material slots before constructing `ModelGeometry`. Keep collision geometry simpler than rendered detail.

After binding, use `geometry.recalculatingNormals(...)`, `geometry.projectingUV(...)` or `geometry.unwrappingUV(...)`, not a detached mesh followed by old weight arrays. These transfer skin/morph correspondence, while `geometry.coloring(...)` retains it unchanged. `geometry.applying(processingResult)` accepts an explicit `MeshProcessingResult` and `MeshVertexMap` belonging to that actual source mesh; equal vertex counts are not sufficient. Arbitrary remeshing does not infer weights or morph correspondence. Reauthor the binding when needed.

## Metric edges, automatic UVs and vertex color

The following is a complete finished prop definition, ready for the same generator/Preview or runtime pattern used below:

```swift
func makeColoredProp() throws -> ModelAssetDefinition {
    let mesh = try MeshBuilder.box(size: [1, 1.6, 0.8])
        .modifyingTopology(welding: .exactPositions) { topology in
            let edges = try topology.selectEdges { ($0.angle ?? 0) > 0.5 }
            topology = try topology.beveled(edges: edges, width: 0.06, segments: 3)
        }
        .recalculatingNormals(smoothingAngle: .pi / 3)
        .unwrappingUV(UVUnwrapOptions(padding: 4.0 / 512))
        .coloring { vertex in
            let t = min(max((vertex.position.y + 0.8) / 1.6, 0), 1)
            return RGBAColor(sRGB: [0.06, 0.22, 0.28])
                .interpolated(to: RGBAColor(sRGB: [0.4, 0.85, 0.7]), fraction: t)
        }
    let surface = MaterialDefinition(id: AnyRealitizerID("surface"), baseColor: .white,
                                     roughness: 0.35, vertexColorMode: .multiply)
    return ModelAssetDefinition(name: "Colored prop", materials: [surface],
        parts: [ModelPartDefinition(id: AnyRealitizerID("body"), mesh: mesh, material: surface.id)])
}
```

Bevels run before binding and create new local topology IDs. Coplanar faces with matching edge attributes/materials are merged before mitering, eliminating triangulation diagonals. Empty edge selections leave the topology unchanged. Widths are model-local face offsets, not world-scaled radii. Invalid selections, collapsed geometry, detected self-intersections or work-budget exhaustion throw; do not suppress those errors or silently clamp width. Rounded corners are miter patches, not spherical CAD fillets. Split problematic geometry or change the authored width/selection.

`UVUnwrapOptions(maximumNormalDeviation:padding:welding:respectMaterialBoundaries:)` defaults to pi/4, 0.005, `.exactPositions` and true. The angle must be in [0, pi/2), padding in [0, 0.5). Automatic charts are connected angle-bounded projections with overlap rejection; their rectangles pack into one unit-square atlas at a shared scale. Padding is reserved on every side, so two neighboring charts have two gutters. Four pixels at 512 resolution is `4.0 / 512`. This is deterministic charting, not a conformal solver or optimal packer. `.exactPositions` may connect touching shells; choose connectivity explicitly. Inputs above 100000 triangles, excessive overlap-check work or impossible gutters throw. Use `MeshProcessor.unwrapUV(of:options:)` to inspect `UVAtlas.islands`, `scale` and `processing`. Island triangle indices refer to the original triangle order. Apply a result after binding with `geometry.applying(atlas.processing)`. Generate UV-dependent textures/colors after the final atlas.

`MeshVertex.color` and `MeshCorner.color` default to white. `coloring` samples source vertices; `interpolated(to:fraction:)` uses linear-light RGB and linear alpha with a fraction in 0...1. Color channels must be finite and in 0...1. Colors survive finishing, topology operations, skin/morph evaluation, LOD and dynamic updates. Color detail is limited by vertex spacing; use textures for finer patterns. Boolean/remesh resampling rejects colored inputs because correspondence is unknown: color afterward, or intentionally clear with `coloring { _ in .white }` first.

## A parameterized, rigged asset

A rigid prop only needs materials and `ModelPartDefinition(id:mesh:material:)`. The following deforming fin also shows a complete rig, functional weights, morph, clip and graph. Keep its API pattern, not its specific shape or colors, when adapting it to another task.

```swift
import Realitizer
import simd

struct FinParameters: Equatable, Sendable {
    var height: Float = 1
}
enum FinError: Error { case invalidHeight }

let fin = ModelAssetGenerator(
    name: "Fin", parameters: FinParameters(), seed: 42,
    validate: { p in
        guard p.height.isFinite, (0.2...3).contains(p.height) else {
            throw FinError.invalidHeight
        }
    }
) { input in
    let h = input.parameters.height
    let root = AnyRealitizerID("root"), tip = AnyRealitizerID("tip")
    let body = AnyRealitizerID("body"), surface = AnyRealitizerID("surface")
    let sway = AnyRealitizerID("sway")
    let tipRest = ModelTransform(translation: [0, h * 0.5, 0])
    let rig = RigDefinition(id: AnyRealitizerID("fin-rig"), joints: [
        JointDefinition(id: root),
        JointDefinition(id: tip, parent: root, restTransform: tipRest)
    ])
    let mesh = try MeshBuilder.surface(
        uSegments: 2, vSegments: input.quality.surfaceSegments
    ) { uv in [(uv.x - 0.5) * 0.5, uv.y * h, 0] }
    let geometry = try ModelGeometry(mesh: mesh).binding(to: rig) { vertex in
        let t = min(max((vertex.position.y - h * 0.5) / (h * 0.5), 0), 1)
        return [JointWeight(root, weight: 1 - t), JointWeight(tip, weight: t)]
    }.addingMorph(id: AnyRealitizerID("wide")) { vertex in
        vertex.position * SIMD3<Float>(1.2, 1, 1)
    }
    var material = MaterialDefinition(id: surface,
        baseColor: RGBAColor(sRGB: [0.12, 0.55, 0.48]))
    material.doubleSided = true
    var asset = ModelAssetDefinition(name: "Fin", materials: [material],
        parts: [ModelPartDefinition(id: body, geometry: geometry, material: surface)],
        rig: rig)
    var bent = tipRest
    bent.rotation = simd_quatf(angle: 0.45, axis: [0, 0, 1])
    let pose = PoseDefinition(id: AnyRealitizerID("bent"), transforms: [.joint(tip): bent])
    asset.poses = [pose]
    asset.clips = [try AnimationClipDefinition.keyPoses(
        id: sway, duration: 2,
        frames: [PoseKeyframe(time: 0, pose: asset.restPose),
                 PoseKeyframe(time: 1, pose: pose),
                 PoseKeyframe(time: 2, pose: asset.restPose)],
        reference: asset.restPose, loopMode: .loop)]
    asset.animationGraph = AnimationGraphDefinition(id: AnyRealitizerID("motion"),
        initialState: sway, states: [AnimationStateDefinition(id: sway, clip: sway)])
    return asset
}
```

`generate()` validates the asset and aggregate geometry budget. Supply `AssetGenerationInput(parameters:seed:quality:)` to generate other inputs. `ModelQualityProfile(curveSegments:surfaceSegments:budget:)` controls tessellation and budgets; it does not automatically simplify an existing mesh. For directly created assets, call `validated()` before handing them to another system. Inspect validation diagnostics rather than substituting empty meshes or suppressing errors.

Skin weights must reference existing joints, be nonnegative and sum to one per vertex, within `maximumInfluences` (default four). `automaticallyBinding(to:)` offers distance-based initial weights, not guaranteed anatomical deformation. Rest transforms define the default pose; omitted bind transforms use the rest transforms. `addingMorph(id:position:)` returns absolute target positions. Raw `MorphTarget` arrays contain deltas. Position-only morphs use native GPU deformation; explicit normal deltas use a CPU streaming path with a different performance cost.

For rigid articulated pieces, attach parts using `parent: .joint(jointID)` instead of adding skin. Sockets are named attachment transforms: `SocketDefinition(id:parent:transform:)` belongs to `asset.sockets`. Retain semantic IDs across LODs: each `ModelGeometryLevel(minimumDistance:geometry:)` must preserve skin presence and morph IDs, though its mesh and weights can differ. Distances must increase. Keep the skinned part's transform at identity and parent unset at every level.

## Materials, color and lighting

`MaterialDefinition(id:baseColor:roughness:metallic:shading:alphaMode:)` defaults to lit and opaque. Use `.blend` for translucency or `.mask(cutoff: 0.5)` for cutouts; texture alpha alone does not enable transparency. Opacity animation requires blend/mask mode. Assign additional material IDs on a part and matching per-triangle `MeshData.materialIndices` when one mesh needs multiple slots.

`RGBAColor(sRGB:alpha:)` stores non-premultiplied sRGB plus linear alpha; `RGBAColor(linearSRGB:alpha:)` explicitly converts linear inputs. `TextureImage.generate(width:height:sample:)` makes color images; assign them to `baseColorTexture` or `emissiveTexture`. `generateData` and `normalMap` produce raw data for normal/roughness/metallic maps. Keep texture encoding consistent with its purpose.

Materials default to `vertexColorMode: .ignore`. Choose `.multiply` to combine base tint, texture and vertex RGB in linear sRGB; the renderer adapter handles working-space conversion. Vertex alpha multiplies texture and material opacity only for blend/mask modes, and the cutout threshold applies to that product. Emission remains independent. Colored lit/unlit materials retain their corresponding material channels and library scalar animation support.

Vertex-colored materials require the bundled Metal shaders. Under Xcode, `ModelRenderingResources.shared()` loads them; the compiler resolves these resources lazily when a material opts in. Native command-line SwiftPM only copies Metal sources: inject a target-compatible compiled library using `ModelRenderingResources(library:)`, then pass `resources:` to `RealityKitModelCompiler.compile` or `RealityKitMaterialCompiler.compile`. A `ModelResourceCache(capacity:resources:)` retains one resource configuration. Missing resources throw; do not discard colors, launch a production compiler subprocess or silently move native skinned models to CPU deformation. Ordinary uncolored materials need no resource setup.

Use `emissiveColor` and `emissiveIntensity` for a bright surface, plus a scene light for nearby illumination. Emission alone does not illuminate other entities or guarantee bloom. Unlit materials support base color/opacity; `unlitToneMapping = false` bypasses tone mapping for authored background colors. Custom RealityKit materials can be installed through `setMaterial(_:for:)`; not every custom shader supports the library's animated material channels.

## Animation and game integration

`AnimationClipDefinition.keyPoses` fills sparse poses from a reference. `bake(id:duration:sampleRate:reference:loopMode:pose:)` samples a function into a clip. `scalarChannels` animate morphs or material values using `ScalarAnimationChannel(target:keyframes:)`; targets are `.morph(part:target:)` and `.material(id, property)`. Morph weights are in 0...1. Graph parameters use declared `.scalar`, `.boolean` or `.trigger` kinds, and transitions use typed conditions. Layer masks define which transforms/scalars each layer owns.

Compilation and runtime Entity operations run on the main actor. Compile once per definition, create separate instances from shared compiled resources, and retain each instance and animator in its scene/controller:

```swift
import Realitizer
import RealitizerRealityKit
import RealityKit

@MainActor
final class FinRuntime {
    let compiled: CompiledModelAsset
    let instance: RuntimeModelInstance
    let animator: RuntimeModelAnimator

    init(definition: ModelAssetDefinition, parent: Entity) throws {
        compiled = try RealityKitModelCompiler.compile(definition)
        instance = try compiled.instantiate()
        animator = try instance.makeAnimator()
        parent.addChild(instance.root)
    }

    func update(deltaTime: Float) throws {
        try animator.advance(by: deltaTime)
    }
}
```

Generate the definition outside View initialization/body and the frame loop, then pass it into the runtime owner during loading. `part(_:)`, `joint(_:)` and `socket(_:)` expose semantic Entity handles. `setLevelOfDetail(_:)` switches geometry without replacing these handles; `updateLevelOfDetail(distance:)` selects by authored thresholds. Include every generation input and generator version in caller-owned cache keys.

Choose a single transform owner. Without an animator, use `setJointTransform(_:for:)`, `apply(_:)`, `sample(_:at:)` and `setMorphWeight(_:part:target:)`. `makeAnimator()` requires a graph and owns animation writes while alive; direct pose/joint/morph setters reject competing writes. Keep the animator alive and advance it with finite, nonnegative delta time. `set(_:for:)` and `activate(_:)` require declared graph parameters and throw on invalid input. Do not also move the root in gameplay when the animator applies root motion. Raw Entity edits bypass validation and ownership protection.

Constraints live in `rig.constraints`: `.inverseKinematics(InverseKinematicsConstraint(id:chain:iterations:tolerance:))`, `.lookAt(LookAtConstraint(id:joint:localAxis:weight:))`, or `.twoBoneIK(TwoBoneIKConstraint(id:root:middle:tip:tolerance:))`. IK chains must be directly connected, and solvers require unit joint scales. Supply runtime rig-space positions with `animator.setConstraintTarget(id, position: point, polePosition: pole)`; only two-bone IK accepts/requires a pole. Use `clearConstraintTarget` to deactivate one. The pole must lie outside the root-to-target axis. Solvers report reachability; the game supplies world/terrain queries. Two-bone IK preserves bone lengths rather than stretching them.

## Optional prebuilt mesh resources

Swift source is the model's source of truth; runtime generation is optional. Generate small or parameter-dependent models during loading, or bake expensive finished geometry into bundled resources during development. Keep hierarchy, rig constraints, clips, animation graphs and LOD distances in shared Swift functions. Loading code must not call a modeling generator just to recover those settings.

RealityKit supplies file I/O: `Entity.write(to:)` saves a `.reality` file, and `Entity(contentsOf:)` loads it. An ordinary prop can be used directly as a loaded Entity without a Realitizer adapter. To use Realitizer's semantic handles, animation and LOD controls, provide existing meshes through `ModelResourceDefinition`. Use `RealityKitModelCompiler.assemble` for deformation and full runtime features, or `assembleRigid` for trusted finished static or rigidly articulated assets. Both accept in-memory resources too; no file format or sidecar metadata is required.

This complete example keeps the material in code and the generated vertex-colored geometry in a file:

```swift
import Foundation
import Realitizer
import RealitizerRealityKit
import RealityKit

enum ResourcePropError: Error { case missingMesh }

func resourcePropMaterial() -> MaterialDefinition {
    MaterialDefinition(id: AnyRealitizerID("surface"), baseColor: .white,
                       roughness: 0.4, vertexColorMode: .multiply)
}

// Run in a development-time baking tool, not during gameplay loading.
@MainActor
func bakeResourceProp(to url: URL) async throws {
    let mesh = try MeshBuilder.sphere(radius: 0.5,
        latitudeSegments: 32, longitudeSegments: 48)
        .coloring { vertex in
            RGBAColor(sRGB: [0.15, 0.45 + vertex.position.y * 0.2, 0.6])
        }
    var exportMaterial = resourcePropMaterial()
    exportMaterial.vertexColorMode = .ignore
    let definition = ModelAssetDefinition(name: "Resource prop",
        materials: [exportMaterial],
        parts: [ModelPartDefinition(id: AnyRealitizerID("body"),
                                    mesh: mesh, material: exportMaterial.id)])
    let instance = try RealityKitModelCompiler.compile(definition).instantiate()
    try await instance.root.write(to: url)
}

// Run once during game loading. No mesh builder is called here.
@MainActor
func loadResourceProp(from url: URL, resources: ModelRenderingResources? = nil)
    async throws -> CompiledModelAsset
{
    let entity = try await Entity(contentsOf: url)
    guard let model = entity.findEntity(named: "mesh:body")?
        .components[ModelComponent.self] else {
        throw ResourcePropError.missingMesh
    }
    let material = resourcePropMaterial()
    let definition = ModelResourceDefinition(name: "Resource prop",
        materials: [material],
        parts: [ModelResourcePart(id: AnyRealitizerID("body"),
                                 mesh: model.mesh, material: material.id)])
    return try RealityKitModelCompiler.assemble(definition, resources: resources)
}
```

Retain the returned `CompiledModelAsset` and call `instantiate()` for independent copies. The returned `RuntimeModelInstance` has the same part/joint/socket, morph, animator and LOD APIs as a generated asset. It starts from the code-defined rest pose and zero morph weights, not the saved entity's current animation state. Assembly creates a new hierarchy and does not adopt or mutate the loaded Entity tree. Set part transforms and parents explicitly; an Entity's transform is not part of its `ModelComponent.mesh`.

Native meshes must be immutable, CPU-readable triangle resources with one model and one identity mesh instance. Finish normals, tangents, bitangents and UVs before saving. Each vertex buffer must be vertex-rate with matching counts; color is optional. Multiple material mesh parts are supported: assign `additionalMaterialIDs` in native material-index order. Skin requires a code-defined `rig` matching the native skeleton ID, ordered joint names, parents, rest transforms and inverse bind matrices. Position-only morphs are read from native buffers. Add `poses`, `clips`, `animationGraph`, `sockets` and `collisions` to the resource definition; `restPose` is available for clip authoring without reading geometry.

Set `ModelResourcePart.levelsOfDetail` to `ModelResourceLevel(minimumDistance:mesh:)` values. Supply every LOD explicitly, with increasing distances and compatible skin/morph identities. Saving one runtime root includes its active geometry only, not inactive LODs or Swift animation definitions. Bake each required level separately or construct a development-only export hierarchy containing them.

Custom shader libraries cannot be embedded by the tested `.reality` writer. The example exports with a native material and restores vertex-color shading through the code material definition. Keep shaders in the app's resource bundles. To retain already-loaded textures/materials, pass a semantic-ID dictionary through `assemble(_:materials:resources:budget:)`; supplied materials override compilation only for those IDs. Their `MaterialDefinition` values must describe the same shading, alpha mode and scalar animation defaults. Omitted IDs are compiled from code; unused supplied IDs are rejected. Command-line SwiftPM requires explicit shader resource injection for vertex-colored materials.

Assembly reuses the exact `MeshResource` objects. It reads and validates CPU arrays once to retain `definition`, `geometry(for:)`, `evaluatedMesh(for:)` and statistics; it is not zero-copy or a guarantee of faster loading. Material mesh parts may have separate CPU vertex copies. The geometry budget applies across all parts and LODs (default 500,000 vertices and triangles each). Unsupported layouts, budget excess and incompatible rigs/LODs throw; no shape generation or GPU-mesh recompilation is used as a fallback.

This path is for finished native geometry, not snapshots of arbitrary live renderers. Normal-delta CPU morphs, streaming LowLevelMesh updates, grass/wave simulation state and custom geometry-modifier behavior are not restored from these files; keep their runtime setup in code. Re-bake resources when shape or binding code changes, ship matching code/resources, and validate the exported assets on supported target OS versions. Measure generation, file loading, assembly and first rendering separately.

### Lightweight rigid loading

For trusted bundled props and rigid articulated models, `assembleRigid` avoids reconstructing CPU vertex/index arrays. It validates hierarchy, transforms, material bindings, native buffer layouts/counts, clip targets and the aggregate geometry budget, including every LOD. It does not scan vertex or index values. Validate the full geometry during baking; use full `assemble` for unvalidated resources or deformation features.

This alternative loader reads the file produced by `bakeResourceProp` above and restores vertex-color shading on its native material:

```swift
@MainActor
func loadRigidResourceProp(from url: URL, resources: ModelRenderingResources? = nil)
    async throws -> RigidModelAsset
{
    let entity = try await Entity(contentsOf: url)
    guard let model = entity.findEntity(named: "mesh:body")?
        .components[ModelComponent.self], let nativeMaterial = model.materials.first else {
        throw ResourcePropError.missingMesh
    }
    let material = resourcePropMaterial()
    let restored = try RealityKitMaterialCompiler.applyingVertexColor(
        to: nativeMaterial, definition: material, resources: resources)
    let definition = ModelResourceDefinition(name: "Resource prop",
        materials: [material],
        parts: [ModelResourcePart(id: AnyRealitizerID("body"),
                                 mesh: model.mesh, material: material.id)])
    return try RealityKitModelCompiler.assembleRigid(
        definition, materials: [material.id: restored], resources: resources)
}
```

Retain the `RigidModelAsset` and call `instantiate()` to get independent `RigidModelInstance` values. Add each instance's `root` to the scene. Meshes/materials are shared and must remain immutable; transforms and LOD selection belong to each instance. Author transforms and parents in `ModelResourceDefinition`, not by assuming the saved Entity tree will be adopted.

Use `part(_:)`, `joint(_:)`, `socket(_:)` and `meshEntity(_:)` for semantic handles; `currentPose`, `apply(_:)`, `resetPose()` and `sample(_:at:)` control rigid transforms. Clip sampling starts from the code-defined rest pose. `updateLevelOfDetail(distance:)` selects from authored thresholds; `setLevelOfDetail(_:)` selects globally. For independently measured spatial chunks, use `setLevelOfDetail(_:part:)` and inspect with `levelOfDetail(for:)`. Zero selects base geometry, and indices beyond a part's available levels select its coarsest level. Negative indices and missing IDs throw without changing the instance. LOD changes preserve semantic Entity handles and do not affect other instances.

`applyingVertexColor(to:definition:resources:)` retains native textures and restores library shader flags, emission tint and alpha controls. The native material must match the definition's shading and texture presence; an emissive texture in the definition is compiled. `.ignore` returns the native material unchanged. Bundle the matching shader resources and material definition with the archive. The same adapter works with the supplied-material dictionary of full `assemble`.

Rigid assembly rejects skinning, morphs, collisions, constraints, animation graphs, scalar animation, events and root motion; use full assembly for those features. `asset.inspect()` explicitly reads and validates CPU geometry and returns a `CompiledModelAsset` for inspection or Preview. Do not call it during ordinary lightweight loading. File layout, source hashes, rebaking and development-mode selection remain caller-owned, and neither assembly route regenerates geometry as a fallback.

## One code-controlled Preview

The following uses the `fin` generator defined above and samples its clip at a fixed time:

```swift
import Realitizer
import RealitizerPreview
import SwiftUI

@MainActor
func finPreviewOptions() -> ModelAssetPreviewOptions {
    var configuration = ModelPreviewConfiguration(selectedClipID: AnyRealitizerID("sway"))
    configuration.sampleTime = 1
    return ModelAssetPreviewOptions(configuration: configuration,
        camera: .orthographic, display: .shaded)
}

#Preview("Fin") {
    ModelAssetPreview(generator: fin, options: finPreviewOptions())
}
```

`ModelAssetPreview(generator:input:options:revision:)` lazily generates the asset; its parameters must be `Equatable` and `Sendable`. It also accepts a prebuilt definition via `asset:`. Camera options include `.perspective`, `.front`, `.back`, `.side`, `.top`, `.orthographic`; display modes include `.shaded`, `.wireframe`, `.normals`, `.uv`, `.materials`, `.bounds`, `.rig`, `.weights`, `.collisions`. Set `levelOfDetail` in options to inspect a level.

`ModelPreviewConfiguration` owns background, framing, sample time, selected clip/pose/graph state and constraint targets, not the asset. Select at most one of `selectedClipID`, `selectedPoseID`, `graphStateID`. Graph inputs require a graph state. Change Swift parameters and use Xcode MCP RenderPreview on this single Preview file; do not add sliders or playback controls. If only a generator closure or prebuilt content changes under the same live View identity, increment `revision:`.

Inspect silhouette/framing before material seams and representative deformations/LODs. A successful build or Ready label proves compilation, not a visible GPU frame. If the capture is empty/loading, inspect diagnostics and try a bounded recapture; use an available live canvas or user-authorized runtime check when needed. Do not claim visual success or inject artificial readiness delays. If capture is unavailable or explicitly skipped, complete numerical checks and report visual verification as unperformed.

## Optional grass and waves

These features need both environment products. Grass scatters a height/density function once, batches spatial chunks and animates on the GPU; do not create entities per blade. Waves update a persistent horizontal mesh, not CPU-rebuilt vertices. The following returns objects the scene must retain, together with their root:

```swift
import Realitizer
import RealitizerRealityKit
import RealitizerEnvironment
import RealitizerEnvironmentRealityKit
import RealityKit

@MainActor
func makeEnvironment(resources: EnvironmentResources) throws -> (Entity, GrassField, WaveSurfaceMesh) {
    let root = Entity()
    let meadow = try GrassFieldDefinition.scatter(
        minimum: [-2, -2], maximum: [2, 2], density: 40,
        height: 0.2...0.4, width: 0.03...0.06, seed: 42,
        surfaceHeight: { _ in 0 }, mask: { p in abs(p.x) < 0.3 ? 0 : 1 })
    let grass = try GrassField(meadow, wind: GrassWind(strength: 0.08),
        detail: GrassDetail(), appearance: GrassAppearance(
            rootColor: RGBAColor(sRGB: [0.3, 0.5, 0.1]),
            tipColor: RGBAColor(sRGB: [0.4, 0.6, 0.2])), resources: resources)
    root.addChild(grass.root)
    let mesh = try MeshBuilder.surface(uSegments: 16, vSegments: 16) { uv in
        [(uv.x - 0.5) * 8, 0, -(uv.y - 0.5) * 8]
    }
    let waves = try WaveField(waves: [DirectionalWave(
        direction: [1, 0.4], amplitude: 0.04, wavelength: 3, speed: 1)])
    let water = try WaveSurfaceMesh(mesh: mesh, field: waves, resources: resources)
    let material = try RealityKitMaterialCompiler.compile(MaterialDefinition(
        id: AnyRealitizerID("water"), baseColor: RGBAColor(sRGB: [0.03, 0.3, 0.5]),
        roughness: 0.25))
    let sea = ModelEntity(mesh: water.resource, materials: [material])
    sea.position = [0, -1, 0]
    root.addChild(sea)
    return (root, grass, water)
}
```

Prepare `EnvironmentResources.shared()` once during loading under Xcode, which compiles the bundled Metal sources. Command-line SwiftPM only copies them: inject a target-compatible compiled library with `EnvironmentResources(library:)` instead. Missing resources throw; do not add production compiler subprocesses or silent CPU fallbacks.

Update `grass.update(time:cameraPosition:)` with camera coordinates local to `grass.root` and `water.update(time:)` with explicit time. The wave update returns an already committed command buffer; never wait for its completion in a gameplay frame. Match local-space wind/light directions, times and radial fading for gameplay sampling with `WaveField.vertex(at:time:)`.

Grass root/tip colors should blend with the ground. Its shader uses approximate ambient/sun lighting, receives neither local lights nor scene shadows, and casts no shadows. LOD is discrete with hysteresis; blade bounds include wind. Waves require a horizontal rest mesh and reject folding configurations; `radialFade` can calm the outer water. They do not supply fluid simulation, reflections or updated collision geometry. Keep fields bounded and measure density/fill rate on devices. Clouds, sky art, bloom and similar style choices remain consumer-owned.

## Verification and handoff

Test the consumer's changed asset: representative parameter extremes/seeds, bounds, winding, material slots and budgets. For rigs, compare rest deformation with the source, sample actual poses/morphs and verify semantic handles after LOD changes. Build/test the affected consumer and required integration targets. If library code changes, also run `swift build`, `swift test` and `git diff --check` in the library.

Keep numerical validation, shader packaging, iOS execution, image inspection and device performance claims separate. Pure SwiftPM tests do not prove the other categories. Honor a user's request to skip Simulator verification. Hand off the model source, adjustable parameters, semantic runtime IDs, Preview entry point and checks actually completed.

Swift generation closures are trusted application code, not sandboxed input. For genuinely untrusted encoded recipes, `ModelingRecipe.decode` offers a separate closed JSON operation set with input/evaluation budgets; do not turn an ordinary Swift modeling task into a JSON workflow. This skill does not authorize publishing, installing tools or changing unrelated project settings.
