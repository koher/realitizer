import Realitizer
import Testing
import simd

@Test func concaveExtrusionPreservesAreaVolumeAndHoles() throws {
    let outline: [SIMD2<Float>] = [[0, 0], [3, 0], [3, 1], [1, 1], [1, 3], [0, 3]]
    let mesh = try MeshBuilder.extrude(Profile2D(outer: outline), depth: 2)
    #expect(abs(mesh.signedVolume - 10) < 0.0001)
    let hollow = try MeshBuilder.extrude(
        Profile2D(
            outer: [[-2, -2], [2, -2], [2, 2], [-2, 2]],
            holes: [[[-1, -1], [-1, 1], [1, 1], [1, -1]]]
        ), depth: 3)
    #expect(abs(hollow.signedVolume - 36) < 0.001)
    #expect(hollow.validationDiagnostics().isEmpty)
}

@Test func intersectingProfilesFailWithDiagnostics() {
    #expect(throws: ModelValidationError.self) {
        try Profile2D(outer: [[0, 0], [2, 2], [0, 2], [2, 0]]).triangulated()
    }
    #expect(throws: ModelValidationError.self) {
        try Profile2D(outer: [[0, 0], [1, 0], [1, 1], [0, 1]], holes: [[[2, 2], [3, 2], [3, 3]]]).triangulated()
    }
}

@Test func revolutionSweepAndMirroringKeepOutwardWinding() throws {
    let turned = try MeshBuilder.revolve(profile: [[0, -1], [1, -1], [1, 1], [0, 1]], segments: 48)
    #expect(turned.signedVolume > 6)
    #expect(abs(turned.mirrored(across: .x).signedVolume - turned.signedVolume) < 0.0001)
    let profile = try Profile2D.circle(radius: 0.2, segments: 12)
    let tube = try MeshBuilder.sweep(profile, along: [[0, 0, 0], [0, 0, 1], [0.3, 0, 2]], twist: 0.4)
    #expect(tube.signedVolume > 0)
    #expect(tube.validationDiagnostics().isEmpty)
    for vertex in tube.vertices {
        let t = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
        #expect(abs(simd_dot(vertex.normal, t)) < 0.001)
    }
}

@Test func smallGeometryIsNotRejectedByMeterScaleTolerance() throws {
    let mesh = try MeshBuilder.box(size: [0.001, 0.001, 0.001])
    #expect(mesh.validationDiagnostics().isEmpty)
}

@Test func curvesAreResampledByDistanceAndSeededVariationRepeats() throws {
    let points = try CurveSampling.resample([[0, 0, 0], [1, 0, 0], [1, 0, 3]], count: 5)
    #expect(points == [[0, 0, 0], [1, 0, 0], [1, 0, 1], [1, 0, 2], [1, 0, 3]])
    var a = ModelingRandom(seed: 73)
    var b = ModelingRandom(seed: 73)
    for _ in 0..<100 { #expect(a.next() == b.next()) }
}
