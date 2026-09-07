import Metal
import Realitizer
import RealitizerRealityKit
import RealityKit
import simd

public enum PreviewDebugMode: String, CaseIterable, Identifiable, Sendable {
    case faceNormals = "Face normals"
    case shaded = "Shaded"
    case wireframe = "Wireframe"
    case normals = "Normals"
    case tangents = "Tangents"
    case uv = "UV checker"
    case materials = "Material slots"
    case bounds = "Bounds"
    case rig = "Bones and sockets"
    case weights = "Skin weights"
    case collisions = "Collision shapes"
    case axes = "Axes"
    case motion = "Motion and events"
    public var id: String { rawValue }
}

@MainActor
enum PreviewDiagnostics {
    static func update(
        mode: PreviewDebugMode, instance: RuntimeModelInstance, overlay: Entity, selectedJoint: AnyRealitizerID?,
        clip: AnimationClipDefinition?
    ) throws {
        overlay.children.removeAll()
        var overrides: [AnyRealitizerID: any Material] = [:]
        try instance.setVisualizationMaterials([:])
        for part in instance.definition.parts { try instance.meshEntity(part.id).isEnabled = true }
        switch mode {
        case .shaded: return
        case .wireframe:
            var material = UnlitMaterial(color: .cyan)
            material.triangleFillMode = .lines
            for definition in instance.definition.materials { overrides[definition.id] = material }
            try instance.setVisualizationMaterials(overrides)
        case .uv:
            var material = MaterialDefinition(
                id: AnyRealitizerID(rawValue: "checker"), baseColor: .white, shading: .unlit)
            material.baseColorTexture = try TextureImage.checker()
            let compiled = try RealityKitMaterialCompiler.compile(material)
            for definition in instance.definition.materials { overrides[definition.id] = compiled }
            try instance.setVisualizationMaterials(overrides)
        case .materials:
            for (index, definition) in instance.definition.materials.enumerated() {
                overrides[definition.id] = UnlitMaterial(color: palette(index))
            }
            try instance.setVisualizationMaterials(overrides)
        case .normals, .tangents, .faceNormals:
            var lines: [SIMD3<Float>] = []
            let length = max(instance.definition.bounds.map { simd_length($0.size) * 0.025 } ?? 0.05, 0.001)
            for part in instance.definition.parts {
                let mesh = try instance.evaluatedMesh(for: part.id)
                let matrix = try instance.part(part.id).transformMatrix(relativeTo: instance.root)
                let step = max(1, mesh.vertices.count / 1500)
                if mode == .faceNormals {
                    for triangle in stride(from: 0, to: mesh.triangleCount, by: max(1, mesh.triangleCount / 1500)) {
                        let vertices = (0..<3).map { mesh.vertices[Int(mesh.indices[triangle * 3 + $0])].position }
                        let center = vertices.reduce(.zero, +) / 3
                        let normal = simd_normalize(simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0]))
                        lines += [point(matrix, center), point(matrix, center + normal * length)]
                    }
                    continue
                }
                for i in stride(from: 0, to: mesh.vertices.count, by: step) {
                    let vertex = mesh.vertices[i]
                    let direction =
                        mode == .normals ? vertex.normal : SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
                    lines += [point(matrix, vertex.position), point(matrix, vertex.position + direction * length)]
                }
            }
            try addLines(lines, color: .green, to: overlay)
        case .bounds:
            for part in instance.definition.parts {
                guard let bound = try instance.evaluatedMesh(for: part.id).bounds else { continue }
                let matrix = try instance.part(part.id).transformMatrix(relativeTo: instance.root)
                try addLines(boxLines(bound).map { point(matrix, $0) }, color: .yellow, to: overlay)
            }
        case .axes:
            try addLines([[0, 0, 0], [1, 0, 0]], color: .red, to: overlay)
            try addLines([[0, 0, 0], [0, 1, 0]], color: .green, to: overlay)
            try addLines([[0, 0, 0], [0, 0, 1]], color: .blue, to: overlay)
        case .rig:
            // Isolate the rig so opaque surfaces cannot hide internal joints and sockets.
            for part in instance.definition.parts { try instance.meshEntity(part.id).isEnabled = false }
            var bones: [SIMD3<Float>] = []
            for joint in instance.definition.rig?.joints ?? [] {
                let p = try instance.joint(joint.id).position(relativeTo: instance.root)
                if let parent = joint.parentID {
                    bones += [try instance.joint(parent).position(relativeTo: instance.root), p]
                }
                try marker(at: p, color: .cyan, to: overlay)
            }
            try addLines(bones, color: .cyan, to: overlay)
            for socket in instance.definition.sockets {
                try marker(
                    at: instance.socket(socket.id).position(relativeTo: instance.root), color: .yellow, to: overlay)
            }
        case .weights:
            guard let joint = selectedJoint ?? instance.definition.rig?.joints.first?.id else { return }
            for part in instance.definition.parts {
                let geometry = try instance.geometry(for: part.id)
                guard let skin = geometry.skin else { continue }
                var mesh = try instance.evaluatedMesh(for: part.id)
                mesh.materialIndices = (0..<mesh.triangleCount).map { triangle in
                    let weight =
                        (0..<3).reduce(Float(0)) { total, corner in
                            total
                                + (skin.influences[Int(mesh.indices[triangle * 3 + corner])].first(where: {
                                    $0.jointID == joint
                                })?.weight ?? 0)
                        } / 3
                    return UInt32(min(max(Int(weight * 7), 0), 7))
                }
                let dynamic = try DynamicModelMesh(mesh: mesh)
                let materials: [any Material] = (0..<8).map { UnlitMaterial(color: weightColor(Float($0) / 7)) }
                let model = ModelEntity(mesh: dynamic.resource, materials: materials)
                model.transform = try instance.part(part.id).transform
                let matrix = try instance.part(part.id).transformMatrix(relativeTo: instance.root)
                model.setTransformMatrix(matrix, relativeTo: nil)
                overlay.addChild(model)
                try instance.meshEntity(part.id).isEnabled = false
            }
        case .collisions:
            // Collision volumes can lie entirely inside the rendered surface.
            for part in instance.definition.parts { try instance.meshEntity(part.id).isEnabled = false }
            for collision in instance.definition.collisions {
                let mesh: MeshData
                switch collision.shape {
                case .box(let size): mesh = try MeshBuilder.box(size: size)
                case .sphere(let radius): mesh = try MeshBuilder.sphere(radius: radius)
                case .capsule(let height, let radius):
                    let half = max(height / 2 - radius, 0)
                    let field = DistanceField.capsule(start: [0, -half, 0], end: [0, half, 0], radius: radius)
                    mesh = try field.mesh(
                        in: MeshBounds(
                            minimum: [-radius * 1.1, -height / 2 - radius * 1.1, -radius * 1.1],
                            maximum: [radius * 1.1, height / 2 + radius * 1.1, radius * 1.1]), resolution: 12)
                case .convex(let points):
                    mesh = try MeshBuilder.convexHull(points: points)
                }
                let dynamic = try DynamicModelMesh(mesh: mesh)
                var material = UnlitMaterial(color: .orange)
                material.triangleFillMode = .lines
                let model = ModelEntity(mesh: dynamic.resource, materials: [material])
                let matrix =
                    try instance.definition.globalTransform(of: collision.parent, pose: instance.currentPose)
                    * collision.transform.matrix
                model.setTransformMatrix(matrix, relativeTo: nil)
                overlay.addChild(model)
            }
        case .motion:
            guard let clip, let target = clip.rootMotionTarget else { return }
            var points: [SIMD3<Float>] = []
            for i in 0...60 {
                let time = clip.duration * Float(i) / 60
                points.append(clip.sample(at: time).transforms[target]?.translation ?? .zero)
            }
            try addLines((0..<60).flatMap { [points[$0], points[$0 + 1]] }, color: .yellow, to: overlay)
            for event in clip.events {
                let position = clip.sample(at: event.time).transforms[target]?.translation ?? .zero
                try marker(at: position, color: .red, to: overlay)
            }
        }
    }

    static func addLines(_ points: [SIMD3<Float>], color: PreviewColor, to parent: Entity) throws {
        guard !points.isEmpty else { return }
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: points.count,
            vertexAttributes: [.init(semantic: .position, format: .float3, offset: 0)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)],
            indexCapacity: points.count)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { buffer in points.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let indices = points.indices.map(UInt32.init)
        mesh.withUnsafeMutableIndices { buffer in indices.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let minimum = points.reduce(points[0], simd_min)
        let maximum = points.reduce(points[0], simd_max)
        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: points.count, topology: .line, bounds: BoundingBox(min: minimum, max: maximum))
        ])
        parent.addChild(try ModelEntity(mesh: MeshResource(from: mesh), materials: [UnlitMaterial(color: color)]))
    }

    static func marker(at point: SIMD3<Float>, color: PreviewColor, to parent: Entity) throws {
        let entity = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [UnlitMaterial(color: color)])
        entity.position = point
        parent.addChild(entity)
    }

    private static func point(_ matrix: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = matrix * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    private static func boxLines(_ bounds: MeshBounds) -> [SIMD3<Float>] {
        let a = bounds.minimum
        let b = bounds.maximum
        let points: [SIMD3<Float>] = [
            [a.x, a.y, a.z], [b.x, a.y, a.z], [b.x, b.y, a.z], [a.x, b.y, a.z], [a.x, a.y, b.z], [b.x, a.y, b.z],
            [b.x, b.y, b.z], [a.x, b.y, b.z],
        ]
        return [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)].flatMap
        { [points[$0.0], points[$0.1]] }
    }
    private static func palette(_ index: Int) -> PreviewColor {
        [.systemBlue, .systemOrange, .systemGreen, .systemPink, .systemPurple, .systemYellow][index % 6]
    }
    private static func weightColor(_ weight: Float) -> PreviewColor {
        PreviewColor(
            red: CGFloat(weight), green: CGFloat(1 - abs(weight - 0.5) * 2), blue: CGFloat(1 - weight), alpha: 1)
    }
}

#if canImport(AppKit)
    import AppKit
    typealias PreviewColor = NSColor
#else
    import UIKit
    typealias PreviewColor = UIColor
#endif
