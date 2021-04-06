#include "../inc/samplers.hlsl"
#include "../inc/uv.hlsl"
#include "../inc/color.hlsl"
#include "../inc/image.hlsl"

[[vk::binding(0)]] Texture2D<float4> input_tex;
[[vk::binding(1)]] Texture2D<float4> history_tex;
[[vk::binding(2)]] Texture2D<float4> reprojection_tex;
[[vk::binding(3)]] RWTexture2D<float4> output_tex;
[[vk::binding(4)]] cbuffer _ {
    float4 input_tex_size;
    float4 output_tex_size;
    float2 jitter;
};

// Apply at Mitchell-Netravali filter to the current frame, "un-jittering" it,
// and sharpening the content.
#define FILTER_CURRENT_FRAME 1

#define ENCODING_VARIANT 2

float3 decode_rgb(float3 a) {
    #if 0 == ENCODING_VARIANT
    return a;
    #elif 1 == ENCODING_VARIANT
    return sqrt(a);
    #elif 2 == ENCODING_VARIANT
    return log(1+sqrt(a));
    #endif
}

float3 encode_rgb(float3 a) {
    #if 0 == ENCODING_VARIANT
    return a;
    #elif 1 == ENCODING_VARIANT
    return a * a;
    #elif 2 == ENCODING_VARIANT
    a = exp(a) - 1;
    return a * a;
    #endif
}

float3 fetch_history(float2 uv) {
	return decode_rgb(
        history_tex.SampleLevel(sampler_lnc, uv, 0).xyz
    );
}

struct HistoryRemap {
    static HistoryRemap create() {
        HistoryRemap res;
        return res;
    }

    float4 remap(float4 v) {
        return float4(decode_rgb(v.rgb), 1);
    }
};

struct InputRemap {
    static InputRemap create() {
        InputRemap res;
        return res;
    }

    float4 remap(float4 v) {
        return float4(decode_rgb(v.rgb), v.a);
    }
};

struct CenterSampleInfo {
    float3 color;
    float coverage;
    float3 ex;
    float3 ex2;
};

CenterSampleInfo fetch_center_filtered(int2 dst_px) {
    const float2 input_resolution_scale = input_tex_size.xy / output_tex_size.xy;
    const int2 base_src_px = int2((dst_px + 0.5) * input_resolution_scale);

    // In pixel units of the destination (upsampled)
    const float2 dst_sample_loc = float2(dst_px) + 0.5;
    const float2 base_src_sample_loc = (base_src_px + 0.5) / input_resolution_scale;

    float4 res = 0.0.xxxx;
    float3 ex = 0.0.xxx;
    float3 ex2 = 0.0.xxx;
    float dev_wt_sum = 0.0;

    // Stretch the kernel if samples become too sparse due to drastic upsampling
    const float kernel_distance_mult = min(1.0, 1.5 * input_tex_size.x / output_tex_size.x);

    int k = 1;
    for (int y = -k; y <= k; ++y) {
        for (int x = -k; x <= k; ++x) {
            int2 src_px = base_src_px + int2(x, y);
            float2 src_sample_loc = base_src_sample_loc + float2(x, y) / input_resolution_scale;

            float4 col = float4(rgb_to_ycbcr(decode_rgb(input_tex[src_px].rgb)), 1);
            float2 sample_center_offset = jitter * float2(1, -1) - (src_sample_loc - dst_sample_loc);
            float dist2 = dot(sample_center_offset, sample_center_offset);
            float dist = sqrt(dist2);

            float wt = mitchell_netravali(dist * kernel_distance_mult);
            float dev_wt = exp2(-dist2);

            res += col * dev_wt;

            ex += col.xyz * dev_wt;
            ex2 += col.xyz * col.xyz * dev_wt;
            dev_wt_sum += dev_wt;
        }
    }

    CenterSampleInfo info;
    info.color = res.rgb / max(1e-5, res.a);
    info.coverage = res.a;
    info.ex = ex / dev_wt_sum;
    info.ex2 = ex2 / dev_wt_sum;
    return info;
}


[numthreads(8, 8, 1)]
void main(uint2 px: SV_DispatchThreadID) {
    const float2 input_resolution_scale = input_tex_size.xy / output_tex_size.xy;
    float2 uv = get_uv(px, output_tex_size);
    
    const float4 reproj = reprojection_tex[(px + 0.5) * input_resolution_scale];
    float2 history_uv = uv + reproj.xy;

#if 0
    float history_g = image_sample_catmull_rom(
        TextureImage::from_parts(history_tex, output_tex_size.xy),
        history_uv,
        HistoryRemap::create()
    ).y;
    float3 history = fetch_history(history_uv);
    if (history.y > 1e-5) {
        history *= history_g / history.y;
    }
#else
    float3 history = image_sample_catmull_rom(
        TextureImage::from_parts(history_tex, output_tex_size.xy),
        history_uv,
        HistoryRemap::create()
    ).rgb;
#endif

    history = rgb_to_ycbcr(history);

    float2 history_pixel = history_uv * output_tex_size.xy;
    float texel_center_dist = dot(1.0.xx, abs(0.5 - frac(history_pixel)));

#if FILTER_CURRENT_FRAME
    CenterSampleInfo center_sample = fetch_center_filtered(px);
    const float3 center = center_sample.color;
#else
    const float3 center = rgb_to_ycbcr(decode_rgb(input_tex[px].rgb));
#endif

#if 0
	float3 vsum = 0.0.xxx;
	float3 vsum2 = 0.0.xxx;
	float wsum = 0;
    
	const int k = 1;
    for (int y = -k; y <= k; ++y) {
        for (int x = -k; x <= k; ++x) {
            float3 neigh = decode_rgb(input_tex[px * input_resolution_scale + int2(x, y)].rgb);
            neigh = rgb_to_ycbcr(neigh);

			float w = exp(-3.0 * float(x * x + y * y) / float((k+1.) * (k+1.)));
			vsum += neigh * w;
			vsum2 += neigh * neigh * w;
			wsum += w;
        }
    }

	float3 ex = vsum / wsum;
	float3 ex2 = vsum2 / wsum;
#else
    float3 ex = center_sample.ex;
    float3 ex2 = center_sample.ex2;
#endif

	float3 dev = sqrt(max(0.0.xxx, ex2 - ex * ex));

    float local_contrast = dev.x / (ex.x + 1e-5);
    float box_size = 1.0;
    box_size *= lerp(0.5, 1.0, smoothstep(-0.1, 0.3, local_contrast));
    box_size *= lerp(0.5, 1.0, clamp(1.0 - texel_center_dist, 0.0, 1.0));

    const float n_deviations = 1.5 * lerp(0.75, 1.0, reproj.w);
	float3 nmin = lerp(center, ex, box_size * box_size) - dev * box_size * n_deviations;
	float3 nmax = lerp(center, ex, box_size * box_size) + dev * box_size * n_deviations;

    float blend_factor = 1.0;
    
	#if 1
        // TODO: make better use of the quad reprojection validity
        uint quad_reproj_valid_packed = uint(reproj.z * 15.0 + 0.5);
        float4 quad_reproj_valid = (quad_reproj_valid_packed & uint4(1, 2, 4, 8)) != 0;
        blend_factor = lerp(1.0, 1.0 / 12.0, dot(quad_reproj_valid, 0.25));

        // HACK: reduces shimmering, but increases ghosting; mostly useful for upsampling
        blend_factor = min(blend_factor, WaveReadLaneAt(blend_factor, WaveGetLaneIndex() ^ 1));
        blend_factor = min(blend_factor, WaveReadLaneAt(blend_factor, WaveGetLaneIndex() ^ 8));

        float3 clamped_history = clamp(history, nmin, nmax);
		//float3 clamped_history = history;

        // "Anti-flicker"
        float clamp_dist = (min(abs(history.x - nmin.x), abs(history.x - nmax.x))) / max(max(history.x, ex.x), 1e-5);
        blend_factor *= lerp(0.2, 1.0, smoothstep(0.0, 2.0, clamp_dist));

        // Reduce blend factor towards the new sample for locations
        // that get poor coverage with temporal upscaling.
        blend_factor *= center_sample.coverage;

		float3 result = lerp(clamped_history, center, blend_factor);
        result = ycbcr_to_rgb(result);

		result = encode_rgb(result);
	#else
		float3 result = encode_rgb(ycbcr_to_rgb(center));
	#endif

#if 0
    if (all(0 == px)) {
        result.x = int(history_tex[uint2(0, 0)].x + 1) % 255;
    }

    if (px.y > 0 && px.y < 40) {
        result = int(history_tex[uint2(0, 0)].x) == px.x / 6;
    }
#endif

    //result = float3(reproj.xy, 0);
    //uint quad_reproj_valid_packed = uint(reproj.z * 15.0 + 0.5);
    //float4 quad_reproj_valid = (quad_reproj_valid_packed & uint4(1, 2, 4, 8)) != 0;
    //result = quad_reproj_valid.rgb;
    //result = float3(abs(reproj.xy), 0);

    output_tex[px] = float4(result, 1);
}
