import Realitizer
import SwiftUI
import simd

struct SurfaceStudyParameters: Equatable, Sendable {
    var height: Float = 1.7
    var width: Float = 0.2
}

let previewStudyOptions: ModelAssetPreviewOptions = {
    var options = ModelAssetPreviewOptions()
    options.configuration = ModelPreviewConfiguration(
        cameraYawRadians: 0.3, cameraPitchRadians: 0.18,
        distanceScale: 1.1, selectedClipID: AnyRealitizerID("sway"))
    options.configuration.sampleTime = 0.8
    return options
}()

/// A reusable surface/rig study rather than a game-specific character.
let previewStudyGenerator = ModelAssetGenerator(
    name: "Articulated Surface Study",
    parameters: SurfaceStudyParameters(),
    seed: 7
) { input in
    let height = input.parameters.height
    let width = input.parameters.width
    let root = AnyRealitizerID("root")
    let middle = AnyRealitizerID("middle")
    let tip = AnyRealitizerID("tip")
    let bodyID = AnyRealitizerID("surface")
    let teal = AnyRealitizerID("ceramic")
    let gold = AnyRealitizerID("brass")
    let rig = RigDefinition(
        id: AnyRealitizerID("study"),
        joints: [
            JointDefinition(id: root),
            JointDefinition(
                id: middle, parent: root, restTransform: ModelTransform(translation: [0, height / 2, 0])),
            JointDefinition(
                id: tip, parent: middle, restTransform: ModelTransform(translation: [0, height / 2, 0])),
        ])
    func surface(segments: Int, rings: Int) throws -> ModelGeometryLevel {
        let sections = try (0...rings).map { i -> LoftSection in
            let t = Float(i) / Float(rings)
            let radius = width * (0.78 + 0.22 * sin(t * .pi))
            let profile = try Profile2D.circle(radius: radius, segments: segments).outer
            return LoftSection(
                profile: profile,
                transform: ModelTransform(
                    rotation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]), translation: [0, t * height, 0]))
        }
        let mesh = try MeshBuilder.loft(sections)
        // Explicit two-bone interpolation avoids distance-based weight ambiguity at the ends.
        let weights = mesh.vertices.map { vertex -> [JointWeight] in
            let t = min(max(vertex.position.y / height, 0), 1) * 2
            if t <= 1 { return [JointWeight(root, weight: 1 - t), JointWeight(middle, weight: t)] }
            return [JointWeight(middle, weight: 2 - t), JointWeight(tip, weight: t - 1)]
        }
        let morph = MorphTarget(
            id: AnyRealitizerID("inflate"),
            positionDeltas: mesh.vertices.map {
                SIMD3($0.position.x, 0, $0.position.z) * 0.35 * sin($0.position.y / height * .pi)
            })
        return ModelGeometryLevel(
            minimumDistance: 0,
            geometry: ModelGeometry(
                mesh: mesh, skin: SkinBinding(influences: weights), morphTargets: [morph]))
    }
    let high = try surface(
        segments: input.quality.curveSegments, rings: input.quality.surfaceSegments)
    var low = try surface(segments: 8, rings: 6)
    low.minimumDistance = 6
    var body = ModelPartDefinition(id: bodyID, geometry: high.geometry, material: teal)
    body.levelsOfDetail = [low]
    let base = try MeshBuilder.revolve(
        profile: [[0, -0.12], [0.38, -0.12], [0.42, -0.08], [0.42, 0], [0.36, 0.08], [0, 0.08]],
        segments: input.quality.curveSegments)
    let crown = try MeshBuilder.sphere(
        radius: width * 1.45, latitudeSegments: 10, longitudeSegments: 20)
    var ceramic = MaterialDefinition(
        id: teal, baseColor: RGBAColor(red: 0.05, green: 0.63, blue: 0.56), roughness: 0.28,
        metallic: 0.12)
    ceramic.roughnessTexture = try TextureImage.noise(
        size: 64, seed: input.seed, low: RGBAColor(red: 0.6, green: 0.6, blue: 0.6), high: .white)
    ceramic.roughnessTexture?.encoding = .raw
    var asset = ModelAssetDefinition(
        name: "Articulated Surface Study",
        materials: [
            ceramic,
            MaterialDefinition(
                id: gold, baseColor: RGBAColor(red: 0.82, green: 0.53, blue: 0.19), roughness: 0.32,
                metallic: 0.7),
        ],
        parts: [
            body,
            ModelPartDefinition(id: AnyRealitizerID("base"), mesh: base, material: gold),
            ModelPartDefinition(
                id: AnyRealitizerID("crown"), mesh: crown, material: gold, parent: .joint(tip)),
        ], rig: rig,
        sockets: [
            SocketDefinition(
                id: AnyRealitizerID("attachment"), parent: .joint(tip),
                transform: ModelTransform(translation: [0, width * 1.6, 0]))
        ],
        collisions: [
            ModelCollisionDefinition(
                id: AnyRealitizerID("baseCollider"), parent: .part(AnyRealitizerID("base")),
                shape: .box(size: [0.84, 0.2, 0.84]))
        ])
    let rest = asset.restPose
    var bent = rest
    bent.transforms[.joint(middle)]?.rotation = simd_quatf(angle: -0.55, axis: [0, 0, 1])
    bent.transforms[.joint(tip)]?.rotation = simd_quatf(angle: 0.8, axis: [0, 0, 1])
    let bendPose = PoseDefinition(id: AnyRealitizerID("bend"), transforms: bent.transforms)
    asset.poses = [bendPose]
    var sway = try AnimationClipDefinition.keyPoses(
        id: AnyRealitizerID("sway"), duration: 2,
        frames: [
            PoseKeyframe(time: 0, pose: rest), PoseKeyframe(time: 1, pose: bendPose),
            PoseKeyframe(time: 2, pose: rest),
        ], reference: rest, loopMode: .loop,
        events: [AnimationEventDefinition(id: AnyRealitizerID("crest"), time: 1)])
    sway.rigSignature = rig.signature
    sway.scalarChannels = [
        ScalarAnimationChannel(
            target: .morph(part: bodyID, target: AnyRealitizerID("inflate")),
            keyframes: [
                ScalarKeyframe(time: 0, value: 0), ScalarKeyframe(time: 1, value: 1),
                ScalarKeyframe(time: 2, value: 0),
            ])
    ]
    asset.clips = [sway]
    asset.animationGraph = AnimationGraphDefinition(
        id: AnyRealitizerID("motion"), initialState: AnyRealitizerID("sway"),
        states: [
            AnimationStateDefinition(id: AnyRealitizerID("sway"), clip: sway.id)
        ])
    return asset
}

#Preview("Realitizer Model Asset", traits: .fixedLayout(width: 820, height: 620)) {
    ModelAssetPreview(generator: previewStudyGenerator, options: previewStudyOptions)
}
