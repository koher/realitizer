import Metal
import Realitizer
import RealityKit
import simd

/// Fixed-capacity vertex/index buffers. Updates retain the MeshResource and refresh drawable bounds.
@MainActor
public final class DynamicModelMesh {
    public let lowLevelMesh: LowLevelMesh
    public let resource: MeshResource
    public private(set) var data: MeshData

    public init(mesh: MeshData, vertexCapacity: Int? = nil, indexCapacity: Int? = nil) throws {
        _ = try mesh.validated()
        let vertices = vertexCapacity ?? mesh.vertices.count
        let indices = indexCapacity ?? mesh.indices.count
        guard vertices >= mesh.vertices.count, indices >= mesh.indices.count else {
            throw DynamicMeshError.capacityExceeded
        }
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: vertices,
            vertexAttributes: [
                .init(semantic: .position, format: .float3, offset: 0),
                .init(semantic: .normal, format: .float3, offset: 16),
                .init(semantic: .uv0, format: .float2, offset: 32),
                .init(semantic: .tangent, format: .float3, offset: 48),
                .init(semantic: .bitangent, format: .float3, offset: 64),
                .init(semantic: .color, format: .float4, offset: 80),
            ], vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<DynamicVertex>.stride)],
            indexCapacity: indices)
        lowLevelMesh = try LowLevelMesh(descriptor: descriptor)
        resource = try MeshResource(from: lowLevelMesh)
        data = mesh
        try update(mesh)
    }

    public func update(_ mesh: MeshData) throws {
        _ = try mesh.validated()
        guard mesh.vertices.count <= lowLevelMesh.vertexCapacity, mesh.indices.count <= lowLevelMesh.indexCapacity
        else { throw DynamicMeshError.capacityExceeded }
        updateValidated(mesh)
    }

    // Caller has validated geometry and capacity before committing a multi-part transaction.
    func updateValidated(_ mesh: MeshData) {
        let vertices = mesh.vertices.map { vertex -> DynamicVertex in
            let t = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
            return DynamicVertex(
                position: vertex.position, normal: vertex.normal, uv: vertex.textureCoordinate, tangent: t,
                bitangent: simd_cross(vertex.normal, t) * vertex.tangent.w, color: vertex.color.linearRGBA)
        }
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
            vertices.withUnsafeBytes { bytes in buffer.copyMemory(from: bytes) }
        }
        // Material grouping changes only index order; vertex indices and skin correspondence remain intact.
        let slots = mesh.materialIndices.isEmpty ? [UInt32(0)] : Set(mesh.materialIndices).sorted()
        var indices: [UInt32] = []
        var parts: [LowLevelMesh.Part] = []
        let bounds = mesh.bounds!
        for slot in slots {
            let start = indices.count
            for i in 0..<mesh.triangleCount where mesh.materialIndices.isEmpty || mesh.materialIndices[i] == slot {
                indices += mesh.indices[(i * 3)..<(i * 3 + 3)]
            }
            parts.append(
                LowLevelMesh.Part(
                    indexOffset: start * MemoryLayout<UInt32>.stride, indexCount: indices.count - start,
                    materialIndex: Int(slot), bounds: BoundingBox(min: bounds.minimum, max: bounds.maximum)))
        }
        lowLevelMesh.withUnsafeMutableIndices { buffer in indices.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        lowLevelMesh.parts.replaceAll(parts)
        data = mesh
    }

    /// Streams only the modified vertex byte range. The caller supplies updated normals and tangents.
    /// Topology/material slots remain unchanged; bounds and the CPU reference data are refreshed.
    public func updateVertices(in range: Range<Int>, with vertices: [MeshVertex]) throws {
        guard range.lowerBound >= 0, range.upperBound <= data.vertices.count, range.count == vertices.count else {
            throw DynamicMeshError.invalidRange
        }
        if range.isEmpty { return }
        var updated = data
        updated.vertices.replaceSubrange(range, with: vertices)
        // Topology and untouched attributes were validated when installed. Avoid
        // allocating diagnostic paths and triangle arrays for every valid frame.
        try validateVertexUpdate(vertices, in: range, mesh: updated)
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
            let destination = buffer.bindMemory(to: DynamicVertex.self)
            for (offset, vertex) in vertices.enumerated() {
                let tangent = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
                destination[range.lowerBound + offset] = DynamicVertex(
                    position: vertex.position, normal: vertex.normal, uv: vertex.textureCoordinate, tangent: tangent,
                    bitangent: simd_cross(vertex.normal, tangent) * vertex.tangent.w, color: vertex.color.linearRGBA)
            }
        }
        let bounds = updated.bounds!
        let parts = lowLevelMesh.parts.map { part in
            var result = part
            result.bounds = BoundingBox(min: bounds.minimum, max: bounds.maximum)
            return result
        }
        lowLevelMesh.parts.replaceAll(parts)
        data = updated
    }

    private func validateVertexUpdate(_ vertices: [MeshVertex], in range: Range<Int>, mesh: MeshData) throws {
        func invalid(_ code: String, _ path: String, _ message: String) -> ModelValidationError {
            ModelValidationError(diagnostics: [ModelDiagnostic(severity: .error, code: code, path: path, message: message)])
        }
        for (offset, v) in vertices.enumerated() {
            guard v.color.isNormalized else {
                throw invalid("mesh.invalidColor", "mesh.vertices[\(range.lowerBound + offset)]",
                              "Vertex color channels must be finite and in [0, 1].")
            }
            guard v.position.x.isFinite, v.position.y.isFinite, v.position.z.isFinite,
                v.normal.x.isFinite, v.normal.y.isFinite, v.normal.z.isFinite,
                v.textureCoordinate.x.isFinite, v.textureCoordinate.y.isFinite,
                v.tangent.x.isFinite, v.tangent.y.isFinite, v.tangent.z.isFinite, v.tangent.w.isFinite else {
                throw invalid("mesh.nonFiniteVertex", "mesh.vertices[\(range.lowerBound + offset)]", "Vertex data must be finite.")
            }
            let t = SIMD3(v.tangent.x, v.tangent.y, v.tangent.z)
            guard abs(simd_length(v.normal) - 1) <= 0.001 else {
                throw invalid("mesh.invalidNormal", "mesh.vertices[\(range.lowerBound + offset)]", "Vertex normal must be normalized.")
            }
            guard abs(simd_length(t) - 1) <= 0.001, abs(simd_dot(v.normal, t)) <= 0.001,
                abs(abs(v.tangent.w) - 1) <= 0.001
            else {
                throw invalid("mesh.invalidTangent", "mesh.vertices[\(range.lowerBound + offset)]", "Tangents must be unit vectors perpendicular to normals with handedness -1 or 1.")
            }
        }
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[triangle]), b = Int(mesh.indices[triangle + 1]), c = Int(mesh.indices[triangle + 2])
            if !range.contains(a), !range.contains(b), !range.contains(c) { continue }
            let area = simd_length(simd_cross(mesh.vertices[b].position - mesh.vertices[a].position,
                mesh.vertices[c].position - mesh.vertices[a].position))
            guard area.isFinite, area > 1e-12 else {
                throw invalid("mesh.degenerateTriangle", "mesh.triangles[\(triangle / 3)]", "Triangle area is below the allowed tolerance.")
            }
        }
    }
}

// Shared with the GPU wave kernel; keep its Metal layout and layout tests in sync.
package struct DynamicVertex {
    package init(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>, tangent: SIMD3<Float>, bitangent: SIMD3<Float>,
                 color: SIMD4<Float> = .one) {
        self.position = position; self.normal = normal; self.uv = uv
        self.tangent = tangent; self.bitangent = bitangent
        self.color = color
    }
    package var position: SIMD3<Float>
    package var normal: SIMD3<Float>
    package var uv: SIMD2<Float>
    package var tangent: SIMD3<Float>
    package var bitangent: SIMD3<Float>
    package var color: SIMD4<Float>
}
public enum DynamicMeshError: Error { case capacityExceeded, invalidRange }
