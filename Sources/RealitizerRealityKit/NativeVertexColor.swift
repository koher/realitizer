import Realitizer
import RealityKit

/// MeshBufferContainer lacks a public color accessor. Obtain its actual semantic from
/// LowLevelMesh's public color attribute instead of relying on a private buffer-name string.
/// Refill all buffers from authored data: low-level resource contents need not contain CPU vertices.
@MainActor enum NativeVertexColor {
    struct Semantic: MeshBufferSemantic {
        typealias Element = SIMD4<Float>
        let id: MeshBuffers.Identifier
    }
    private static var cached: Semantic?

    static func semantic() throws -> Semantic {
        if let cached { return cached }
        let mesh = try MeshBuilder.surface(uSegments: 1, vSegments: 1) { [$0.x, $0.y, 0] }
        let dynamic = try DynamicModelMesh(mesh: mesh)
        guard let part = dynamic.resource.contents.models.first?.parts.first,
            let identifier = part.buffers.first(where: {
                $0.key.isCustom && $0.value.elementType == .simd4Float
            })?.key
        else {
            throw ModelRenderingResourceError.vertexColorSemanticUnavailable
        }
        let semantic = Semantic(id: identifier)
        cached = semantic
        return semantic
    }
}
