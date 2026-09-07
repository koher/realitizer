# Changelog

This changelog records the contents of each release. Version 0.1.0 is the planned initial release and has not been tagged yet.

## 0.1.0 - Unreleased

### Initial release

- Code-first asset definitions, caller-owned parameter structs, seeded generators, quality profiles and structured validation.
- Procedural primitives, extrusion with holes, revolution, sweeps, lofts, parametric surfaces, convex hulls and deterministic deformation/variation operators.
- Polygon topology editing, selected metric bevels, solidification, subdivision, bounded implicit surfaces and approximate mesh booleans/remeshing.
- Normal and tangent generation, UV projection and automatic atlas packing, per-vertex colors, procedural textures, material slots, PBR/unlit materials and explicit transparency modes.
- Coherent geometry/skin/morph ownership, checked vertex correspondence, explicit/automatic weights, native RealityKit skinning and morphs, and a CPU path for normal-delta morphs.
- Semantic parts, joints and sockets; pose/clip authoring, layered animation graphs, blend spaces, events, root motion, IK, look-at, joint limits, retargeting and spring evaluation.
- RealityKit compilation and independent runtime instances, authored LODs, resource caches, static GPU batches, dynamic buffers, material overrides and physics/input configuration.
- Optional prebuilt native mesh assembly, including lightweight rigid instances, per-part LOD selection and vertex-color restoration on archive materials. Expensive geometry can be baked into `.reality` resources while runtime metadata stays in Swift.
- Optional environment products for spatially chunked, wind-driven grass and bounded GPU Gerstner waves, with configurable appearance and injectable Metal resources.
- A code-controlled SwiftUI/RealityView Preview with camera, lighting, pose/time/LOD sampling and geometry, material, rig and collision diagnostics.
- A self-contained AI authoring skill, independent public API consumer examples, and numerical, renderer-contract and shader-resource tests.
