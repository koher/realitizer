import Foundation
import Testing
import simd

@testable import Realitizer

@Test func automaticUVChartsArePackedDeterministicAndPreserveAttributes() throws {
    let mesh = try MeshBuilder.box(size: [1, 2, 3]).coloring { vertex in
        RGBAColor(sRGB: [vertex.position.x + 0.5, 0.4, 0.6])
    }
    let atlas = try MeshProcessor.unwrapUV(of: mesh)
    let repeated = try MeshProcessor.unwrapUV(of: mesh)
    #expect(atlas.processing.mesh == repeated.processing.mesh)
    #expect(atlas.islands.count == 6)
    #expect(atlas.islands.flatMap(\.triangles).sorted() == Array(0..<mesh.triangleCount))
    for (i, island) in atlas.islands.enumerated() {
        #expect(island.minimum.x >= 0.00499 && island.minimum.y >= 0.00499)
        #expect(island.maximum.x <= 0.99501 && island.maximum.y <= 0.99501)
        for other in atlas.islands.dropFirst(i + 1) {
            let separated =
                island.maximum.x + 0.00999 <= other.minimum.x
                || other.maximum.x + 0.00999 <= island.minimum.x
                || island.maximum.y + 0.00999 <= other.minimum.y
                || other.maximum.y + 0.00999 <= island.minimum.y
            #expect(separated)
        }
    }
    for (i, row) in atlas.processing.vertexMap.contributions.enumerated() {
        let original = mesh.vertices[row[0].sourceIndex]
        let result = atlas.processing.mesh.vertices[i]
        #expect(
            result.position == original.position && result.normal == original.normal
                && result.color == original.color)
    }
}

@Test func automaticUVHandlesCurvesConcavityAndBoundGeometry() throws {
    let curved = try MeshBuilder.sphere(radius: 1, latitudeSegments: 12, longitudeSegments: 24)
    let charted = try curved.unwrappingUV()
    #expect(charted.triangleCount == curved.triangleCount)
    for v in charted.vertices {
        #expect(v.textureCoordinate.x >= 0 && v.textureCoordinate.x <= 1)
        #expect(v.textureCoordinate.y >= 0 && v.textureCoordinate.y <= 1)
    }
    let joint = AnyRealitizerID("joint")
    let rig = RigDefinition(id: AnyRealitizerID("rig"), joints: [JointDefinition(id: joint)])
    let geometry = try ModelGeometry(mesh: curved).binding(to: rig) { _ in
        [JointWeight(joint, weight: 1)]
    }
    .addingMorph(id: AnyRealitizerID("wide")) { $0.position * SIMD3(1.2, 1, 1) }
    let result = try geometry.unwrappingUV()
    try result.validate()
    for i in result.mesh.vertices.indices {
        #expect(result.skin!.influences[i] == [JointWeight(joint, weight: 1)])
        #expect(
            abs(
                result.morphTargets[0].positionDeltas[i].x - result.mesh.vertices[i].position.x
                    * 0.2)
                < 1e-6)
    }
    let concave = try lPrism().renderMesh().unwrappingUV()
    #expect(concave.triangleCount > 0)
}

@Test func invalidUVOptionsAndImpossiblePaddingThrow() throws {
    let mesh = try MeshBuilder.box(size: [1, 1, 1])
    for options in [
        UVUnwrapOptions(maximumNormalDeviation: .nan),
        .init(maximumNormalDeviation: .pi / 2), .init(padding: -1), .init(padding: 0.49),
    ] {
        #expect(throws: ModelValidationError.self) { try mesh.unwrappingUV(options) }
    }
}

@Test func uvConnectivityAndMaterialBoundariesAreExplicit() throws {
    let plane = try MeshBuilder.surface(uSegments: 1, vSegments: 1) { [$0.x, $0.y, 0] }
    let split = MeshData(
        vertices: plane.indices.map { plane.vertices[Int($0)] },
        indices: Array(0..<UInt32(plane.indices.count)), materialIndices: [0, 1])
    #expect(try MeshProcessor.unwrapUV(of: split).islands.count == 2)
    #expect(
        try MeshProcessor.unwrapUV(of: split, options: .init(respectMaterialBoundaries: false))
            .islands
            .count == 1)
    #expect(
        try MeshProcessor.unwrapUV(
            of: split, options: .init(welding: .none, respectMaterialBoundaries: false)
        ).islands.count == 2)
}

@Test func vertexColorsSurviveTransformsFinishingTopologyAndSerialization() throws {
    let original = try MeshBuilder.box(size: [1, 1, 1]).coloring { _ in
        RGBAColor(sRGB: [0.1, 0.5, 0.8], alpha: 0.4)
    }
    let processed = try original.transformed(by: ModelTransform(scale: [-2, 1, 3]))
        .recalculatingNormals().unwrappingUV()
    #expect(processed.vertices.allSatisfy { $0.color == original.vertices[0].color })
    var topology = try EditableMesh(renderMesh: original, welding: .exactPositions)
    try topology.extrude(faces: topology.selectFaces { $0.normal.y > 0.9 }, offset: [0, 0.3, 0])
    #expect(
        try topology.renderMesh().vertices.allSatisfy { $0.color == original.vertices[0].color })
    let encoded = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(MeshData.self, from: encoded) == original)
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(original.vertices[0]))
            as? [String: Any]
    )
    object.removeValue(forKey: "color")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(MeshVertex.self, from: legacy).color == .white)
    #expect(throws: ModelValidationError.self) {
        try original.coloring { _ in RGBAColor(red: .nan, green: 0, blue: 0) }
    }
    let midpoint = RGBAColor(red: 0, green: 0, blue: 0).interpolated(to: .white, fraction: 0.5)
    #expect(abs(midpoint.linearSRGB.x - 0.5) < 1e-6)
}

@Test func bevelHasConstantWidthAndCircularBandsOnUnequalBox() throws {
    let source = try boxTopology()
    let flat = try source.beveled(width: 0.1).renderMesh()
    #expect(abs(flat.bounds!.size.x - 2) < 1e-5)
    #expect(flat.vertices.contains { simd_distance($0.position, [0.9, 1.5, 1.9]) < 1e-5 })
    let rounded = try source.beveled(width: 0.1, segments: 4)
    try rounded.validate(requireClosed: true)
    let mesh = try rounded.renderMesh()
    #expect(mesh.triangleCount > flat.triangleCount)
    #expect(mesh.signedVolume > 0 && mesh.signedVolume < 24)
    let edgePoints = mesh.vertices.filter {
        abs($0.position.y - 1.4) < 1e-5 && $0.position.x > 0.9 && $0.position.z > 1.9
    }
    #expect(!edgePoints.isEmpty)
    for point in edgePoints {
        let p = point.position
        #expect(abs(simd_length(SIMD2(p.x - 0.9, p.z - 1.9)) - 0.1) < 1e-5)
    }
}

@Test func bevelSupportsConcaveMeshesSelectionAndTriangleInput() throws {
    for segments in [1, 3] {
        let concave = try lPrism().beveled(width: 0.08, segments: segments)
        try concave.validate(requireClosed: true)
        #expect(try concave.renderMesh().signedVolume > 0)
        let box = try boxTopology()
        let edges = try box.selectEdges {
            abs($0.center.z - 2) < 1e-5 && abs($0.center.y - 1.5) < 1e-5
        }
        #expect(edges.count == 1)
        let selected = try box.beveled(edges: edges, width: 0.1, segments: segments, material: 1)
        try selected.validate(requireClosed: true)
        #expect(try selected.renderMesh().materialIndices.contains(1))
        let triangles = try EditableMesh(
            renderMesh: MeshBuilder.box(size: [2, 3, 4]), welding: .exactPositions)
        try triangles.beveled(width: 0.1, segments: segments).validate(requireClosed: true)
    }
}

@Test func bevelRejectsOversizedWidthsAndInvalidSelections() throws {
    let mesh = try boxTopology()
    for width: Float in [0, -1, .nan, 3] {
        #expect(throws: ModelValidationError.self) { try mesh.beveled(width: width) }
    }
    #expect(throws: ModelValidationError.self) { try mesh.beveled(width: 0.1, segments: 0) }
    #expect(throws: ModelValidationError.self) {
        try mesh.beveled(edges: [MeshEdge(VertexID(99), VertexID(100))], width: 0.1)
    }
    let open = try EditableMesh(
        positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], polygons: [[0, 1, 2]])
    #expect(throws: ModelValidationError.self) { try open.beveled(width: 0.1) }
}

private func boxTopology() throws -> EditableMesh {
    try EditableMesh(
        positions: [
            [-1, -1.5, -2], [1, -1.5, -2], [1, 1.5, -2], [-1, 1.5, -2],
            [-1, -1.5, 2], [1, -1.5, 2], [1, 1.5, 2], [-1, 1.5, 2],
        ],
        polygons: [
            [0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5],
        ])
}

@Test(arguments: [1, 3]) func bevelSupportsEdgePairsAndCylinderRims(segments: Int) throws {
    let box = try boxTopology()
    let edges = try box.selectEdges { _ in true }
    for i in edges.indices {
        let selection = [edges[i], edges[(i + 1) % edges.count]]
        let result = try box.beveled(edges: selection, width: 0.08, segments: segments)
        try result.validate(requireClosed: true)
    }
    let cylinder = try EditableMesh(
        renderMesh: MeshBuilder.cylinder(radius: 1, height: 2, segments: 16),
        welding: .exactPositions)
    let rims = try cylinder.selectEdges { ($0.angle ?? 0) > .pi / 4 }
    #expect(rims.count == 32)
    try cylinder.beveled(edges: rims, width: 0.05, segments: segments).validate(requireClosed: true)
    let unchanged = try cylinder.beveled(edges: [], width: 0.1)
    #expect(unchanged.faces == cylinder.faces && unchanged.positions == cylinder.positions)
}

@Test func coloredResamplingRequiresExplicitAttributeDiscard() throws {
    let mesh = try MeshBuilder.box(size: [1, 1, 1]).coloring { _ in RGBAColor(sRGB: [1, 0, 0]) }
    #expect(throws: ModelValidationError.self) { try mesh.remeshed(resolution: 8) }
    #expect(throws: ModelValidationError.self) {
        try mesh.boolean(.union, with: mesh, resolution: 8)
    }
    #expect(try mesh.coloring { _ in .white }.remeshed(resolution: 8).triangleCount > 0)
    let uncolored = try boxTopology().beveled(width: 0.08, segments: 3).renderMesh()
    #expect(uncolored.vertices.allSatisfy { $0.color == .white })
    #expect(try boxTopology().subdivided().renderMesh().vertices.allSatisfy { $0.color == .white })
    #expect(try uncolored.remeshed(resolution: 8).triangleCount > 0)
}

private func lPrism() throws -> EditableMesh {
    let outline: [SIMD2<Float>] = [[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]]
    let points =
        outline.map { SIMD3($0.x, $0.y, Float(0)) } + outline.map { SIMD3($0.x, $0.y, Float(1)) }
    let sides = outline.indices.map { i in [i, (i + 1) % 6, (i + 1) % 6 + 6, i + 6] }
    return try EditableMesh(
        positions: points, polygons: [Array((0..<6).reversed()), Array(6..<12)] + sides)
}
