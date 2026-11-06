#include <metal_stdlib>
using namespace metal;

struct VideoParameters { float4 distortion; float4 intrinsics; float4 options; float4 range; float4 matrix; };
float3 decodeSDR(float3 c, uint transfer) {
    c = max(c, 0.0);
    if (transfer == 1) return select(pow((c+0.055)/1.055,float3(2.4)), c/12.92, c <= 0.04045);
    if (transfer == 2) return select(pow((c+0.099)/1.099,float3(1.0/0.45)), c/4.5, c < 0.081);
    return c;
}
kernel void normalizeCamera(texture2d<float,access::sample> first [[texture(0)]],
    texture2d<float,access::sample> chroma [[texture(1)]], texture2d<float,access::write> output [[texture(2)]],
    constant VideoParameters& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 uv = (float2(gid)+0.5)/float2(output.get_width(),output.get_height());
    float2 xy = (uv-p.intrinsics.xy)/p.intrinsics.zw;
    float r2 = dot(xy,xy);
    float radial = 1 + p.distortion.x*r2 + p.distortion.y*r2*r2 + p.distortion.z*r2*r2*r2;
    float p1=p.distortion.w, p2=p.options.x;
    float2 distorted = xy*radial + float2(2*p1*xy.x*xy.y+p2*(r2+2*xy.x*xy.x), p1*(r2+2*xy.y*xy.y)+2*p2*xy.x*xy.y);
    float2 sampleUV = p.intrinsics.xy + distorted*p.intrinsics.zw;
    float3 rgb = first.sample(s,sampleUV).rgb;
    if (p.options.w > 0.5) {
        float y = (rgb.r*p.matrix.z-p.range.x)*p.range.y;
        float2 cbcr = (chroma.sample(s,sampleUV).rg*p.matrix.z-p.range.z)*p.range.w;
        float kr=p.matrix.x, kb=p.matrix.y, kg=1-kr-kb;
        rgb = float3(y+2*(1-kr)*cbcr.y,
            y-2*kb*(1-kb)/kg*cbcr.x-2*kr*(1-kr)/kg*cbcr.y, y+2*(1-kb)*cbcr.x);
    }
    bool inBounds = all(sampleUV >= 0.0) && all(sampleUV <= 1.0);
    output.write(float4(decodeSDR(rgb,uint(p.options.y)), p.options.z*(inBounds ? 1.0 : 0.0)),gid);
}
kernel void buildMatte(texture2d<float,access::read> video [[texture(0)]],
    texture2d<float,access::write> matte [[texture(1)]], constant float4& key [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= matte.get_width() || gid.y >= matte.get_height()) return;
    float4 color=video.read(gid);
    float dominance=color.g-max(color.r,color.b);
    float strength=smoothstep(key.y,key.y+max(key.z,0.001),dominance);
    matte.write(float4(color.a*(1-key.x*strength)),gid);
}
struct SceneVertex { float4 position; float4 normal; };
struct SceneParameters { float4x4 viewProjection; float4x4 lightProjection; float4 camera; float4 lightDirection; float4 radiance; };
struct MaterialParameters { float4 baseColor; float4 factors; };
struct MeshOutput { float4 position [[position]]; float3 world; float3 normal; float4 shadow; };
vertex MeshOutput studioMeshVertex(uint id [[vertex_id]], device const SceneVertex* vertices [[buffer(0)]], constant SceneParameters& u [[buffer(1)]]) {
    MeshOutput v;
    v.position=u.viewProjection*vertices[id].position;
    v.world=vertices[id].position.xyz;
    v.normal=vertices[id].normal.xyz;
    v.shadow=u.lightProjection*vertices[id].position;
    return v;
}
vertex float4 studioShadowVertex(uint id [[vertex_id]], device const SceneVertex* vertices [[buffer(0)]], constant SceneParameters& u [[buffer(1)]]) {
    return u.lightProjection*vertices[id].position;
}
fragment float4 studioPBR(MeshOutput in [[stage_in]], constant SceneParameters& u [[buffer(0)]],
    constant MaterialParameters& m [[buffer(1)]], depth2d<float> shadow [[texture(0)]]) {
    constexpr sampler comparison(filter::linear,compare_func::less_equal,address::clamp_to_edge);
    float3 N=normalize(in.normal), L=normalize(u.lightDirection.xyz), V=normalize(u.camera.xyz-in.world), H=normalize(L+V);
    float nl=max(dot(N,L),0.0), nv=max(dot(N,V),0.001), nh=max(dot(N,H),0.0), vh=max(dot(V,H),0.0);
    float rough=clamp(m.factors.y,0.045,1.0), metal=clamp(m.factors.x,0.0,1.0);
    float a2=pow(rough,4.0), denominator=nh*nh*(a2-1)+1;
    float D=a2/(M_PI_F*denominator*denominator+0.0001);
    float k=pow(rough+1,2.0)/8;
    float G=(nv/(nv*(1-k)+k))*(nl/(nl*(1-k)+k));
    float3 F0=mix(float3(0.04),m.baseColor.rgb,metal);
    float3 F=F0+(1-F0)*pow(1-vh,5.0);
    float3 specular=D*G*F/(4*nv*max(nl,0.001)+0.0001);
    float3 diffuse=(1-F)*(1-metal)*m.baseColor.rgb/M_PI_F;
    float3 coord=in.shadow.xyz/in.shadow.w;
    float2 uv=coord.xy*float2(0.5,-0.5)+0.5;
    float visibility=1;
    if (all(uv >= 0.0) && all(uv <= 1.0) && coord.z >= 0 && coord.z <= 1)
        visibility=shadow.sample_compare(comparison,uv,coord.z-max(0.0005,0.002*(1-nl)));
    float3 color=(diffuse+specular)*u.radiance.rgb*nl*visibility + m.baseColor.rgb*0.035;
    return float4(color,1);
}
struct QuadOutput { float4 position [[position]]; float2 uv; };
vertex QuadOutput studioQuad(uint id [[vertex_id]]) {
    constexpr float2 p[]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    return {float4(p[id],0,1),p[id]*float2(0.5,-0.5)+0.5};
}
fragment float4 studioComposite(QuadOutput in [[stage_in]], texture2d<float> scene [[texture(0)]],
    texture2d<float> video [[texture(1)]], texture2d<float> matte [[texture(2)]], constant float4& options [[buffer(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    if (options.y > 0.5) return float4(0.025,0.008,0.012,1);
    float3 background=scene.sample(s,in.uv).rgb;
    float3 foreground=video.sample(s,in.uv).rgb;
    float alpha=matte.sample(s,in.uv).r;
    if (options.x == 1) return float4(clamp(background,0.0,1.0),1);
    if (options.x == 2) return float4(clamp(foreground,0.0,1.0),1);
    if (options.x == 3) return float4(float3(alpha),1);
    foreground.g=mix(foreground.g,min(foreground.g,max(foreground.r,foreground.b)),(1-alpha)*options.z);
    // Linear Rec.709/sRGB primaries; the sRGB render target performs the output transfer once.
    return float4(clamp(foreground*alpha+background*(1-alpha),0.0,1.0),1);
}
