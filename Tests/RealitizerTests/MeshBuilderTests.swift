import Realitizer
import Testing

@Test
func boxProducesValidatedFlatShadedGeometry() throws {
    let mesh = try MeshBuilder.box(size: [2, 4, 6])

    #expect(mesh.vertices.count == 24)
    #expect(mesh.indices.count == 36)
    #expect(mesh.bounds?.minimum == [-1, -2, -3])
    #expect(mesh.bounds?.maximum == [1, 2, 3])
    #expect(mesh.validationDiagnostics().isEmpty)
}

@Test
func composedMeshAppliesLocalTransforms() throws {
    let source = try MeshBuilder.box(size: [1, 1, 1])
    var builder = MeshBuilder()
    builder.append(source)
    builder.append(source, transform: ModelTransform(translation: [2, 0, 0]))

    let mesh = try builder.build()

    #expect(mesh.vertices.count == 48)
    #expect(mesh.bounds?.minimum == [-0.5, -0.5, -0.5])
    #expect(mesh.bounds?.maximum == [2.5, 0.5, 0.5])
}

@Test
func invalidPrimitiveReturnsMachineReadableDiagnostics() {
    #expect(throws: ModelValidationError.self) {
        try MeshBuilder.cylinder(radius: 1, height: 2, segments: 2)
    }
}

@Test
func curvedPrimitivesProduceValidatedGeometry() throws {
    let sphere = try MeshBuilder.sphere(
        radius: 1,
        latitudeSegments: 8,
        longitudeSegments: 12
    )
    let cone = try MeshBuilder.cone(radius: 0.5, height: 2, segments: 12)

    #expect(sphere.validationDiagnostics().isEmpty)
    #expect(cone.validationDiagnostics().isEmpty)
    #expect(sphere.bounds?.size.y == 2)
}
