import Realitizer
import Testing
import simd

func testRig() -> RigDefinition {
    RigDefinition(
        id: AnyRealitizerID(rawValue: "rig"),
        joints: [
            JointDefinition(id: AnyRealitizerID(rawValue: "root")),
            JointDefinition(
                id: AnyRealitizerID(rawValue: "middle"), parent: AnyRealitizerID(rawValue: "root"),
                restTransform: ModelTransform(translation: [0, 1, 0])),
            JointDefinition(
                id: AnyRealitizerID(rawValue: "tip"), parent: AnyRealitizerID(rawValue: "middle"),
                restTransform: ModelTransform(translation: [0, 1, 0])),
        ])
}

@Test func skinRestPoseIsIdentityAndDeformationUsesJointWeights() throws {
    let mesh = try MeshBuilder.box(size: [0.2, 0.2, 0.2])
    let rig = testRig()
    let skin = SkinBinding(
        influences: mesh.vertices.map { _ in
            [JointWeight(AnyRealitizerID(rawValue: "middle"), weight: 1)]
        })
    let rest = try skin.deform(
        mesh, rig: rig, pose: PoseDefinition(id: AnyRealitizerID(rawValue: "rest"), transforms: [:]))
    for i in mesh.vertices.indices {
        #expect(simd_distance(mesh.vertices[i].position, rest.vertices[i].position) < 0.00001)
    }
    let moved = try skin.deform(
        mesh, rig: rig,
        pose: PoseDefinition(
            id: AnyRealitizerID(rawValue: "raised"),
            transforms: [
                .joint(AnyRealitizerID(rawValue: "middle")): ModelTransform(translation: [0, 2, 0])
            ]))
    #expect(abs(moved.bounds!.center.y - 1) < 0.00001)
    let automatic = try SkinBinding.automatic(mesh: mesh, rig: rig)
    try automatic.validate(vertexCount: mesh.vertices.count, rig: rig)
}

@Test func ikConvergesAndReportsUnreachableTargetsWithoutNaNs() throws {
    var rig = testRig()
    rig.constraints = [
        .inverseKinematics(
            InverseKinematicsConstraint(
                id: AnyRealitizerID("hand"), chain: ["root", "middle", "tip"], iterations: 64,
                tolerance: 0.001))
    ]
    let pose = PoseDefinition(id: AnyRealitizerID(rawValue: "pose"), transforms: [:])
    let reachable = try RigSolver.solve(
        rig: rig, pose: pose, targets: ["hand": .init(position: [1, 1, 0])])
    #expect(reachable.inverseKinematics[0].reached)
    let unreachable = try RigSolver.solve(
        rig: rig, pose: pose, targets: ["hand": .init(position: [20, 20, 0])])
    #expect(!unreachable.inverseKinematics[0].reached)
    #expect(unreachable.pose.transforms.values.allSatisfy { $0.isFinite })
}

@Test func maskedAdditivePosesDoNotOverwriteUnselectedJoints() throws {
    let root = AnimationTarget.joint(AnyRealitizerID(rawValue: "root"))
    let middle = AnimationTarget.joint(AnyRealitizerID(rawValue: "middle"))
    let base = PoseDefinition(
        id: AnyRealitizerID(rawValue: "base"), transforms: [root: .identity, middle: .identity])
    let overlay = PoseDefinition(
        id: AnyRealitizerID(rawValue: "overlay"),
        transforms: [
            root: ModelTransform(translation: [9, 0, 0]), middle: ModelTransform(translation: [0, 2, 0]),
        ])
    let result = try base.blended(
        with: overlay, weight: 0.5, mask: BoneMask(weights: [middle: 1]), mode: .additive)
    #expect(result.transforms[root] == .identity)
    #expect(result.transforms[middle]?.translation == [0, 1, 0])
}

@Test func blendSpacesInterpolateAndClampAtTheirBoundaries() throws {
    let space = BlendSpaceDefinition(
        xParameter: AnyRealitizerID(rawValue: "speed"),
        samples: [
            BlendSpaceSample(clip: AnyRealitizerID(rawValue: "idle"), position: [0, 0]),
            BlendSpaceSample(clip: AnyRealitizerID(rawValue: "run"), position: [4, 0]),
        ])
    #expect(try space.weights(at: [1, 0]) == [0.75, 0.25])
    #expect(try space.weights(at: [9, 0]) == [0, 1])
    let plane = BlendSpaceDefinition(
        xParameter: AnyRealitizerID(rawValue: "x"), yParameter: "y",
        samples: [
            BlendSpaceSample(clip: AnyRealitizerID(rawValue: "a"), position: [0, 0]),
            BlendSpaceSample(clip: AnyRealitizerID(rawValue: "b"), position: [1, 0]),
            BlendSpaceSample(clip: AnyRealitizerID(rawValue: "c"), position: [0, 1]),
        ], triangles: [[0, 1, 2]])
    #expect(try plane.weights(at: [0.25, 0.25]) == [0.5, 0.25, 0.25])
    #expect(abs(try plane.weights(at: [2, 2]).reduce(0, +) - 1) < 0.00001)
}

@Test func rootMotionAccumulatesAcrossLoopsAndSupportsReverse() throws {
    let root = AnimationTarget.joint(AnyRealitizerID(rawValue: "root"))
    var clip = AnimationClipDefinition(
        id: AnyRealitizerID(rawValue: "walk"), duration: 1, loopMode: .loop,
        channels: [
            TransformAnimationChannel(
                target: root,
                keyframes: [
                    TransformKeyframe(time: 0, transform: .identity),
                    TransformKeyframe(time: 1, transform: ModelTransform(translation: [0, 0, 2])),
                ])
        ])
    clip.rootMotionTarget = root
    #expect(try clip.rootMotion(from: 0.25, to: 2.75).translation == [0, 0, 5])
    #expect(try clip.rootMotion(from: 2.75, to: 0.25).translation == [0, 0, -5])
}

@Test func springClosedFormAgreesAcrossTimePartitions() throws {
    var whole = SpringMotion()
    var halves = SpringMotion()
    try whole.advance(towards: [1, 2, 3], frequency: 2, deltaTime: 0.5)
    for _ in 0..<5 { try halves.advance(towards: [1, 2, 3], frequency: 2, deltaTime: 0.1) }
    #expect(simd_distance(whole.position, halves.position) < 0.00001)
    #expect(simd_distance(whole.velocity, halves.velocity) < 0.00001)
}
