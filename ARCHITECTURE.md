# Realitizer Architecture

## Definitions, compilation and instances

The core has three one-way layers:

1. `Realitizer` contains deterministic value types and CPU reference algorithms. It imports neither RealityKit nor SwiftUI.
2. `RealitizerRealityKit` validates and compiles definitions into reusable resources, then creates separate per-instance state.
3. `RealitizerPreview` uses the same compiler and runtime as a game.

`EditableMesh` is polygon topology with local vertex/face IDs and per-corner UVs/colors. It is intermediate data in a Swift generation function, not a persistent editor document. Spatial face/edge queries, region extrusion, solidify, metric bevel, chamfer and subdivision compose in ordinary code. Reconstructing topology from `MeshData` requires an explicit welding policy. An ID that survives a local operation is not a guarantee of correspondence between separately generated models. Bevel creates new local topology IDs.

`MeshData` is an indexed render mesh; a render vertex is not a topological vertex. Finish the shape, normals, UVs and material slots before binding by default. `ModelGeometry` then owns one immutable mesh/skin/morph payload. Parts and LODs replace this payload as a unit instead of independently mutating parallel arrays. Raw definitions are validated at explicit validation and compilation boundaries.

`MeshProcessor` produces `MeshProcessingResult` values with the actual source mesh and weighted output-to-source vertex contributions. `ModelGeometry.applying` checks that source and transfers skin and morph arrays. Normal processing only splits a source vertex when required by shading; UV projection duplicates angular-seam vertices, and atlas unwrapping duplicates chart-seam vertices. Different source indices never merge merely because their positions match. Skin transfer checks influence limits without silent pruning. Morph delta vectors interpolate in mesh space; this is not nonlinear target regeneration or remeshing correspondence inference. Shape-stage booleans, topology reconstruction and arbitrary deformations have no automatic post-binding transfer contract.

Optional `RealitizerEnvironment` depends only on core definitions. `RealitizerEnvironmentRealityKit` depends on both portable environment definitions and the renderer adapter. Core and Preview products do not depend on either environment product.

A `ModelAssetGenerator<Parameters>` combines a caller-owned parameter struct and its validator, a seed, a quality profile and a Swift generation function. Game-specific proportions, palettes and style-specific scenery generators remain in the consuming project, built on the library's mesh, texture and material primitives. An `ArtStyleProfile` supplies material replacements and a normal policy without fixing the library to one visual style.

Colors store sRGB RGB with linear alpha. Linear-light inputs use explicit conversion. Color textures are tagged sRGB; scalar and normal textures are tagged raw. Direct material compilation and asset validation use one material contract.

Vertex colors belong to `MeshVertex` and `MeshCorner`, not parallel part-owned arrays. White defaults keep uncolored geometry neutral; older encoded vertices/corners without a color decode as white. Shape operations retain or explicitly interpolate colors. Resampling rejects colored input because it has no correspondence inference. Atlas creation returns the same checked processing payload as other surface finishing, so UV seam splits retain colors, weights and morphs together.

`ModelRenderingResources` owns the optional compiled vertex-color shader library. Materials explicitly opt into multiplication; ordinary material compilation does not require this resource. The adapter uploads linear sRGB vertex values, combines them with textures/tints through explicit working-color-space conversion, and handles cutout in the shader. Both native skin/morph meshes and CPU-updated meshes carry color. The high-level RealityKit mesh API has no color convenience accessor, so the adapter obtains its semantic from a public low-level color descriptor and refills it from authored data, without hardcoding an internal buffer identifier. The wave kernel shares the dynamic vertex layout, including its retained color channel.

`MaterialAlphaMode` explicitly selects opaque, blended or masked rasterization. The compiler does not scan image alpha to decide rendering policy. Opacity channels are only valid for blend/mask materials, and animation retains the authored cutout threshold. Opaque materials have no implicit opacity entry in the animation reference state.

## Coordinate conventions

- Meters, positive y up, radians and normalized quaternions.
- Counterclockwise exterior triangle winding.
- Parts, joints and sockets store parent-local transforms.
- Rest transforms describe the default pose. Bind transforms describe the skinning reference; omitted bind transforms use rest transforms.
- Skinned parts are identity-transform roots and their vertices are in rig space. Rigid parts may attach to any part or joint.
- Morph position/normal deltas are applied in mesh space before skinning.
- CPU skin matrices are current global joint matrices multiplied by inverse global bind matrices.
- Normals use inverse-transpose transforms; mirrored geometry also reverses winding and tangent handedness.
- IK targets are rig-space positions. Solvers use unit joint scales and local XYZ Euler limits, composed as Z * Y * X.
- Constraint kinds carry dedicated configuration structs. `RigConstraintTarget` supplies a position and an optional two-bone pole. Missing targets deactivate a constraint; unknown targets and missing/unused poles are errors. Pole-controlled two-bone IK preserves bone lengths and reports the final constrained residual, including unreachable targets.
- Capsule collision height includes its two spherical caps.

`RigSignature` compares the rig ID, author-managed version and sorted joint/parent identifiers. Declaration order is irrelevant. Increment the version when changing bind conventions or compatibility. `RetargetMap` explicitly transfers rest-relative rotation and translation with axis/length corrections; it does not infer humanoid semantics.

## Animation evaluation

`AnimationClipDefinition.keyPoses` converts sparse named poses into complete transform channels using a reference pose. `bake` samples a function on an explicit endpoint-inclusive grid.

Graph evaluation follows this order:

1. Select the first eligible ordered transition; consume only its trigger conditions.
2. Sample the base state or normalized-time 1D/2D blend space. Fill sparse channels from reference values.
3. Crossfade using the declared easing. When interrupted, freeze the displayed base pose as the new transition source to avoid a pose jump.
4. Apply ordered override/additive layers with explicit transform masks and separate scalar masks.
5. Apply joint limits, IK and look-at in the runtime constraint stage.
6. Apply the resulting pose, scalar material values and morph weights.
7. Optionally accumulate root-local translation/rotation on the instance root.

Root motion is extracted from rigid hierarchy-root channels before those channels are removed from the visual pose. Blend-space root deltas and crossfades are blended too. Layers do not contribute root motion. A game may consume `AnimationFrame.rootMotion` for its movement/collision controller instead of setting `appliesRootMotion`.

Events come from the active destination state's reference clip, not every weighted clip or layer. This prevents duplicate gameplay events during blending. Forward queries use (start, end]; reverse queries use [end, start). Queries throw if their occurrence/cycle budget would be exceeded. Clip sampling supports reverse scrubbing; graph advancement requires nonnegative elapsed time. Seeking resets transitions and pending triggers and never emits historical events.

`SpringMotion` is a deterministic, closed-form critically damped evaluator for explicit procedural secondary motion and baked clips. It is not a cloth simulation or an implicit transform writer. Callers choose the joint/offset and evaluation order.

## Ownership and runtime resources

Compiled mesh/material resources are shared. Entities, animation state, morph weights, LOD selections and material overrides are not.

There are two resource construction paths. `RealityKitModelCompiler.compile` generates native resources from portable modeling results. `assemble` accepts `ModelResourceDefinition`, reuses existing native meshes and binds code-owned hierarchy/material/animation definitions. File I/O remains RealityKit's responsibility; `.reality` is an optional source of native resources, not a Realitizer archive format. Assembly reads and validates CPU geometry once to preserve the complete existing inspection/runtime API. It does not repeat shape operations or regenerate GPU meshes. Native inputs must remain immutable after assembly. The aggregate budget includes every part and LOD, including repeated CPU vertex arrays in material submeshes.

Resource assembly starts at the code-defined rest pose and creates independent entity trees. It does not adopt loaded scene entities, their animation playback state or their transforms. Only explicitly supplied mesh levels and code-owned behavior participate. Skin is checked against the supplied rig, and position morphs are recovered from native buffers. Materials may be compiled from definitions or supplied by semantic ID to reuse loaded textures; definitions remain authoritative for validation and scalar animation defaults. Live low-level renderers and CPU normal-delta deformation require their code-owned source data and setup.

Each part has a semantic parent entity and a rendering child. LOD changes the rendering child's geometry while retaining the parent, joints and sockets. Every LOD must preserve skin presence and morph identifiers; vertex counts and weights may differ. Lower-resolution recipes or authored meshes provide LOD geometry; distance thresholds select levels.

Native GPU skinning uses `MeshResource.Skeleton`, joint influences and `SkeletalPosesComponent`. Position-only morphs use native blend shape offsets/weights. Explicit normal deltas use CPU morph/skin evaluation streamed to a persistent `LowLevelMesh`; this costs CPU time but does not recreate the resource each frame.

`DynamicModelMesh.update` updates topology/vertices within fixed capacity. `updateVertices(in:with:)` streams a selected vertex range without changing indices. Both validate before writing and update bounds. They do not automatically rebuild dependent collision shapes.

`WaveField` is a deterministic CPU authoring/sampling definition. `WaveSurfaceMesh` owns immutable horizontal rest vertices, a wave parameter buffer and a fixed-topology mesh. A shared Metal compute pipeline updates positions and tangent frames without CPU readback. Conservative bounds cover all displacements, including radial fading. Each surface retains at most one unfinished committed command buffer; updates reuse it under GPU backpressure and report GPU failures on subsequent calls. Collision shapes are not updated. Gameplay surface queries use `WaveField` with matching fade settings, not a stale CPU mesh copy.

`GrassFieldDefinition` owns deterministic rooted blades; scatter samples caller-supplied height and density functions once. `GrassChunk` encodes normalized blade height and stable variation in UVs. Near geometry uses five vertices; far geometry uses three and a deterministic subset. Keep roots close to the field origin for floating-point precision. This is environmental decoration, not a collection of semantic rigged instances.

`GrassField` compiles both chunk LODs once and changes mesh references only at distance thresholds. Hysteresis prevents oscillation; there is no transparency crossfade. The field owns a single material value, updates time uniforms for enabled chunks and expands every model's bounds for wind. It never regenerates meshes, reads GPU vertices back or creates per-blade entities during animation. Frame work on the CPU scales with chunks rather than blades. Statistics report submitted geometry, not measured GPU work.

`Grass.metal` uses a geometry modifier for wind and interpolated vertex lighting, plus an inexpensive opaque surface shader. The unlit material's otherwise unused scalar PBR fields carry private lighting constants, while base/emissive colors carry the root/tip palette; these are not actual PBR properties or scene emission. Roots remain fixed through a quadratic height weight. Sun and wind use field-local space, as do LOD camera coordinates. The custom path neither receives scene light/shadow maps nor casts shadows; the consuming game must opt into these tradeoffs deliberately.

Xcode compiles grass and wave Metal resources into the optional renderer bundle. `EnvironmentResources.shared()` prepares and shares its library and wave pipeline; callers can prepare it before creating fields. Native SwiftPM does not: non-Xcode renderers inject a precompiled target-compatible `MTLLibrary`. Tests compile a host-only temporary library and compare a compute entry point sharing the same wind function with the portable CPU reference. Production never invokes a compiler subprocess. Missing shader libraries fail explicitly.

Failed graph evaluation uses a candidate value and commits only after success. Runtime application resolves all transform/material writes, computes and validates CPU deformations, and allocates any new meshes before committing. Existing dynamic buffers remain shared across successful updates. Animator time and IK reports commit only after the instance accepts the frame. Raw entity edits and asynchronous GPU/device failures are outside this invalid-input transaction guarantee.

Only one live `RuntimeModelAnimator` may own an instance. Direct pose/joint setters reject competing writes. Releasing the animator releases ownership. Raw entity handles are an intentional escape hatch: callers must coordinate writes and call `synchronizeJointEntities()` after manually editing bone entities.

Manual materials, sampled material values and visualization overlays are separate. Diagnostics never erase game/animation materials. Native PBR/unlit channels and the library's vertex-colored material channels are supported; attempting to animate an incompatible caller-supplied custom material throws.

Physics bodies live on semantic part owners so simulation moves their visuals. Each body has one non-trigger local collider, with unit local scale. Dynamic bodies cannot also have transform animation channels; graph reference-pose filling does not overwrite their simulation transforms. Compound bodies and ragdoll arbitration remain the game's responsibility. Simple collision-only children can still be combined on a hierarchy.

`ModelResourceCache` is a bounded caller-keyed LRU cache. Include generator version, all parameters, seed, style and quality in the key. It does not hash arbitrary Swift closures. `StaticModelBatch` uses GPU instance buffers for static visual assets and preserves instance/part/socket transform queries without creating an entity hierarchy per copy. Rigs, physics and per-copy animation use ordinary instances.

## Safe runtime recipes

Swift authoring functions are trusted code. They are not sandboxed by this library.

`ModelingRecipe` is a separate, closed, versioned Codable operation tree. It cannot read files, use the network or execute source code. Decode limits bytes and JSON nesting; evaluation limits operations, graph depth, intermediate/output geometry, profile sizes, arrays and cached references. Missing/cyclic references produce structured diagnostics. Seeded variation never uses randomized Swift hashing.

Use `ModelingRecipe.decode`, not a direct JSONDecoder, for untrusted encoded recipes. Resource budgets are guardrails, not a hard wall-clock deadline or an OS sandbox. Applications should additionally rate-limit requests and schedule expensive generation away from gameplay frames.

## Preview contract

`ModelAssetPreview` is a deterministic inspection surface, not a modeling editor. AI agents change Swift parameters and call RenderPreview. No parameter descriptors, sliders, inspector controls or playback loop are part of this product.

The view accepts a typed generator/input or an existing asset, plus code-defined camera, lighting, pose/time, LOD and diagnostic options. `ModelPreviewConfiguration` belongs to Preview and is validated separately from the asset. Select at most one clip, named pose or graph state. Graph inputs require a graph state; constraint targets use rig space.

View initializers and body never generate meshes. A private `@State` owns a main-actor `@Observable` model; generation runs off-main and compilation/insertion runs on the main actor. Generation revisions discard stale results. Changing inputs/options replaces viewport state. Increment the public content `revision` when changing only a closure or prebuilt asset's contents at the same live SwiftUI identity. Compilation failures are visible and never substitute placeholder geometry.

RealityKit render readiness is separate from compilation. RenderPreview can capture an empty viewport or loading indicator before the first GPU frame, even with Ready in the header. Inspect captures and retry; Ready alone is not visual proof. There is no reliable renderer-completion handshake or artificial-delay workaround.

Diagnostics include wireframes, normals, tangents, UVs, material slots, skin weights, bounds, bones, sockets, collision shapes and root/event paths. Numerical tests and snapshots complement, but do not replace, device-level performance measurements.
