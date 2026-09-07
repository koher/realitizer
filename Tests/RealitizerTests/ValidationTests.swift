import Realitizer
import Testing

private enum MaterialID: String, RealitizerID {
    case shell
}

private enum PartID: String, RealitizerID {
    case body
}

private enum RigID: String, RealitizerID {
    case character
}

private enum JointID: String, RealitizerID {
    case root
    case child
}

@Test
func validAssetHasNoDiagnostics() throws {
    let asset = ModelAssetDefinition(
        name: "Validated Asset",
        materials: [
            MaterialDefinition(id: MaterialID.shell, baseColor: .white)
        ],
        parts: [
            ModelPartDefinition(
                id: PartID.body,
                mesh: try MeshBuilder.box(size: [1, 1, 1]),
                material: MaterialID.shell
            )
        ]
    )

    #expect(asset.validationReport().diagnostics.isEmpty)
}

@Test
func validatorReportsRigCyclesWithStableCodes() throws {
    let asset = ModelAssetDefinition(
        name: "Cyclic Rig",
        materials: [MaterialDefinition(id: MaterialID.shell, baseColor: .white)],
        parts: [
            ModelPartDefinition(
                id: PartID.body,
                mesh: try MeshBuilder.box(size: [1, 1, 1]),
                material: MaterialID.shell,
                parent: .joint(id: JointID.root)
            )
        ],
        rig: RigDefinition(
            id: RigID.character,
            joints: [
                JointDefinition(id: JointID.root, parent: JointID.child),
                JointDefinition(id: JointID.child, parent: JointID.root),
            ]
        )
    )

    let codes = asset.validationReport().diagnostics.map(\.code)

    #expect(codes.filter { $0 == "joint.hierarchyCycle" }.count == 2)
}
