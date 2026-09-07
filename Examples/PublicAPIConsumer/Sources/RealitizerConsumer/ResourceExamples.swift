import Foundation
import Realitizer
import RealitizerRealityKit
import RealityKit

public enum ResourcePropError: Error { case missingMesh }

public func resourcePropMaterial() -> MaterialDefinition {
    MaterialDefinition(
        id: AnyRealitizerID("surface"), baseColor: .white,
        roughness: 0.4, vertexColorMode: .multiply)
}

// Run in a development-time baking tool, not during gameplay loading.
@MainActor
public func bakeResourceProp(to url: URL) async throws {
    let mesh = try MeshBuilder.sphere(
        radius: 0.5,
        latitudeSegments: 32, longitudeSegments: 48
    )
    .coloring { vertex in
        RGBAColor(sRGB: [0.15, 0.45 + vertex.position.y * 0.2, 0.6])
    }
    var exportMaterial = resourcePropMaterial()
    exportMaterial.vertexColorMode = .ignore
    let definition = ModelAssetDefinition(
        name: "Resource prop",
        materials: [exportMaterial],
        parts: [
            ModelPartDefinition(
                id: AnyRealitizerID("body"),
                mesh: mesh, material: exportMaterial.id)
        ])
    let instance = try RealityKitModelCompiler.compile(definition).instantiate()
    try await instance.root.write(to: url)
}

// Run once during game loading. No mesh builder is called here.
@MainActor
public func loadResourceProp(from url: URL, resources: ModelRenderingResources? = nil)
    async throws -> CompiledModelAsset
{
    let entity = try await Entity(contentsOf: url)
    guard
        let model = entity.findEntity(named: "mesh:body")?
            .components[ModelComponent.self]
    else {
        throw ResourcePropError.missingMesh
    }
    let material = resourcePropMaterial()
    let definition = ModelResourceDefinition(
        name: "Resource prop",
        materials: [material],
        parts: [
            ModelResourcePart(
                id: AnyRealitizerID("body"),
                mesh: model.mesh, material: material.id)
        ])
    return try RealityKitModelCompiler.assemble(definition, resources: resources)
}

@MainActor
public func loadRigidResourceProp(from url: URL, resources: ModelRenderingResources? = nil)
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
