#include "inc/frame_constants.hlsl"
#include "inc/pack_unpack.hlsl"

[[vk::binding(0)]] Texture2D<float> input_tex;
[[vk::binding(1)]] RWTexture2D<float> output_tex;
[[vk::binding(2)]] cbuffer _ {
    float4 input_tex_size;
    float4 output_tex_size;
};

[numthreads(8, 8, 1)]
void main(in int2 px : SV_DispatchThreadID) {
    int2 src_px = int2(((px + 0.25) / output_tex_size.xy) * input_tex_size.xy);
	output_tex[px] = input_tex[src_px];
}
