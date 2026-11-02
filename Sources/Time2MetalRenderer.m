//
//  Time2MetalRenderer.m
//  Time2 - Metal 玻璃渲染器
//

#import "Time2MetalRenderer.h"
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import <UIKit/UIKit.h>

// Metal shader 代码（参考 BigTime 的 liquidGlass shader）
static NSString *const kMetalShaderSource = @"\
#include <metal_stdlib>\
using namespace metal;\
\
struct Uniforms {\
    float2 resolution;\
    float glassThickness;\
    float refractionScale;\
    float refractiveIndex;\
    float blurRadius;\
    float3 tintColor;\
    float tintAlpha;\
};\
\
struct VertexOut {\
    float4 position [[position]];\
    float2 uv;\
};\
\
vertex VertexOut liquidGlassVertex(uint vertexID [[vertex_id]]) {\
    VertexOut out;\
    constexpr float2 positions[] = {\
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)\
    };\
    out.position = float4(positions[vertexID], 0.0, 1.0);\
    out.uv = positions[vertexID] * 0.5 + 0.5;\
    return out;\
}\
\
fragment float4 liquidGlassFragment(\
    VertexOut in [[stage_in]],\
    texture2d<float, access::sample> src [[texture(0)]],\
    texture2d<float, access::sample> glyphMask [[texture(1)]],\
    constant Uniforms &u [[buffer(0)]]) {\
    \
    constexpr sampler sampl(filter::linear, mip_filter::linear, addr::clamp_to_edge);\
    \
    // 采样字形遮罩\
    float mask = glyphMask.sample(sampl, in.uv).r;\
    if (mask < 0.01) return float4(0.0);\
    \
    // 计算边缘位置（距离字形边缘的距离）\
    float2 center = float2(0.5, 0.5);\
    float dist = distance(in.uv, center);\
    float edgeRatio = smoothstep(0.0, 0.2, dist); // 简化版边缘计算\
    \
    // 计算折射偏移\
    float eta = 1.0 / u.refractiveIndex;\
    float2 normal = float2(edgeRatio - 0.5, 0.0); // 简化版法线\
    \
    // 应用折射偏移\
    float2 offset = normal * u.glassThickness * u.refractionScale * 0.02;\
    float2 srcUV = in.uv + offset;\
    \
    // 采样背景\
    float4 bg = src.sample(sampl, srcUV);\
    \
    // 应用模糊（简化版：多次采样）\
    float4 blur = float4(0.0);\
    float blurRadius = u.blurRadius / u.resolution.x;\
    int sampleCount = 0;\
    for (int i = -2; i <= 2; i++) {\
        for (int j = -2; j <= 2; j++) {\
            float2 offsetUV = float2(i, j) * blurRadius;\
            blur += src.sample(sampl, srcUV + offsetUV);\
            sampleCount++;\
        }\
    }\
    blur /= float(sampleCount);\
    \
    // 菲涅尔效应\
    float f0 = (u.refractiveIndex - 1.0) / (u.refractiveIndex + 1.0);\
    f0 = f0 * f0;\
    float fresnel = f0 + (1.0 - f0) * pow(1.0 - edgeRatio, 5.0);\
    \
    // 合成颜色\
    float3 color = blur.rgb;\
    color = mix(color, u.tintColor, u.tintAlpha);\
    color += fresnel * 0.15; // 边缘高光\
    \
    return float4(color, mask);\
}\
";

@interface Time2MetalRenderer ()

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLTexture> sourceTexture;
@property (nonatomic, strong) id<MTLTexture> maskTexture;
@property (nonatomic, assign) CGSize outputSize;

@end

@implementation Time2MetalRenderer

+ (instancetype)sharedRenderer {
    static Time2MetalRenderer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[Time2MetalRenderer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupMetal];
    }
    return self;
}

- (void)setupMetal {
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"[Time2Metal] Metal 不支持");
        return;
    }
    
    self.commandQueue = [self.device newCommandQueue];
    
    // 编译 shader
    NSError *error = nil;
    MTLLibrary *library = [self.device newLibraryWithSource:kMetalShaderSource options:nil error:&error];
    if (!library) {
        NSLog(@"[Time2Metal] Shader 编译失败: %@", error);
        return;
    }
    
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"liquidGlassVertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"liquidGlassFragment"];
    
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!self.pipelineState) {
        NSLog(@"[Time2Metal] Pipeline 创建失败: %@", error);
        return;
    }
    
    NSLog(@"[Time2Metal] Metal 初始化成功");
}

- (id<MTLTexture>)textureFromImage:(UIImage *)image {
    if (!image) return nil;
    
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;
    
    MTKTextureLoader *textureLoader = [[MTKTextureLoader alloc] initWithDevice:self.device];
    NSError *error = nil;
    id<MTLTexture> texture = [textureLoader newTextureWithCGImage:cgImage
                                                         options:@{MTKTextureLoaderOptionSRGB: @(NO)}
                                                           error:&error];
    if (!texture) {
        NSLog(@"[Time2Metal] 创建纹理失败: %@", error);
    }
    return texture;
}

- (void)renderGlassWithSourceImage:(UIImage *)sourceImage
                          glyphMask:(UIImage *)glyphMask
                         outputSize:(CGSize)outputSize
                       glassThickness:(float)glassThickness
                      refractiveIndex:(float)refractiveIndex
                       refractionScale:(float)refractionScale
                           blurRadius:(float)blurRadius
                           tintColor:(UIColor *)tintColor
                            tintAlpha:(float)tintAlpha
                          completion:(void (^)(UIImage *result))completion {
    
    if (!self.device || !self.pipelineState) {
        NSLog(@"[Time2Metal] Metal 未初始化");
        completion(nil);
        return;
    }
    
    self.outputSize = outputSize;
    
    // 创建纹理
    self.sourceTexture = [self textureFromImage:sourceImage];
    self.maskTexture = [self textureFromImage:glyphMask];
    
    if (!self.sourceTexture || !self.maskTexture) {
        NSLog(@"[Time2Metal] 创建纹理失败");
        completion(nil);
        return;
    }
    
    // 创建输出纹理
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
    textureDescriptor.textureType = MTLTextureType2D;
    textureDescriptor.width = outputSize.width;
    textureDescriptor.height = outputSize.height;
    textureDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> outputTexture = [self.device newTextureWithDescriptor:textureDescriptor];
    
    // 创建命令缓冲区
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    
    // 创建渲染描述符
    MTLRenderPassDescriptor *renderPassDescriptor = [[MTLRenderPassDescriptor alloc] init];
    renderPassDescriptor.colorAttachments[0].texture = outputTexture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    
    // 创建渲染命令编码器
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [renderEncoder setRenderPipelineState:self.pipelineState];
    
    // 设置纹理
    [renderEncoder setFragmentTexture:self.sourceTexture atIndex:0];
    [renderEncoder setFragmentTexture:self.maskTexture atIndex:1];
    
    // 设置 uniforms
    struct Uniforms {
        float2 resolution;
        float glassThickness;
        float refractionScale;
        float refractiveIndex;
        float blurRadius;
        float3 tintColor;
        float tintAlpha;
    };
    
    struct Uniforms uniforms;
    uniforms.resolution = (float2){outputSize.width, outputSize.height};
    uniforms.glassThickness = glassThickness;
    uniforms.refractionScale = refractionScale;
    uniforms.refractiveIndex = refractiveIndex;
    uniforms.blurRadius = blurRadius;
    
    CGFloat r, g, b, a;
    [tintColor getRed:&r green:&g blue:&b alpha:&a];
    uniforms.tintColor = (float3){r, g, b};
    uniforms.tintAlpha = tintAlpha;
    
    [renderEncoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    
    // 绘制
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [renderEncoder endEncoding];
    
    // 提交命令
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    // 从纹理读取结果
    NSInteger bytesPerRow = outputSize.width * 4;
    NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * outputSize.height];
    [outputTexture getBytes:data.mutableBytes
                bytesPerRow:bytesPerRow
                 bytesPerImage:0
                    fromRegion:MTLRegionMake2D(0, 0, outputSize.width, outputSize.height)
                   mipmapLevel:0
                        slice:0];
    
    // 创建 CGImage
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data.mutableBytes,
                                                 outputSize.width,
                                                 outputSize.height,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage *result = [UIImage imageWithCGImage:cgImage];
    
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(cgImage);
    
    completion(result);
}

@end
