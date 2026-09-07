import Realitizer
import Testing
import simd

@Test func closedPrimitivesHaveExactSeamsForTopologyProcessing() throws {
    let primitives = [
        try MeshBuilder.cylinder(radius: 0.5, height: 1, segments: 24),
        try MeshBuilder.cone(radius: 0.5, height: 1, segments: 24),
        try MeshBuilder.sphere(radius: 0.5, latitudeSegments: 8, longitudeSegments: 16),
        try MeshBuilder.revolve(
            profile: [[0, -0.5], [0.5, -0.5], [0.5, 0.5], [0, 0.5]], segments: 24),
    ]
    for primitive in primitives {
        let topology = try EditableMesh(renderMesh: primitive, welding: .exactPositions)
        try topology.validate(requireClosed: true)
        #expect(primitive.signedVolume > 0)
    }
}

@Test func normalProcessingRetainsSharedVerticesOnAnOrdinaryGrid() throws {
    let mesh = try MeshBuilder.surface(uSegments: 100, vSegments: 100) { [$0.x, 0, -$0.y] }
    #expect(mesh.vertices.count == 10_201)
    let result = try MeshProcessor.recalculateNormals(of: mesh)
    #expect(result.mesh.vertices.count == 10_201)
    #expect(result.mesh.indices.count == 60_000)
    #expect(try result.mesh.recalculatingNormals() == result.mesh)
    #expect(result.vertexMap.contributions.count == result.mesh.vertices.count)
}

private func foldedSurface() -> MeshData {
    MeshData(
        vertices: [SIMD3<Float>(0, 0, 0), [1, 0, 0], [0, 1, 0], [0, 0, 1]].map {
            MeshVertex(position: $0, normal: [0, 1, 0])
        }, indices: [0, 1, 2, 0, 3, 1])
}

@Test func hardEdgeSplittingTransfersSkinAndMorphCorrespondence() throws {
    let mesh = foldedSurface()
    let rig = testRig()
    let geometry = try ModelGeometry(mesh: mesh)
        .binding(to: rig) { vertex in
            [JointWeight(AnyRealitizerID(vertex.position.x > 0 ? "tip" : "root"), weight: 1)]
        }
        .addingMorph(id: AnyRealitizerID("stretch")) { $0.position * 1.2 }
    let processing = try MeshProcessor.recalculateNormals(of: mesh, smoothingAngle: 0)
    let output = try geometry.applying(processing)
    #expect(output.mesh.vertices.count == 6)
    #expect(output.mesh.triangleCount == mesh.triangleCount)
    let skin = try #require(output.skin)
    for i in output.mesh.vertices.indices {
        let source = processing.vertexMap.contributions[i][0].sourceIndex
        #expect(skin.influences[i] == geometry.skin?.influences[source])
        #expect(
            output.morphTargets[0].positionDeltas[i] == geometry.morphTargets[0].positionDeltas[source])
    }
    #expect(try geometry.recalculatingNormals(smoothingAngle: 0).mesh == output.mesh)
    #expect(geometry.mesh == mesh)
}

@Test func seamSplittingDuplicatesOnlySeamVerticesAndKeepsBindings() throws {
    let mesh = MeshData(
        vertices: [SIMD3<Float>(-1, 0, -0.1), [-1, 0, 0.1], [-1, 0.5, 0.1]].map {
            MeshVertex(position: $0, normal: [-1, 0, 0])
        }, indices: [0, 1, 2])
    let geometry = try ModelGeometry(mesh: mesh).automaticallyBinding(to: testRig())
        .addingMorph(id: AnyRealitizerID("rise")) { $0.position + SIMD3(0, 0.1, 0) }
    let output = try geometry.projectingUV(.spherical)
    #expect(output.mesh.vertices.count == 4)
    #expect(output.skin?.influences.count == 4)
    #expect(output.morphTargets[0].positionDeltas.count == 4)
    #expect(output.skin?.influences[0] == output.skin?.influences[3])
    try output.validate()
}

@Test func processingRejectsWrongSourcesAndMalformedMaps() throws {
    let mesh = try MeshBuilder.box(size: [1, 1, 1])
    let result = try MeshProcessor.recalculateNormals(of: mesh)
    let other = ModelGeometry(mesh: mesh.transformed(by: ModelTransform(translation: [1, 0, 0])))
    #expect(throws: ModelValidationError.self) { try other.applying(result) }
    for row: [VertexContribution] in [
        [], [.init(sourceIndex: -1)], [.init(sourceIndex: 4)],
        [.init(sourceIndex: 0, weight: .nan)], [.init(sourceIndex: 0, weight: 0.5)],
        [.init(sourceIndex: 0, weight: 0.5), .init(sourceIndex: 0, weight: 0.5)],
    ] {
        #expect(throws: ModelValidationError.self) {
            try MeshVertexMap(sourceVertexCount: 4, contributions: [row])
        }
    }
}

@Test func weightedMapsInterpolateWithoutSilentlyDroppingJointInfluences() throws {
    let weights = [
        [JointWeight(AnyRealitizerID("root"), weight: 1)],
        [JointWeight(AnyRealitizerID("tip"), weight: 1)],
    ]
    let map = try MeshVertexMap(
        sourceVertexCount: 2,
        contributions: [
            [
                .init(sourceIndex: 0, weight: 0.25), .init(sourceIndex: 1, weight: 0.75),
            ]
        ])
    let skin = try SkinBinding(influences: weights, maximumInfluences: 2).remapped(using: map)
    #expect(
        skin.influences[0] == [
            JointWeight(AnyRealitizerID("root"), weight: 0.25),
            JointWeight(AnyRealitizerID("tip"), weight: 0.75),
        ])
    #expect(throws: ModelValidationError.self) {
        try SkinBinding(influences: weights, maximumInfluences: 1).remapped(using: map)
    }
}

@Test func regionExtrusionDoesNotInsertWallsBetweenSelectedTriangles() throws {
    let box = try MeshBuilder.box(size: [1, 1, 1])
    var topology = try EditableMesh(renderMesh: box, welding: .exactPositions)
    let top = topology.selectFaces { $0.normal.y > 0.99 && $0.center.y > 0 }
    #expect(top.count == 2)
    let result = try topology.extrude(faces: top, offset: [0, 0.5, 0])
    #expect(result.sideFaces.count == 4)
    #expect(result.capFaces == top)
    try topology.validate(requireClosed: true)
    #expect(abs(try topology.renderMesh().signedVolume - 1.5) < 0.00001)
    let before = try topology.renderMesh()
    #expect(throws: ModelValidationError.self) {
        try topology.extrude(faces: [top[0], top[0]], offset: [0, 1, 0])
    }
    #expect(try topology.renderMesh() == before)
    let composed = try box.modifyingTopology(welding: .exactPositions) { shape in
        try shape.extrude(faces: shape.selectFaces(normal: [0, 1, 0]), offset: [0, 0.5, 0])
    }
    #expect(composed == before)
}

@Test func topologyWeldingIsExplicitAndDoesNotAssumeCoincidentShellsAreConnected() throws {
    let box = try MeshBuilder.box(size: [1, 1, 1])
    let separate = try EditableMesh(renderMesh: box, welding: .none)
    let welded = try EditableMesh(renderMesh: box, welding: .exactPositions)
    #expect(separate.vertexIDs.count == box.vertices.count)
    #expect(welded.vertexIDs.count == 8)
    #expect(throws: ModelValidationError.self) { try separate.validate(requireClosed: true) }
    try welded.validate(requireClosed: true)
}

@Test func solidifyClosesAnOpenSurfaceWithMetricThicknessAndRimSlots() throws {
    let surface = try EditableMesh(
        positions: [[0, 0, 0], [1, 0, 0], [1, 0, -1], [0, 0, -1]], polygons: [[0, 1, 2, 3]])
    for offset: Float in [-1, 0, 1] {
        let shell = try surface.solidified(thickness: 0.2, offset: offset, rimMaterial: 2)
        try shell.validate(requireClosed: true)
        let mesh = try shell.renderMesh()
        #expect(abs(mesh.signedVolume - 0.2) < 0.00001)
        #expect(abs(mesh.bounds!.size.y - 0.2) < 0.00001)
        #expect(abs(mesh.bounds!.center.y - offset * 0.1) < 0.00001)
        #expect(shell.faces.values.filter { $0.materialIndex == 2 }.count == 4)
    }
    #expect(throws: ModelValidationError.self) { try surface.solidified(thickness: 0) }
    #expect(throws: ModelValidationError.self) { try editableCube().solidified(thickness: 0.1) }
}

@Test func geometryRejectsIncompleteBindingsAndDuplicateMorphs() throws {
    let mesh = try MeshBuilder.box(size: [1, 1, 1])
    #expect(throws: ModelValidationError.self) {
        try ModelGeometry(mesh: mesh, skin: SkinBinding(influences: [])).validate()
    }
    let geometry = try ModelGeometry(mesh: mesh).addingMorph(id: AnyRealitizerID("same")) {
        $0.position
    }
    #expect(throws: ModelValidationError.self) {
        try geometry.addingMorph(id: AnyRealitizerID("same")) { $0.position }
    }
}

@Test func twoBoneIKUsesThePoleAndReportsUnreachableTargets() throws {
    var rig = testRig()
    rig.constraints = [
        .twoBoneIK(
            TwoBoneIKConstraint(
                id: AnyRealitizerID("arm"), root: AnyRealitizerID("root"),
                middle: AnyRealitizerID("middle"), tip: AnyRealitizerID("tip")))
    ]
    let pose = PoseDefinition(id: AnyRealitizerID("rest"), transforms: [:])
    for sign: Float in [-1, 1] {
        let output = try RigSolver.solve(
            rig: rig, pose: pose,
            targets: ["arm": .init(position: [0, 1, 0], polePosition: [sign, 0, 0])])
        #expect(output.inverseKinematics[0].reached)
        let globals = try rig.resolvedSkeleton().globalMatrices(pose: output.pose)
        #expect(globals[1].columns.3.x * sign > 0.8)
        #expect(abs(globals[2].columns.3.y - 1) < 0.0001)
    }
    let far = try RigSolver.solve(
        rig: rig, pose: pose, targets: ["arm": .init(position: [0, 8, 0], polePosition: [1, 0, 0])])
    #expect(!far.inverseKinematics[0].reached)
    #expect(abs(far.inverseKinematics[0].remainingDistance - 6) < 0.0001)
    #expect(try RigSolver.solve(rig: rig, pose: pose, targets: [:]).inverseKinematics.isEmpty)
    #expect(throws: ModelValidationError.self) {
        try RigSolver.solve(rig: rig, pose: pose, targets: ["arm": .init(position: [0, 1, 0])])
    }
    #expect(throws: ModelValidationError.self) {
        try RigSolver.solve(
            rig: rig, pose: pose, targets: ["arm": .init(position: [0, 1, 0], polePosition: [0, 3, 0])])
    }
}
