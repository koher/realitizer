#include <metal_stdlib>
using namespace metal;
struct Vertex { float3 position; float3 normal; float2 uv; float3 tangent; float3 bitangent; float4 color; };
struct Parameters { float4 timing; uint4 counts; };
kernel void realitizerWaves(device const Vertex *rest [[buffer(0)]],
    device const float4 *waves [[buffer(1)]], device Vertex *output [[buffer(2)]],
    constant Parameters &p [[buffer(3)]], uint id [[thread_position_in_grid]]) {
    if (id >= p.counts.x) return;
    Vertex v = rest[id];
    float3 displacement = 0, dx = float3(1, 0, 0), dz = float3(0, 0, 1);
    for (uint i = 0; i < p.counts.y; ++i) {
        float4 a = waves[i * 2], b = waves[i * 2 + 1];
        float2 d = a.xy;
        float angle = a.w * (dot(d, v.position.xz) - b.x * p.timing.x) + b.z;
        float s = sin(angle), c = cos(angle), h = b.y * a.z, k = a.w;
        displacement += float3(h * d.x * c, a.z * s, h * d.y * c);
        dx += float3(-h*k*d.x*d.x*s, a.z*k*d.x*c, -h*k*d.x*d.y*s);
        dz += float3(-h*k*d.x*d.y*s, a.z*k*d.y*c, -h*k*d.y*d.y*s);
    }
    if (p.timing.z > p.timing.y) {
        float r = length(v.position.xz), width = p.timing.z - p.timing.y;
        float t = clamp((p.timing.z - r) / width, 0.0f, 1.0f);
        float f = t*t*(3 - 2*t);
        float2 gradient = r > 0 ? -6*t*(1-t)/width * v.position.xz/r : float2(0);
        dx = float3(1,0,0) + (dx-float3(1,0,0))*f + displacement*gradient.x;
        dz = float3(0,0,1) + (dz-float3(0,0,1))*f + displacement*gradient.y;
        displacement *= f;
    }
    float handedness = dot(cross(v.normal, v.tangent), v.bitangent) < 0 ? -1 : 1;
    float3 normal = normalize(cross(dz, dx)) * sign(v.normal.y);
    float3 tangent = normalize(dx*v.tangent.x + dz*v.tangent.z);
    v.position += displacement;
    v.normal = normal;
    v.tangent = tangent;
    v.bitangent = cross(normal, tangent) * handedness;
    output[id] = v;
}
