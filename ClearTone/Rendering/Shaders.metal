// Metal shader：低对比流动背景 + 频谱
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct AmbientUniforms {
    float time;
    float2 resolution;
    uint colorCount;
    uint spectrumEnabled;
    float renderScale;
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    float2 positions[6] = {
        {-1, -1}, {1, -1}, {-1, 1},
        {-1, 1}, {1, -1}, {1, 1}
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

// 简单噪声函数
float noise(float2 p, float time) {
    return sin(p.x * 3.0 + time * 0.3) * sin(p.y * 2.5 + time * 0.2) * 0.5 + 0.5;
}

fragment float4 fragment_ambient(VertexOut in [[stage_in]],
                                  constant AmbientUniforms &uniforms [[buffer(0)]],
                                  constant float3 *colors [[buffer(1)]],
                                  constant float *spectrum [[buffer(2)]]) {
    float2 uv = in.uv;
    float time = uniforms.time;

    // 注意：`renderScale` **不再**在这里缩放 UV。降分辨率已经由
    // `AmbientBackgroundRenderer` 调小 `drawableSize` 完成；两处都缩的话
    // 图案会被额外放大（0.5 时放大 2×），与全分辨率下的观感对不上。
    float2 patternUV = uv;

    // 基础背景色
    float3 baseColor = colors[0];

    // 流动渐变：混合 3-5 个封面颜色
    float3 finalColor = baseColor;
    float totalWeight = 1.0;

    for (uint i = 1; i < uniforms.colorCount && i < 5; i++) {
        float phase = time * (0.1 + float(i) * 0.05) + float(i) * 1.5;
        float2 center = float2(
            0.5 + 0.3 * sin(phase),
            0.5 + 0.3 * cos(phase * 0.8)
        );
        float dist = distance(patternUV, center);
        float weight = smoothstep(0.8, 0.0, dist) * 0.5;
        finalColor = mix(finalColor, colors[i], weight);
        totalWeight += weight;
    }

    // 添加轻微噪声纹理
    float n = noise(patternUV * 4.0, time) * 0.03;
    finalColor += n;

    // 频谱叠加（底部区域）
    if (uniforms.spectrumEnabled == 1) {
        float spectrumHeight = 0.15; // 底部 15% 区域
        if (uv.y < spectrumHeight) {
            // uv.x 可能取到 1.0，需夹取到有效频段范围，避免越界读取
            int band = clamp(int(uv.x * 64.0), 0, 63);
            float amplitude = spectrum[band];
            float barHeight = amplitude * spectrumHeight;
            if (uv.y < barHeight) {
                float intensity = 0.6 + 0.4 * amplitude;
                finalColor = mix(finalColor, float3(0.94, 0.42, 0.42), intensity * 0.7);
            }
        }
    }

    // 暗角
    float vignette = 1.0 - distance(uv, float2(0.5)) * 0.5;
    finalColor *= vignette;

    return float4(finalColor, 1.0);
}
