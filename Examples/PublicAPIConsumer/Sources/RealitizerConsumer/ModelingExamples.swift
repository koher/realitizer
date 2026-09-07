import Realitizer
import RealitizerRealityKit

/// Uses the production shader bundle. A build without compiled resources must fail explicitly.
@MainActor public func compileBundledFinishedProp() throws -> RuntimeModelInstance {
    try RealityKitModelCompiler.compile(makeFinishedProp(), resources: .shared()).instantiate()
}

/// One shape pipeline using metric bevels, an automatic UV atlas and functional vertex color.
public func makeFinishedProp() throws -> ModelAssetDefinition {
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
    var surface = MaterialDefinition(
        id: AnyRealitizerID("surface"), baseColor: .white,
        roughness: 0.35, vertexColorMode: .multiply)
    surface.baseColorTexture = try TextureImage.checker(
        size: 512, cells: 16,
        first: .white, second: RGBAColor(sRGB: [0.8, 0.8, 0.8]))
    return try ModelAssetDefinition(
        name: "Finished prop", materials: [surface],
        parts: [ModelPartDefinition(id: AnyRealitizerID("body"), mesh: mesh, material: surface.id)]
    ).validated()
}

/// Trusted Swift composes operations directly; there is no editor transcript or second authoring language.
public func makeHollowCylinder(radius: Float = 0.5, height: Float = 1) throws -> MeshData {
    let outside = try MeshBuilder.cylinder(radius: radius, height: height, segments: 24)
    let cutter = try MeshBuilder.cylinder(radius: radius * 0.6, height: height * 1.2, segments: 24)
    return try outside.boolean(.subtraction, with: cutter, resolution: 20)
        .projectingUV(.cylindrical(axis: .y, scale: [1, 1]))
}

public func makeArticulatedColumn(height: Float = 1) throws -> ModelAssetDefinition {
    let root = AnyRealitizerID("root")
    let tip = AnyRealitizerID("tip")
    let surface = AnyRealitizerID("surface")
    let shape = try MeshBuilder.box(size: [0.5, height, 0.5]).modifyingTopology(
        welding: .exactPositions
    ) { topology in
        let top = topology.selectFaces { $0.normal.y > 0.99 }
        try topology.extrude(faces: top, offset: [0, height * 0.3, 0])
    }.projectingUV(.cylindrical(axis: .y, scale: [1, 1]))
    let rig = RigDefinition(
        id: AnyRealitizerID("column"),
        joints: [
            JointDefinition(id: root),
            JointDefinition(
                id: tip, parent: root,
                restTransform: ModelTransform(translation: [0, height * 0.5, 0])),
        ])
    let geometry = try ModelGeometry(mesh: shape).binding(to: rig) { vertex in
        let t = min(max(vertex.position.y / height, 0), 1)
        return [JointWeight(root, weight: 1 - t), JointWeight(tip, weight: t)]
    }.addingMorph(id: AnyRealitizerID("expand")) { vertex in
        vertex.position * [1.2, 1, 1.2]
    }
    return try ModelAssetDefinition(
        name: "Articulated column", materials: [MaterialDefinition(id: surface, baseColor: .white)],
        parts: [
            ModelPartDefinition(
                id: AnyRealitizerID("column"), geometry: geometry, material: surface)
        ], rig: rig
    ).validated()
}
