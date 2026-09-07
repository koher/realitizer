import Foundation

extension MeshVertex {
    private enum CodingKeys: String, CodingKey {
        case position, normal, textureCoordinate, tangent, color
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            position: try values.decode(SIMD3<Float>.self, forKey: .position),
            normal: try values.decode(SIMD3<Float>.self, forKey: .normal),
            textureCoordinate: try values.decode(SIMD2<Float>.self, forKey: .textureCoordinate),
            tangent: try values.decode(SIMD4<Float>.self, forKey: .tangent),
            color: try values.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .white)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(position, forKey: .position)
        try values.encode(normal, forKey: .normal)
        try values.encode(textureCoordinate, forKey: .textureCoordinate)
        try values.encode(tangent, forKey: .tangent)
        try values.encode(color, forKey: .color)
    }
}

extension MeshData {
    /// Samples source vertices without changing topology, UVs, normals or material slots.
    public func coloring(_ sample: (MeshVertex) throws -> RGBAColor) throws -> Self {
        _ = try validated()
        var result = self
        for i in vertices.indices { result.vertices[i].color = try sample(vertices[i]) }
        return try result.validated()
    }
}

extension MeshCorner {
    private enum CodingKeys: String, CodingKey { case vertex, uv, color }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try values.decode(VertexID.self, forKey: .vertex),
            uv: try values.decode(SIMD2<Float>.self, forKey: .uv),
            color: try values.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .white)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(vertex, forKey: .vertex)
        try values.encode(uv, forKey: .uv)
        try values.encode(color, forKey: .color)
    }
}

extension ModelGeometry {
    /// Recolors the base mesh while preserving its skin and morph correspondence.
    public func coloring(_ sample: (MeshVertex) throws -> RGBAColor) throws -> Self {
        try validate()
        return Self(mesh: try mesh.coloring(sample), skin: skin, morphTargets: morphTargets)
    }
}
