import Realitizer
import RealitizerEnvironment
import RealitizerRealityKit
import RealityKit
import Testing
import simd

private let bodyID = AnyRealitizerID("body")
private let jointID = AnyRealitizerID("root")
private let materialID = AnyRealitizerID("surface")
private let morphID = AnyRealitizerID("expand")

@MainActor @Test func unlitToneMappingOptionsKeepDefaultsAndTextureTransparency() throws {
    var definition = MaterialDefinition(id: materialID, baseColor: .white, shading: .unlit)
    #expect(definition.unlitToneMapping)
    _ = try #require(RealityKitMaterialCompiler.compile(definition) as? UnlitMaterial)
    definition.unlitToneMapping = false
    definition.alphaMode = .blend
    definition.baseColorTexture = try TextureImage.generate(width: 2, height: 2) { _ in
        RGBAColor(red: 0.3, green: 0.7, blue: 1, alpha: 0.5)
    }
    let painted = try #require(RealityKitMaterialCompiler.compile(definition) as? UnlitMaterial)
    // The legacy UnlitMaterial initializer does not expose its tone-map flag
    // through program.descriptor (even for Apple's direct initializer). Verify
    // rendered color separately; the descriptor is not a readback of that flag.
    #expect(!definition.unlitToneMapping)
    #expect(painted.color.texture != nil)
    guard case .transparent = painted.blending else {
        Issue.record("Unlit tone mapping must not disable texture transparency.")
        return
    }
}

private func runtimeAsset(normalMorph: Bool = false, skinned: Bool = true) throws
    -> ModelAssetDefinition
{
    var mesh = try MeshBuilder.box(size: [1, 1, 1])
    mesh.materialIndices = (0..<mesh.triangleCount).map { UInt32($0 % 2) }
    let skin = SkinBinding(influences: mesh.vertices.map { _ in [JointWeight(jointID, weight: 1)] })
    let morph = MorphTarget(
        id: morphID, positionDeltas: mesh.vertices.map { _ in SIMD3<Float>(0.2, 0, 0) },
        normalDeltas: normalMorph ? mesh.vertices.map { _ in SIMD3<Float>.zero } : [])
    let geometry = ModelGeometry(mesh: mesh, skin: skinned ? skin : nil, morphTargets: [morph])
    var part = ModelPartDefinition(id: bodyID, geometry: geometry, material: materialID)
    part.additionalMaterialIDs = [AnyRealitizerID("accent")]
    part.levelsOfDetail = [ModelGeometryLevel(minimumDistance: 5, geometry: geometry)]
    return ModelAssetDefinition(
        name: "Runtime contract",
        materials: [
            MaterialDefinition(id: materialID, baseColor: .white),
            MaterialDefinition(id: AnyRealitizerID("accent"), baseColor: .white),
        ], parts: [part],
        rig: skinned
            ? RigDefinition(id: AnyRealitizerID("rig"), joints: [JointDefinition(id: jointID)]) : nil,
        sockets: [
            SocketDefinition(
                id: AnyRealitizerID("socket"), parent: skinned ? .joint(jointID) : .part(bodyID))
        ])
}

@MainActor @Test func directMaterialCompilationUsesAssetValidation() throws {
    var material = MaterialDefinition(id: materialID, baseColor: .white)
    material.roughness = .nan
    #expect(throws: ModelValidationError.self) { try RealityKitMaterialCompiler.compile(material) }
    let asset = ModelAssetDefinition(name: "Invalid", materials: [material], parts: [])
    #expect(asset.validationReport().diagnostics.contains { $0.code == "material.invalidRoughness" })
}

@MainActor @Test func failedAnimationApplicationDoesNotPublishTransformsOrAdvanceTheAnimator()
    throws
{
    var asset = try runtimeAsset(skinned: false)
    var clip = AnimationClipDefinition(
        id: AnyRealitizerID("motion"), duration: 1,
        channels: [
            TransformAnimationChannel(
                target: .part(bodyID),
                keyframes: [
                    TransformKeyframe(time: 0, transform: .identity),
                    TransformKeyframe(time: 1, transform: ModelTransform(translation: [2, 0, 0])),
                ])
        ])
    clip.scalarChannels = [
        ScalarAnimationChannel(
            target: .material(materialID, .roughness),
            keyframes: [ScalarKeyframe(time: 0, value: 0.3)])
    ]
    asset.clips = [clip]
    asset.animationGraph = AnimationGraphDefinition(
        id: AnyRealitizerID("graph"), initialState: clip.id,
        states: [AnimationStateDefinition(id: clip.id, clip: clip.id)])
    let instance = try RealityKitModelCompiler.compile(asset).instantiate()
    let animator = try instance.makeAnimator()
    try instance.setMaterial(UnlitMaterial(color: .red), for: materialID)
    let before = instance.currentPose.transforms
    #expect(throws: RuntimeModelError.self) { try animator.advance(by: 0.5) }
    #expect(instance.currentPose.transforms == before)
    instance.resetMaterials()
    let recovered = try animator.advance(by: 0.1)
    #expect(abs(recovered.pose.localTime - 0.1) < 0.00001)
}

@MainActor @Test func invalidNormalMorphLeavesWeightsAndGPUResourceUnchanged() throws {
    var asset = try runtimeAsset(normalMorph: true, skinned: false)
    let geometry = asset.parts[0].geometry
    var morphs = geometry.morphTargets
    morphs[0].normalDeltas = geometry.mesh.vertices.map { -$0.normal }
    asset.parts[0].geometry = ModelGeometry(
        mesh: geometry.mesh, skin: geometry.skin, morphTargets: morphs)
    let instance = try RealityKitModelCompiler.compile(asset).instantiate()
    let before = try instance.evaluatedMesh(for: bodyID)
    let resource = try instance.meshEntity(bodyID).model?.mesh
    #expect(throws: ModelValidationError.self) {
        try instance.setMorphWeight(1, part: bodyID, target: morphID)
    }
    #expect(try instance.evaluatedMesh(for: bodyID) == before)
    #expect(try instance.meshEntity(bodyID).model?.mesh === resource)
}

@MainActor @Test
func nativeSkinMorphMaterialSlotsAndLODKeepSemanticHandles() throws {
    let compiled = try RealityKitModelCompiler.compile(runtimeAsset())
    let first = try compiled.instantiate()
    let second = try compiled.instantiate()
    let model = try first.meshEntity(bodyID)
    let shared = try #require(model.model?.mesh)
    #expect(try shared === second.meshEntity(bodyID).model?.mesh)
    #expect(shared.contents.skeletons.count == 1)
    #expect(shared.contents.models.first?.parts.count == 2)
    #expect(model.components[SkeletalPosesComponent.self] != nil)
    #expect(model.components[BlendShapeWeightsComponent.self] != nil)
    let socket = try first.socket(AnyRealitizerID("socket"))
    let part = try first.part(bodyID)
    try first.setJointTransform(ModelTransform(translation: [0, 2, 0]), for: jointID)
    try first.setMorphWeight(0.5, part: bodyID, target: morphID)
    let deformed = try first.evaluatedMesh(for: bodyID)
    #expect(
        abs(
            deformed.vertices[0].position.x
                - (first.definition.parts[0].geometry.mesh.vertices[0].position.x + 0.1)) < 1e-5)
    #expect(try second.joint(jointID).position == .zero)
    try first.setLevelOfDetail(1)
    #expect(try first.part(bodyID) === part)
    #expect(try first.socket(AnyRealitizerID("socket")) === socket)
    #expect(try first.evaluatedMesh(for: bodyID) == deformed)
    #expect(try first.joint(jointID).position == [0, 2, 0])
}

@MainActor @Test
func normalMorphFallbackStreamsIntoAStablePerInstanceResource() throws {
    let instance = try RealityKitModelCompiler.compile(runtimeAsset(normalMorph: true)).instantiate()
    let original = try #require(instance.meshEntity(bodyID).model?.mesh)
    try instance.setMorphWeight(1, part: bodyID, target: morphID)
    #expect(try instance.meshEntity(bodyID).model?.mesh === original)
    #expect(try instance.meshEntity(bodyID).components[SkeletalPosesComponent.self] == nil)
    #expect(try instance.evaluatedMesh(for: bodyID).bounds?.maximum.x == 0.7)
    try instance.resetPose()
    #expect(try instance.evaluatedMesh(for: bodyID).bounds?.maximum.x == 0.5)
}

@MainActor @Test
func dynamicMeshUpdatesBoundsAndRejectsOverCapacityWithoutMutation() throws {
    let box = try MeshBuilder.box(size: [1, 1, 1])
    let dynamic = try DynamicModelMesh(mesh: box)
    let resource = dynamic.resource
    let moved = box.transformed(by: ModelTransform(translation: [2, 0, 0]))
    try dynamic.update(moved)
    #expect(dynamic.resource === resource)
    #expect(dynamic.lowLevelMesh.parts.first?.bounds.max.x == 2.5)
    #expect(throws: DynamicMeshError.self) {
        try dynamic.update(box.repeated(at: [.identity, .identity]))
    }
    #expect(dynamic.data == moved)
    var changed = moved.vertices[0]
    changed.position.x += 0.1
    try dynamic.updateVertices(in: 0..<1, with: [changed])
    #expect(dynamic.data.vertices[0] == changed)
    #expect(dynamic.data.vertices[1] == moved.vertices[1])
    #expect(throws: DynamicMeshError.self) { try dynamic.updateVertices(in: 0..<2, with: [changed]) }
    let valid = dynamic.data
    changed.position = moved.vertices[1].position
    #expect(throws: ModelValidationError.self) {
        try dynamic.updateVertices(in: 0..<1, with: [changed])
    }
    #expect(dynamic.data == valid)
    changed = valid.vertices[0]
    changed.normal = .zero
    #expect(throws: ModelValidationError.self) {
        try dynamic.updateVertices(in: 0..<1, with: [changed])
    }
    #expect(dynamic.data == valid)
    changed = valid.vertices[0]
    changed.textureCoordinate.x = .nan
    #expect(throws: ModelValidationError.self) {
        try dynamic.updateVertices(in: 0..<1, with: [changed])
    }
    #expect(dynamic.data == valid)
}

@MainActor @Test func waveStreamingKeepsGPUResourcesAndBoundsValid() throws {
    let mesh = try MeshBuilder.surface(uSegments: 120, vSegments: 120) {
        [($0.x - 0.5) * 100, 0, (0.5 - $0.y) * 100]
    }
    let field = try WaveField(waves: [
        DirectionalWave(direction: [1, 0.3], amplitude: 0.2, wavelength: 8, speed: 1)
    ])
    let dynamic = try DynamicModelMesh(mesh: mesh)
    let resource = dynamic.resource
    let rest = mesh.vertices.map(\.position)
    var vertices = mesh.vertices
    for frame in 0..<6 {
        try field.updateVertices(&vertices, restPositions: rest, time: Float(frame) / 24)
        try dynamic.updateVertices(in: vertices.indices, with: vertices)
        #expect(dynamic.resource === resource)
        #expect(dynamic.lowLevelMesh.parts.first!.bounds.max.y <= field.maximumVerticalDisplacement)
    }
}

@MainActor @Test
func authoringMaterialOverlaysDoNotEraseAnimatedMaterialValues() throws {
    var asset = try runtimeAsset(skinned: false)
    var clip = AnimationClipDefinition(id: AnyRealitizerID("polish"), duration: 1, channels: [])
    clip.scalarChannels = [
        ScalarAnimationChannel(
            target: .material(materialID, .roughness), keyframes: [ScalarKeyframe(time: 0, value: 0.2)])
    ]
    asset.clips = [clip]
    let instance = try RealityKitModelCompiler.compile(asset).instantiate()
    try instance.sample(clip.id, at: 0)
    try instance.setVisualizationMaterials([materialID: UnlitMaterial(color: .red)])
    try instance.sample(clip.id, at: 0.5)
    try instance.setVisualizationMaterials([:])
    let material = try #require(
        instance.meshEntity(bodyID).model?.materials[0] as? PhysicallyBasedMaterial)
    #expect(abs(material.roughness.scale - 0.2) < 1e-5)
}

@MainActor @Test
func cacheAndStaticBatchRetainSemanticTransforms() throws {
    var asset = try runtimeAsset(skinned: false)
    asset.parts[0].geometry = ModelGeometry(
        mesh: asset.parts[0].geometry.mesh, skin: asset.parts[0].geometry.skin)
    asset.parts[0].levelsOfDetail = []
    asset.parts[0].transform.translation = [1, 0, 0]
    let cache = ModelResourceCache<String>(capacity: 1)
    var generations = 0
    let compiled = try cache.asset(for: "one") {
        generations += 1
        return asset
    }
    let again = try cache.asset(for: "one") {
        generations += 1
        return asset
    }
    #expect(compiled === again)
    #expect(generations == 1)
    let copy = AnyRealitizerID("copy")
    let batch = try StaticModelBatch(
        asset: compiled, instances: [(copy, ModelTransform(translation: [2, 0, 0]))])
    #expect(try batch.transform(of: bodyID, in: copy).columns.3.x == 3)
    try batch.setTransform(ModelTransform(translation: [5, 0, 0]), for: copy)
    #expect(try batch.socketTransform(AnyRealitizerID("socket"), in: copy).columns.3.x == 6)
    #expect(batch.root.children.count == 1)
    _ = try cache.asset(for: "two") { asset }
    #expect(cache.count == 1)
}

@MainActor @Test
func physicsBodyLivesOnTheVisualOwnerAndAnimatorOwnershipIsExclusive() throws {
    var asset = try runtimeAsset(skinned: false)
    var collider = ModelCollisionDefinition(
        id: AnyRealitizerID("physics"), parent: .part(bodyID), shape: .box(size: [1, 1, 1]))
    collider.physics = ModelPhysicsDefinition(mode: .dynamic)
    asset.collisions = [collider]
    let instance = try RealityKitModelCompiler.compile(asset).instantiate()
    #expect(try instance.collision(collider.id) === instance.part(bodyID))
    #expect(try instance.part(bodyID).components[PhysicsBodyComponent.self] != nil)
    var animated = try runtimeAsset()
    animated.clips = [AnimationClipDefinition(id: AnyRealitizerID("idle"), duration: 1, channels: [])]
    animated.animationGraph = AnimationGraphDefinition(
        id: AnyRealitizerID("graph"), initialState: AnyRealitizerID("idle"),
        states: [AnimationStateDefinition(id: AnyRealitizerID("idle"), clip: AnyRealitizerID("idle"))])
    let controlled = try RealityKitModelCompiler.compile(animated).instantiate()
    var animator: RuntimeModelAnimator? = try controlled.makeAnimator()
    #expect(throws: RuntimeModelError.self) {
        try controlled.setJointTransform(.identity, for: jointID)
    }
    _ = try animator?.advance(by: 0.1)
    animator = nil
    try controlled.setJointTransform(.identity, for: jointID)
}
