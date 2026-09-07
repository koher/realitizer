import CoreGraphics
import Foundation
import ImageIO
import Metal
import Realitizer
import RealityKit
import Testing

@testable import RealitizerRealityKit

@Suite(.serialized) @MainActor struct VertexColorRenderingTests {
    @Test func nativeMaterialsRestoreVertexColorAndTextureFlags() throws {
        let resources = try VertexColorTestResources.result.get()
        var definition = MaterialDefinition(id: AnyRealitizerID("stone"),
            baseColor: RGBAColor(sRGB: [0.7, 0.6, 0.5], alpha: 0.6),
            roughness: 0.8, alphaMode: .mask(cutoff: 0.4), vertexColorMode: .multiply)
        definition.doubleSided = true
        definition.baseColorTexture = try TextureImage.generate(width: 2, height: 2) { _ in .white }
        definition.normalTexture = try TextureImage.normalMap(size: 2, strength: 0.1) { _ in 0 }
        var export = definition
        export.vertexColorMode = .ignore
        let native = try #require(RealityKitMaterialCompiler.compile(export) as? PhysicallyBasedMaterial)
        let restored = try #require(RealityKitMaterialCompiler.applyingVertexColor(
            to: native, definition: definition, resources: resources) as? CustomMaterial)
        #expect(restored.custom.value == SIMD4<Float>(3, definition.emissiveIntensity, 1, 0.4))
        #expect(restored.baseColor.tint == native.baseColor.tint)
        #expect(restored.roughness.scale == native.roughness.scale)
        #expect(restored.faceCulling == .none)
        // RealityKit may return a new Swift wrapper for the same native texture.
        let base = try #require(restored.baseColor.texture?.resource)
        let normal = try #require(restored.normal.texture?.resource)
        #expect(base.width == native.baseColor.texture?.resource.width)
        #expect(base.height == native.baseColor.texture?.resource.height)
        #expect(normal.width == native.normal.texture?.resource.width)
        #expect(normal.height == native.normal.texture?.resource.height)
        #expect(restored.opacityThreshold == 0.4)
        #expect(try RealityKitMaterialCompiler.applyingVertexColor(to: native, definition: export)
            is PhysicallyBasedMaterial)
    }

    @Test func compiledAndDynamicMeshesRenderInterpolatedVertexColors() async throws {
        let resources = try VertexColorTestResources.result.get()
        let mesh = try MeshBuilder.surface(uSegments: 1, vSegments: 1) {
            [($0.x - 0.5) * 2, ($0.y - 0.5) * 2, 0]
        }
        .coloring { RGBAColor(sRGB: $0.position.x < 0 ? [1, 0, 0] : [0, 0, 1]) }
        var material = MaterialDefinition(
            id: AnyRealitizerID("surface"), baseColor: .white,
            shading: .unlit, vertexColorMode: .multiply)
        material.unlitToneMapping = false
        let asset = ModelAssetDefinition(
            name: "Vertex color", materials: [material],
            parts: [
                ModelPartDefinition(id: AnyRealitizerID("body"), mesh: mesh, material: material.id)
            ])
        let compiled = try RealityKitModelCompiler.compile(asset, resources: resources)
        let instance = try compiled.instantiate()
        let dynamic = try DynamicModelMesh(mesh: mesh)
        let dynamicEntity = ModelEntity(
            mesh: dynamic.resource,
            materials: [try RealityKitMaterialCompiler.compile(material, resources: resources)])
        for (name, entity) in [("static", instance.root), ("dynamic", dynamicEntity)] {
            let pixels = try await renderColors(entity, name: name)
            let left = pixel(pixels, x: 48, y: 64)
            let right = pixel(pixels, x: 80, y: 64)
            #expect(left.x > left.z + 20 && right.z > right.x + 20)
            // The output texture uses RealityKit's linear Display P3 working primaries.
            #expect(left.y < 12 && right.y < 12)
            let center = pixel(pixels, x: 64, y: 64)
            #expect(center.x > 30 && center.z > 30)
        }
        let green = try mesh.coloring { _ in RGBAColor(sRGB: [0, 1, 0]) }
        try dynamic.updateVertices(in: green.vertices.indices, with: green.vertices)
        let changed = try await renderColors(dynamicEntity, name: "dynamic-update")
        #expect(pixel(changed, x: 64, y: 64).y > 200)
        var invalid = green.vertices
        invalid[0].color.red = .nan
        #expect(throws: ModelValidationError.self) {
            try dynamic.updateVertices(in: invalid.indices, with: invalid)
        }
        #expect(dynamic.data == green)
    }

    @Test func vertexColorMultipliesTextureTintAndHonorsAlpha() async throws {
        let resources = try VertexColorTestResources.result.get()
        let mesh = try MeshBuilder.surface(uSegments: 1, vSegments: 1) {
            [($0.x - 0.5) * 2, ($0.y - 0.5) * 2, 0]
        }
        .coloring { _ in RGBAColor(linearSRGB: [0.5, 1, 0.5], alpha: 0.5) }
        var material = MaterialDefinition(
            id: AnyRealitizerID("surface"), baseColor: .white,
            shading: .unlit, vertexColorMode: .multiply)
        material.unlitToneMapping = false
        material.baseColorTexture = try TextureImage.generate(width: 2, height: 2) { _ in
            RGBAColor(linearSRGB: [1, 0.5, 0.5])
        }
        let entity = ModelEntity(mesh: try RealityKitModelCompiler.compileMesh(mesh), materials: [])
        var values: [SIMD4<Float>] = []
        for (name, alpha) in [
            ("opaque", MaterialAlphaMode.opaque), ("blend", .blend), ("mask", .mask(cutoff: 0.6)),
        ] {
            material.alphaMode = alpha
            entity.model?.materials = [
                try RealityKitMaterialCompiler.compile(material, resources: resources)
            ]
            let rendered = try await renderColors(entity, name: name)
            values.append(pixel(rendered, x: 64, y: 64))
        }
        #expect(abs(values[0].x - values[0].y) < 5)
        #expect(values[0].x > values[0].z * 1.7)
        #expect(abs(values[1].x / values[0].x - 0.5) < 0.06)
        #expect(values[2].x < 5 && values[2].y < 5 && values[2].z < 5)

        material.baseColor = RGBAColor(linearSRGB: [0.5, 0.5, 0.5], alpha: 0.5)
        material.baseColorTexture = try TextureImage.generate(width: 2, height: 2) { _ in
            RGBAColor(linearSRGB: [1, 0.5, 0.5], alpha: 0.4)
        }
        material.alphaMode = .opaque
        entity.model?.materials = [
            try RealityKitMaterialCompiler.compile(material, resources: resources)
        ]
        let tinted = pixel(try await renderColors(entity, name: "tinted-opaque"), x: 64, y: 64)
        #expect(abs(tinted.x / values[0].x - 0.5) < 0.05)
        material.alphaMode = .blend
        entity.model?.materials = [
            try RealityKitMaterialCompiler.compile(material, resources: resources)
        ]
        let transparent = pixel(try await renderColors(entity, name: "tinted-blend"), x: 64, y: 64)
        // Material, texture and vertex alpha all participate: 0.5 * 0.4 * 0.5.
        #expect(abs(transparent.x / tinted.x - 0.1) < 0.025)
    }

    @Test func vertexColorsStayOnNativeSkinMorphAndLODPaths() throws {
        let resources = try VertexColorTestResources.result.get()
        let joint = AnyRealitizerID("root")
        let body = AnyRealitizerID("body")
        let surface = AnyRealitizerID("surface")
        let rig = RigDefinition(id: AnyRealitizerID("rig"), joints: [JointDefinition(id: joint)])
        let mesh = try MeshBuilder.box(size: [1, 1, 1]).coloring { _ in
            RGBAColor(sRGB: [0.2, 0.7, 0.3])
        }
        let geometry = try ModelGeometry(mesh: mesh).binding(to: rig) { _ in
            [JointWeight(joint, weight: 1)]
        }
        .addingMorph(id: AnyRealitizerID("tall")) { $0.position * SIMD3(1, 1.3, 1) }.unwrappingUV()
        var part = ModelPartDefinition(id: body, geometry: geometry, material: surface)
        part.levelsOfDetail = [.init(minimumDistance: 3, geometry: geometry)]
        let material = MaterialDefinition(
            id: surface, baseColor: .white, vertexColorMode: .multiply)
        let asset = ModelAssetDefinition(
            name: "Colored skin", materials: [material], parts: [part], rig: rig)
        let instance = try RealityKitModelCompiler.compile(asset, resources: resources)
            .instantiate()
        let entity = try instance.meshEntity(body)
        #expect(entity.components[SkeletalPosesComponent.self] != nil)
        #expect(entity.components[BlendShapeWeightsComponent.self] != nil)
        let semantic = try NativeVertexColor.semantic()
        let buffer = try #require(entity.model?.mesh.contents.models.first?.parts.first?[semantic])
        #expect(buffer.count == geometry.mesh.vertices.count)
        #expect(simd_distance(buffer.elements[0], mesh.vertices[0].color.linearRGBA) < 1e-5)
        try instance.setMorphWeight(1, part: body, target: AnyRealitizerID("tall"))
        try instance.setLevelOfDetail(1)
        #expect(
            try instance.evaluatedMesh(for: body).vertices.allSatisfy {
                $0.color == mesh.vertices[0].color
            })
    }

    @Test func coloredLitMaterialsReceiveLightsAndKeepEmissionIndependent() async throws {
        let resources = try VertexColorTestResources.result.get()
        let mesh = try MeshBuilder.surface(uSegments: 1, vSegments: 1) {
            [($0.x - 0.5) * 2, ($0.y - 0.5) * 2, 0]
        }
        .coloring { _ in RGBAColor(sRGB: [1, 0, 0]) }
        var definition = MaterialDefinition(
            id: AnyRealitizerID("surface"), baseColor: .white,
            roughness: 1, vertexColorMode: .multiply)
        let entity = ModelEntity(
            mesh: try RealityKitModelCompiler.compileMesh(mesh),
            materials: [try RealityKitMaterialCompiler.compile(definition, resources: resources)])
        let dark = pixel(try await renderColors(entity, name: "lit-dark"), x: 64, y: 64)
        let lit = pixel(
            try await renderColors(entity, name: "lit-sun", illuminate: true), x: 64, y: 64)
        #expect(lit.x > dark.x + 20 && lit.x > lit.y * 1.5)
        definition.emissiveColor = RGBAColor(sRGB: [0, 0, 1])
        definition.emissiveIntensity = 0.5
        entity.model?.materials = [
            try RealityKitMaterialCompiler.compile(definition, resources: resources)
        ]
        let emitted = pixel(try await renderColors(entity, name: "lit-emission"), x: 64, y: 64)
        #expect(emitted.z > 50 && emitted.z > emitted.x + 20)
    }

    @Test func coloredMaterialAnimationAndInjectedCacheRetainTheirContracts() throws {
        let resources = try VertexColorTestResources.result.get()
        let surface = AnyRealitizerID("surface")
        let body = AnyRealitizerID("body")
        let clipID = AnyRealitizerID("change")
        let definition = MaterialDefinition(
            id: surface, baseColor: .white, alphaMode: .mask(cutoff: 0.4),
            vertexColorMode: .multiply)
        var clip = AnimationClipDefinition(id: clipID, duration: 1, channels: [])
        clip.scalarChannels = [
            AnimatedMaterialProperty.roughness, .metallic, .emissiveIntensity, .opacity,
        ].map {
            ScalarAnimationChannel(
                target: .material(surface, $0),
                keyframes: [.init(time: 0, value: 0.2), .init(time: 1, value: 0.8)])
        }
        let asset = ModelAssetDefinition(
            name: "Animated color", materials: [definition],
            parts: [
                ModelPartDefinition(
                    id: body, mesh: try MeshBuilder.box(size: [1, 1, 1]), material: surface)
            ], clips: [clip])
        let cache = ModelResourceCache<String>(capacity: 2, resources: resources)
        let compiled = try cache.asset(for: "asset") { asset }
        #expect(try cache.asset(for: "asset") { asset } === compiled)
        let instance = try compiled.instantiate()
        try instance.sample(clipID, at: 0.5)
        let material = try #require(
            instance.meshEntity(body).model?.materials[0] as? CustomMaterial)
        #expect(abs(material.roughness.scale - 0.5) < 1e-6)
        #expect(abs(material.metallic.scale - 0.5) < 1e-6)
        #expect(abs(material.custom.value.y - 0.5) < 1e-6)
        #expect(material.custom.value.w == 0.4 && material.opacityThreshold == 0.4)
    }
}

@MainActor private func renderColors(_ entity: Entity, name: String, illuminate: Bool = false)
    async throws -> [UInt8]
{
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try RealityRenderer()
    let camera = PerspectiveCamera()
    camera.position = [0, 0, 3]
    renderer.entities.append(contentsOf: [camera, entity])
    if illuminate {
        let sun = DirectionalLight()
        sun.light.intensity = 3000
        renderer.entities.append(sun)
    }
    renderer.activeCamera = camera
    renderer.cameraSettings.isToneMappingEnabled = false
    renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 1))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
    for _ in 0..<3 {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try renderer.updateAndRender(
                    deltaTime: 1.0 / 60, cameraOutput: output,
                    onComplete: { _ in continuation.resume() })
            } catch { continuation.resume(throwing: error) }
        }
    }
    var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
    texture.getBytes(
        &bytes, bytesPerRow: 128 * 4,
        from: .init(
            origin: .init(x: 0, y: 0, z: 0), size: .init(width: 128, height: 128, depth: 1)),
        mipmapLevel: 0)
    if let directory = ProcessInfo.processInfo.environment["REALITIZER_RENDER_OUTPUT_DIRECTORY"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("vertex-color-\(name).png")
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(
            CGImage(
                width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 128 * 4,
                space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
    return bytes
}

private func pixel(_ bytes: [UInt8], x: Int, y: Int) -> SIMD4<Float> {
    let i = (y * 128 + x) * 4
    return SIMD4(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]), Float(bytes[i + 3]))
}

@MainActor enum VertexColorTestResources {
    static let result: Result<ModelRenderingResources, any Error> = Result {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #if os(macOS)
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let temporary =
                ProcessInfo.processInfo.environment["REALITIZER_TEST_TEMPORARY_DIRECTORY"]
                .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
            let directory = temporary.appendingPathComponent(
                "RealitizerColorTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("VertexColor.metallib")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "--sdk", "macosx", "metal", "-fmodules-cache-path=\(directory.path)/Cache",
                package.appendingPathComponent(
                    "Sources/RealitizerRealityKit/Shaders/VertexColor.metal"
                )
                .path, "-o", output.path,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let diagnostics = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(
                process.terminationStatus == 0,
                "Metal compiler: \(String(decoding: diagnostics, as: UTF8.self))")
            return try ModelRenderingResources(library: device.makeLibrary(URL: output))
        #else
            return try ModelRenderingResources.shared()
        #endif
    }
}
