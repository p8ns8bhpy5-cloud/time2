//
//  Time2.xm
//  时间2（Time2）— 仿 iOS26 原生锁屏时间，按老版 BigTime 纯净口径裁剪（独立新插件，不依赖其它主插件）
//
//  本版范围（对齐老版 BigTime 提取包实证）：
//    - 隐藏系统原生时间；系统原生日期 / 星期保留系统原样，本插件不渲染日期
//    - 24h HH:mm 大字时钟；固定内置 axs66.otf 可变字体，不提供字体选择 / 系统细体回退
//    - 字体链对齐 BigTime 实证：NSData → CGDataProviderCreateWithCFData → CGFontCreateWithDataProvider
//      → CTFontCreateWithGraphicsFont → kCTFontVariationAttribute 设轴；不做进程字体表注册，不存在 code=305
//    - 可变字体轴：粗细 wght / 宽度 wdth / 高度 HGHT / 柔和 SOFT；大小 = 固定基准 pt × 大小倍率（无独立基础字号滑杆）
//    - 字形磨砂：模糊 / 染色只被字形遮罩限定在笔画内部，笔画外透明，不形成背景矩形框
//    - 联动（仿 iOS26 原生回缩，老版 DynamicHeightAxis 实证）：测量最近通知 / 播放器卡片顶部，逼近时只下压
//      HGHT 高度轴把数字纵向压扁；字号倍率、宽度、透明度、位置全部保持不变；卡片离开后高度轴平滑回弹。
//      时钟基准位置固定，不物理平移；不缩字号、不变淡、玻璃不随收缩衰减。
//    - 玻璃厚度 / 折射系数 / 折射强度依赖 backboardd Metal，本版本不开放；镜面 / 滚动联动 / 外链 / 重置均不做
//
//  安全纪律（技能 ios-rootless-theos-tweak 红线）：
//    - 本版不 hook 任何未经真机日志确认的 SpringBoard 私有控制器 / 视图类；
//      原生时间隐藏只走 sweep + 父链类名复合判定兜底；生命周期由系统公开通知 + 延时 sweep 驱动。
//    - 联动只读取原生大时钟标签基准 frame 与通知 / 播放器容器 frame，不 hook setFrame:/setCenter:，不修改系统视图位置。
//    - 高频布局 / DisplayLink 回调只读已缓存的全局参数，不重读磁盘 plist。
//    - 不沿父链回溯隐藏大容器；不写 rootful 绝对路径，系统路径走 ROOT_PATH_NS。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <math.h>
#import <rootless.h>
#import <substrate.h>
#import "clockformat.h"

// ===================== 常量（并入主插件时仅需改本段域 / 路径 / 通知名） =====================
static NSString *const kTime2PrefsPath = @"/var/mobile/Library/Preferences/com.xiaoyu.time2.plist";
static NSString *const kTime2LogPath  = @"/var/mobile/Time2.log";
// 随包内置字体目录：rootless 前缀下（layout/Library/Time2/Fonts → /var/jb/Library/Time2/Fonts）
// ROOT_PATH_NS 为运行时调用，不能用于 const 编译期初始化，注册时再取路径
static NSString *const kTime2BuiltinFontSubdir = @"/Library/Time2/Fonts";
static NSString *const kTime2PrefsChangedNotification = @"com.xiaoyu.time2.prefschanged";
// 随包内置字体文件名（位于 kTime2BuiltinFontSubdir）
static NSString *const kTime2BuiltinFontFile = @"axs66.otf";

// ===================== 日志（追加写 /var/mobile/Time2.log，全程判空容错） =====================
static void writeLog(NSString *msg) {
    if (!msg.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kTime2LogPath]) [fm createFileAtPath:kTime2LogPath contents:nil attributes:nil];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kTime2LogPath];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
}

// ===================== 偏好读取（直接读盘 plist，不依赖跨进程 NSUserDefaults 内存同步） =====================
static NSDictionary *loadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kTime2PrefsPath];
    return prefs ?: @{};
}

static BOOL readBool(NSDictionary *prefs, NSString *key, BOOL def) {
    id v = prefs[key];
    if (v == nil || [v isKindOfClass:[NSNull class]]) return def;
    return [v boolValue];
}

static NSInteger readInt(NSDictionary *prefs, NSString *key, NSInteger def) {
    id v = prefs[key];
    if (v == nil || [v isKindOfClass:[NSNull class]]) return def;
    return [v integerValue];
}

static CGFloat readFloat(NSDictionary *prefs, NSString *key, CGFloat def) {
    id v = prefs[key];
    if (v == nil || [v isKindOfClass:[NSNull class]]) return def;
    return [v doubleValue];
}

static NSString *readString(NSDictionary *prefs, NSString *key, NSString *def) {
    id v = prefs[key];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
    return def;
}

static CGFloat clampFloat(CGFloat v, CGFloat lo, CGFloat hi) {
    return MAX(lo, MIN(hi, v));
}

static BOOL gPrefsEnabled = YES;
static BOOL gClockEnabled  = YES;
static BOOL gHideStockTime = YES;

static BOOL prefEnabled(void) { return gPrefsEnabled; }

// ===================== 自定义字体（对齐 BigTime 实证路线：DataProvider→CGFont→CTFont，不做进程注册） =====================
// BigTime.dylib 导入函数实证：CGDataProviderCreateWithCFData / CGFontCreateWithDataProvider /
// CTFontCreateWithGraphicsFont / CTFontDescriptorCreateWithAttributes / CTFontCreateWithFontDescriptor；
// 主 dylib 不调用 CTFontManagerRegisterFontsForURL、不使用 kCTFontURLAttribute，因此不存在进程字体表
// code=305 注册失败，也不会在 descriptor 匹配失败时静默回退系统 Helvetica。

// 文件名 -> NSData（持有文件字节，provider 依赖它，进程内不释放）
static NSMutableDictionary<NSString *, NSData *> *gFontDataMap = nil;
// 文件名 -> CGFontRef（CF 长期缓存，ARC 下用 NSValue 包指针；进程结束随系统释放）
static NSMutableDictionary<NSString *, NSValue *> *gCGFontMap = nil;
// 文件名 -> PostScript 名（诊断用；从已成功构造的 CGFont/CTFont 读取，不按 URL descriptor 猜测）
static NSMutableDictionary<NSString *, NSString *> *gFontPSMap = nil;
// 文件名 -> NSURL（路径记录与诊断）
static NSMutableDictionary<NSString *, NSURL *> *gFontURLMap = nil;
// 本版字体固定内置 kTime2BuiltinFontFile，不提供面板字体选择，不回退系统细体。

static void registerCustomFonts(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!gFontPSMap)  gFontPSMap  = [NSMutableDictionary dictionary];
    if (!gFontURLMap) gFontURLMap = [NSMutableDictionary dictionary];

    // 本版只加载随包内置 axs66.otf；不扫描用户字体目录，不提供面板字体选择。
    if (gFontPSMap[kTime2BuiltinFontFile]) return;  // 已加载，幂等跳过
    NSString *dir = ROOT_PATH_NS(kTime2BuiltinFontSubdir);
    if (!dir.length) return;
    NSString *path = [dir stringByAppendingPathComponent:kTime2BuiltinFontFile];
    NSURL *url = [NSURL fileURLWithPath:path];
    gFontURLMap[kTime2BuiltinFontFile] = url;

    BOOL exists = NO;
    if (![fm fileExistsAtPath:path isDirectory:&exists]) {
        writeLog([NSString stringWithFormat:@"[FONT] 内置字体不存在: %@", path]);
        return;
    }

    // 参考 LockTime 方法：用 CTFontManagerRegisterFontsForURL 从 URL 注册
    CFErrorRef err = NULL;
    Boolean ok = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &err);
    if (!ok) {
        writeLog([NSString stringWithFormat:@"[FONT] 注册字体失败: %@", err ? (__bridge NSError *)err : @"(nil)"]);
        if (err) CFRelease(err);
        return;
    }

    // 用 kCTFontURLAttribute 创建 descriptor，读取 PostScript 名
    NSDictionary *attrs = @{ (__bridge NSString *)kCTFontURLAttribute: url };
    CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
    if (desc) {
        CTFontRef ct = CTFontCreateWithFontDescriptor(desc, 12.0, NULL);
        if (ct) {
            CFStringRef psRef = CTFontCopyPostScriptName(ct);
            if (psRef) {
                NSString *ps = (__bridge_transfer NSString *)psRef;
                if (ps.length) gFontPSMap[kTime2BuiltinFontFile] = ps;
            }
            CFRelease(ct);
        }
        CFRelease(desc);
    }

    writeLog([NSString stringWithFormat:@"[FONT] 已注册内置 %@ -> PS=%@",
              kTime2BuiltinFontFile, gFontPSMap[kTime2BuiltinFontFile] ?: @"(nil)"]);
}

// ===================== 全局视图状态 =====================
static UIView             *gContainer     = nil;  // 全屏容器（挂锚点，clipsToBounds=NO）
static UIView             *gGlassHost     = nil;  // 字形磨砂宿主（frame = 字形包围盒）
static UIVisualEffectView *gBlurBackdrop = nil;  // 笔画内模糊层（layer.mask = 字形 mask）
static UIView             *gTintView      = nil;  // 笔画内染色层（layer.mask = 字形 mask）
static CALayer            *gBlurMaskLayer = nil; // 模糊层字形遮罩
static CALayer            *gTintMaskLayer  = nil;  // 染色层字形遮罩（两层不能共享同一 mask layer）
static UILabel            *gClockLabel     = nil; // 最上层清晰时钟文字

static BOOL      gLockVisible = NO;
static NSInteger gLastMinute = -1;
static NSInteger gDiagRound = 0;
static NSInteger gFrameCount = 0;   // DisplayLink 帧计数，用于低频刷新原生标签引用

// 当前生效的样式参数（高频回调内只读取，不重读盘）
// 基本
// 固定基准字号 pt（老版无独立基础字号滑杆；最终字号 = 基准 pt × 大小倍率 gSizeScale）
static const CGFloat kBaseClockSize = 110.0;
static CGFloat gClockOffsetY = 0;
static CGFloat gClockOffsetX = 0;
static NSInteger gFPS = 60;
// 玻璃
static BOOL gGlassEnabled = YES;
static CGFloat gBezelWidth = 0.5;        // 边缘宽度（描边）
static CGFloat gBlurRadius = 5.0;        // 模糊强度 0–20
static CGFloat gLightTint  = 0.10;
static CGFloat gDarkTint   = 0.10;
static NSString *gTintMode = @"system";  // system / light / dark
// 可变字体
static BOOL gPresetFontEnabled = YES;
static CGFloat gFontWeight  = 400;       // wght 1–1000
static CGFloat gSizeScale   = 1.0;       // 大小倍率 0.5–3.0
static CGFloat gFontWidth   = 100;       // wdth 60–100
static CGFloat gFontHeight  = 100;       // HGHT 100–500
static CGFloat gFontSoftness = 70;       // SOFT 0–100

// BigTime 式联动：缓存唯一的原生大时钟标签作为初始基准 frame；避让由最近通知 / 播放器卡片顶部驱动
// 动态下压高度轴 + 缩字号 + 降 alpha（对齐 cachedNearestNotificationTop / animatedDynamicHeightAxis）。
static UILabel      *gNativeTimeLabel = nil;  // 原生大时钟标签引用；系统重建视图后失效，由 sweep 刷新
static CADisplayLink *gDisplayLink = nil;     // 每帧驱动动态状态（对齐 BigTime AxsDisplayLinkDriver）

// 避让收缩状态（0 = 无遮挡完整竖长；1 = 最大收缩）
static CGRect        gSourceFrame = CGRectZero;      // 原生大时钟在 gContainer 坐标系的基准 frame
static CGFloat       gNearestCardTopY = INFINITY;   // 最近通知 / 卡片顶部 y（容器坐标）；INFINITY = 无遮挡
static CGFloat       gTargetShrink = 0;               // 目标收缩量 0..1
static CGFloat       gShrink = 0;                    // 当前平滑收缩量（每帧向目标插值）
static CFAbsoluteTime gLastCardScan = 0;             // 卡片测量节流时间戳

// ===================== 可变字体构造（axs66 fvar 实测轴：wght / wdth / HGHT / SOFT） =====================
// 最终字号 = 固定基准 pt × 大小倍率；回缩时只下压传入的 HGHT 高度轴，不缩放倍率、不调透明度。
// 注意：可变轴字典的 key 必须是轴标识符的 NSNumber（十进制），不是字符串！
// 轴标识符：wght=0x77676874=2003265652, wdth=0x77647468=2003072104, HGHT=0x48474854=1214516308, SOFT=0x534F4654=1399874132
static NSDictionary<NSNumber *, NSNumber *> *variationAxes(CGFloat height) {
    NSMutableDictionary<NSNumber *, NSNumber *> *d = [NSMutableDictionary dictionary];
    d[@(2003265652)] = @(clampFloat(gFontWeight, 1, 1000));           // wght
    
    // 自动调整 wdth 轴：当高度 > 500 时，收窄宽度，保持整体宽度不变
    // 原理：字号变大 N 倍，wdth 轴收窄 N 倍，宽度 = 字号 × wdth 轴 保持不变
    CGFloat heightScale = fmax(1.0, gFontHeight / 500.0); // 500 以上才放大
    CGFloat autoWidth = gFontWidth / heightScale;
    d[@(2003072104)] = @(clampFloat(autoWidth, 60, 100));             // wdth（只能收窄 60-100）
    
    d[@(1212631124)] = @(clampFloat(height, 100, 500));               // HGHT（正确轴标识符）
    d[@(1397704276)] = @(clampFloat(gFontSoftness, 0, 100));           // SOFT（正确轴标识符）
    return d;
}

// 由缓存 CGFont 构造带可变轴的 CTFont；返回值需调用方 CFRelease。失败返回 NULL。
static CTFontRef buildCustomCTFont(NSString *key, CGFloat size, CGFloat height) {
    NSString *psName = gFontPSMap[key];
    if (!psName.length) {
        writeLog(@"[FONT] buildCustomCTFont: psName 为空");
        return NULL;
    }
    
    // 先用 PostScript 名加载基础字体（字体已注册到字体管理器）
    CTFontRef base = CTFontCreateWithName((__bridge CFStringRef)psName, size, NULL);
    if (!base) {
        writeLog([NSString stringWithFormat:@"[FONT] CTFontCreateWithName 失败 PS=%@", psName]);
        return NULL;
    }
    
    CFStringRef basePs = CTFontCopyPostScriptName(base);
    writeLog([NSString stringWithFormat:@"[FONT] base 字体 PS=%@ size=%.1f",
              basePs ? (__bridge_transfer NSString *)basePs : @"(nil)", size]);
    
    if (gPresetFontEnabled) {
        // 创建带可变轴的 descriptor
        NSDictionary *axes = variationAxes(height);
        writeLog([NSString stringWithFormat:@"[FONT] 可变轴: %@", axes]);
        NSDictionary *attrs = @{
            (id)kCTFontVariationAttribute: axes,
        };
        CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        CTFontRef out = CTFontCreateCopyWithAttributes(base, size, NULL, desc);
        CFRelease(desc);
        
        if (out) {
            CFStringRef outPs = CTFontCopyPostScriptName(out);
            writeLog([NSString stringWithFormat:@"[FONT] out 字体 PS=%@",
                      outPs ? (__bridge_transfer NSString *)outPs : @"(nil)"]);
        } else {
            writeLog(@"[FONT] CTFontCreateCopyWithAttributes 返回 NULL");
        }
        
        CFRelease(base);
        return out;
    } else {
        return base;
    }
}

// CTFont -> UIFont：CTFont 和 UIFont 是 toll-free bridged，直接转换即可，保留可变轴。
// 不能用 UIFontDescriptor 重新包装，那样会丢失可变轴设置。
static UIFont *uifontFromCTFont(CTFontRef ct, CGFloat size) {
    if (!ct) return nil;
    // CTFontRef 可以直接当成 UIFont 用（toll-free bridging）
    // 这里我们不释放 ct，因为它会被 UIFont 接管
    return (__bridge_transfer UIFont *)ct;
}

// height：HGHT 轴目标值（回缩下压该轴）；字号恒为 固定基准 pt × 大小倍率，不另乘收缩系数。
static UIFont *clockFontWithHeight(CGFloat height) {
    // 自动调整字号：当高度 > 500 时，放大字号，同时收窄宽度（在 variationAxes 里处理）
    // 这样宽度保持不变，高度增加
    CGFloat heightScale = fmax(1.0, gFontHeight / 500.0); // 500 以上才放大
    CGFloat size = kBaseClockSize * gSizeScale * heightScale;

    CTFontRef ct = buildCustomCTFont(kTime2BuiltinFontFile, size, height);
    if (ct) {
        CFStringRef psRef = CTFontCopyPostScriptName(ct);
        NSString *ps = psRef ? (__bridge_transfer NSString *)psRef : @"(nil)";
        // uifontFromCTFont 内部用 __bridge_transfer 接管所有权，这里不再 CFRelease
        UIFont *f = uifontFromCTFont(ct, size);
        if (f) {
            // 诊断：PS 名若不是 axs66 自身前缀，说明 UIKit 又回退到了系统字
            if (![ps hasPrefix:@"SFAdaptive"] && ![ps hasPrefix:@".SF Adaptive"]) {
                writeLog([NSString stringWithFormat:@"[FONT] 警告：构造字体 PS=%@（疑似回退系统字）", ps]);
            }
            return f;
        }
        writeLog([NSString stringWithFormat:@"[FONT] CTFont 构造成功但 UIFont 转换失败 PS=%@", ps]);
        // 转换失败，手动释放
        CFRelease(ct);
    } else {
        writeLog(@"[FONT] 内置 axs66 字体构造失败");
    }

    // 最终兜底：仍走内置字体（无轴变体）；不使用系统细体，保证字形与面板轴口径一致
    CTFontRef fallback = buildCustomCTFont(kTime2BuiltinFontFile, size, gFontHeight);
    if (fallback) {
        UIFont *f = uifontFromCTFont(fallback, size);
        if (f) return f;
        CFRelease(fallback);
    }
    // 字体加载失败，不显示时间（用户要求：没有这个字体就不显示）
    writeLog(@"[FONT] axs66 字体加载失败，不显示自定义时间");
    return nil;
}

// 前向声明：避让动态状态辅助与完整重排（定义在后文避让段 / 布局段）
static CGFloat currentHeightAxis(void);
static UIFont *currentClockFont(void);
static void relayoutViews(void);

// ===================== 文本特征识别（sweep 兜底，不依赖私有类名） =====================
static BOOL matchesTimeText(NSString *s) {
    if (!s.length) return NO;
    static NSPredicate *predicate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"^\\d{1,2}:\\d{2}$"];
    });
    return [predicate evaluateWithObject:s];
}

// BigTime cfstrings 实证：锁屏大时钟锚点父链类名集合（命中其一即属于系统大时钟区域）
static NSSet<NSString *> *anchorClockClassNames(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"_UIAnimatingLabel", @"CSProminentTimeView", @"SBUILegibilityLabel",
            @"SBFLockScreenDateView", @"CSProminentDisplayView",
        ]];
    });
    return set;
}

// BigTime cfstrings 实证：通知 / 播放器 / 相机 / 密码 / 快照子树，命中其一即判定为非锁屏大时钟
static NSSet<NSString *> *excludedSubtreeClassNames(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"NCNotificationListView", @"NCNotificationShortLookView", @"NCNotificationLongLookView",
            @"NCNotificationStructuredListViewController", @"PLPlatterView", @"VibrancyEffectView",
            @"CAMViewfinderView", @"CAMPreviewView", @"CAMPreviewViewControllerView",
            @"CAMFullscreenViewfinderView", @"CSPasscodeBackgroundView", @"PBUISnapshotReplicaView",
        ]];
    });
    return set;
}

static BOOL viewChainContainsNames(UIView *v, NSSet<NSString *> *names) {
    UIView *cur = v;
    while (cur) {
        if ([names containsObject:NSStringFromClass([cur class])]) return YES;
        cur = cur.superview;
    }
    return NO;
}

// 复合判定：只认锁屏大时钟标签。父链必须命中锚点集合，且不得落入通知 / 播放器 / 相机等排除子树；
// 文本符合 HH:mm；排除状态栏（y<50）。播放器进度条、计时器、通知里的 0:41 / 1:01 一律不隐藏、不缓存。
static BOOL isNativeClockLabel(UIView *v) {
    if (![v isKindOfClass:[UILabel class]]) return NO;
    if (viewChainContainsNames(v, excludedSubtreeClassNames())) return NO;
    if (!viewChainContainsNames(v, anchorClockClassNames())) return NO;
    NSString *text = ((UILabel *)v).text.length ? ((UILabel *)v).text : ((UILabel *)v).attributedText.string;
    if (!matchesTimeText(text)) return NO;
    UIWindow *w = v.window;
    CGPoint origin = w ? [v convertPoint:CGPointZero toView:w] : v.frame.origin;
    if (origin.y < 50) return NO;
    return YES;
}

// ===================== 视图辅助 =====================
static NSString *labelText(UILabel *lab) {
    if (lab.text.length) return lab.text;
    return lab.attributedText.string;
}

static NSString *viewPath(UIView *v) {
    NSMutableArray *parts = [NSMutableArray array];
    UIView *cur = v;
    while (cur) {
        [parts insertObject:NSStringFromClass([cur class]) atIndex:0];
        cur = cur.superview;
    }
    return [parts componentsJoinedByString:@" > "];
}

static BOOL isStatusBarOrSwitcher(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    if ([cls containsString:@"StatusBar"]) return YES;
    if ([viewPath(v) containsString:@"StatusBar"]) return YES;
    UIWindow *win = v.window;
    if (win && [NSStringFromClass([win class]) containsString:@"Switcher"]) return YES;
    return NO;
}

static UIView *fullscreenAncestor(UIView *label) {
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    UIView *node = label;
    while (node.superview) {
        node = node.superview;
        if (node.bounds.size.height >= screenH * 0.75) return node;
    }
    return label.superview;
}

static UIView *visibleAnchor(UIView *anchor) {
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    UIView *node = anchor;
    while (node) {
        if (!node.isHidden && node.bounds.size.height >= screenH * 0.50) return node;
        node = node.superview;
    }
    return anchor;
}

static NSArray<UIView *> *superviewChain(UIView *label) {
    NSMutableArray<UIView *> *chain = [NSMutableArray array];
    UIView *node = label.superview;
    while (node) { [chain addObject:node]; node = node.superview; }
    return chain;
}

static UIView *commonAncestorOfChains(NSArray<NSArray<UIView *> *> *chains) {
    if (chains.count == 0) return nil;
    if (chains.count == 1) return chains[0].firstObject;
    NSUInteger minLen = NSNotFound;
    for (NSArray *c in chains) minLen = MIN(minLen, c.count);
    UIView *common = nil;
    for (NSUInteger i = 0; i < minLen; i++) {
        UIView *ref = chains[0][i];
        BOOL same = YES;
        for (NSArray *c in chains) { if (c[i] != ref) { same = NO; break; } }
        if (!same) break;
        common = ref;
    }
    return common;
}

static NSMutableSet *collectWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableSet *windows = [NSMutableSet set];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in app.windows) [windows addObject:w];
#pragma clang diagnostic pop
    for (UIScene *sc in app.connectedScenes)
        if ([sc respondsToSelector:@selector(windows)])
            for (UIWindow *w in [(id)sc windows]) [windows addObject:w];
    return windows;
}

static UIWindow *bestDisplayWindow(void) {
    UIWindow *best = nil;
    for (UIWindow *w in collectWindows()) {
        if (w.isHidden) continue;
        if (!best || w.bounds.size.height > best.bounds.size.height) best = w;
    }
    return best;
}

// ===================== 挂载锚点（纯文本特征 sweep，不依赖私有类名） =====================
static UIView *findNativeAnchor(void) {
    NSMutableArray<NSArray<UIView *> *> *chains = [NSMutableArray array];
    UIView *timeLabel = nil;
    UIView *firstLabel = nil;
    BOOL diag = (gDiagRound < 10);
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    NSInteger visited = 0;

    for (UIWindow *win in collectWindows()) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (++visited > 4000) break;  // 视图树异常膨胀时兜底，避免主线程卡死
            if ([v isKindOfClass:[UILabel class]]) {
                NSString *text = labelText((UILabel *)v);
                // 优先复合判定锁屏大时钟；识别不到时回退纯文本特征兜底找全屏祖先锚点
                BOOL hit = isNativeClockLabel(v) || matchesTimeText(text);
                if (hit) {
                    [chains addObject:superviewChain(v)];
                    if (!firstLabel) firstLabel = v;
                    if (!timeLabel) timeLabel = v;
                    if (diag) writeLog([NSString stringWithFormat:
                        @"[ANCHOR-DIAG] text=%@ label=%@ path=%@",
                        text, NSStringFromClass([v class]), viewPath(v)]);
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }

    UIView *common = commonAncestorOfChains(chains);
    UIView *anchor = nil;
    // 挂在全屏的视图上，这样坐标系是全屏的，才能正确检测卡片位置
    if (common && common.bounds.size.height >= screenH * 0.50) anchor = common;
    else if (timeLabel ?: firstLabel) anchor = fullscreenAncestor(timeLabel ?: firstLabel);
    if (anchor) anchor = visibleAnchor(anchor);

    if (anchor) writeLog([NSString stringWithFormat:
        @"[ANCHOR-CHOICE] anchor=%@ window=%@ bounds=%@",
        NSStringFromClass([anchor class]),
        NSStringFromClass([anchor.window class]),
        NSStringFromCGRect(anchor.bounds)]);
    return anchor;
}

// ===================== 自定义视图构建（字形磨砂：模糊 / 染色只落在笔画内，字体本身是磨砂玻璃质感） =====================
static UIBlurEffectStyle thinBlurStyleForDark(BOOL dark) {
    // iOS 17 原生磨砂效果：用 Thick 材质，模糊更强
    return dark ? UIBlurEffectStyleSystemThickMaterialDark
                : UIBlurEffectStyleSystemThickMaterialLight;
}

static void ensureContainer(void) {
    if (gContainer) return;

    UIView *anchor = findNativeAnchor();
    BOOL fellBackToWindow = NO;
    if (!anchor) { anchor = bestDisplayWindow(); fellBackToWindow = YES; }
    if (!anchor) { writeLog(@"[ERR] 找不到挂载锚点"); return; }

    gContainer = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gContainer.backgroundColor = [UIColor clearColor];
    gContainer.userInteractionEnabled = NO;
    gContainer.clipsToBounds = NO;
    gContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [anchor addSubview:gContainer];

    BOOL dark = (gContainer.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    // 1) 字形磨砂宿主：frame 后续按字形包围盒设置；不裁剪，避免笔画被切
    gGlassHost = [[UIView alloc] init];
    gGlassHost.userInteractionEnabled = NO;
    gGlassHost.clipsToBounds = NO;
    [gContainer addSubview:gGlassHost];

    // 2) 笔画内模糊层：UIVisualEffectView，外层 layer.mask 用字形遮罩
    gBlurBackdrop = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:thinBlurStyleForDark(dark)]];
    gBlurBackdrop.userInteractionEnabled = NO;
    gBlurBackdrop.clipsToBounds = NO;
    [gGlassHost addSubview:gBlurBackdrop];

    // 3) 笔画内染色层：同样挂字形遮罩
    gTintView = [[UIView alloc] init];
    gTintView.userInteractionEnabled = NO;
    gTintView.clipsToBounds = NO;
    gTintView.backgroundColor = [UIColor whiteColor];
    [gGlassHost addSubview:gTintView];

    // 4) 两个独立字形遮罩层（CALayer.mask 不能被两个 layer 共享）
    gBlurMaskLayer = [CALayer layer];
    gBlurMaskLayer.contentsGravity = kCAGravityResize;
    gTintMaskLayer = [CALayer layer];
    gTintMaskLayer.contentsGravity = kCAGravityResize;

    // 5) 时钟文字（最上层清晰）
    gClockLabel = [[UILabel alloc] init];
    gClockLabel.backgroundColor = [UIColor clearColor];
    gClockLabel.adjustsFontSizeToFitWidth = NO;
    gClockLabel.textAlignment = NSTextAlignmentCenter;
    gClockLabel.userInteractionEnabled = NO;
    [gContainer addSubview:gClockLabel];

    writeLog([NSString stringWithFormat:
        @"[OK]%s anchor=%@ window=%@ bounds=%@",
        fellBackToWindow ? " [FALLBACK-WINDOW]" : "",
        NSStringFromClass([anchor class]),
        NSStringFromClass([anchor.window class]),
        NSStringFromCGRect(anchor.bounds)]);
}

static void relinkIfNeeded(void) {
    if (!gContainer) return;
    if (gContainer.window) return;
    UIView *anchor = findNativeAnchor();
    if (!anchor) anchor = bestDisplayWindow();
    if (!anchor) return;
    gContainer.frame = [UIScreen mainScreen].bounds;
    gContainer.clipsToBounds = NO;
    [anchor addSubview:gContainer];
    writeLog([NSString stringWithFormat:@"[RELINK] anchor=%@", NSStringFromClass([anchor class])]);
}

// ===================== 字形遮罩图像（同文字 / 同字体 / 离屏渲染，白字透明底作为 alpha mask） =====================
static UIImage *glyphMaskImage(NSString *text, UIFont *font, CGSize *outSize) {
    NSDictionary<NSAttributedStringKey, id> *attr = @{ NSFontAttributeName: font };
    CGSize textSize = [text sizeWithAttributes:attr];
    CGFloat pad = MAX(10.0, gBezelWidth * 2.0 + 8.0);
    CGSize size = CGSizeMake(ceil(textSize.width + pad * 2.0),
                             ceil(textSize.height + pad * 2.0));
    CGFloat scale = [UIScreen mainScreen].scale;

    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        [text drawInRect:CGRectMake(pad, pad, textSize.width, textSize.height)
          withAttributes:attr];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (outSize) *outSize = size;
    return img;
}

// ===================== 文本刷新 =====================
static NSString *clockText(void) { return t2ClockString(); }

static void refreshTexts(void) {
    if (!gClockLabel) return;
    NSString *text = clockText();
    UIFont *font = currentClockFont();
    // 整字玻璃块模式：文字清晰白色，不加描边
    gClockLabel.attributedText =
        [[NSAttributedString alloc] initWithString:text
            attributes:@{ NSFontAttributeName: font,
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:0.96 alpha:0.95] }];
}

// ===================== 原生视图隐藏（只认锁屏大时钟；跳过状态栏 / 切换器 / 通知播放器子树 / 自身子树） =====================
static void dumpAndHideNative(void) {
    if (!prefEnabled() || !gHideStockTime || !gClockEnabled) return;
    BOOL diag = (gDiagRound < 10);
    int hidden = 0;

    for (UIWindow *win in collectWindows()) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (v == gContainer || v == gClockLabel || v == gGlassHost) continue;
            if (isStatusBarOrSwitcher(v)) {
                for (UIView *sub in v.subviews) [stack addObject:sub];
                continue;
            }
            if (![v isKindOfClass:[UILabel class]]) {
                for (UIView *sub in v.subviews) [stack addObject:sub];
                continue;
            }
            UILabel *lab = (UILabel *)v;
            // 复合判定：父链锚点 + 排除通知/播放器/相机子树 + 文本格式 + 非状态栏；
            // 播放器进度条、计时器、通知里的 0:41 / 1:01 不会进入这里，不会被隐藏、不会污染引用。
            BOOL hit = isNativeClockLabel(lab);
            if (hit) {
                if (diag) {
                    writeLog([NSString stringWithFormat:
                        @"[DIAG] native clock text=%@ frame=%@ path=%@",
                        labelText(lab), NSStringFromCGRect(lab.frame), viewPath(lab)]);
                }
                // 缓存唯一的原生大时钟标签（BigTime sourceLabel），作为初始基准 frame 来源
                gNativeTimeLabel = lab;
                if (!lab.isHidden) {
                    lab.hidden = YES;
                    hidden++;
                    writeLog([NSString stringWithFormat:@"[HIDE] %@ text=%@",
                              NSStringFromClass([lab class]), labelText(lab)]);
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    // 本轮 sweep 没找到原生大时钟时，保留上一轮有效引用（系统重建视图间隙不清空）
    if (hidden > 0) writeLog([NSString stringWithFormat:@"[SWEEP] hidden=%d", hidden]);
    if (diag) gDiagRound++;
}

// 关闭总开关：恢复此前被隐藏的原生大时钟标签（日期从未隐藏，保持系统原样）
static void restoreNative(void) {
    for (UIWindow *win in collectWindows()) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (isStatusBarOrSwitcher(v)) {
                for (UIView *sub in v.subviews) [stack addObject:sub];
                continue;
            }
            if ([v isKindOfClass:[UILabel class]] && isNativeClockLabel(v)) {
                UILabel *lab = (UILabel *)v;
                if (lab.isHidden) {
                    lab.hidden = NO;
                    writeLog([NSString stringWithFormat:@"[RESTORE] %@ text=%@",
                              NSStringFromClass([lab class]), labelText(lab)]);
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    gNativeTimeLabel = nil;  // 关闭插件后释放旧原生标签引用，避免残留指针
}

// ===================== 仿 iOS26 原生回缩：测量最近通知 / 播放器卡片顶部，只下压 HGHT 高度轴 =====================
// 机制（老版 ivar 实证 + 真机视频核对）：时钟基准位置固定，不物理平移去追被隐藏的原生 label；
// 卡片上推逼近时只把 HGHT 高度轴往下压、数字纵向压扁；字号倍率、宽度、透明度、位置保持不变，
// 玻璃模糊 / 染色不随收缩衰减；卡片离开后高度轴平滑回弹。对应老版
// cachedNearestNotificationTop / animatedDynamicHeightAxis / targetDynamicHeightAxis / applyDynamicHeightAxis:。
// 全程只读系统视图 frame，不 hook setFrame:/setCenter:，不修改系统视图位置。

// 通知 / 播放器容器类名（cfstrings 实证 + 真机旧日志 MRU 播放器族前缀）
static NSSet<NSString *> *cardContainerClassNames(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"NCNotificationShortLookView", @"NCNotificationLongLookView",
            @"NCNotificationStructuredListCellView", @"NCNotificationListViewCell",
            @"PLPlatterView", @"PLPlatterContainerView",
            @"CCCPPlatterViewControllerView",
        ]];
    });
    return set;
}

// 真正承载一张通知卡片 / 播放器面板的候选视图；列表容器本身常驻，不作为测量候选
static BOOL isCardContainer(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    if ([cardContainerClassNames() containsObject:cls]) return YES;
    if ([cls hasPrefix:@"MRUNowPlaying"]) return YES;  // 锁屏播放器 NowPlaying 容器族
    if ([cls hasPrefix:@"NCNotification"]) return YES;  // 放宽：所有 NCNotification 开头的都算
    if ([cls hasPrefix:@"PLPlatter"]) return YES;  // 放宽：所有 PLPlatter 开头的都算
    return NO;
}

// 刷新原生大时钟基准 frame（容器坐标系）；标签失效时保留上一轮缓存
static void refreshSourceFrame(void) {
    UILabel *src = gNativeTimeLabel;
    if (!src || !src.superview || !src.window || !gContainer) return;
    CGRect f = [src convertRect:src.bounds toView:gContainer];
    if (f.size.width >= 10 && f.size.height >= 10) gSourceFrame = f;
}

// 低频测量：取所有可见通知卡片 / 播放器面板在容器坐标系中最靠上的顶部 y（minY 最小者）；无候选为 INFINITY
static void measureNearestCardTop(void) {
    gNearestCardTopY = INFINITY;
    if (!gContainer) return;
    CGFloat bestTop = INFINITY;
    for (UIWindow *win in collectWindows()) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            // 隐藏 / 近乎透明容器子树整体不可见，跳过其后代，避免后台常驻残留容器参与避让
            if (v.isHidden || v.alpha <= 0.3) { continue; }
            if (isCardContainer(v) && v.window && v.bounds.size.height > 40) {
                CGRect f = [v convertRect:v.bounds toView:gContainer];
                if (f.size.height > 40 && f.origin.y < bestTop) bestTop = f.origin.y;
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    gNearestCardTopY = bestTop;
}

// 由当前收缩量推导目标高度轴；回缩只覆盖 HGHT，字号倍率 / 宽度 / 透明度不随 gShrink 改变。
// 压扁下限为轴最小值 100（clampFloat 已在 variationAxes 内复核）。
// 当 gFontHeight > 500 时，HGHT 轴固定为 500（最大值），超出部分用字号放大补充
static CGFloat currentHeightAxis(void) {
    CGFloat maxHeight = fmin(gFontHeight, 500.0); // HGHT 轴最大 500
    return maxHeight + (100.0 - maxHeight) * gShrink;
}

// 字体缓存：只有当字体参数变化时才重新创建，避免卡顿
static UIFont *gCachedClockFont = nil;
static CGFloat gCachedFontHeight = -1;
static CGFloat gCachedFontSize = -1;
static CGFloat gCachedFontWeight = -1;
static CGFloat gCachedFontWidth = -1;
static CGFloat gCachedFontSoftness = -1;
static CGFloat gCachedFontSizeScale = -1;

static UIFont *currentClockFont(void) {
    CGFloat height = currentHeightAxis();
    CGFloat heightScale = fmax(1.0, gFontHeight / 500.0);
    CGFloat size = kBaseClockSize * gSizeScale * heightScale;
    
    // 检查缓存是否有效
    if (gCachedClockFont &&
        gCachedFontHeight == height &&
        gCachedFontSize == size &&
        gCachedFontWeight == gFontWeight &&
        gCachedFontWidth == gFontWidth &&
        gCachedFontSoftness == gFontSoftness &&
        gCachedFontSizeScale == gSizeScale) {
        return gCachedClockFont;
    }
    
    // 缓存无效，重新创建字体
    UIFont *f = clockFontWithHeight(height);
    gCachedClockFont = f;
    gCachedFontHeight = height;
    gCachedFontSize = size;
    gCachedFontWeight = gFontWeight;
    gCachedFontWidth = gFontWidth;
    gCachedFontSoftness = gFontSoftness;
    gCachedFontSizeScale = gSizeScale;
    return f;
}

// 计算目标收缩量：卡片顶部进入时钟下沿上方 220pt 避让带，越往上 t 越大
static void updateTargetShrink(void) {
    gTargetShrink = 0;
    if (!gClockLabel) return;
    if (gNearestCardTopY == INFINITY) return;

    // 时钟下沿：优先用 gClockLabel 实际位置，兜底用 gSourceFrame，再兜底用屏幕 30% 高度
    CGFloat clockBottom;
    if (!CGRectIsEmpty(gSourceFrame)) {
        clockBottom = CGRectGetMaxY(gSourceFrame);
    } else if (gClockLabel.bounds.size.height > 10) {
        clockBottom = gClockLabel.center.y + gClockLabel.bounds.size.height / 2.0;
    } else {
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        clockBottom = screenH * 0.35;  // 兜底：默认时钟在屏幕上方 35%
    }

    const CGFloat kAvoidRange = 300.0;  // pt，放宽触发带让压缩更明显
    CGFloat gap = clockBottom - gNearestCardTopY;  // >0：卡片顶部已进入时钟下沿上方
    if (gap > 0) gTargetShrink = clampFloat(gap / kAvoidRange, 0.0, 1.0);

    // 调试日志
    if (gTargetShrink > 0.01) {
        writeLog([NSString stringWithFormat:
            @"[SHRINK] clockBottom=%.0f cardTop=%.0f gap=%.0f target=%.2f",
            clockBottom, gNearestCardTopY, gap, gTargetShrink]);
    }
}

// 时钟基准位置：水平居中、垂直对齐原生大时钟基准 frame 中心 + 偏移；不随卡片物理平移
static void syncClockPosition(void) {
    if (!gContainer || !gClockLabel || !gClockEnabled) return;
    CGFloat containerW = gContainer.bounds.size.width;
    CGFloat containerH = gContainer.bounds.size.height;
    CGFloat centerX, centerY;
    if (!CGRectIsEmpty(gSourceFrame)) {
        centerX = CGRectGetMidX(gSourceFrame) + gClockOffsetX;
        centerY = CGRectGetMidY(gSourceFrame) + gClockOffsetY;
    } else {
        centerX = containerW / 2.0 + gClockOffsetX;
        centerY = containerH * 0.30 + gClockOffsetY;
    }
    
    // 当 gFontHeight > 500 时，字号放大，向上对齐，这样字体看起来就是向上拉长的，而不是整体变大
    CGFloat heightScale = fmax(1.0, gFontHeight / 500.0);
    if (heightScale > 1.0) {
        // 向上对齐：底部位置不变，顶部向上延伸
        CGFloat originalCenterY = centerY;
        // 字体高度大约是字号的 1.2 倍，所以向上偏移 (heightScale-1) * 字体高度 / 2
        CGFloat offsetY = (heightScale - 1.0) * 100.0; // 估算值，大概是字体高度的一半
        centerY = originalCenterY - offsetY;
    }
    
    centerY = MAX(containerH * 0.08, MIN(containerH * 0.72, centerY));
    gClockLabel.center = CGPointMake(centerX, centerY);
    gGlassHost.center = gClockLabel.center;
}

// 每帧动态状态：平滑插值收缩量 → 位置固定；HGHT 变化跨过阈值才重建字体 / 遮罩。
// 文字与玻璃 alpha 不随收缩改变，只在 relayoutViews 按用户设定的模糊 / 染色原值设置一次。
static void applyDynamicState(void) {
    if (!gContainer || !gClockLabel || !gClockEnabled) return;
    gShrink += (gTargetShrink - gShrink) * 0.12;
    if (fabs(gTargetShrink - gShrink) < 0.005) gShrink = gTargetShrink;

    syncClockPosition();

    static CGFloat lastRebuildShrink = -1.0;
    if (fabs(gShrink - lastRebuildShrink) > 0.08) {  // 提高阈值，减少重建字体频率，避免卡顿
        lastRebuildShrink = gShrink;
        relayoutViews();  // 内部按 currentClockFont 重建字体与字形遮罩
    }
}

// ===================== 完整重排视图（样式变更 / 分钟切换调用；高频回调只缓存参数） =====================
static void relayoutViews(void) {
    if (!gContainer || !gClockLabel) return;

    BOOL showClock = gClockEnabled;

    gClockLabel.hidden = !showClock;
    gGlassHost.hidden  = !showClock;
    gBlurBackdrop.hidden = !(showClock && gGlassEnabled);
    gTintView.hidden  = !(showClock && gGlassEnabled);

    if (!showClock) return;

    refreshTexts();
    [gClockLabel sizeToFit];

    // 位置：基准中心对齐原生大时钟 frame（内部含回退与钳制），不随卡片物理平移
    syncClockPosition();

    // 重建字形遮罩（文字 / 字体 / 尺寸 / 避让收缩变化时同步）；磨砂宿主尺寸 = 遮罩图像尺寸，中心与文字对齐
    NSString *text = gClockLabel.attributedText.string ?: gClockLabel.text;
    UIFont *font = currentClockFont();
    CGSize glyphSize;
    UIImage *maskImg = glyphMaskImage(text, font, &glyphSize);

    gGlassHost.bounds = CGRectMake(0, 0, glyphSize.width, glyphSize.height);
    gGlassHost.center = gClockLabel.center;
    gBlurBackdrop.frame = gGlassHost.bounds;
    gTintView.frame = gGlassHost.bounds;

    // 纵向缩放：去掉 transform 拉伸（会导致字体变形）
    // 改用字体 HGHT 轴本身来控制高度，先确认轴效果
    CGFloat scaleY = 1.0;
    gClockLabel.transform = CGAffineTransformMakeScale(1.0, scaleY);
    gGlassHost.transform = CGAffineTransformMakeScale(1.0, scaleY);

    if (maskImg) {
        gBlurMaskLayer.frame = gGlassHost.bounds;
        gTintMaskLayer.frame = gGlassHost.bounds;
        gBlurMaskLayer.contents = (__bridge id)maskImg.CGImage;
        gTintMaskLayer.contents = (__bridge id)maskImg.CGImage;
        gBlurBackdrop.layer.mask = gBlurMaskLayer;
        gTintView.layer.mask = gTintMaskLayer;
    }

    // 回缩不改变透明度：玻璃模式下隐藏最上层清晰文字，只显示模糊+染色层；非玻璃模式显示清晰文字。
    if (gGlassEnabled) {
        // 磨砂玻璃模式：隐藏清晰文字，只显示下面的模糊层和染色层
        gClockLabel.hidden = YES;
        gBlurBackdrop.hidden = (gBlurRadius <= 0);
        gBlurBackdrop.alpha = (gBlurRadius <= 0) ? 0.0 : 1.0;
    } else {
        // 清晰文字模式：隐藏玻璃层，只显示清晰文字
        gClockLabel.hidden = NO;
        gClockLabel.alpha = 1.0;
        gBlurBackdrop.hidden = YES;
        gTintView.hidden = YES;
        return;
    }

    // 染色层：iOS 17 原生磨砂效果，轻微的白色染色
    gTintView.alpha = gLightTint;
    gTintView.hidden = NO;
    // 用带透明度的白色，模拟磨砂玻璃质感
    gTintView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
}

// ===================== 样式应用（必须主线程；从磁盘读盘只在这里与 DisplayLink 状态切换时调用） =====================
static void applyStyles(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ applyStyles(); });
        return;
    }

    NSDictionary *prefs = loadPrefs();
    gPrefsEnabled  = readBool(prefs, @"Enable", YES);
    gClockEnabled  = readBool(prefs, @"ClockEnabled", YES);
    gHideStockTime = readBool(prefs, @"HideStockTime", YES);

    if (!gPrefsEnabled) {
        if (gContainer) gContainer.hidden = YES;
        restoreNative();
        return;
    }

    if (!gCGFontMap.count || !gFontURLMap.count) registerCustomFonts();
    ensureContainer();
    relinkIfNeeded();
    if (!gContainer) return;

    // 基本（字号只走大小倍率，基准 pt 为代码内常量 kBaseClockSize，无独立基础字号滑杆）
    gClockOffsetY = readFloat(prefs, @"ClockVerticalOffset", 0);
    gClockOffsetX = readFloat(prefs, @"ClockHorizontalOffset", 0);
    gFPS          = MAX(1, MIN(120, readInt(prefs, @"FPS", 60)));

    // 玻璃
    gGlassEnabled = readBool(prefs, @"GlassEnabled", YES);
    gBezelWidth   = clampFloat(readFloat(prefs, @"BezelWidth", 0.5), 0, 10);
    gBlurRadius   = clampFloat(readFloat(prefs, @"Blur", 5.0), 0, 20);
    gLightTint    = clampFloat(readFloat(prefs, @"LightTintAlpha", 0.10), 0, 1);
    gDarkTint     = clampFloat(readFloat(prefs, @"DarkTintAlpha", 0.10), 0, 1);
    gTintMode     = readString(prefs, @"TintOverrideMode", @"system");

    // 可变字体（固定内置 axs66；PresetFontEnabled 关闭时不写可变轴，使用字体默认实例，不切系统字体）
    gPresetFontEnabled = readBool(prefs, @"PresetFontEnabled", YES);
    gFontWeight   = clampFloat(readFloat(prefs, @"FontWeight", 400), 1, 1000);
    gSizeScale    = clampFloat(readFloat(prefs, @"SizeScale", 1.0), 0.5, 3.0);
    gFontWidth    = clampFloat(readFloat(prefs, @"FontWidth", 100), 60, 100);
    gFontHeight   = clampFloat(readFloat(prefs, @"FontHeight", 100), 100, 1000);
    gFontSoftness = clampFloat(readFloat(prefs, @"FontSoftness", 70), 0, 100);

    // 参数 / 开关刷新后复位避让动态状态，重新测量基准 frame（避免残留上一次收缩态）
    gShrink = 0;
    gTargetShrink = 0;
    gSourceFrame = CGRectZero;
    gNearestCardTopY = INFINITY;

    gContainer.hidden = NO;
    [gContainer.superview bringSubviewToFront:gContainer];

    dumpAndHideNative();
    refreshSourceFrame();
    relayoutViews();

    writeLog([NSString stringWithFormat:
        @"[STYLE] 开关=%d 时钟=%d 隐藏原生=%d 倍率=%.2f 偏移=%.0f 字体=%@ FPS=%ld | 玻璃=%d 边缘=%.1f 模糊=%.1f 浅染=%.2f 深染=%.2f 模式=%@ | 粗细=%.0f 宽=%.0f 高=%.0f 柔和=%.0f 可变轴=%d 原生标签=%d 收缩=%.2f",
        gPrefsEnabled, gClockEnabled, gHideStockTime, gSizeScale,
        gClockOffsetY, kTime2BuiltinFontFile, (long)gFPS,
        gGlassEnabled, gBezelWidth, gBlurRadius, gLightTint, gDarkTint, gTintMode,
        gFontWeight, gFontWidth, gFontHeight, gFontSoftness, gPresetFontEnabled,
        gNativeTimeLabel != nil, gShrink]);
}

// ===================== CADisplayLink 每帧驱动（对齐 BigTime AxsDisplayLinkDriver；非 1 秒定时器） =====================
// 每帧只做轻量位置同步；分钟切换才刷新文字 / 重建遮罩；低频兜底刷新原生标签引用。
@interface Time2DisplayLinkBridge : NSObject
@property (nonatomic, copy) void (^tickBlock)(void);
- (void)tick:(CADisplayLink *)link;
@end
@implementation Time2DisplayLinkBridge
- (void)tick:(CADisplayLink *)link { (void)link; if (self.tickBlock) self.tickBlock(); }
@end

static Time2DisplayLinkBridge *gBridge = nil;

static void startDisplayLinkIfNeeded(void) {
    if (gDisplayLink || !gLockVisible) return;
    if (!gBridge) gBridge = [[Time2DisplayLinkBridge alloc] init];
    gBridge.tickBlock = ^{
        if (!gLockVisible) return;
        gFrameCount++;

        NSCalendar *cal = [NSCalendar currentCalendar];
        NSInteger minute = [cal component:NSCalendarUnitMinute fromDate:[NSDate date]];

        if (minute != gLastMinute) {
            gLastMinute = minute;
            refreshTexts();
            dumpAndHideNative();
            refreshSourceFrame();
            relayoutViews();
        } else {
            // 每帧刷新原生大时钟基准 frame（轻量，只读缓存引用）
            refreshSourceFrame();
            // 低频测量最近通知 / 播放器卡片顶部（约 6–7 帧一次，避免每帧全树遍历）
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - gLastCardScan > 0.15) {
                gLastCardScan = now;
                measureNearestCardTop();
            }
            updateTargetShrink();
            applyDynamicState();
            // 约每秒刷新一次原生标签引用，应对系统重建视图导致旧引用失效
            if (gFrameCount % 30 == 0) dumpAndHideNative();
        }
    };
    gDisplayLink = [CADisplayLink displayLinkWithTarget:gBridge selector:@selector(tick:)];
    gDisplayLink.preferredFramesPerSecond = gFPS;
    [gDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void stopDisplayLink(void) {
    if (gDisplayLink) {
        [gDisplayLink invalidate];
        gDisplayLink = nil;
    }
    if (gBridge) gBridge.tickBlock = nil;
}

// ===================== 锁屏可见状态（由系统公开通知 + 延时 sweep 驱动，不 hook 私有控制器） =====================
static void lockScreenDidAppear(NSString *source) {
    BOOL wasHidden = !gLockVisible;
    gLockVisible = YES;
    writeLog([NSString stringWithFormat:@"[APPEAR] source=%@%s", source, wasHidden ? " (was hidden)" : ""]);
    dispatch_async(dispatch_get_main_queue(), ^{
        applyStyles();
        dumpAndHideNative();
        refreshSourceFrame();
        startDisplayLinkIfNeeded();
    });
}

static void lockScreenDidDisappear(NSString *source) {
    gLockVisible = NO;
    writeLog([NSString stringWithFormat:@"[DISAPPEAR] source=%@", source]);
    dispatch_async(dispatch_get_main_queue(), ^{
        stopDisplayLink();
        if (gContainer) gContainer.hidden = YES;
    });
}

// ===================== 偏好变更（Darwin 通知，主线程实时生效） =====================
static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    writeLog(@"[NOTIFY] 设置变更，实时刷新");
    dispatch_async(dispatch_get_main_queue(), ^{
        // 直接读盘判断总开关，避免沿用上一次内存中的旧全局值
        NSDictionary *prefs = loadPrefs();
        if (readBool(prefs, @"Enable", YES)) {
            registerCustomFonts();
            applyStyles();
            dumpAndHideNative();
        } else {
            gPrefsEnabled = NO;
            if (gContainer) gContainer.hidden = YES;
            restoreNative();
        }
    });
}

// ===================== 加载入口 =====================
%ctor {
    writeLog(@"Time2 已加载（仿 iOS26 原生回缩：固定内置 axs66 可变四轴；卡片逼近只下压 HGHT 高度轴，不缩字号/不变淡/玻璃不衰减；仅 sweep 兜底，无私有类 hook）");
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ registerCustomFonts(); });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                         NULL, &prefsChanged,
                                         (__bridge CFStringRef)kTime2PrefsChangedNotification,
                                         NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // BigTime 11.4.5 实证的应用生命周期公开通知（不依赖私有控制器类名）
        NSArray *appearNames = @[
            UIApplicationDidFinishLaunchingNotification,
            UIApplicationDidBecomeActiveNotification,
            UIApplicationWillEnterForegroundNotification
        ];
        for (NSString *n in appearNames)
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *note) {
            lockScreenDidAppear([NSString stringWithFormat:@"notify:%@", n]);
        }];

        NSArray *disappearNames = @[
            UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification
        ];
        for (NSString *n in disappearNames)
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *note) {
            lockScreenDidDisappear([NSString stringWithFormat:@"notify:%@", n]);
        }];

        // 启动兜底：SpringBoard 视图树就绪后多次尝试挂载与 sweep
        for (NSNumber *d in @[@1.0, @2.5, @5.0, @9.0]) {
            NSString *src = [NSString stringWithFormat:@"boot-%.1fs", d.doubleValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ lockScreenDidAppear(src); });
        }
    }
}
