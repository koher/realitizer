#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Keep this function in sync with GrassWind.offset. Units are field-local meters.
static float3 grass_offset(float3 p, float height, float variation, float4 wind) {
    float t = wind.x;
    float2 velocity = wind.yz;
    float strength = length(velocity);
    float gust = sin(dot(p.xz, float2(0.31, 0.19)) - t * 1.13);
    float ripple = sin(dot(p.xz, float2(-0.63, 0.47)) - t * 1.91 + variation * 6.2831853);
    float flutter = sin(t * 3.17 + variation * 17.0 + p.x * 0.11);
    float travel = 0.45 + 0.38 * gust + 0.17 * ripple;
    float2 horizontal = (velocity * travel + float2(-velocity.y, velocity.x) * flutter * 0.12) * height * height;
    return float3(horizontal.x, -abs(travel) * strength * 0.18 * height * height, horizontal.y);
}

[[visible]] void realitizer_grass_geometry(realitykit::geometry_parameters params) {
    auto g = params.geometry();
    float2 uv = g.uv0();
    float3 displacement = grass_offset(g.model_position(), uv.x, uv.y, params.uniforms().custom_parameter());
    g.set_model_position_offset(displacement);

    // The unlit material's scalar fields carry lighting constants, not PBR properties.
    auto m = params.material_constants();
    float3 sun = normalize(float3(m.metallic_scale(), m.specular_scale(), m.clearcoat_scale()) * 2.0 - 1.0);
    float3 n = normalize(g.normal() + float3(-displacement.x, 0.0, -displacement.z) * 0.3);
    float cosine = dot(n, sun);
    float wrap = saturate((cosine + 0.6) / 1.6);
    float light = m.roughness_scale() + (1.0 - m.roughness_scale()) * wrap;
    light += m.clearcoat_roughness_scale() * saturate(-cosine) * uv.x;
    g.set_custom_attribute(float4(uv, light * (0.86 + 0.23 * uv.y), 0.0));
}

[[visible]] void realitizer_grass_surface(realitykit::surface_parameters params) {
    float4 leaf = params.geometry().custom_attribute();
    half3 root = half3(params.material_constants().base_color_tint());
    half3 tip = half3(params.material_constants().emissive_color());
    half3 color = mix(root, tip, half(smoothstep(0.0, 1.0, leaf.x)));
    // Opaque, texture-free, interpolated vertex lighting: no alpha discard or PBR evaluation.
    params.surface().set_emissive_color(color * half(leaf.z));
}

// The test kernel exercises exactly the same deformation as the geometry modifier.
kernel void realitizer_grass_wind_samples(
    device const float4 *positions [[buffer(0)]], device const float2 *weights [[buffer(1)]],
    constant float4 &wind [[buffer(2)]], device float4 *output [[buffer(3)]], uint id [[thread_position_in_grid]]) {
    output[id] = float4(grass_offset(positions[id].xyz, weights[id].x, weights[id].y, wind), 0.0);
}
