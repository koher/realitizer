# Realitizer

Realitizer is a code-first 3D modeling and animation library for RealityKit. Define a game asset in Swift, validate it, inspect it through one Xcode Preview, and use the same semantic parts, bones, sockets and animations in gameplay.

The primary authoring interface is a Swift API, including for AI agents. Edit Swift source, regenerate the asset, and inspect it in Preview. Modeling operations are composable calculations inside that code, not commands recorded in a persistent editor session. Realitizer is a focused game-asset toolkit, not a recreation of Blender or a particular game's art style.

For a first asset, follow the package setup, model/Preview example and gameplay example below. For shape operations and rigging, continue with [MODELING.md](MODELING.md); for coordinate spaces and runtime ownership, use [ARCHITECTURE.md](ARCHITECTURE.md). AI agents can use [Skill/SKILL.md](Skill/SKILL.md), a self-contained authoring workflow with API examples and contracts. The skill does not require those other documents or install/register itself with an agent tool.

## Demo

Try **REALITIZER** in [Mugen no Game for iOS](https://apps.apple.com/jp/app/id6800794420). REALITIZER is a technical demo of this library, showcasing code-authored 3D models, materials and animation in an interactive scene.

## Capabilities

| Area | Implemented APIs |
| --- | --- |
| Surfaces | Primitives, concave profiles with holes, extrusion, revolution, parallel-transport sweeps, lofts, parametric surfaces and convex hulls |
| Shape processing | Explicit topology welding, spatial face/edge queries, region extrusion, face inset, open-surface solidification, selected metric bevels, convex chamfer and Catmull-Clark subdivision |
| Variation | Mirror, arrays, bend, twist, taper, seeded displacement, parameterized generators, quality profiles and versioned JSON recipes |
| Appearance | Shared hard/smooth vertices, tangents, UV projection and automatic atlas charting/packing, functional vertex colors, material slots, procedural textures, PBR/unlit shading and explicit opaque/blend/cutout modes |
| Optional environment | Wind-driven grass, bounded Gerstner waves and analytic surface normals/tangents |
| Rigging | Coherent mesh/skin/morph payloads, checked correspondence for post-binding processing, explicit/automatic weights, GPU skinning and semantic sockets |
| Animation | Pose-based authoring, procedural baking, scalar channels, bounded events, masks, additive layers, 1D/2D blend spaces, interruptible transitions and root motion |
| Constraints | Typed constraint definitions, joint limits, CCD and pole-controlled two-bone IK with reachability reports, look-at, retarget maps and spring evaluation |
| Runtime | Code-generated or prebuilt native mesh resources, isolated instance state, stable LOD handles, material overrides, dynamic buffer updates, static GPU batches and physics/input components |
| Preview | Code-configured camera, lighting, deterministic pose/time/graph/IK samples, LOD and geometry/rig diagnostics |

See [MODELING.md](MODELING.md) for a workflow and the supported domains of each modeling operation. Some operations are intentionally restricted: chamfer works on closed convex topology; booleans are voxel-resolution approximations; LODs are authored or regenerated at different resolutions, not automatically decimated.

## Authoring stages

1. **Build the shape.** Compose `MeshBuilder`, `MeshData` operations and, where needed, a local `modifyingTopology` block. Ordinary Swift functions, loops and caller-owned parameter structs are the modeling language.
2. **Finish the surface.** Choose normals, UVs, vertex colors and material slots. Generate during loading or bake finished geometry into resources during development, never in the animation loop.
3. **Bind geometry.** `ModelGeometry` groups a finished mesh, its skin and its morphs. Attach the whole value to a part or LOD. There are no independently mutable part-level vertex/weight arrays.
4. **Assemble and animate.** Name parts, joints and sockets; author poses/clips; compile once and instantiate. Gameplay uses those same semantic IDs.

For normal/UV changes after binding, use `ModelGeometry.recalculatingNormals`, `projectingUV` or `unwrappingUV`. They transfer correspondence automatically; `coloring` also preserves bindings. Advanced processors return `MeshProcessingResult` with a checked source and weighted output-to-input map; applying a result from another source is an error. Arbitrary remeshing, boolean operations and topology reconstruction remain shape-stage operations: they do not guess skin or morph correspondence.

## Bevel, unwrap and color in code

```swift
import Realitizer

func makeFinishedAsset() throws -> ModelAssetDefinition {
    let finishedMesh = try MeshBuilder.box(size: [1, 1.6, 0.8])
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
    return ModelAssetDefinition(name: "Finished prop", materials: [surface],
        parts: [ModelPartDefinition(id: AnyRealitizerID("body"), mesh: finishedMesh, material: surface.id)])
}
```

`beveled` uses a metric offset along each incident face, not a face-relative fraction. It accepts closed planar-faced manifolds, including concave shapes. Coplanar triangulation diagonals with matching attributes/materials are dissolved before mitering. One segment produces flat bands; additional segments produce circular edge profiles with mitered/triangulated corner patches, not spherical CAD fillets. Invalid selections, collapsed faces and detected self-intersections throw instead of silently reducing the requested width. Perform bevels before binding.

`unwrappingUV` automatically forms connected angle-bounded charts, rejects overlap within a projected chart, and packs their rectangles into a single unit-square atlas. All charts share a uniform scale. Padding is reserved on every side of every island; use texture resolution to convert pixels into UV units. This is deterministic projection-based charting, not conformal unwrapping or optimal packing. Use `MeshProcessor.unwrapUV(of:options:)` to inspect `UVAtlas.islands`, `scale` and its checked `processing` result. Reapply UV-dependent colors/textures when changing the atlas.

`MeshVertex.color` and `MeshCorner.color` default to white. `coloring` samples source vertices, and `RGBAColor.interpolated` interpolates in linear light. Colors survive topology operations, normal/UV splitting, skinning, morphs, LOD and dynamic updates. Resampling cannot infer color correspondence: booleans/remeshing reject colored inputs. Color afterward, or explicitly clear colors with `coloring { _ in .white }` first.

Materials opt in with `vertexColorMode: .multiply`; `.ignore` is the default. Base tint, texture and vertex RGB multiply in linear sRGB, with conversion at the RealityKit working-color-space boundary. Vertex alpha multiplies texture/material opacity only in blend/mask modes, and emission remains independent. Both lit and unlit colored materials support their usual channels and library scalar animations.

Vertex-colored materials use bundled Metal shaders. Xcode compiles them automatically. `ModelRenderingResources.shared()` prepares the library during loading; command-line SwiftPM consumers must supply a target-compatible compiled library through `ModelRenderingResources(library:)` and `RealityKitModelCompiler.compile(_:resources:)` (or the material compiler's `resources:` argument). Missing shaders throw, without silently discarding colors or switching skinned models to CPU deformation. Ordinary materials need no shader resource argument.

## Package products

Requires Swift 6.3 and iOS 26 or macOS 26.

- `Realitizer`: RealityKit-independent geometry, rigs, animation and diagnostics.
- `RealitizerRealityKit`: compilation, resource sharing and runtime instances.
- `RealitizerPreview`: the code-configured SwiftUI / RealityView inspection viewport.
- `RealitizerEnvironment`: optional portable grass and wave definitions.
- `RealitizerEnvironmentRealityKit`: optional grass/wave rendering and shared shader preparation.

Add the repository as a package dependency, then select the products needed by your target:

```swift
.package(url: "https://github.com/koher/realitizer.git", branch: "main")

.product(name: "Realitizer", package: "realitizer")
.product(name: "RealitizerRealityKit", package: "realitizer")
.product(name: "RealitizerPreview", package: "realitizer")
```

The API is pre-release. Pin an exact commit for production until versioned releases are available.

Use meters, positive y up, radians, normalized quaternions and counterclockwise exterior triangles. Parts and joints use parent-local transforms. Skinned meshes are authored in rig space on identity-transform root parts; move the resulting instance root to place the asset in the world. Keep stable semantic IDs for parts, joints, sockets and animations, not render-vertex indices.

## Define and preview an asset

Generation is lazy: neither the view initializer nor its body builds a mesh.

```swift
import Realitizer
import RealitizerPreview
import SwiftUI

struct VesselParameters: Equatable, Sendable {
    var height: Float = 1
}

let vessel = ModelAssetGenerator(
    name: "Vessel",
    parameters: VesselParameters()
) { input in
    let height = input.parameters.height
    let mesh = try MeshBuilder.revolve(
        profile: [[0,0], [0.3,0], [0.4,height * 0.6],
                  [0.22,height], [0,height]],
        segments: input.quality.curveSegments
    )
    return ModelAssetDefinition(
        name: "Vessel",
        materials: [
            MaterialDefinition(id: AnyRealitizerID("ceramic"),
                baseColor: RGBAColor(red: 0.1, green: 0.6, blue: 0.5))
        ],
        parts: [
            ModelPartDefinition(id: AnyRealitizerID("body"),
                mesh: mesh, material: AnyRealitizerID("ceramic"))
        ]
    )
}

#Preview("Vessel") {
    ModelAssetPreview(generator: vessel)
}
```

Use Xcode MCP's `RenderPreview` on this file. The result is a fixed sample. Change Swift parameters and render again; no sliders, inspector editor or playback controls are installed. `ModelAssetPreview(asset:)` also accepts an existing definition.

Known limitation: automated static captures can race RealityKit initialization and show an empty viewport. Always inspect the image; retry or confirm in the live canvas when this occurs. The Ready label confirms compilation, not that a GPU frame was captured.

For a repeatable diagnostic image, pass `options: .init(camera: .orthographic, display: .rig, levelOfDetail: 1)` to the same view. These options do not require another preview declaration.

Pass a typed `AssetGenerationInput` through `input:` to change parameters, seed or quality without defining another generator. Define domain-specific checks with the generator's `validate:` closure. Parameters are dedicated caller-owned structs, not string-keyed dictionaries.

`ModelAssetPreviewOptions.configuration` holds background/framing, a selected clip/pose/graph state, sample time, graph inputs and constraint targets. All settings live in the Preview product, not `ModelAssetDefinition`. A preview configuration error cannot invalidate a game asset. Parameter/input and option changes replace viewport state. If only a generator closure or prebuilt asset's contents change within the same live SwiftUI identity, increment `revision:`; closures are not automatically compared.

The included [surface study](Sources/RealitizerPreview/RealitizerPreviewDemo.swift) demonstrates lofted geometry, explicit skin weights, morph animation, a rig-attached part, sockets and two geometry levels in a single preview.

## Use the same asset in gameplay

Run compilation, instantiation and runtime Entity operations on the main actor. Retain the instance in the consuming scene/controller and add its `root` to the scene once; do not regenerate or compile the model in a SwiftUI `body` or a frame loop.

```swift
import RealitizerRealityKit

let definition = try vessel.generate()
let compiled = try RealityKitModelCompiler.compile(definition)
let first = try compiled.instantiate()
let second = try compiled.instantiate()

let body = try first.part(AnyRealitizerID("body"))
body.isEnabled = true
// Add first.root and second.root to your RealityView scene.
```

For rigged assets, `setJointTransform(_:for:)` synchronizes bone entities and skinning. `makeAnimator()` creates an exclusive per-instance graph controller; drive it with parameters, triggers and elapsed time. `setLevelOfDetail(_:)` changes rendering resources without replacing semantic handles.

Typed enums can conform to `RealitizerID`. Use `.joint(id: Joint.elbow)` or `.part(id: Part.body)` for typed hierarchy/animation references, and `.joint(erasedID)` / `.part(erasedID)` for erased IDs. The explicit label avoids overloaded enum-case ambiguity.

## Optional prebuilt mesh resources

Swift source is the model's source of truth; runtime generation is optional. Generate small or parameter-dependent models during loading, or bake expensive finished geometry into bundled resources during development. Keep hierarchy, rig constraints, clips, animation graphs and LOD distances in shared Swift functions. Loading code must not call a modeling generator just to recover those settings.

RealityKit supplies file I/O: `Entity.write(to:)` saves a `.reality` file, and `Entity(contentsOf:)` loads it. An ordinary prop can be used directly as a loaded Entity without a Realitizer adapter. To use Realitizer's semantic handles, animation and LOD controls, provide existing meshes through `ModelResourceDefinition` and call `RealityKitModelCompiler.assemble`. This accepts in-memory resources too; no file format or sidecar metadata is required.

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

### Lightweight rigid resources

For finished static or rigidly animated assets, `assembleRigid` avoids CPU vertex/index reconstruction. It checks hierarchy references, transforms, material bindings, native buffer layouts/counts, clip targets and the aggregate geometry budget. It does not scan vertex values or triangle index values: perform full geometry validation when baking trusted bundled resources. Use full `assemble` for unvalidated input or deformation features.

```swift
@MainActor
func instantiateRigidProp(_ definition: ModelResourceDefinition,
                          materials: [AnyRealitizerID: any Material]) throws -> RigidModelInstance {
    let asset = try RealityKitModelCompiler.assembleRigid(definition, materials: materials)
    let instance = try asset.instantiate()
    try instance.updateLevelOfDetail(distance: 30)
    return instance
}
```

Retain `RigidModelAsset` for repeated instances. Its `definition` contains native resources and small code-owned metadata. `RigidModelInstance` exposes `root`, `part`, `joint`, `socket`, `meshEntity`, `currentPose`, `apply`, `resetPose`, transform-clip `sample`, and LOD controls. Copies share meshes/materials while retaining independent transforms and LOD selection. Treat shared meshes as immutable; edit authoring code and bake again to change shape. Sampling starts from the rest pose, and LOD changes preserve semantic Entity handles.

Use `instance.setLevelOfDetail(index, part: id)` for spatial chunks whose LOD distances are measured independently. Other parts and other instances retain their levels. Like the global setter, nonnegative indices beyond a part's levels select its coarsest level; missing IDs and negative indices throw without modifying the instance.

For native archive materials that need library vertex-color shading, call `RealityKitMaterialCompiler.applyingVertexColor(to:definition:resources:)` before supplying the materials to assembly. The native material must already match the definition's shading and texture presence. The adapter retains loaded textures and restores the shader flags, emission tint and alpha controls; an emissive texture in the definition is compiled. `.ignore` leaves the native material unchanged. Keep the matching definition and shader resources with the archive.

Skinning, morphs, collisions, constraints, animation graphs, scalar animation, events and root motion require full assembly and are rejected by this route. For explicit CPU geometry inspection, call `asset.inspect()` to obtain a `CompiledModelAsset`; normal loading and instantiation never call it. Both routes reuse supplied native textures/materials and never regenerate geometry as a fallback. File I/O, archive layout, source hashes, rebaking and development-mode selection remain the consuming game's responsibility.

## Author moving surfaces

Style-specific scenery generators belong in the consuming project. Use
`TextureImage.generate`, mesh builders and material definitions to implement
the project's art direction without adding style-specific APIs to the library.

Set `MaterialDefinition.unlitToneMapping = false` for authored unlit colors
that should bypass RealityKit's post-process tone map. It defaults to `true` to
preserve existing materials and is ignored by lit materials. Keep visible
backgrounds separate from the lighting environment when art changes should not
recolor the scene.

```swift
import RealitizerEnvironment
import RealitizerEnvironmentRealityKit
import RealityKit

let resources = try EnvironmentResources.shared() // Prepare once during scene loading.
let waves = try WaveField(waves: [
    DirectionalWave(direction: [1, 0.4], amplitude: 0.27,
                    wavelength: 11, speed: 1.8),
    DirectionalWave(direction: [-0.3, 1], amplitude: 0.12,
                    wavelength: 6.3, speed: 1.2, phase: 1.2)
])
let restPositions = mesh.vertices.map(\.position)
var animatedVertices = mesh.vertices
try waves.updateVertices(&animatedVertices, restPositions: restPositions, time: 2)
// CPU reference, useful for sampling and offline authoring.

// For a large horizontal surface, use the GPU runtime bridge on the main actor:
let water = try WaveSurfaceMesh(mesh: mesh, field: waves, radialFade: 75...130, resources: resources)
let entity = ModelEntity(mesh: water.resource, materials: [waterMaterial])
try water.update(time: 2) // Already committed; never wait for the GPU in a frame.
```

The wave field moves vertices in all three axes and produces analytic normals and
tangents while preserving UVs and tangent handedness. It rejects folding configurations.
Use `maximumVerticalDisplacement` for conservative water bounds and `vertex(at:time:)`
for independent surface samples. This is a procedural surface, not a fluid simulation.
`WaveSurfaceMesh` (in `RealitizerEnvironmentRealityKit`) uses one shared Metal compute pipeline,
retains immutable rest vertices and replaces the entire low-level vertex buffer on the GPU.
It preserves the mesh's UV tangent orientation and expands culling bounds conservatively.
Optional radial fading includes its derivative in the normal calculation. Rest meshes must
be horizontal, within one million meters of the origin; time and phase are limited to
one million seconds/radians. An unfinished update is reused instead of queuing unbounded
work. The returned committed command buffer supports completion/error inspection; a GPU
failure is also reported by the next update. CPU reference data is not updated or read back.
Use `WaveField` for gameplay sampling (apply the same fade when sampling a faded surface).
The surface renderer does not implement screen-space or planar reflections.
Likewise, emissive materials make a surface appear bright but do not illuminate other
entities: pair a glowing asset with a RealityKit light when the scene needs light spill.

## Grow wind-driven grass

`GrassFieldDefinition` scatters upright, rooted blades over a height function with a
seeded, jittered grid and a continuous density mask. It is independent of RealityKit
and can be generated off the main actor. The mask excludes paths, water or bare rock.
Author a ground color that matches the grass roots: distant grass eventually disappears.

```swift
let meadow = try GrassFieldDefinition.scatter(
    minimum: [-12, -12], maximum: [12, 12], density: 70,
    height: 0.35...0.75, width: 0.04...0.08, seed: 621,
    surfaceHeight: { p in sin(p.x * 0.2) * 0.3 },
    mask: { p in abs(p.y) < 1.5 ? 0 : 1 }
)

// On the main actor, once. Retain the field alongside your other runtime objects.
let grass = try GrassField(meadow, wind: GrassWind(strength: 0.24),
                          detail: GrassDetail(),
                          appearance: GrassAppearance(
                              rootColor: RGBAColor(sRGB: [0.3, 0.5, 0.1]),
                              tipColor: RGBAColor(sRGB: [0.4, 0.6, 0.2])),
                          resources: resources)
sceneRoot.addChild(grass.root)

// In the game's frame loop. Explicit time supports pause, replay and scrubbing.
try grass.update(time: elapsedSeconds,
    cameraPosition: grass.root.convert(position: cameraPosition, from: sceneRoot))
```

Near blades use five vertices and three triangles; distant blades use three vertices
and one triangle with a stable, lower-density subset. Geometry is batched into spatial
chunks, cached once, and selected by camera distance with hysteresis. There is no entity,
animation controller, collision shape or per-frame CPU vertex update per blade. Bounds
include the maximum wind offset. RealityKit also performs its ordinary frustum culling.
`statistics` counts enabled chunks, blades and triangles, not GPU draw calls or timings.

Wind combines spatial gusts and independent flutter in a geometry modifier, keeping roots
fixed. `GrassWind.offset` is the matching CPU reference, not a runtime update requirement.
The shader is texture-free, opaque and double-sided: it does not use alpha cards, sorting,
discard or PBR lighting. `GrassAppearance` controls the root/tip palette and approximate
ambient, wrapped sunlight and transmission. Sun and wind directions are field-local.
This is not Roblox's implementation, nor a claim of zero GPU cost.

Tradeoffs: the grass does not receive scene shadows or local lights and does not cast
shadows, bend around characters, simulate collisions, or preserve blade length exactly.
LOD changes are discrete, not crossfades; hysteresis prevents boundary oscillation.
Use modest wind strengths relative to blade height. Dense fields still consume vertex
bandwidth and fill rate; measure them on your target devices. Keep roots near the local
origin and transform `root` to place a field. Distances and wind are local-space meters,
so scale changes also scale their apparent range. Scatter samples and blade counts are
limited to 200,000 per field, with at most 1,024 occupied chunks; larger worlds should
use streamed, bounded fields.

Xcode compiles `RealitizerEnvironmentRealityKit/Shaders/*.metal` into its resource bundle. Both renderers share `EnvironmentResources`; call `shared()` during loading, or inject `EnvironmentResources(library:)` for explicit device/build-system ownership. This prepares the library and wave compute pipeline; RealityKit still controls its own render-pipeline compilation. Command-line SwiftPM copies source files, so non-Xcode applications must supply a target-compatible compiled library. Resource and pipeline failures throw `EnvironmentResourceError` with context, without a silent CPU fallback or production compiler subprocess.

## Color and failure contracts

Materials default to `alphaMode: .opaque`, even when a color or texture has alpha. Choose `.blend` for translucent surfaces or `.mask(cutoff: 0.5)` for cutouts. Opacity animation requires blend or mask mode. An emissive surface does not light its surroundings; scene lighting is a separate responsibility.

`RGBAColor(red:green:blue:alpha:)` and `RGBAColor(sRGB:alpha:)` use non-premultiplied sRGB channels and linear alpha. `RGBAColor(linearSRGB:alpha:)` converts linear light inputs; `linearSRGB` exposes decoded RGB for calculations. Existing numeric color literals keep their sRGB appearance.

`TextureImage.generate` writes sRGB color bytes. `generateData` writes raw channels without gamma correction; `normalMap` also returns raw data. Color/emission textures require `.sRGB`; normal/roughness/metallic textures require `.raw`. Imported pixel arrays specify `encoding:`. Direct material compilation and asset compilation share the same material validator.

Graph construction validates clips, parameters, transitions and layers. Graph/animator `set` and `activate` now throw for unknown IDs, incorrect kinds or non-finite scalar inputs. Failed graph advance/seek preserves time, transitions and pending triggers. Runtime pose/morph/LOD updates prepare transforms, materials and deformations before publishing; invalid input leaves previous entities, weights and buffers intact. Raw Entity writes are caller-owned and cannot be rolled back by the library.

## Design and verification

See [ARCHITECTURE.md](ARCHITECTURE.md) for coordinate spaces, evaluation order, ownership, cache keys, LOD and runtime safety. [CHANGELOG.md](CHANGELOG.md) records API changes.

```sh
swift build
swift test
git diff --check
```

[PublicAPIConsumer](Examples/PublicAPIConsumer) is a separate Swift package that imports public products without `@testable`. Its iOS tests load the real Xcode-built shader bundles, instantiate vertex-colored geometry and run both environment renderers. Run:

```sh
cd Examples/PublicAPIConsumer
swift build
swift test
xcodebuild test -scheme RealitizerConsumer -destination 'platform=iOS Simulator,name=iPhone 17e'
```

Tests cover geometric invariants, topology operations, recipe limits, animation regressions and RealityKit resource/instance contracts. Device-specific frame time and visual suitability still need measurement in each consuming game.

## Contributions and license

This project does not accept issues, pull requests or external contributions. If you need changes or fixes, please fork the repository and maintain your own version. See [CONTRIBUTING.md](CONTRIBUTING.md) for the maintenance policy.

Realitizer is available under the [MIT License](LICENSE).
