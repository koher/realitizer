import Foundation
import Realitizer
import RealitizerRealityKit
import RealityKit
import Testing
import simd

@Suite(.serialized) @MainActor
struct ModelResourceTests {
    private let body = AnyRealitizerID("body")
    private let material = AnyRealitizerID("surface")
    private let joint = AnyRealitizerID("root")
    private let morph = AnyRealitizerID("wide")

    @Test func loadedSkinMorphLODAndAnimationReuseNativeResources() async throws {
        let source = try fixture(skinned: true)
        let original = try RealityKitModelCompiler.compile(source).instantiate()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var meshes: [MeshResource] = []
        for level in 0...1 {
            try original.setLevelOfDetail(level)
            let url = directory.appendingPathComponent("level-\(level).reality")
            try await original.root.write(to: url)
            let loaded = try await Entity(contentsOf: url)
            meshes.append(
                try #require(
                    loaded.findEntity(named: "mesh:body")?.components[ModelComponent.self]?.mesh))
        }
        let definition = resourceDefinition(source, meshes: meshes)
        #expect(definition.restPose.transforms == source.restPose.transforms)
        let compiled = try RealityKitModelCompiler.assemble(definition)
        let first = try compiled.instantiate()
        let second = try compiled.instantiate()
        let firstMesh = try first.meshEntity(body)
        let partHandle = try first.part(body)
        let socketHandle = try first.socket(AnyRealitizerID("tip"))
        #expect(firstMesh.model?.mesh === meshes[0])
        #expect(try second.meshEntity(body).model?.mesh === meshes[0])
        #expect(firstMesh.components[SkeletalPosesComponent.self] != nil)
        #expect(firstMesh.components[BlendShapeWeightsComponent.self] != nil)
        try first.setJointTransform(ModelTransform(translation: [0.3, 0, 0]), for: joint)
        try first.setMorphWeight(0.7, part: body, target: morph)
        let a = try first.evaluatedMesh(for: body)
        let expected = try RealityKitModelCompiler.compile(source).instantiate()
        try expected.setJointTransform(ModelTransform(translation: [0.3, 0, 0]), for: joint)
        try expected.setMorphWeight(0.7, part: body, target: morph)
        let b = try expected.evaluatedMesh(for: body)
        #expect(a.vertices.count == b.vertices.count)
        for (a, b) in zip(a.vertices, b.vertices) {
            #expect(simd_distance(a.position, b.position) < 0.00001)
        }
        try first.setLevelOfDetail(1)
        #expect(firstMesh.model?.mesh === meshes[1])
        #expect(try first.part(body) === partHandle)
        #expect(try first.socket(AnyRealitizerID("tip")) === socketHandle)
        #expect(try second.joint(joint).position == .zero)
        #expect(try second.meshEntity(body).model?.mesh === meshes[0])
        let animator = try second.makeAnimator()
        _ = try animator.advance(by: 0.5)
        #expect(try second.joint(joint).position.x > 0)
        let animated = try second.evaluatedMesh(for: body)
        let restX = source.parts[0].geometry.mesh.vertices[0].position.x
        #expect(abs(animated.vertices[0].position.x - (restX * 1.08 + 0.15)) < 0.00001)
        #expect(throws: RuntimeModelError.self) {
            try second.setMorphWeight(1, part: body, target: morph)
        }
    }

    @Test func loadedVertexColorsAndTexturesCanUseCodeMaterials() async throws {
        let resources = try VertexColorTestResources.result.get()
        var source = try fixture(skinned: false)
        source.materials[0].vertexColorMode = .multiply
        source.materials[0].baseColorTexture = try TextureImage.generate(width: 2, height: 2) { _ in
            RGBAColor(sRGB: [0.4, 0.6, 0.8])
        }
        source.parts[0].geometry = try source.parts[0].geometry.coloring { _ in
            RGBAColor(sRGB: [0.2, 0.7, 0.3])
        }
        let original = try RealityKitModelCompiler.compile(source, resources: resources)
            .instantiate()
        let exportMesh = try original.meshEntity(body)
        // The baked file has a native material; the custom shader remains an application resource.
        var nativeDefinition = source.materials[0]
        nativeDefinition.vertexColorMode = .ignore
        exportMesh.model?.materials = [try RealityKitMaterialCompiler.compile(nativeDefinition)]
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("colored.reality")
        try await original.root.write(to: url)
        let loaded = try await Entity(contentsOf: url)
        let component = try #require(
            loaded.findEntity(named: "mesh:body")?.components[ModelComponent.self])
        let restoredMaterial = try RealityKitMaterialCompiler.compile(
            source.materials[0], resources: resources)
        let definition = resourceDefinition(source, meshes: [component.mesh])
        let instance = try RealityKitModelCompiler.assemble(
            definition, materials: [material: restoredMaterial]
        ).instantiate()
        #expect(try instance.meshEntity(body).model?.mesh === component.mesh)
        let result = try #require(
            instance.meshEntity(body).model?.materials.first as? CustomMaterial)
        #expect(result.baseColor.texture != nil)
        for vertex in try instance.geometry(for: body).mesh.vertices {
            #expect(
                simd_distance(
                    vertex.color.linearRGBA,
                    source.parts[0].geometry.mesh.vertices[0].color.linearRGBA)
                    < 0.00001)
        }
        let nativeInstance = try RealityKitModelCompiler.assemble(
            definition, materials: [material: component.materials[0]]
        ).instantiate()
        #expect(
            try
                (nativeInstance.meshEntity(body).model?.materials.first as? PhysicallyBasedMaterial)?
                .baseColor.texture != nil)
    }

    @Test func multipleMaterialSlotsPreserveTrianglesAndSkin() throws {
        var source = try fixture(skinned: true)
        let second = AnyRealitizerID("second")
        source.materials.append(MaterialDefinition(id: second, baseColor: .white))
        source.parts[0].additionalMaterialIDs = [second]
        let geometry = source.parts[0].geometry
        var mesh = geometry.mesh
        mesh.materialIndices = (0..<mesh.triangleCount).map { UInt32($0 % 2) }
        source.parts[0].geometry = ModelGeometry(
            mesh: mesh, skin: geometry.skin, morphTargets: geometry.morphTargets)
        let native = try RealityKitModelCompiler.compile(source).instantiate().meshEntity(body)
            .model!
            .mesh
        let definition = resourceDefinition(source, meshes: [native])
        let instance = try RealityKitModelCompiler.assemble(definition).instantiate()
        #expect(try instance.meshEntity(body).model?.mesh === native)
        let restored = try instance.geometry(for: body)
        #expect(restored.mesh.triangleCount == mesh.triangleCount)
        #expect(Set(restored.mesh.materialIndices) == [0, 1])
        #expect(restored.skin != nil && restored.morphTargets.count == 1)
        try instance.setMorphWeight(0.4, part: body, target: morph)
        _ = try instance.evaluatedMesh(for: body)
    }

    @Test func rigMismatchBadReferencesAndAggregateBudgetFail() throws {
        let source = try fixture(skinned: true)
        let native = try RealityKitModelCompiler.compile(source).instantiate().meshEntity(body)
            .model!
            .mesh
        var definition = resourceDefinition(source, meshes: [native])
        definition.rig?.joints[0].restTransform.translation.x = 0.1
        #expect(throws: ModelResourceError.self) {
            try RealityKitModelCompiler.assemble(definition)
        }
        definition.rig = source.rig
        definition.parts[0].parent = .part(AnyRealitizerID("missing"))
        #expect(throws: ModelValidationError.self) {
            try RealityKitModelCompiler.assemble(definition)
        }
        definition.parts[0].parent = nil
        #expect(throws: ModelResourceError.self) {
            try RealityKitModelCompiler.assemble(
                definition, materials: [AnyRealitizerID("unknown"): UnlitMaterial()])
        }
        definition.parts[0].levelsOfDetail = [.init(minimumDistance: 2, mesh: native)]
        #expect(throws: ModelResourceError.self) {
            try RealityKitModelCompiler.assemble(
                definition,
                budget: GeometryBudget(
                    maximumVertices: source.parts[0].geometry.mesh.vertices.count))
        }
        definition.parts[0].levelsOfDetail[0].minimumDistance = 0
        #expect(throws: ModelValidationError.self) {
            try RealityKitModelCompiler.assemble(definition)
        }
    }

    @Test func resourceInstancesAndIncompatibleLODDeformationAreRejected() throws {
        let source = try fixture(skinned: false)
        let mesh = try RealityKitModelCompiler.compile(source).instantiate().meshEntity(body).model!
            .mesh
        var contents = mesh.contents
        let modelID = try #require(contents.models.first?.id)
        contents.instances = [
            .init(id: "offset", model: modelID, at: ModelTransform(translation: [1, 0, 0]).matrix)
        ]
        let offsetMesh = try MeshResource.generate(from: contents)
        #expect(throws: ModelResourceError.self) {
            try RealityKitModelCompiler.assemble(resourceDefinition(source, meshes: [offsetMesh]))
        }
        let rigged = try fixture(skinned: true)
        let riggedMesh = try RealityKitModelCompiler.compile(rigged).instantiate().meshEntity(body)
            .model!.mesh
        let definition = resourceDefinition(rigged, meshes: [riggedMesh, mesh])
        #expect(throws: ModelValidationError.self) {
            try RealityKitModelCompiler.assemble(definition)
        }
    }

    private func fixture(skinned: Bool) throws -> ModelAssetDefinition {
        let rig = RigDefinition(id: AnyRealitizerID("rig"), joints: [JointDefinition(id: joint)])
        func geometry(_ segments: Int) throws -> ModelGeometry {
            let mesh = try MeshBuilder.surface(uSegments: segments, vSegments: segments) {
                [($0.x - 0.5) * 2, ($0.y - 0.5) * 2, 0]
            }
            if skinned {
                return try ModelGeometry(mesh: mesh).binding(to: rig) { _ in
                    [JointWeight(joint, weight: 1)]
                }
                .addingMorph(id: morph) { $0.position * SIMD3(1.2, 1, 1) }
            }
            return ModelGeometry(mesh: mesh)
        }
        var part = ModelPartDefinition(id: body, geometry: try geometry(4), material: material)
        part.levelsOfDetail = [.init(minimumDistance: 3, geometry: try geometry(2))]
        var asset = ModelAssetDefinition(
            name: "Resource test", materials: [MaterialDefinition(id: material, baseColor: .white)],
            parts: [part], rig: skinned ? rig : nil,
            sockets: [SocketDefinition(id: AnyRealitizerID("tip"), parent: .part(body))])
        if skinned {
            var clip = try AnimationClipDefinition.keyPoses(
                id: AnyRealitizerID("move"), duration: 1,
                frames: [
                    .init(time: 0, pose: asset.restPose),
                    .init(
                        time: 1,
                        pose: PoseDefinition(
                            id: AnyRealitizerID("end"),
                            transforms: [.joint(joint): ModelTransform(translation: [0.3, 0, 0])])),
                ],
                reference: asset.restPose, loopMode: .loop)
            clip.scalarChannels = [
                ScalarAnimationChannel(
                    target: .morph(part: body, target: morph),
                    keyframes: [.init(time: 0, value: 0), .init(time: 1, value: 0.8)])
            ]
            asset.clips = [clip]
            asset.animationGraph = AnimationGraphDefinition(
                id: AnyRealitizerID("graph"), initialState: clip.id,
                states: [AnimationStateDefinition(id: clip.id, clip: clip.id)])
        }
        return asset
    }

    private func resourceDefinition(_ source: ModelAssetDefinition, meshes: [MeshResource])
        -> ModelResourceDefinition
    {
        var part = ModelResourcePart(id: body, mesh: meshes[0], material: material)
        part.additionalMaterialIDs = source.parts[0].additionalMaterialIDs
        part.levelsOfDetail = meshes.dropFirst().enumerated().map {
            .init(minimumDistance: Float($0.offset + 1) * 3, mesh: $0.element)
        }
        return ModelResourceDefinition(
            name: source.name, materials: source.materials, parts: [part],
            rig: source.rig, sockets: source.sockets, clips: source.clips,
            animationGraph: source.animationGraph)
    }

    private func temporaryDirectory() throws -> URL {
        let base =
            ProcessInfo.processInfo.environment["REALITIZER_TEST_TEMPORARY_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("ModelResourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
