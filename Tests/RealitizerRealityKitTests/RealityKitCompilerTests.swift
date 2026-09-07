import Realitizer
import RealitizerRealityKit
import RealityKit
import Testing

private enum MaterialID: String, RealitizerID {
    case shell
}

private enum PartID: String, RealitizerID {
    case body
}

private enum SocketID: String, RealitizerID {
    case effect
}

private enum CollisionID: String, RealitizerID {
    case body
}

@MainActor
@Test
func compilerCreatesSemanticRuntimeHandles() throws {
    let asset = ModelAssetDefinition(
        name: "Runtime Asset",
        materials: [
            MaterialDefinition(id: MaterialID.shell, baseColor: .white)
        ],
        parts: [
            ModelPartDefinition(
                id: PartID.body,
                mesh: try MeshBuilder.box(size: [1, 1, 1]),
                material: MaterialID.shell
            )
        ],
        sockets: [
            SocketDefinition(id: SocketID.effect, parent: .part(id: PartID.body))
        ],
        collisions: [
            ModelCollisionDefinition(
                id: CollisionID.body,
                parent: .part(id: PartID.body),
                shape: .box(size: [1, 1, 1])
            )
        ]
    )

    let compiled = try RealityKitModelCompiler.compile(asset)
    let instance = try compiled.instantiate()

    #expect(try instance.part(PartID.body).name == "part:body")
    #expect(try instance.socket(SocketID.effect).name == "socket:effect")
    #expect(try instance.collision(CollisionID.body).components[CollisionComponent.self] != nil)
}
