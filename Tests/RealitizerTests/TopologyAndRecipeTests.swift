import Foundation
import Realitizer
import Testing

func editableCube() throws -> EditableMesh {
    try EditableMesh(
        positions: [
            [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1],
            [-1, 1, 1],
        ],
        polygons: [
            [0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4],
        ])
}

@Test func topologyEditsPreserveUnaffectedIDsAndClosedEdges() throws {
    var mesh = try editableCube()
    try mesh.validate(requireClosed: true)
    let top = mesh.selectFaces(normal: [0, 1, 0])[0]
    let untouched = mesh.positions[VertexID(0)]
    try mesh.inset(face: top, fraction: 0.2)
    try mesh.extrude(face: top, distance: 0.5)
    try mesh.validate(requireClosed: true)
    #expect(mesh.positions[VertexID(0)] == untouched)
    #expect(mesh.faces[top] != nil)
    #expect(try mesh.halfEdges().allSatisfy { $0.oppositeFace != nil })
    #expect(try mesh.renderMesh().signedVolume > 8)
}

@Test func bevelAndSubdivisionProduceClosedRenderableSurfaces() throws {
    let cube = try editableCube()
    let beveled = try cube.chamfered(fraction: 0.15)
    try beveled.validate(requireClosed: true)
    let chamfered = try beveled.renderMesh()
    #expect(chamfered.signedVolume > 5 && chamfered.signedVolume < 8)
    let subdivided = try cube.subdivided(iterations: 2)
    try subdivided.validate(requireClosed: true)
    #expect(try subdivided.renderMesh(smoothingAngle: .pi).validationDiagnostics().isEmpty)
}

@Test func implicitBooleanCreatesAClosedLookingCavityWithPositiveVolume() throws {
    let field = DistanceField.subtraction(
        .box(center: .zero, halfSize: [1, 1, 1], rounding: 0.1),
        .sphere(center: [0, 0.5, 0], radius: 0.7))
    let mesh = try field.mesh(
        in: MeshBounds(minimum: [-1.2, -1.2, -1.2], maximum: [1.2, 1.2, 1.2]), resolution: 16)
    #expect(mesh.signedVolume > 4 && mesh.signedVolume < 8)
    #expect(mesh.validationDiagnostics().isEmpty)
}

@Test func recipesRoundTripCacheSharedReferencesAndRejectCyclesAndOversizedArrays() throws {
    let recipe = ModelingRecipe(
        definitions: ["pillar": .cylinder(radius: 0.2, height: 2)],
        root: .group([
            .reference("pillar"),
            .transformed(.reference("pillar"), ModelTransform(translation: [1, 0, 0])),
        ]))
    let decoded = try ModelingRecipe.decode(JSONEncoder().encode(recipe))
    let result = try decoded.evaluate()
    let repeated = try recipe.evaluate()
    #expect(result.mesh == repeated.mesh)
    #expect(result.cachedReferences == 1)
    #expect(throws: ModelValidationError.self) {
        try ModelingRecipe(definitions: ["cycle": .reference("cycle")], root: .reference("cycle"))
            .evaluate()
    }
    #expect(throws: ModelValidationError.self) {
        try ModelingRecipe(
            root: .array(.box(size: [1, 1, 1]), transforms: Array(repeating: .identity, count: 100))
        )
        .evaluate(
            quality: ModelQualityProfile(budget: GeometryBudget(maximumVertices: 50)))
    }
}
