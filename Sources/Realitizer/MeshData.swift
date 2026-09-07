import simd

/// One render vertex produced by the modeling layer.
public struct MeshVertex: Equatable, Sendable, Codable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var textureCoordinate: SIMD2<Float>
    /// Non-premultiplied sRGB authoring color. Renderers interpolate in linear light.
    /// White leaves the material's base color and texture unchanged.
    public var color: RGBAColor
    /// xyz is the unit tangent; w is the bitangent handedness.
    public var tangent: SIMD4<Float>

    public init(
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        textureCoordinate: SIMD2<Float> = .zero,
        tangent: SIMD4<Float>? = nil,
        color: RGBAColor = .white
    ) {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
        self.tangent = tangent ?? SIMD4(orthogonal(to: normal), 1)
        self.color = color
    }
}

/// An axis-aligned bound for generated geometry.
public struct MeshBounds: Equatable, Sendable, Codable {
    public var minimum: SIMD3<Float>
    public var maximum: SIMD3<Float>

    public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var center: SIMD3<Float> {
        (minimum + maximum) * 0.5
    }

    public var size: SIMD3<Float> {
        maximum - minimum
    }
}

/// RealityKit-independent indexed triangle data.
public struct MeshData: Equatable, Sendable, Codable {
    public var vertices: [MeshVertex]
    public var indices: [UInt32]
    /// Empty means material slot zero for every triangle.
    public var materialIndices: [UInt32]

    public init(vertices: [MeshVertex], indices: [UInt32], materialIndices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
        self.materialIndices = materialIndices
    }

    public var bounds: MeshBounds? {
        guard let first = vertices.first?.position else {
            return nil
        }

        var minimum = first
        var maximum = first
        for vertex in vertices.dropFirst() {
            minimum = simd_min(minimum, vertex.position)
            maximum = simd_max(maximum, vertex.position)
        }
        return MeshBounds(minimum: minimum, maximum: maximum)
    }

    public func transformed(by transform: ModelTransform) -> Self {
        let reflected = transform.scale.x * transform.scale.y * transform.scale.z < 0
        let mapped = vertices.map { vertex -> MeshVertex in
            let n = transform.applyingToNormal(vertex.normal)
            let oldTangent = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
            let rawTangent = transform.rotation.act(transform.scale * oldTangent)
            let t = orthonormalTangent(rawTangent, normal: n)
            return MeshVertex(
                position: transform.applying(to: vertex.position), normal: n,
                textureCoordinate: vertex.textureCoordinate, tangent: SIMD4(t, vertex.tangent.w * (reflected ? -1 : 1)),
                color: vertex.color)
        }
        var mappedIndices = indices
        if reflected {
            for i in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
                mappedIndices.swapAt(i + 1, i + 2)
            }
        }
        return Self(vertices: mapped, indices: mappedIndices, materialIndices: materialIndices)
    }

    public func validationDiagnostics(
        path: String = "mesh",
        epsilon: Float = 0.000_001
    ) -> [ModelDiagnostic] {
        var diagnostics: [ModelDiagnostic] = []

        if !materialIndices.isEmpty && materialIndices.count != indices.count / 3 {
            diagnostics.append(
                .error("mesh.materialCount", path: path, "Material indices must match the triangle count."))
        }

        if vertices.isEmpty {
            diagnostics.append(.error("mesh.empty", path: path, "Mesh has no vertices."))
        }
        if indices.isEmpty {
            diagnostics.append(.error("mesh.noIndices", path: path, "Mesh has no indices."))
        }
        if !indices.count.isMultiple(of: 3) {
            diagnostics.append(
                .error(
                    "mesh.invalidIndexCount",
                    path: path,
                    "Triangle index count must be a multiple of three."
                )
            )
        }

        for (index, vertex) in vertices.enumerated() {
            let vertexPath = "\(path).vertices[\(index)]"
            if !vertex.color.isNormalized {
                diagnostics.append(.error("mesh.invalidColor", path: vertexPath,
                    "Vertex color channels must be finite and in [0, 1]."))
            }
            if !vertex.position.isFinite || !vertex.normal.isFinite || !vertex.textureCoordinate.isFinite
                || !vertex.tangent.isFinite
            {
                diagnostics.append(
                    .error("mesh.nonFiniteVertex", path: vertexPath, "Vertex data must be finite.")
                )
            }
            let normalLength = simd_length(vertex.normal)
            let tangent = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
            if abs(simd_length(tangent) - 1) > 0.001 || abs(simd_dot(vertex.normal, tangent)) > 0.001
                || abs(abs(vertex.tangent.w) - 1) > 0.001
            {
                diagnostics.append(
                    .error(
                        "mesh.invalidTangent", path: vertexPath,
                        "Tangents must be unit vectors perpendicular to normals with handedness -1 or 1."))
            }
            if !normalLength.isFinite || abs(normalLength - 1) > 0.001 {
                diagnostics.append(
                    .error(
                        "mesh.invalidNormal",
                        path: vertexPath,
                        "Vertex normal must be normalized."
                    )
                )
            }
        }

        for (offset, index) in indices.enumerated() where Int(index) >= vertices.count {
            diagnostics.append(
                .error(
                    "mesh.indexOutOfRange",
                    path: "\(path).indices[\(offset)]",
                    "Index \(index) is outside the vertex buffer."
                )
            )
        }

        if indices.count.isMultiple(of: 3) {
            for triangle in stride(from: 0, to: indices.count, by: 3) {
                let triangleIndices = indices[triangle..<(triangle + 3)].map(Int.init)
                guard triangleIndices.allSatisfy({ $0 < vertices.count }) else {
                    continue
                }
                let a = vertices[triangleIndices[0]].position
                let b = vertices[triangleIndices[1]].position
                let c = vertices[triangleIndices[2]].position
                let doubledArea = simd_length(simd_cross(b - a, c - a))
                if !doubledArea.isFinite || doubledArea <= epsilon * epsilon {
                    diagnostics.append(
                        .error(
                            "mesh.degenerateTriangle",
                            path: "\(path).triangles[\(triangle / 3)]",
                            "Triangle area is below the allowed tolerance."
                        )
                    )
                }
            }
        }

        return diagnostics
    }

    public func validated(path: String = "mesh") throws -> Self {
        let report = ModelValidationReport(diagnostics: validationDiagnostics(path: path))
        try report.throwingIfNeeded()
        return self
    }
}
