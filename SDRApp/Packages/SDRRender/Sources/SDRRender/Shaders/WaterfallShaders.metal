#include <metal_stdlib>
using namespace metal;

// Vertex structure for fullscreen quad
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen quad vertex shader
vertex VertexOut waterfallVertexShader(uint vertexID [[vertex_id]]) {
    // Two-triangle fullscreen quad
    const float2 positions[] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1),  float2(1, -1), float2(1,  1)
    };
    const float2 texCoords[] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Classic waterfall: blue -> cyan -> green -> yellow -> red -> white
float4 waterfallColorClassic(float value) {
    float4 color;

    if (value < 0.2) {
        // Black to blue
        float t = value / 0.2;
        color = float4(0, 0, t, 1);
    } else if (value < 0.4) {
        // Blue to cyan
        float t = (value - 0.2) / 0.2;
        color = float4(0, t, 1, 1);
    } else if (value < 0.6) {
        // Cyan to green
        float t = (value - 0.4) / 0.2;
        color = float4(0, 1, 1 - t, 1);
    } else if (value < 0.8) {
        // Green to yellow
        float t = (value - 0.6) / 0.2;
        color = float4(t, 1, 0, 1);
    } else {
        // Yellow to red to white
        float t = (value - 0.8) / 0.2;
        color = float4(1, 1 - t * 0.5, t, 1);
    }

    return color;
}

// Thermal waterfall: black -> deep red -> orange -> yellow -> white
float4 waterfallColorThermal(float value) {
    if (value < 0.25) {
        float t = value / 0.25;
        return float4(0.25 * t, 0.02 * t, 0.0, 1.0);
    } else if (value < 0.5) {
        float t = (value - 0.25) / 0.25;
        return float4(0.25 + 0.6 * t, 0.02 + 0.18 * t, 0.0, 1.0);
    } else if (value < 0.75) {
        float t = (value - 0.5) / 0.25;
        return float4(0.85 + 0.15 * t, 0.2 + 0.55 * t, 0.05 * t, 1.0);
    } else {
        float t = (value - 0.75) / 0.25;
        return float4(1.0, 0.75 + 0.25 * t, 0.05 + 0.95 * t, 1.0);
    }
}

// Grayscale waterfall: black -> white
float4 waterfallColorGrayscale(float value) {
    return float4(value, value, value, 1.0);
}

float4 waterfallColorMap(float value, uint scheme) {
    switch (scheme) {
        case 1:
            return waterfallColorThermal(value);
        case 2:
            return waterfallColorGrayscale(value);
        default:
            return waterfallColorClassic(value);
    }
}

// Waterfall fragment shader
// Reads from a float texture (single-channel, normalized dB values)
// and applies a color map.
struct WaterfallUniforms {
    float scrollOffset; // Current scroll row offset (0.0 - 1.0)
    uint colorScheme;   // 0=classic, 1=thermal, 2=grayscale
};

fragment float4 waterfallFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> waterfallTexture [[texture(0)]],
    constant WaterfallUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::repeat);

    // Apply scroll offset: newest row at top, oldest at bottom
    // scrollOffset = currentRow / height, so scrollOffset points to the NEXT row to write (oldest)
    // At screen top (uv.y=0) we want the newest row = scrollOffset - 1/height
    // At screen bottom (uv.y=1) we want the oldest row = scrollOffset
    float2 uv = in.texCoord;
    uv.y = fract(uniforms.scrollOffset - uv.y);

    float value = waterfallTexture.sample(texSampler, uv).r;
    return waterfallColorMap(value, uniforms.colorScheme);
}

// Spectrum line vertex shader
struct SpectrumVertexIn {
    float2 position [[attribute(0)]];
};

struct SpectrumVertexOut {
    float4 position [[position]];
    float value;
};

vertex SpectrumVertexOut spectrumVertexShader(
    uint vertexID [[vertex_id]],
    constant float *bins [[buffer(0)]],
    constant uint &binCount [[buffer(1)]]
) {
    SpectrumVertexOut out;

    float x = float(vertexID) / float(binCount - 1) * 2.0 - 1.0;
    float y = bins[vertexID] * 2.0 - 1.0; // normalized 0-1 to -1..1

    out.position = float4(x, y, 0, 1);
    out.value = bins[vertexID];
    return out;
}

fragment float4 spectrumFragmentShader(SpectrumVertexOut in [[stage_in]]) {
    // Green spectrum line with brightness based on value
    float brightness = 0.5 + in.value * 0.5;
    return float4(0.2 * brightness, brightness, 0.3 * brightness, 1.0);
}
