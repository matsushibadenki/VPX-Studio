#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float3 normal;
    float3 worldPosition;
};

struct BackgroundOutput {
    float4 position [[position]];
    float2 uv;
};

struct ChromaKeyUniforms {
    float isEnabled;
    float hasVideo;
    float greenThreshold;
    float greenSoftness;
    float radialDistortionK1;
    float principalPointX;
    float principalPointY;
    float padding;
};

vertex BackgroundOutput backgroundVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
    };
    BackgroundOutput output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = output.position.xy * float2(0.5, -0.5) + 0.5;
    return output;
}

fragment float4 cameraFragment(
    BackgroundOutput input [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    constant ChromaKeyUniforms &key [[buffer(0)]]
) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 principalPoint = float2(key.principalPointX, key.principalPointY);
    float2 centeredUV = input.uv - principalPoint;
    float radiusSquared = dot(centeredUV, centeredUV);
    float2 correctedUV = principalPoint + centeredUV * (1.0 + key.radialDistortionK1 * radiusSquared);
    float3 rgb = cameraTexture.sample(linearSampler, correctedUV).rgb;
    float greenDominance = rgb.g - max(rgb.r, rgb.b);
    float keyStrength = smoothstep(key.greenThreshold, key.greenThreshold + key.greenSoftness, greenDominance);
    float alpha = key.hasVideo * (1.0 - key.isEnabled * keyStrength);
    float3 despilled = mix(rgb, rgb * (1.0 - 0.25 * keyStrength), key.isEnabled);
    return float4(despilled, alpha);
}

struct PreviewUniforms {
    float time;
    float aspectRatio;
    float verticalFieldOfViewRadians;
    float padding;
};

float4x4 rotationY(float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float4x4(
        float4(c, 0.0, -s, 0.0),
        float4(0.0, 1.0, 0.0, 0.0),
        float4(s, 0.0, c, 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );
}

float4x4 rotationX(float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float4x4(
        float4(1.0, 0.0, 0.0, 0.0),
        float4(0.0, c, s, 0.0),
        float4(0.0, -s, c, 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );
}

vertex VertexOutput fullscreenVertex(uint vertexID [[vertex_id]],
                                     constant PreviewUniforms &uniforms [[buffer(0)]]) {
    constexpr float3 positions[36] = {
        {-1, -1,  1}, { 1, -1,  1}, { 1,  1,  1}, {-1, -1,  1}, { 1,  1,  1}, {-1,  1,  1},
        { 1, -1, -1}, {-1, -1, -1}, {-1,  1, -1}, { 1, -1, -1}, {-1,  1, -1}, { 1,  1, -1},
        {-1, -1, -1}, {-1, -1,  1}, {-1,  1,  1}, {-1, -1, -1}, {-1,  1,  1}, {-1,  1, -1},
        { 1, -1,  1}, { 1, -1, -1}, { 1,  1, -1}, { 1, -1,  1}, { 1,  1, -1}, { 1,  1,  1},
        {-1,  1,  1}, { 1,  1,  1}, { 1,  1, -1}, {-1,  1,  1}, { 1,  1, -1}, {-1,  1, -1},
        {-1, -1, -1}, { 1, -1, -1}, { 1, -1,  1}, {-1, -1, -1}, { 1, -1,  1}, {-1, -1,  1}
    };
    constexpr float3 normals[6] = {
        {0, 0, 1}, {0, 0, -1}, {-1, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, -1, 0}
    };
    uint face = vertexID / 6;
    float4x4 model = rotationY(uniforms.time * 0.8) * rotationX(uniforms.time * 0.45);
    float4 world = model * float4(positions[vertexID] * 0.62, 1.0);
    float z = world.z + 4.0;

    VertexOutput output;
    float focalScale = 1.0 / tan(uniforms.verticalFieldOfViewRadians * 0.5);
    output.position = float4(
        world.x * focalScale / (z * uniforms.aspectRatio),
        world.y * focalScale / z,
        z / 8.0,
        1.0
    );
    output.normal = (model * float4(normals[face], 0.0)).xyz;
    output.worldPosition = world.xyz;
    return output;
}

fragment float4 previewFragment(VertexOutput input [[stage_in]],
                                [[front_facing]] bool isFrontFacing) {
    float3 normal = normalize(input.normal) * (isFrontFacing ? 1.0 : -1.0);
    float3 lightDirection = normalize(float3(-0.4, 0.8, 0.7));
    float diffuse = max(dot(normal, lightDirection), 0.0);
    float rim = pow(1.0 - max(normal.z, 0.0), 3.0);
    float3 color = float3(0.04, 0.32, 0.76) * (0.22 + diffuse) + float3(0.05, 0.42, 0.9) * rim;
    return float4(color, 1.0);
}
