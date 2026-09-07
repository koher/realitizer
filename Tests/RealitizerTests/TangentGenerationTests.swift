import Realitizer
import Testing
import simd

@Suite struct TangentGenerationTests {
    @Test(arguments: [3, 4, 6], [false, true])
    func lowSidedSweepsAcceptConstantAndTaperedSections(sides: Int, capped: Bool) throws {
        for radius: Float in [0.0005, 0.05, 5] {
            let profile = try Profile2D.circle(radius: radius, segments: sides)
            for scales: [Float] in [[], [1, 1], [2, 2], [1, 0.998], [1, 0.999999]] {
                let mesh = try MeshBuilder.sweep(
                    profile, along: [[0, 0, 0], [0, 2, 0]], scales: scales, capped: capped)
                try expectValidFrames(mesh)
                #expect(mesh.triangleCount == sides * 2 + (capped ? 2 * (sides - 2) : 0))
            }
        }
    }

    @Test(arguments: [false, true])
    func triangularLoftsHaveValidFramesWithAndWithoutCaps(capped: Bool) throws {
        let profile = try Profile2D.circle(radius: 0.05, segments: 3)
        for scale: Float in [1, 0.998] {
            let mesh = try MeshBuilder.loft(sections(profile, endScale: scale), capped: capped)
            try expectValidFrames(mesh)
            #expect(mesh.vertices.count == (capped ? 14 : 8))
            #expect(mesh.triangleCount == (capped ? 8 : 6))
        }
    }

    @Test func normalRecalculationPreservesTriangularSeamsAndVertexCorrespondence() throws {
        let profile = try Profile2D.circle(radius: 0.05, segments: 3)
        let rings = sections(profile)
        let vertices = rings.enumerated().flatMap { ring, section in
            (0...3).map { corner in
                MeshVertex(
                    position: section.transform.applying(to: SIMD3(profile.outer[corner % 3], 0)),
                    normal: [0, 1, 0], textureCoordinate: [Float(corner) / 3, Float(ring) * 2])
            }
        }
        let source = MeshData(
            vertices: vertices, indices: [0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6],
            materialIndices: [0, 0, 1, 1, 2, 2])
        let processing = try MeshProcessor.recalculateNormals(of: source, smoothingAngle: .pi)
        let mesh = processing.mesh
        try expectValidFrames(mesh)
        #expect(mesh.vertices.count == source.vertices.count)
        #expect(mesh.materialIndices == source.materialIndices)
        let sources = processing.vertexMap.contributions.map { $0[0].sourceIndex }
        #expect(sources.sorted() == Array(source.vertices.indices))
        #expect(processing.vertexMap.contributions.allSatisfy { $0.count == 1 && $0[0].weight == 1 })
        #expect(mesh.indices.map { UInt32(sources[Int($0)]) } == source.indices)
        for (i, vertex) in mesh.vertices.enumerated() {
            #expect(vertex.position == source.vertices[sources[i]].position)
            #expect(vertex.textureCoordinate == source.vertices[sources[i]].textureCoordinate)
            // Area weighting remains part of normal generation; tangent repair must not change it.
            var sum = SIMD3<Float>.zero
            for triangle in stride(from: 0, to: source.indices.count, by: 3) {
                let p = (0..<3).map { source.vertices[Int(source.indices[triangle + $0])].position }
                if p.contains(vertex.position) { sum += simd_cross(p[1] - p[0], p[2] - p[0]) }
            }
            #expect(simd_distance(vertex.normal, simd_normalize(sum)) < 0.000001)
        }
    }

    @Test(arguments: [Float(0.9995), 1, 1.0005], [Float(0.0001), 1, 10_000])
    func nearlyParallelTangentsRemainOrthogonalAtDifferentScales(normalLength: Float, scale: Float) throws {
        let direction = simd_normalize(SIMD3<Float>(0.5, 0, 0.8660254))
        let across = SIMD3<Float>(0, 1, 0)
        for angle: Float in [0, 0.7, 2.1] {
            let rotation = simd_quatf(angle: angle, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
            let normal = rotation.act(direction) * normalLength
            for separation: Float in [0, 0.0000001, 0.00001, 0.01] {
                let edge = rotation.act(direction + across * separation) * scale
                let other = rotation.act(simd_cross(direction, across)) * scale
                let source = MeshData(
                    vertices: [
                        MeshVertex(position: .zero, normal: normal, textureCoordinate: [0, 0]),
                        MeshVertex(position: edge, normal: normal, textureCoordinate: [1, 0]),
                        MeshVertex(position: other, normal: normal, textureCoordinate: [0, 1]),
                    ], indices: [0, 1, 2])
                let result = try source.generatingTangents()
                try expectValidFrames(result)
                #expect(result.vertices.map(\.normal) == source.vertices.map(\.normal))
                #expect(try source.generatingTangents() == result)
                if separation >= 0.00001 {
                    let t = result.vertices[0].tangent
                    #expect(simd_dot(SIMD3(t.x, t.y, t.z), rotation.act(across)) > 0.999)
                }
            }
        }
    }

    @Test(arguments: [Float(-1), 1])
    func ordinaryUVTangentsAndHandednessSurviveReflectedTransforms(uSign: Float) throws {
        let source = MeshData(
            vertices: [
                MeshVertex(position: [0, 0, 0], normal: [0, 0, 1], textureCoordinate: [0, 0]),
                MeshVertex(position: [2, 0, 0], normal: [0, 0, 1], textureCoordinate: [uSign, 0]),
                MeshVertex(position: [0, 3, 0], normal: [0, 0, 1], textureCoordinate: [0, 1]),
            ], indices: [0, 1, 2], materialIndices: [2])
        let mesh = try source.generatingTangents()
        try expectValidFrames(mesh)
        #expect(mesh.vertices.allSatisfy { $0.tangent == SIMD4(uSign, 0, 0, uSign) })
        #expect(mesh.indices == source.indices && mesh.materialIndices == source.materialIndices)
        let rotation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        let transformed = mesh.transformed(by: ModelTransform(scale: [-2, 3, 0.5], rotation: rotation))
        try expectValidFrames(transformed)
        #expect(transformed.indices == [0, 2, 1])
        for vertex in transformed.vertices {
            let t = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
            #expect(simd_distance(t, rotation.act(SIMD3(-uSign, 0, 0))) < 0.000001)
            #expect(vertex.tangent.w == -uSign)
            #expect(simd_dot(simd_cross(vertex.normal, t) * vertex.tangent.w, rotation.act([0, 1, 0])) > 0.999)
        }
    }

    @Test func missingUVDirectionsHaveDeterministicValidFallbacksWithoutRepairingInvalidNormals() throws {
        let mesh = try MeshBuilder.box(size: [1, 1, 1])
        var collapsedUV = mesh
        for i in collapsedUV.vertices.indices { collapsedUV.vertices[i].textureCoordinate = .zero }
        let generated = try collapsedUV.generatingTangents()
        try expectValidFrames(generated)
        #expect(try generated.generatingTangents() == generated)
        var invalid = collapsedUV
        invalid.vertices[0].normal = [0, 2, 0]
        #expect(throws: ModelValidationError.self) { try invalid.generatingTangents().validated() }
    }

    private func sections(_ profile: Profile2D, endScale: Float = 1) -> [LoftSection] {
        // The same orientation as a straight +y sweep: local x -> +z, y -> +x, z -> +y.
        let rotation = simd_quatf(simd_float3x3(columns: ([0, 0, 1], [1, 0, 0], [0, 1, 0])))
        return [Float(1), endScale].enumerated().map { i, scale in
            LoftSection(
                profile: profile.outer,
                transform: ModelTransform(
                    scale: SIMD3(repeating: scale), rotation: rotation, translation: [0, Float(i) * 2, 0]))
        }
    }

    private func expectValidFrames(_ mesh: MeshData) throws {
        _ = try mesh.validated()
        for vertex in mesh.vertices {
            let tangent = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
            #expect(abs(simd_length(tangent) - 1) < 0.000001)
            #expect(abs(simd_dot(vertex.normal, tangent)) < 0.000001)
            #expect(abs(vertex.tangent.w) == 1)
        }
    }
}
