import simd

/// A deterministic accumulator for indexed triangle meshes.
public struct MeshBuilder: Sendable {
    public private(set) var vertices: [MeshVertex] = []
    public private(set) var indices: [UInt32] = []
    public private(set) var materialIndices: [UInt32] = []

    public init() {}

    public mutating func append(_ mesh: MeshData, transform: ModelTransform = .identity) {
        let transformed = mesh.transformed(by: transform)
        let baseIndex = UInt32(vertices.count)
        vertices.append(contentsOf: transformed.vertices)
        indices.append(contentsOf: transformed.indices.map { $0 + baseIndex })
        materialIndices.append(
            contentsOf: transformed.materialIndices.isEmpty
                ? Array(repeating: 0, count: transformed.indices.count / 3) : transformed.materialIndices)
    }

    public mutating func addTriangle(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) {
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        let normal = length > 0 ? cross / length : SIMD3<Float>.zero
        appendTriangle(
            positions: [a, b, c],
            normals: [normal, normal, normal],
            textureCoordinates: [[0, 0], [1, 0], [0.5, 1]]
        )
    }

    public func build(path: String = "mesh") throws -> MeshData {
        try MeshData(vertices: vertices, indices: indices, materialIndices: materialIndices).validated(
            path: path)
    }

    public static func box(size: SIMD3<Float>) throws -> MeshData {
        guard size.isFinite, size.x > 0, size.y > 0, size.z > 0 else {
            throw ModelValidationError(
                diagnostics: [
                    .error(
                        "primitive.invalidBoxSize",
                        path: "box.size",
                        "Every box dimension must be finite and greater than zero."
                    )
                ]
            )
        }

        let half = size * 0.5
        let nnn = SIMD3<Float>(-half.x, -half.y, -half.z)
        let pnn = SIMD3<Float>(half.x, -half.y, -half.z)
        let npn = SIMD3<Float>(-half.x, half.y, -half.z)
        let ppn = SIMD3<Float>(half.x, half.y, -half.z)
        let nnp = SIMD3<Float>(-half.x, -half.y, half.z)
        let pnp = SIMD3<Float>(half.x, -half.y, half.z)
        let npp = SIMD3<Float>(-half.x, half.y, half.z)
        let ppp = SIMD3<Float>(half.x, half.y, half.z)

        var builder = Self()
        builder.appendQuad(nnp, pnp, ppp, npp, normal: [0, 0, 1])
        builder.appendQuad(pnn, nnn, npn, ppn, normal: [0, 0, -1])
        builder.appendQuad(nnn, nnp, npp, npn, normal: [-1, 0, 0])
        builder.appendQuad(pnp, pnn, ppn, ppp, normal: [1, 0, 0])
        builder.appendQuad(npp, ppp, ppn, npn, normal: [0, 1, 0])
        builder.appendQuad(nnn, pnn, pnp, nnp, normal: [0, -1, 0])
        return try builder.build(path: "box")
    }

    public static func cylinder(
        radius: Float,
        height: Float,
        segments: Int = 16
    ) throws -> MeshData {
        guard radius.isFinite, radius > 0 else {
            throw ModelValidationError(
                diagnostics: [
                    .error(
                        "primitive.invalidCylinderRadius",
                        path: "cylinder.radius",
                        "Cylinder radius must be finite and greater than zero."
                    )
                ]
            )
        }
        guard height.isFinite, height > 0 else {
            throw ModelValidationError(
                diagnostics: [
                    .error(
                        "primitive.invalidCylinderHeight",
                        path: "cylinder.height",
                        "Cylinder height must be finite and greater than zero."
                    )
                ]
            )
        }
        guard segments >= 3 else {
            throw ModelValidationError(
                diagnostics: [
                    .error(
                        "primitive.invalidCylinderSegments",
                        path: "cylinder.segments",
                        "Cylinder segment count must be at least three."
                    )
                ]
            )
        }

        let halfHeight = height * 0.5
        var builder = Self()
        for segment in 0..<segments {
            let startAngle = Float(segment) / Float(segments) * 2 * .pi
            let endAngle = Float((segment + 1) % segments) / Float(segments) * 2 * .pi
            let startDirection = SIMD3<Float>(cos(startAngle), 0, sin(startAngle))
            let endDirection = SIMD3<Float>(cos(endAngle), 0, sin(endAngle))
            let startBottom = startDirection * radius + SIMD3(0, -halfHeight, 0)
            let startTop = startDirection * radius + SIMD3(0, halfHeight, 0)
            let endBottom = endDirection * radius + SIMD3(0, -halfHeight, 0)
            let endTop = endDirection * radius + SIMD3(0, halfHeight, 0)

            builder.appendQuad(
                positions: [startBottom, startTop, endTop, endBottom],
                normals: [startDirection, startDirection, endDirection, endDirection]
            )
            builder.appendTriangle(
                positions: [[0, halfHeight, 0], endTop, startTop],
                normals: Array(repeating: [0, 1, 0], count: 3),
                textureCoordinates: [[0.5, 0.5], [1, 1], [1, 0]]
            )
            builder.appendTriangle(
                positions: [[0, -halfHeight, 0], startBottom, endBottom],
                normals: Array(repeating: [0, -1, 0], count: 3),
                textureCoordinates: [[0.5, 0.5], [1, 0], [1, 1]]
            )
        }
        return try builder.build(path: "cylinder")
    }

    public static func cone(
        radius: Float,
        height: Float,
        segments: Int = 16
    ) throws -> MeshData {
        guard radius.isFinite, radius > 0, height.isFinite, height > 0, segments >= 3 else {
            throw ModelValidationError(
                diagnostics: [
                    .error(
                        "primitive.invalidCone",
                        path: "cone",
                        "Cone dimensions must be finite and greater than zero, with at least three segments."
                    )
                ]
            )
        }

        let halfHeight = height * 0.5
        let apex = SIMD3<Float>(0, halfHeight, 0)
        var builder = Self()
        for segment in 0..<segments {
            let startAngle = Float(segment) / Float(segments) * 2 * .pi
            let endAngle = Float((segment + 1) % segments) / Float(segments) * 2 * .pi
            let startDirection = SIMD3<Float>(cos(startAngle), 0, sin(startAngle))
            let endDirection = SIMD3<Float>(cos(endAngle), 0, sin(endAngle))
            let start = startDirection * radius + SIMD3(0, -halfHeight, 0)
            let end = endDirection * radius + SIMD3(0, -halfHeight, 0)
            let startNormal = simd_normalize(
                SIMD3<Float>(startDirection.x, radius / height, startDirection.z)
            )
            let endNormal = simd_normalize(
                SIMD3<Float>(endDirection.x, radius / height, endDirection.z)
            )
            let apexNormal = simd_normalize(startNormal + endNormal)

            builder.appendTriangle(
                positions: [start, apex, end],
                normals: [startNormal, apexNormal, endNormal],
                textureCoordinates: [[0, 0], [0.5, 1], [1, 0]]
            )
            builder.appendTriangle(
                positions: [[0, -halfHeight, 0], start, end],
                normals: Array(repeating: SIMD3<Float>(0, -1, 0), count: 3),
                textureCoordinates: [[0.5, 0.5], [1, 0], [1, 1]]
            )
        }
        return try builder.build(path: "cone")
    }

    public static func sphere(
        radius: Float,
        latitudeSegments: Int = 12,
        longitudeSegments: Int = 24
    ) throws -> MeshData {
        guard radius.isFinite, radius > 0,
            latitudeSegments >= 2,
            longitudeSegments >= 3
        else {
            throw ModelValidationError(
                diagnostics: [
                    .error(
                        "primitive.invalidSphere",
                        path: "sphere",
                        "Sphere radius must be finite and greater than zero, with at least two latitude and three longitude segments."
                    )
                ]
            )
        }

        var vertices: [MeshVertex] = []
        for latitude in 0...latitudeSegments {
            let v = Float(latitude) / Float(latitudeSegments)
            let phi = v * .pi - .pi / 2
            // Canonical seam/pole positions make the surface exactly closed after welding.
            let ringRadius: Float = latitude == 0 || latitude == latitudeSegments ? 0 : cos(phi)
            let y = sin(phi)
            for longitude in 0...longitudeSegments {
                let u = Float(longitude) / Float(longitudeSegments)
                let theta = Float(longitude % longitudeSegments) / Float(longitudeSegments) * 2 * .pi
                let normal = SIMD3<Float>(ringRadius * cos(theta), y, ringRadius * sin(theta))
                vertices.append(
                    MeshVertex(
                        position: normal * radius,
                        normal: simd_normalize(normal),
                        textureCoordinate: [u, 1 - v]
                    )
                )
            }
        }

        let rowSize = longitudeSegments + 1
        var indices: [UInt32] = []
        for latitude in 0..<latitudeSegments {
            for longitude in 0..<longitudeSegments {
                let lowerLeft = UInt32(latitude * rowSize + longitude)
                let lowerRight = lowerLeft + 1
                let upperLeft = UInt32((latitude + 1) * rowSize + longitude)
                let upperRight = upperLeft + 1
                if latitude > 0 {
                    indices.append(contentsOf: [lowerLeft, upperLeft, lowerRight])
                }
                if latitude < latitudeSegments - 1 {
                    indices.append(contentsOf: [lowerRight, upperLeft, upperRight])
                }
            }
        }
        return try MeshData(vertices: vertices, indices: indices).validated(path: "sphere")
    }

    private mutating func appendQuad(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        _ d: SIMD3<Float>,
        normal: SIMD3<Float>
    ) {
        appendQuad(
            positions: [a, b, c, d],
            normals: Array(repeating: normal, count: 4)
        )
    }

    private mutating func appendQuad(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>]
    ) {
        let baseIndex = UInt32(vertices.count)
        let textureCoordinates: [SIMD2<Float>] = [[0, 0], [0, 1], [1, 1], [1, 0]]
        vertices.append(
            contentsOf: zip(zip(positions, normals), textureCoordinates).map { pair, uv in
                MeshVertex(position: pair.0, normal: pair.1, textureCoordinate: uv)
            }
        )
        indices.append(contentsOf: [
            baseIndex,
            baseIndex + 1,
            baseIndex + 2,
            baseIndex,
            baseIndex + 2,
            baseIndex + 3,
        ])
        materialIndices.append(contentsOf: [0, 0])
    }

    private mutating func appendTriangle(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        textureCoordinates: [SIMD2<Float>]
    ) {
        let baseIndex = UInt32(vertices.count)
        vertices.append(
            contentsOf: zip(zip(positions, normals), textureCoordinates).map { pair, uv in
                MeshVertex(position: pair.0, normal: pair.1, textureCoordinate: uv)
            }
        )
        indices.append(contentsOf: [baseIndex, baseIndex + 1, baseIndex + 2])
        materialIndices.append(0)
    }
}
