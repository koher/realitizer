import Foundation
import Realitizer
import RealitizerRealityKit
import RealityKit
import Testing
import simd

@Suite(.serialized) @MainActor
struct RigidModelTests {
    private let part = AnyRealitizerID("flag")
    private let joint = AnyRealitizerID("mast")
    private let material = AnyRealitizerID("cloth")

    @Test func savedLODResourcesKeepHandlesMotionAndIndependentInstances() async throws {
        let (source, definition) = try fixture()
        let folder = FileManager.default.temporaryDirectory.appending(path: "RigidModelTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var loaded = definition
        for index in 0...1 {
            let mesh = index == 0 ? definition.parts[0].mesh : definition.parts[0].levelsOfDetail[0].mesh
            let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
            let url = folder.appending(path: "level-\(index).reality")
            try await entity.write(to: url)
            let saved = try await Entity(contentsOf: url)
            let component = try #require(saved.components[ModelComponent.self])
            if index == 0 { loaded.parts[0].mesh = component.mesh }
            else { loaded.parts[0].levelsOfDetail[0].mesh = component.mesh }
        }
        let asset = try RealityKitModelCompiler.assembleRigid(loaded)
        let first = try asset.instantiate(), second = try asset.instantiate()
        let handle = try first.part(part), socket = try first.socket(AnyRealitizerID("tip"))
        #expect(try first.meshEntity(part).model?.mesh === loaded.parts[0].mesh)
        #expect(try second.meshEntity(part).model?.mesh === loaded.parts[0].mesh)
        try first.sample(AnyRealitizerID("wave"), at: 0.5)
        #expect(try first.joint(joint).position.x == 0.5)
        #expect(try second.joint(joint).position.x == 0)
        try first.updateLevelOfDetail(distance: 20)
        #expect(try first.meshEntity(part).model?.mesh === loaded.parts[0].levelsOfDetail[0].mesh)
        #expect(try second.levelOfDetail(for: part) == 0)
        #expect(try first.part(part) === handle)
        #expect(try first.socket(AnyRealitizerID("tip")) === socket)
        try first.updateLevelOfDetail(distance: 19.99)
        #expect(try first.meshEntity(part).model?.mesh === loaded.parts[0].mesh)
        try first.resetPose()
        #expect(first.currentPose.transforms == source.restPose.transforms)
        // CPU reconstruction is an explicit inspection operation, separate from normal loading.
        let inspected = try asset.inspect()
        #expect(inspected.definition.parts[0].geometry.mesh == source.parts[0].geometry.mesh)
        #expect(inspected.definition.parts[0].levelsOfDetail[0].geometry.mesh == source.parts[0].levelsOfDetail[0].geometry.mesh)
    }

    @Test func individualPartsSelectIndependentLevelsWithoutReplacingHandles() throws {
        let (_, source) = try fixture()
        var definition = source
        var neighbor = ModelResourcePart(id: AnyRealitizerID("neighbor"), mesh: source.parts[0].mesh,
            material: source.parts[0].materialID, parent: source.parts[0].parent)
        neighbor.levelsOfDetail = source.parts[0].levelsOfDetail
        definition.parts.append(neighbor)
        let asset = try RealityKitModelCompiler.assembleRigid(definition)
        let first = try asset.instantiate(), second = try asset.instantiate()
        let handle = try first.part(part), socket = try first.socket(AnyRealitizerID("tip"))
        try first.setLevelOfDetail(99, part: part)
        #expect(try first.levelOfDetail(for: part) == 1)
        #expect(try first.levelOfDetail(for: neighbor.id) == 0)
        #expect(try second.levelOfDetail(for: part) == 0)
        #expect(try first.meshEntity(part).model?.mesh === source.parts[0].levelsOfDetail[0].mesh)
        #expect(try first.part(part) === handle)
        #expect(try first.socket(AnyRealitizerID("tip")) === socket)
        #expect(throws: RuntimeModelError.self) { try first.setLevelOfDetail(-1, part: part) }
        #expect(throws: RuntimeModelError.self) { try first.setLevelOfDetail(0, part: AnyRealitizerID("missing")) }
        #expect(try first.levelOfDetail(for: part) == 1)
        try first.setLevelOfDetail(0, part: part)
        #expect(try first.meshEntity(part).model?.mesh === source.parts[0].mesh)
    }

    @Test func invalidControlUpdatesAreAtomic() throws {
        let (_, definition) = try fixture()
        let instance = try RealityKitModelCompiler.assembleRigid(definition).instantiate()
        let before = instance.currentPose
        var invalid = before
        invalid.transforms[.joint(joint)] = ModelTransform(translation: [1, 0, 0])
        invalid.transforms[.part(AnyRealitizerID("missing"))] = .identity
        #expect(throws: RuntimeModelError.self) { try instance.apply(invalid) }
        #expect(instance.currentPose.transforms == before.transforms)
        #expect(throws: RuntimeModelError.self) { try instance.setLevelOfDetail(-1) }
        #expect(throws: RuntimeModelError.self) { try instance.updateLevelOfDetail(distance: .nan) }
        #expect(try instance.levelOfDetail(for: part) == 0)
    }

    @Test func metadataAndAggregateBudgetAreCheckedBeforeInstantiation() throws {
        let (_, original) = try fixture()
        var definition = original
        definition.parts[0].parent = .part(part)
        #expect(throws: ModelResourceError.self) { try RealityKitModelCompiler.assembleRigid(definition) }
        definition = original
        definition.parts[0].levelsOfDetail[0].minimumDistance = 0
        #expect(throws: ModelResourceError.self) { try RealityKitModelCompiler.assembleRigid(definition) }
        #expect(throws: ModelResourceError.self) {
            try RealityKitModelCompiler.assembleRigid(original, budget: GeometryBudget(maximumVertices: 1))
        }
        definition = original
        definition.parts.append(definition.parts[0])
        #expect(throws: ModelResourceError.self) { try RealityKitModelCompiler.assembleRigid(definition) }
        #expect(throws: ModelResourceError.self) {
            try RealityKitModelCompiler.assembleRigid(original, materials: [AnyRealitizerID("missing"): UnlitMaterial()])
        }
        definition = original
        definition.clips[0].channels[0].target = .part(AnyRealitizerID("missing"))
        #expect(throws: ModelResourceError.self) { try RealityKitModelCompiler.assembleRigid(definition) }
    }

    @Test func deformingMeshesAreRejectedRatherThanLosingTheirBinding() throws {
        let (source, original) = try fixture()
        let geometry = try source.parts[0].geometry.addingMorph(id: AnyRealitizerID("wide")) { $0.position * 2 }
        var asset = source
        asset.parts[0].geometry = geometry
        asset.parts[0].levelsOfDetail = []
        let generated = try RealityKitModelCompiler.compile(asset).instantiate()
        var definition = original
        definition.parts[0].mesh = try generated.meshEntity(part).model!.mesh
        definition.parts[0].levelsOfDetail = []
        #expect(throws: ModelResourceError.self) { try RealityKitModelCompiler.assembleRigid(definition) }
    }

    private func fixture() throws -> (ModelAssetDefinition, ModelResourceDefinition) {
        let near = try MeshBuilder.box(size: [1, 1, 0.1]).projectingUV(.planar(horizontal: .x, vertical: .y, scale: .one))
        let far = try MeshBuilder.box(size: [0.9, 0.9, 0.1]).projectingUV(.planar(horizontal: .x, vertical: .y, scale: .one))
        var piece = ModelPartDefinition(id: part, mesh: near, material: material, parent: .joint(joint))
        piece.levelsOfDetail = [.init(minimumDistance: 20, mesh: far)]
        var source = ModelAssetDefinition(name: "Rigid flag", materials: [.init(id: material, baseColor: .white, shading: .unlit)], parts: [piece],
            rig: RigDefinition(id: AnyRealitizerID("rig"), joints: [.init(id: joint)]),
            sockets: [.init(id: AnyRealitizerID("tip"), parent: .part(part), transform: .init(translation: [0, 1, 0]))])
        var moved = source.restPose
        moved.transforms[.joint(joint)] = .init(translation: [1, 0, 0])
        source.clips = [try .keyPoses(id: AnyRealitizerID("wave"), duration: 2,
            frames: [.init(time: 0, pose: source.restPose), .init(time: 1, pose: moved), .init(time: 2, pose: source.restPose)],
            reference: source.restPose, loopMode: .loop)]
        let generated = try RealityKitModelCompiler.compile(source).instantiate()
        let mesh = try generated.meshEntity(part).model!.mesh
        try generated.setLevelOfDetail(1)
        var resource = ModelResourcePart(id: part, mesh: mesh, material: material, parent: .joint(joint))
        resource.levelsOfDetail = [.init(minimumDistance: 20, mesh: try generated.meshEntity(part).model!.mesh)]
        return (source, ModelResourceDefinition(name: source.name, materials: source.materials, parts: [resource],
            rig: source.rig, sockets: source.sockets, clips: source.clips))
    }
}
