import Foundation
import Realitizer
import Testing
import simd

private func constantClip(_ name: String, x: Float) -> AnimationClipDefinition {
    AnimationClipDefinition(
        id: AnyRealitizerID(name), duration: 1, loopMode: .loop,
        channels: [
            TransformAnimationChannel(
                target: .joint("root"),
                keyframes: [TransformKeyframe(time: 0, transform: ModelTransform(translation: [x, 0, 0]))])
        ])
}

@Test func interruptedCrossfadeStartsFromTheCurrentlyDisplayedPose() throws {
    let a = AnyRealitizerID("a")
    let b = AnyRealitizerID("b")
    let c = AnyRealitizerID("c")
    let go = AnyRealitizerID("go")
    var first = AnimationTransitionDefinition(from: a, to: b, duration: 1)
    first.interruptible = true
    let graph = AnimationGraphDefinition(
        id: AnyRealitizerID("graph"), initialState: a,
        parameters: [AnimationParameterDefinition(id: go, kind: .trigger)],
        states: [a, b, c].map { AnimationStateDefinition(id: $0, clip: $0) },
        transitions: [
            first, AnimationTransitionDefinition(from: b, to: c, duration: 1, conditions: [.trigger(go)]),
        ])
    var player = try AnimationGraphPlayer(
        graph: graph,
        clips: [constantClip("a", x: 0), constantClip("b", x: 10), constantClip("c", x: 20)])
    let before = try player.advance(by: 0.25)
    try player.activate(go)
    let after = try player.advance(by: 0)
    #expect(before.pose.transforms[.joint("root")]?.translation.x == 2.5)
    #expect(after.pose.transforms == before.pose.transforms)
}

@Test func secondBlendTriangleDoesNotRetainWeightsFromTheFirstTriangle() throws {
    let space = BlendSpaceDefinition(
        xParameter: AnyRealitizerID("x"), yParameter: "y",
        samples: [
            BlendSpaceSample(clip: AnyRealitizerID("a"), position: [0, 0]),
            BlendSpaceSample(clip: AnyRealitizerID("b"), position: [1, 0]),
            BlendSpaceSample(clip: AnyRealitizerID("c"), position: [0, 1]),
            BlendSpaceSample(clip: AnyRealitizerID("d"), position: [1, 1]),
        ], triangles: [[0, 1, 2], [1, 3, 2]])
    let weights = try space.weights(at: [0.8, 0.8])
    #expect(weights[0] == 0)
    #expect(abs(weights.reduce(0, +) - 1) < 1e-6)
}

@Test func layeredAnimationAndBlendSpaceRootMotionAreDeterministic() throws {
    let root = AnimationTarget.joint("root")
    let hand = AnimationTarget.joint("hand")
    func moving(_ id: String, distance: Float) -> AnimationClipDefinition {
        var clip = AnimationClipDefinition(
            id: AnyRealitizerID(id), duration: 1, loopMode: .loop,
            channels: [
                TransformAnimationChannel(
                    target: root,
                    keyframes: [
                        TransformKeyframe(time: 0, transform: .identity),
                        TransformKeyframe(time: 1, transform: ModelTransform(translation: [distance, 0, 0])),
                    ])
            ])
        clip.rootMotionTarget = root
        return clip
    }
    let slow = moving("slow", distance: 1)
    let fast = moving("fast", distance: 3)
    let upper = AnimationClipDefinition(
        id: AnyRealitizerID("upper"), duration: 1,
        channels: [
            TransformAnimationChannel(
                target: hand,
                keyframes: [TransformKeyframe(time: 0, transform: ModelTransform(translation: [0, 2, 0]))])
        ])
    var state = AnimationStateDefinition(id: AnyRealitizerID("move"), clip: slow.id)
    state.blendSpace = BlendSpaceDefinition(
        xParameter: AnyRealitizerID("speed"),
        samples: [
            BlendSpaceSample(clip: slow.id, position: [0, 0]),
            BlendSpaceSample(clip: fast.id, position: [1, 0]),
        ])
    var graph = AnimationGraphDefinition(
        id: AnyRealitizerID("graph"), initialState: state.id,
        parameters: [
            AnimationParameterDefinition(id: AnyRealitizerID("speed"), kind: .scalar(defaultValue: 0.5))
        ],
        states: [state])
    graph.layers = [
        AnimationLayerDefinition(
            id: AnyRealitizerID("upper"), clip: upper.id, mask: BoneMask(weights: [hand: 1]), weight: 0.5)
    ]
    var player = try AnimationGraphPlayer(
        graph: graph, clips: [slow, fast, upper],
        referencePose: PoseDefinition(
            id: AnyRealitizerID("rest"), transforms: [root: .identity, hand: .identity]))
    let frame = try player.advance(by: 0.5)
    #expect(frame.rootMotion.translation.x == 1)
    #expect(frame.pose.transforms[root]?.translation == .zero)
    #expect(frame.pose.transforms[hand]?.translation.y == 1)
}

@Test func eventQueriesAreBoundedAndReverseIntervalsDoNotDuplicateEndpoints() throws {
    var clip = constantClip("events", x: 0)
    clip.events = [AnimationEventDefinition(id: AnyRealitizerID("step"), time: 0.5)]
    #expect(try clip.events(from: 0, to: 1).map(\.elapsedTime) == [0.5])
    #expect(try clip.events(from: 1, to: 0.5).map(\.elapsedTime) == [0.5])
    #expect(try clip.events(from: 0.5, to: 0).isEmpty)
    #expect(throws: ModelValidationError.self) {
        try clip.events(from: 0, to: .greatestFiniteMagnitude)
    }
    #expect(throws: ModelValidationError.self) {
        try clip.events(from: 0, to: 100, maximumOccurrences: 10)
    }
}

@Test func convexHullEnclosesCubeAndRejectsCoplanarInputs() throws {
    let cube = try MeshBuilder.box(size: [1, 1, 1])
    let hull = try MeshBuilder.convexHull(points: cube.vertices.map(\.position) + [.zero])
    #expect(abs(hull.signedVolume - 1) < 1e-5)
    try EditableMesh(renderMesh: hull, welding: .exactPositions).validate(requireClosed: true)
    #expect(throws: ModelValidationError.self) {
        try MeshBuilder.convexHull(points: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]])
    }
}

@Test func seededRecipesAndTexturesRepeatWithoutCrackingCoincidentVertices() throws {
    let operation = ModelingOperation.noise(.sphere(radius: 1), amplitude: 0.1, frequency: 2)
    let recipe = ModelingRecipe(seed: 42, root: operation)
    let first = try recipe.evaluate().mesh
    let second = try recipe.evaluate().mesh
    #expect(first == second)
    #expect(try ModelingRecipe(seed: 43, root: operation).evaluate().mesh != first)
    #expect(
        try TextureImage.noise(
            size: 8, seed: 42, low: .white, high: RGBAColor(red: 0, green: 0, blue: 0))
            == TextureImage.noise(
                size: 8, seed: 42, low: .white, high: RGBAColor(red: 0, green: 0, blue: 0)))
    #expect(throws: ModelValidationError.self) { try TextureImage.normalMap(size: 4) { _ in .nan } }
    let nested = Data(
        (String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)).utf8)
    #expect(throws: ModelValidationError.self) { try ModelingRecipe.decode(nested) }
}

@Test func crossFeatureValidationRejectsInvalidLODTexturesSignaturesAndPhysics() throws {
    var asset = ModelAssetDefinition(
        name: "Validation",
        materials: [MaterialDefinition(id: AnyRealitizerID("m"), baseColor: .white)],
        parts: [
            ModelPartDefinition(
                id: AnyRealitizerID("p"), mesh: try MeshBuilder.box(size: [1, 1, 1]),
                material: AnyRealitizerID("m"))
        ], rig: testRig())
    let good = asset
    asset.materials[0].normalTexture = TextureImage(width: 2, height: 2, pixels: [])
    #expect(throws: ModelValidationError.self) { try asset.validated() }
    asset = good
    asset.parts[0].geometry = try asset.parts[0].geometry.addingMorph(id: AnyRealitizerID("morph")) {
        $0.position
    }
    asset.parts[0].levelsOfDetail = [
        ModelGeometryLevel(minimumDistance: 1, mesh: asset.parts[0].geometry.mesh)
    ]
    #expect(asset.validationReport().diagnostics.contains { $0.code == "lod.deformationContract" })
    asset = good
    var clip = constantClip("incompatible", x: 0)
    var otherRig = testRig()
    otherRig.version = 2
    clip.rigSignature = otherRig.signature
    asset.clips = [clip]
    #expect(asset.validationReport().diagnostics.contains { $0.code == "clip.rigSignature" })
    asset = good
    var collision = ModelCollisionDefinition(
        id: AnyRealitizerID("collider"), parent: .part("p"), shape: .sphere(radius: 1))
    collision.physics = ModelPhysicsDefinition(mode: .dynamic)
    collision.isTrigger = true
    asset.collisions = [collision]
    #expect(asset.validationReport().diagnostics.contains { $0.code == "physics.ownership" })
}

@Test func rigSignaturesIgnoreDeclarationOrderAndMirroringIsAnInvolution() throws {
    let rig = testRig()
    var reordered = rig
    reordered.joints.reverse()
    #expect(reordered.signature == rig.signature)
    let pose = PoseDefinition(
        id: AnyRealitizerID("pose"),
        transforms: [
            .joint("middle"): ModelTransform(
                rotation: simd_quatf(angle: 0.4, axis: [0, 0, 1]), translation: [1, 2, 3])
        ])
    let twice = try pose.mirrored(rig: rig).mirrored(rig: rig)
    #expect(twice.transforms == pose.transforms)
}
