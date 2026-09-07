import Realitizer
import RealitizerRealityKit
import RealityKit
import Testing
import simd

@MainActor @Test func materialAlphaModesAreExplicitForLitAndUnlitMaterials() throws {
    let texture = try TextureImage.generate(width: 2, height: 2) { uv in
        RGBAColor(red: 1, green: 1, blue: 1, alpha: uv.x)
    }
    for shading in [MaterialShading.lit, .unlit] {
        var definition = MaterialDefinition(
            id: AnyRealitizerID("leaf"), baseColor: .white, shading: shading)
        definition.baseColorTexture = texture
        for alpha in [MaterialAlphaMode.opaque, .blend, .mask(cutoff: 0.4)] {
            definition.alphaMode = alpha
            let compiled = try RealityKitMaterialCompiler.compile(definition)
            let threshold: Float?
            let transparent: Bool
            if let lit = compiled as? PhysicallyBasedMaterial {
                threshold = lit.opacityThreshold
                if case .transparent = lit.blending { transparent = true } else { transparent = false }
            } else {
                let unlit = try #require(compiled as? UnlitMaterial)
                threshold = unlit.opacityThreshold
                if case .transparent = unlit.blending { transparent = true } else { transparent = false }
            }
            switch alpha {
            case .opaque: #expect(!transparent && threshold == nil)
            case .blend: #expect(transparent && threshold == nil)
            case .mask(let cutoff): #expect(threshold == cutoff)
            }
        }
        definition.alphaMode = .mask(cutoff: .nan)
        #expect(throws: ModelValidationError.self) {
            try RealityKitMaterialCompiler.compile(definition)
        }
    }
}

@MainActor @Test func processedBindingsReachNativeSkinMorphAndLODResources() throws {
    let joint = AnyRealitizerID("root")
    let partID = AnyRealitizerID("body")
    let materialID = AnyRealitizerID("surface")
    let rig = RigDefinition(id: AnyRealitizerID("rig"), joints: [JointDefinition(id: joint)])
    let mesh = try MeshBuilder.surface(uSegments: 4, vSegments: 4) { [$0.x, $0.y, 0] }
    let geometry = try ModelGeometry(mesh: mesh).binding(to: rig) { _ in
        [JointWeight(joint, weight: 1)]
    }
    .addingMorph(id: AnyRealitizerID("inflate")) { $0.position + SIMD3(0, 0, 0.2) }
    .recalculatingNormals()
    .projectingUV(.planar(horizontal: .x, vertical: .y, scale: [1, 1]))
    var part = ModelPartDefinition(id: partID, geometry: geometry, material: materialID)
    part.levelsOfDetail = [ModelGeometryLevel(minimumDistance: 5, geometry: geometry)]
    let asset = ModelAssetDefinition(
        name: "Processed bindings", materials: [MaterialDefinition(id: materialID, baseColor: .white)],
        parts: [part], rig: rig)
    let styled = try ArtStyleProfile(materials: [], normalSmoothingAngle: 0).applying(to: asset)
    try styled.parts[0].geometry.validate()
    let instance = try RealityKitModelCompiler.compile(styled).instantiate()
    let owner = try instance.part(partID)
    #expect(try instance.meshEntity(partID).components[SkeletalPosesComponent.self] != nil)
    #expect(try instance.meshEntity(partID).components[BlendShapeWeightsComponent.self] != nil)
    try instance.setJointTransform(ModelTransform(translation: [0, 1, 0]), for: joint)
    try instance.setMorphWeight(0.5, part: partID, target: AnyRealitizerID("inflate"))
    let evaluated = try instance.evaluatedMesh(for: partID)
    #expect(abs(evaluated.bounds!.minimum.z - 0.1) < 0.00001)
    #expect(abs(evaluated.bounds!.minimum.y - 1) < 0.00001)
    try instance.setLevelOfDetail(1)
    #expect(try instance.part(partID) === owner)
    #expect(try instance.evaluatedMesh(for: partID) == evaluated)
    #expect(try instance.levelOfDetail(for: partID) == 1)
}

@MainActor @Test func opacityAnimationRetainsCutoutAndRejectsOpaqueDefinitions() throws {
    let materialID = AnyRealitizerID("leaf")
    let body = AnyRealitizerID("body")
    let clipID = AnyRealitizerID("fade")
    var clip = AnimationClipDefinition(id: clipID, duration: 1, channels: [])
    clip.scalarChannels = [
        ScalarAnimationChannel(
            target: .material(materialID, .opacity),
            keyframes: [ScalarKeyframe(time: 0, value: 1), ScalarKeyframe(time: 1, value: 0.5)])
    ]
    var asset = ModelAssetDefinition(
        name: "Masked animation",
        materials: [
            MaterialDefinition(id: materialID, baseColor: .white, alphaMode: .mask(cutoff: 0.3))
        ],
        parts: [
            ModelPartDefinition(
                id: body, mesh: try MeshBuilder.box(size: [1, 1, 1]), material: materialID)
        ], clips: [clip])
    asset.animationGraph = AnimationGraphDefinition(
        id: AnyRealitizerID("graph"), initialState: clipID,
        states: [AnimationStateDefinition(id: clipID, clip: clipID)])
    let instance = try RealityKitModelCompiler.compile(asset).instantiate()
    let animator = try instance.makeAnimator()
    try animator.advance(by: 0.5)
    let material = try #require(
        instance.meshEntity(body).model?.materials[0] as? PhysicallyBasedMaterial)
    #expect(material.opacityThreshold == 0.3)
    asset.materials[0].alphaMode = .opaque
    #expect(asset.referenceScalarValues[.material(materialID, .opacity)] == nil)
    #expect(asset.validationReport().diagnostics.contains { $0.code == "clip.opaqueMaterial" })
}
