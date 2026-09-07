import Realitizer
import RealityKit
import simd

/// A checked CPU view of an immutable native mesh. The original GPU resource is never replaced.
@MainActor
enum NativeModelGeometry {
    static func read(
        _ resource: MeshResource, skeleton expected: MeshResource.Skeleton?,
        maximumVertices: Int, maximumTriangles: Int
    ) throws -> (geometry: ModelGeometry, skeleton: MeshResource.Skeleton?) {
        let contents = resource.contents
        guard contents.models.count == 1, let model = contents.models.first,
            contents.instances.count == 1, let instance = contents.instances.first,
            instance.model == model.id, instance.transform == matrix_identity_float4x4,
            !model.parts.isEmpty
        else {
            throw invalid(
                "A resource needs one model and one identity mesh instance; assemble scene parts explicitly."
            )
        }
        let parts = Array(model.parts)
        let hasSkin = parts[0].jointInfluences != nil
        let morphNames = parts[0].blendShapeNames.sorted()
        let skeleton: MeshResource.Skeleton?
        if hasSkin {
            guard contents.skeletons.count == 1, let native = contents.skeletons.first,
                let expected, matching(native, expected)
            else {
                throw invalid(
                    "The resource skeleton must match the code rig's names, hierarchy, rest and bind transforms."
                )
            }
            skeleton = native
        } else {
            guard contents.skeletons.isEmpty else {
                throw invalid("An unskinned resource cannot contain unused skeletons.")
            }
            skeleton = nil
        }
        var vertexCount = 0
        var triangleCount = 0
        for part in parts {
            guard part.positions.count > 0, let indices = part.triangleIndices,
                indices.count > 0, indices.count.isMultiple(of: 3), part.materialIndex >= 0,
                part.materialIndex <= Int(UInt32.max),
                part.positions.count <= maximumVertices - vertexCount,
                indices.count / 3 <= maximumTriangles - triangleCount,
                (part.jointInfluences != nil) == hasSkin,
                part.skeletonID == skeleton?.id, part.blendShapeNames.sorted() == morphNames
            else {
                throw invalid(
                    "Mesh parts must contain budgeted triangles with consistent skin, morphs and material slots."
                )
            }
            vertexCount += part.positions.count
            triangleCount += indices.count / 3
        }
        guard vertexCount <= Int(UInt32.max) else {
            throw invalid("The resource exceeds the index range.")
        }
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        var materialIndices: [UInt32] = []
        var influences: [[JointWeight]] = []
        var maximumInfluences = 1
        var deltas = Array(repeating: [SIMD3<Float>](), count: morphNames.count)
        vertices.reserveCapacity(vertexCount)
        indices.reserveCapacity(triangleCount * 3)
        let colorSemantic = try NativeVertexColor.semantic()
        for part in parts {
            let count = part.positions.count
            let positions = try values(part.positions, count: count, name: "positions")
            guard let normalBuffer = part.normals, let tangentBuffer = part.tangents,
                let bitangentBuffer = part.bitangents, let uvBuffer = part.textureCoordinates
            else {
                throw invalid(
                    "Resources require authored normals, tangents, bitangents and UVs; finish geometry before saving."
                )
            }
            let normals = try values(normalBuffer, count: count, name: "normals")
            let tangents = try values(tangentBuffer, count: count, name: "tangents")
            let bitangents = try values(bitangentBuffer, count: count, name: "bitangents")
            let uvs = try values(uvBuffer, count: count, name: "UVs")
            let colors = try part[colorSemantic].map {
                try values($0, count: count, name: "colors")
            }
            let offset = UInt32(vertices.count)
            for i in 0..<count {
                let handedness = simd_dot(simd_cross(normals[i], tangents[i]), bitangents[i])
                guard handedness.isFinite, abs(handedness) > 0.000001 else {
                    throw invalid(
                        "Bitangents must define finite, nondegenerate tangent handedness.")
                }
                let color: RGBAColor
                if let colors {
                    let c = colors[i]
                    guard (0..<4).allSatisfy({ c[$0].isFinite && (0...1).contains(c[$0]) }) else {
                        throw invalid(
                            "Vertex colors must contain finite linear sRGB and alpha channels in [0, 1]."
                        )
                    }
                    color = RGBAColor(linearSRGB: [c.x, c.y, c.z], alpha: c.w)
                } else {
                    color = .white
                }
                vertices.append(
                    MeshVertex(
                        position: positions[i], normal: normals[i], textureCoordinate: uvs[i],
                        tangent: SIMD4(tangents[i], handedness < 0 ? -1 : 1), color: color))
            }
            let nativeIndices = part.triangleIndices!.elements
            guard nativeIndices.count == part.triangleIndices!.count,
                nativeIndices.allSatisfy({ $0 < UInt32(count) })
            else {
                throw invalid(
                    "Triangle indices must be CPU-readable and reference existing vertices.")
            }
            indices += nativeIndices.map { offset + $0 }
            materialIndices += Array(
                repeating: UInt32(part.materialIndex), count: nativeIndices.count / 3)
            if let skin = part.jointInfluences, let skeleton {
                let buffer = skin.influences
                guard buffer.count.isMultiple(of: count), (1...8).contains(buffer.count / count),
                    buffer.rate == .vertex
                else {
                    throw invalid("Skin buffers require one through eight influences per vertex.")
                }
                let width = buffer.count / count
                maximumInfluences = max(maximumInfluences, width)
                let weights = buffer.elements
                guard weights.count == buffer.count else {
                    throw invalid("Skin weights must be CPU-readable.")
                }
                for i in 0..<count {
                    var row: [JointWeight] = []
                    for influence in weights[(i * width)..<((i + 1) * width)] {
                        guard influence.weight.isFinite, influence.weight >= 0,
                            skeleton.joints.indices.contains(influence.jointIndex)
                        else {
                            throw invalid(
                                "Skin weights require valid joint indices and finite nonnegative weights."
                            )
                        }
                        if influence.weight > 0 {
                            row.append(
                                JointWeight(
                                    AnyRealitizerID(skeleton.joints[influence.jointIndex].name),
                                    weight: influence.weight))
                        }
                    }
                    influences.append(row)
                }
            }
            for i in morphNames.indices {
                guard let buffer = part.blendShapeOffsets(named: morphNames[i]) else {
                    throw invalid("A declared morph has no position buffer.")
                }
                deltas[i] += try values(buffer, count: count, name: "morph offsets")
            }
        }
        let geometry = ModelGeometry(
            mesh: MeshData(vertices: vertices, indices: indices, materialIndices: materialIndices),
            skin: hasSkin
                ? SkinBinding(influences: influences, maximumInfluences: maximumInfluences) : nil,
            morphTargets: morphNames.indices.map {
                MorphTarget(id: AnyRealitizerID(morphNames[$0]), positionDeltas: deltas[$0])
            })
        try geometry.validate()
        return (geometry, skeleton)
    }

    private static func values<T>(_ buffer: MeshBuffer<T>, count: Int, name: String) throws -> [T] {
        guard buffer.count == count, buffer.rate == .vertex else {
            throw invalid("The \(name) buffer must have one element per vertex.")
        }
        let values = buffer.elements
        guard values.count == count else {
            throw invalid("The \(name) buffer must be CPU-readable.")
        }
        return values
    }

    private static func matching(_ lhs: MeshResource.Skeleton, _ rhs: MeshResource.Skeleton) -> Bool
    {
        guard lhs.id == rhs.id, lhs.joints.count == rhs.joints.count else { return false }
        return zip(lhs.joints, rhs.joints).allSatisfy { a, b in
            a.name == b.name && a.parentIndex == b.parentIndex
                && close(a.inverseBindPoseMatrix, b.inverseBindPoseMatrix)
                && close(a.restPoseTransform.matrix, b.restPoseTransform.matrix)
        }
    }

    private static func close(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in
            (0..<4).allSatisfy { row in
                let a = lhs[column][row]
                let b = rhs[column][row]
                return a.isFinite && b.isFinite && abs(a - b) <= 0.00001 * max(1, abs(a), abs(b))
            }
        }
    }

    private static func invalid(_ message: String) -> ModelResourceError { .invalid(message) }
}
