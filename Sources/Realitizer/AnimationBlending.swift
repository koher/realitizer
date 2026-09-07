import simd

public struct BlendSpaceSample: Sendable {
    public let clipID: AnyRealitizerID
    public var position: SIMD2<Float>
    public init<ID: RealitizerID>(clip: ID, position: SIMD2<Float>) {
        clipID = clip.erasedID
        self.position = position
    }
}

/// One-dimensional linear or two-dimensional triangulated blending with normalized-time synchronization.
/// Two-dimensional spaces explicitly author triangles to avoid ambiguous triangulation across collinear samples.
public struct BlendSpaceDefinition: Sendable {
    public var xParameter: AnyRealitizerID
    public var yParameter: AnyRealitizerID?
    public var samples: [BlendSpaceSample]
    public var triangles: [SIMD3<Int>]
    public init<X: RealitizerID>(
        xParameter: X, yParameter: AnyRealitizerID? = nil, samples: [BlendSpaceSample], triangles: [SIMD3<Int>] = []
    ) {
        self.xParameter = xParameter.erasedID
        self.yParameter = yParameter
        self.samples = samples
        self.triangles = triangles
    }
    public func weights(at point: SIMD2<Float>) throws -> [Float] {
        guard !samples.isEmpty, samples.allSatisfy({ $0.position.isFinite }), point.isFinite else {
            throw modelingError("blendSpace.samples", "Blend spaces need finite samples and parameters.")
        }
        var weights = Array(repeating: Float(0), count: samples.count)
        if yParameter == nil {
            let order = samples.indices.sorted { samples[$0].position.x < samples[$1].position.x }
            for i in 1..<order.count where samples[order[i]].position.x <= samples[order[i - 1]].position.x {
                throw modelingError("blendSpace.duplicate", "One-dimensional sample positions must be distinct.")
            }
            if point.x <= samples[order[0]].position.x {
                weights[order[0]] = 1
                return weights
            }
            for i in 1..<order.count {
                let a = order[i - 1]
                let b = order[i]
                if point.x <= samples[b].position.x {
                    let t = (point.x - samples[a].position.x) / (samples[b].position.x - samples[a].position.x)
                    weights[a] = 1 - t
                    weights[b] = t
                    return weights
                }
            }
            weights[order.last!] = 1
            return weights
        }
        guard !triangles.isEmpty else {
            throw modelingError("blendSpace.triangulation", "Two-dimensional blend spaces require authored triangles.")
        }
        for triangle in triangles {
            let ids = [triangle.x, triangle.y, triangle.z]
            guard Set(ids).count == 3, ids.allSatisfy({ samples.indices.contains($0) }) else {
                throw modelingError(
                    "blendSpace.triangleIndex", "Blend triangles require three distinct valid sample indices.")
            }
            guard
                abs(
                    cross2(
                        samples[ids[1]].position - samples[ids[0]].position,
                        samples[ids[2]].position - samples[ids[0]].position)) > 1e-8
            else { throw modelingError("blendSpace.degenerate", "Blend triangles must have nonzero area.") }
        }
        var nearestDistance = Float.infinity
        for triangle in triangles {
            let ids = [triangle.x, triangle.y, triangle.z]
            guard Set(ids).count == 3, ids.allSatisfy({ samples.indices.contains($0) }) else {
                throw modelingError(
                    "blendSpace.triangleIndex", "Blend triangles require three distinct valid sample indices.")
            }
            let a = samples[ids[0]].position
            let b = samples[ids[1]].position
            let c = samples[ids[2]].position
            let denominator = cross2(b - a, c - a)
            guard abs(denominator) > 1e-8 else {
                throw modelingError("blendSpace.degenerate", "Blend triangles must have nonzero area.")
            }
            let v = cross2(point - a, c - a) / denominator
            let w = cross2(b - a, point - a) / denominator
            let u = 1 - v - w
            if min(u, v, w) >= 0 {
                weights = Array(repeating: 0, count: samples.count)
                weights[ids[0]] = u
                weights[ids[1]] = v
                weights[ids[2]] = w
                return weights
            }
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let p = samples[ids[i]].position
                let d = samples[ids[j]].position - p
                let t = min(max(simd_dot(point - p, d) / simd_length_squared(d), 0), 1)
                let distance = simd_distance_squared(point, p + d * t)
                if distance < nearestDistance {
                    nearestDistance = distance
                    weights = Array(repeating: 0, count: samples.count)
                    weights[ids[i]] = 1 - t
                    weights[ids[j]] = t
                }
            }
        }
        return weights
    }
}

public struct AnimationLayerDefinition: Sendable {
    public let id: AnyRealitizerID
    public var clipID: AnyRealitizerID
    public var mask: BoneMask
    public var weight: Float
    public var weightParameter: AnyRealitizerID?
    public var mode: PoseBlendMode
    public var speed: Float
    public var referencePose: PoseDefinition?
    /// Scalar channels have separate ownership from transform masks.
    public var scalarWeights: [ScalarAnimationTarget: Float] = [:]
    public init<ID: RealitizerID, Clip: RealitizerID>(
        id: ID, clip: Clip, mask: BoneMask, weight: Float = 1,
        weightParameter: AnyRealitizerID? = nil, mode: PoseBlendMode = .override, speed: Float = 1,
        referencePose: PoseDefinition? = nil
    ) {
        self.id = id.erasedID
        clipID = clip.erasedID
        self.mask = mask
        self.weight = weight
        self.weightParameter = weightParameter
        self.mode = mode
        self.speed = speed
        self.referencePose = referencePose
    }
}
