// src/Core/AuraSignEngine.mm
#import <CoreFoundation/CoreFoundation.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define environ (*_NSGetEnviron())
#else
extern char **environ;
#endif

@interface UIImage (AuraEngineIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface NSObject (AuraDynamicPrivateAPIs)
- (id)anisetteDataWithError:(NSError **)error;
- (void)anisetteDataWithCompletion:(void(^)(id data, NSError *error))completion;
- (NSString *)machineID;
- (NSString *)oneTimePassword;
- (unsigned long long)routingInfo;
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)isInstalled;
- (BOOL)isPlaceholder;
- (BOOL)installApplication:(NSURL *)path withOptions:(NSDictionary *)options error:(NSError **)error;
- (NSString *)applicationIdentifier;
- (NSURL *)bundleURL;
- (NSString *)shortVersionString;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

@interface NSObject (AuraUserNotificationsPrivate)
+ (id)currentNotificationCenter;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleId;
- (void)requestAuthorizationWithOptions:(NSUInteger)options completionHandler:(void (^)(BOOL granted, NSError *error))completionHandler;
- (void)addNotificationRequest:(id)request withCompletionHandler:(void (^)(NSError *error))completionHandler;
- (void)setTitle:(NSString *)title;
- (void)setBody:(NSString *)body;
- (void)setSound:(id)sound;
+ (id)defaultSound;
@end

@interface NSObject (AuraDynamicGlassView)
- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)setTintLevel:(CGFloat)level;
- (void)setAccentGlowColor:(UIColor *)color;
@end

typedef CFTypeRef (*MISProfileCreateWithDataFunc)(CFAllocatorRef allocator, CFDataRef data);
typedef int (*MISInstallProvisioningProfileFunc)(CFTypeRef profile);

// 纯 C 内存 ZIP 打包头结构体
#pragma pack(push, 1)
typedef struct {
    uint32_t signature;       // 0x04034b50
    uint16_t versionNeeded;   // 20
    uint16_t flags;           // 0
    uint16_t compression;     // 0 (Store)
    uint16_t modTime;         // 0
    uint16_t modDate;         // 0x5421
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t fileNameLen;
    uint16_t extraFieldLen;
} AuraZipLocalHeader;

typedef struct {
    uint32_t signature;       // 0x02014b50
    uint16_t versionMadeBy;   // 0x0314 (UNIX)
    uint16_t versionNeeded;   // 20
    uint16_t flags;           // 0
    uint16_t compression;     // 0
    uint16_t modTime;         // 0
    uint16_t modDate;         // 0x5421
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t fileNameLen;
    uint16_t extraFieldLen;
    uint16_t fileCommentLen;
    uint16_t diskNumberStart;
    uint16_t internalAttrs;
    uint32_t externalAttrs;   // UNIX permissions << 16
    uint32_t localHeaderOffset;
} AuraZipCentralHeader;

typedef struct {
    uint32_t signature;       // 0x06054b50
    uint16_t diskNumber;
    uint16_t centralDirDisk;
    uint16_t numEntriesThisDisk;
    uint16_t numEntriesTotal;
    uint32_t centralDirSize;
    uint32_t centralDirOffset;
    uint16_t commentLen;
} AuraZipEndRecord;
#pragma pack(pop)

static uint32_t aura_crc32_compute(const uint8_t *data, size_t length) {
    static uint32_t table[256];
    static BOOL table_inited = NO;
    if (!table_inited) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int j = 0; j < 8; j++) {
                c = (c & 1) ? (0xEDB88320L ^ (c >> 1)) : (c >> 1);
            }
            table[i] = c;
        }
        table_inited = YES;
    }
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

@implementation AuraAppInfo
@end

#define AURA_PREFS_PATH AURA_NS_JBROOT(@"/var/mobile/Library/Preferences/com.aurasign.pro.plist")

@implementation AuraSignEngine {
    NSMutableArray<NSString *> *_guardedBundleIDs;
}

+ (instancetype)sharedEngine {
    static AuraSignEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AuraSignEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _autoRenewEnabled = YES; // 修复默认未开启的 Bug
        _normalRenewThresholdDays = 5;
        _lowBatteryRescueEnabled = YES;
        _lowBatteryTriggerPercent = 5;
        _lowBatteryThresholdDays = 5;
        _rebootShieldEnabled = YES;
        _notificationEnabled = YES;
        _smartStripExtensions = YES;
        _liquidGlassTintLevel = 0.25f;
        _guardedBundleIDs = [NSMutableArray array];
        _earliestGuardedExpTimestamp = 0;
        [self loadPreferences];

        // 监听跨进程开关变更通知，确保 App 修改开关后 aurasignd 与 SpringBoard 实时同步内存状态
        int prefToken = 0;
        notify_register_dispatch("com.aurasign.pro.prefsChanged", &prefToken, dispatch_get_main_queue(), ^(int token) {
            [self loadPreferences];
        });

        NSString *iconPath = AURA_NS_JBROOT(@"/Applications/AuraSignPro.app/AppIcon60x60@3x.png");
        if (![[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
            [self generateAndInstallScheme1AppIcons];
        }
    }
    return self;
}

- (UIImage *)renderScheme1EmeraldShieldIconWithSize:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat s = size.width / 512.0;
    CGContextScaleCTM(ctx, s, s);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    // 1. 深海暗夜蓝-翡翠绿渐变底色
    CGFloat bgColors[] = {
        0.027, 0.133, 0.153, 1.0,
        0.024, 0.067, 0.129, 1.0,
        0.039, 0.180, 0.212, 1.0
    };
    CGFloat bgLocs[] = {0.0, 0.5, 1.0};
    CGGradientRef bgGrad = CGGradientCreateWithColorComponents(cs, bgColors, bgLocs, 3);
    CGContextDrawLinearGradient(ctx, bgGrad, CGPointMake(0, 0), CGPointMake(512, 512), 0);
    CGGradientRelease(bgGrad);

    // 2. 中心翡翠径向发光
    CGFloat glowColors[] = {
        0.063, 0.725, 0.506, 0.52,
        0.063, 0.725, 0.506, 0.0
    };
    CGGradientRef glowGrad = CGGradientCreateWithColorComponents(cs, glowColors, NULL, 2);
    CGContextDrawRadialGradient(ctx, glowGrad, CGPointMake(256, 235), 10, CGPointMake(256, 235), 220, 0);
    CGGradientRelease(glowGrad);

    // 3. 外层液态玻璃主护盾
    UIBezierPath *outerShield = [UIBezierPath bezierPath];
    [outerShield moveToPoint:CGPointMake(256, 76)];
    [outerShield addLineToPoint:CGPointMake(396, 132)];
    [outerShield addCurveToPoint:CGPointMake(256, 432) controlPoint1:CGPointMake(396, 258) controlPoint2:CGPointMake(346, 364)];
    [outerShield addCurveToPoint:CGPointMake(116, 132) controlPoint1:CGPointMake(166, 364) controlPoint2:CGPointMake(116, 258)];
    [outerShield closePath];

    CGContextSaveGState(ctx);
    [outerShield addClip];
    CGFloat shColors[] = {
        0.431, 0.906, 0.718, 0.45,
        0.063, 0.725, 0.506, 0.24,
        0.220, 0.741, 0.973, 0.42
    };
    CGGradientRef shGrad = CGGradientCreateWithColorComponents(cs, shColors, bgLocs, 3);
    CGContextDrawLinearGradient(ctx, shGrad, CGPointMake(116, 76), CGPointMake(396, 432), 0);
    CGGradientRelease(shGrad);
    CGContextRestoreGState(ctx);

    [[UIColor colorWithRed:0.65 green:0.95 blue:0.85 alpha:0.85] setStroke];
    outerShield.lineWidth = 6.0;
    outerShield.lineJoinStyle = kCGLineJoinRound;
    [outerShield stroke];

    // 4. 内层暗色晶盾
    UIBezierPath *innerShield = [UIBezierPath bezierPath];
    [innerShield moveToPoint:CGPointMake(256, 104)];
    [innerShield addLineToPoint:CGPointMake(368, 150)];
    [innerShield addCurveToPoint:CGPointMake(256, 396) controlPoint1:CGPointMake(368, 252) controlPoint2:CGPointMake(326, 338)];
    [innerShield addCurveToPoint:CGPointMake(144, 150) controlPoint1:CGPointMake(186, 338) controlPoint2:CGPointMake(144, 252)];
    [innerShield closePath];
    [[UIColor colorWithRed:0.024 green:0.086 blue:0.149 alpha:0.52] setFill];
    [innerShield fill];
    [[UIColor colorWithWhite:1.0 alpha:0.25] setStroke];
    innerShield.lineWidth = 2.5;
    [innerShield stroke];

    // 5. 核心闪电符号 (⚡)
    UIBezierPath *bolt = [UIBezierPath bezierPath];
    [bolt moveToPoint:CGPointMake(270, 150)];
    [bolt addLineToPoint:CGPointMake(194, 254)];
    [bolt addLineToPoint:CGPointMake(250, 254)];
    [bolt addLineToPoint:CGPointMake(232, 346)];
    [bolt addLineToPoint:CGPointMake(328, 228)];
    [bolt addLineToPoint:CGPointMake(268, 228)];
    [bolt closePath];

    CGContextSaveGState(ctx);
    [bolt addClip];
    CGFloat boltColors[] = {
        1.0, 1.0, 1.0, 1.0,
        0.655, 0.953, 0.816, 1.0,
        0.063, 0.725, 0.506, 1.0
    };
    CGGradientRef boltGrad = CGGradientCreateWithColorComponents(cs, boltColors, bgLocs, 3);
    CGContextDrawLinearGradient(ctx, boltGrad, CGPointMake(194, 150), CGPointMake(328, 346), 0);
    CGGradientRelease(boltGrad);
    CGContextRestoreGState(ctx);

    CGColorSpaceRelease(cs);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)generateAndInstallScheme1AppIcons {
    NSString *appDir = AURA_NS_JBROOT(@"/Applications/AuraSignPro.app");
    if (![[NSFileManager defaultManager] fileExistsAtPath:appDir]) return;

    NSString *icon3xPath = [appDir stringByAppendingPathComponent:@"AppIcon60x60@3x.png"];
    NSString *icon2xPath = [appDir stringByAppendingPathComponent:@"AppIcon60x60@2x.png"];
    NSString *iconDefPath = [appDir stringByAppendingPathComponent:@"icon.png"];

    UIImage *img180 = [self renderScheme1EmeraldShieldIconWithSize:CGSizeMake(180, 180)];
    UIImage *img120 = [self renderScheme1EmeraldShieldIconWithSize:CGSizeMake(120, 120)];

    if (img180) {
        NSData *png180 = UIImagePNGRepresentation(img180);
        [png180 writeToFile:icon3xPath atomically:YES];
        [png180 writeToFile:iconDefPath atomically:YES];
        chmod(icon3xPath.UTF8String, 0644);
        chmod(iconDefPath.UTF8String, 0644);
    }
    if (img120) {
        NSData *png120 = UIImagePNGRepresentation(img120);
        [png120 writeToFile:icon2xPath atomically:YES];
        chmod(icon2xPath.UTF8String, 0644);
    }
}

- (void)loadPreferences {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:AURA_PREFS_PATH];
    if (dict) {
        _autoRenewEnabled         = dict[@"autoRenewEnabled"] ? [dict[@"autoRenewEnabled"] boolValue] : YES;
        _normalRenewThresholdDays = dict[@"normalRenewThresholdDays"] ? [dict[@"normalRenewThresholdDays"] integerValue] : 5;
        _lowBatteryRescueEnabled  = dict[@"lowBatteryRescueEnabled"] ? [dict[@"lowBatteryRescueEnabled"] boolValue] : YES;
        _lowBatteryTriggerPercent = dict[@"lowBatteryTriggerPercent"] ? [dict[@"lowBatteryTriggerPercent"] integerValue] : 5;
        _lowBatteryThresholdDays  = dict[@"lowBatteryThresholdDays"] ? [dict[@"lowBatteryThresholdDays"] integerValue] : 5;
        _rebootShieldEnabled      = dict[@"rebootShieldEnabled"] ? [dict[@"rebootShieldEnabled"] boolValue] : YES;
        _notificationEnabled      = dict[@"notificationEnabled"] ? [dict[@"notificationEnabled"] boolValue] : YES;
        _smartStripExtensions     = YES;
        _liquidGlassTintLevel     = 0.25f;
        _guardedBundleIDs         = [dict[@"guardedBundleIDs"] mutableCopy] ?: [NSMutableArray array];
        _earliestGuardedExpTimestamp = [dict[@"earliestGuardedExpTimestamp"] doubleValue];
    }
}

- (void)savePreferences {
    NSString *prefDir = AURA_NS_JBROOT(@"/var/mobile/Library/Preferences");
    [[NSFileManager defaultManager] createDirectoryAtPath:prefDir withIntermediateDirectories:YES attributes:nil error:nil];
    chmod(prefDir.UTF8String, 0777);

    NSDictionary *dict = @{
        @"autoRenewEnabled": @(_autoRenewEnabled),
        @"normalRenewThresholdDays": @(_normalRenewThresholdDays),
        @"lowBatteryRescueEnabled": @(_lowBatteryRescueEnabled),
        @"lowBatteryTriggerPercent": @(_lowBatteryTriggerPercent),
        @"lowBatteryThresholdDays": @(_lowBatteryThresholdDays),
        @"rebootShieldEnabled": @(_rebootShieldEnabled),
        @"notificationEnabled": @(_notificationEnabled),
        @"smartStripExtensions": @(YES),
        @"liquidGlassTintLevel": @(0.25f),
        @"guardedBundleIDs": _guardedBundleIDs ?: @[],
        @"earliestGuardedExpTimestamp": @(_earliestGuardedExpTimestamp)
    };
    [dict writeToFile:AURA_PREFS_PATH atomically:YES];
    chmod(AURA_PREFS_PATH.UTF8String, 0666);
    chown(AURA_PREFS_PATH.UTF8String, 501, 501);

    // 广播跨进程配置更新通知
    notify_post("com.aurasign.pro.prefsChanged");
}

- (BOOL)hasAnyGuardedAppApproachingExpirationInMemory {
    [self loadPreferences];
    if (!_autoRenewEnabled) return NO;
    if (_earliestGuardedExpTimestamp <= 1000.0) return YES; // 尚未初始化缓存时允许扫描一次
    double remainDays = (_earliestGuardedExpTimestamp - [[NSDate date] timeIntervalSince1970]) / 86400.0;
    return (remainDays < (double)_normalRenewThresholdDays);
}

#pragma mark - 3 槽位自动守护管理

- (BOOL)isBundleIDGuarded:(NSString *)bundleID isLoader:(BOOL)isLoader {
    if (isLoader) return YES; // 越狱工具强制锁定守护
    if (!bundleID.length) return NO;
    return [_guardedBundleIDs containsObject:bundleID];
}

- (BOOL)toggleGuardForApp:(AuraAppInfo *)app allApps:(NSArray<AuraAppInfo *> *)allApps outError:(NSString **)outError {
    if (app.isJailbreakLoader) {
        if (outError) *outError = @"越狱加载器属于最高优先级核心应用，已默认锁定守护！";
        return NO;
    }
    [self loadPreferences];
    if ([_guardedBundleIDs containsObject:app.bundleID]) {
        [_guardedBundleIDs removeObject:app.bundleID];
        app.isGuarded = NO;
        [self savePreferences];
        return YES;
    }

    NSInteger currentGuardedCount = 0;
    for (AuraAppInfo *item in allApps) {
        if (item.isJailbreakLoader || [_guardedBundleIDs containsObject:item.bundleID]) {
            currentGuardedCount++;
        }
    }
    if (currentGuardedCount >= 3) {
        if (outError) *outError = @"苹果免费个人证书最多同时激活 3 个应用槽位！请先取消其他应用的守护后再勾选。";
        return NO;
    }
    [_guardedBundleIDs addObject:app.bundleID];
    app.isGuarded = YES;
    [self savePreferences];
    return YES;
}

#pragma mark - 进程互斥锁 (防并发)

- (NSString *)signingLockFilePath {
    return AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro/signing.lock");
}

- (void)setSigningLockActive:(BOOL)active {
    NSString *p = [self signingLockFilePath];
    if (active) {
        [@{@"time": @([[NSDate date] timeIntervalSince1970])} writeToFile:p atomically:YES];
        chmod(p.UTF8String, 0666);
        chown(p.UTF8String, 501, 501);
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
}

- (BOOL)isSigningLockActive {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self signingLockFilePath]];
    if (!d) return NO;
    NSTimeInterval ts = [d[@"time"] doubleValue];
    // 超过 90 秒自动失效防死锁
    return (([[NSDate date] timeIntervalSince1970] - ts) < 90.0);
}

#pragma mark - iOS 原生系统级通知与横幅引擎

- (void)requestSystemNotificationPermission {
    // 顶部通知横幅由自研特权悬浮窗直接驱动，无需调用系统 UNUserNotificationCenter 弹窗申请权限
}

// 实现 UNUserNotificationCenterDelegate，确保 App 在前台时也能响应
- (void)userNotificationCenter:(id)center
       willPresentNotification:(id)notification
         withCompletionHandler:(void (^)(NSUInteger options))completionHandler {
    if (completionHandler) completionHandler(0x1A);
}

static UIWindow *gInAppBannerWindow = nil;

- (void)sendSystemNotificationWithTitle:(NSString *)title body:(NSString *)body {
    [self loadPreferences];
    if (!_notificationEnabled) return;

    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];
    if ([myBid isEqualToString:@"com.aurasign.pro"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AudioServicesPlaySystemSound(1007);
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen notificationOccurred:UINotificationFeedbackTypeSuccess];

            CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
            CGFloat bannerW = MIN(screenW - 24.0, 390.0);
            CGFloat bannerH = 86.0;
            CGFloat bannerX = (screenW - bannerW) / 2.0;

            if (!gInAppBannerWindow) {
                UIWindowScene *activeScene = nil;
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        activeScene = (UIWindowScene *)scene;
                        break;
                    }
                }
                if (activeScene) {
                    gInAppBannerWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
                } else {
                    gInAppBannerWindow = [[UIWindow alloc] initWithFrame:CGRectMake(bannerX, -130.0, bannerW, bannerH)];
                }
                gInAppBannerWindow.windowLevel = UIWindowLevelAlert + 300.0;
                gInAppBannerWindow.backgroundColor = [UIColor clearColor];
                gInAppBannerWindow.userInteractionEnabled = NO;
                gInAppBannerWindow.clipsToBounds = NO;
            }
            for (UIView *sub in gInAppBannerWindow.subviews) [sub removeFromSuperview];
            gInAppBannerWindow.frame = CGRectMake(bannerX, -130.0, bannerW, bannerH);
            gInAppBannerWindow.hidden = NO;

            Class glassCls = NSClassFromString(@"AuraLiquidGlassView");
            UIView *pill = nil;
            if (glassCls) {
                pill = [(id)[glassCls alloc] initWithFrame:CGRectMake(0, 0, bannerW, bannerH) cornerRadius:24.0];
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(pill, sel_registerName("setTintLevel:"), (CGFloat)0.38);
                ((void (*)(id, SEL, id))objc_msgSend)(pill, sel_registerName("setAccentGlowColor:"), [UIColor colorWithRed:0.08 green:0.38 blue:0.28 alpha:1.0]);
            } else {
                pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bannerW, bannerH)];
                pill.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
                pill.layer.cornerRadius = 24.0;
                pill.clipsToBounds = YES;
            }

            UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 13, 22, 22)];
            iconView.layer.cornerRadius = 5.5;
            iconView.clipsToBounds = YES;
            UIImage *bannerIcon = [UIImage imageWithContentsOfFile:AURA_NS_JBROOT(@"/Applications/AuraSignPro.app/AppIcon60x60@3x.png")];
            if (!bannerIcon && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
                bannerIcon = [UIImage _applicationIconImageForBundleIdentifier:@"com.aurasign.pro" format:2 scale:[UIScreen mainScreen].scale];
            }
            iconView.image = bannerIcon;
            [pill addSubview:iconView];

            UILabel *appNameLbl = [[UILabel alloc] initWithFrame:CGRectMake(42, 13, 140, 20)];
            appNameLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
            appNameLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.80];
            appNameLbl.text = @"续签";
            [pill addSubview:appNameLbl];

            UILabel *nowLbl = [[UILabel alloc] initWithFrame:CGRectMake(bannerW - 64, 13, 48, 20)];
            nowLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
            nowLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
            nowLbl.textAlignment = NSTextAlignmentRight;
            nowLbl.text = @"现在";
            [pill addSubview:nowLbl];

            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 36, bannerW - 28, 19)];
            titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
            titleLbl.textColor = [UIColor whiteColor];
            titleLbl.text = title ?: @"续签";
            [pill addSubview:titleLbl];

            UILabel *bodyLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 55, bannerW - 28, 22)];
            bodyLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
            bodyLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
            bodyLbl.text = body ?: @"";
            [pill addSubview:bodyLbl];

            [gInAppBannerWindow addSubview:pill];

            [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
                gInAppBannerWindow.frame = CGRectMake(bannerX, 48.0, bannerW, bannerH);
            } completion:^(BOOL finished) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.28 animations:^{
                        gInAppBannerWindow.frame = CGRectMake(bannerX, -130.0, bannerW, bannerH);
                    } completion:^(BOOL done) {
                        gInAppBannerWindow.hidden = YES;
                    }];
                });
            }];
        });
        return;
    }

    // 后台守护进程 aurasignd 调用时：写入跨进程通知载荷并唤醒 SpringBoard 弹窗
    NSString *bannerDir = AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro");
    [[NSFileManager defaultManager] createDirectoryAtPath:bannerDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    NSString *bannerFile = [bannerDir stringByAppendingPathComponent:@"pending_banner.plist"];
    NSDictionary *payload = @{
        @"title": title ?: @"续签",
        @"body": body ?: @"",
        @"time": @([[NSDate date] timeIntervalSince1970])
    };
    [payload writeToFile:bannerFile atomically:YES];
    chmod(bannerFile.UTF8String, 0666);
    chown(bannerFile.UTF8String, 501, 501);
    notify_post("com.aurasign.pro.pushBanner");
}

- (NSDictionary<NSString *, NSString *> *)fetchNativeAnisetteHeaders {
    __block id anisetteDataObj = nil;
    Class ctrlClass = NSClassFromString(@"AKAnisetteProvisioningController");
    if (ctrlClass) {
        id ctrl = [[ctrlClass alloc] init];
        if ([ctrl respondsToSelector:@selector(anisetteDataWithError:)]) {
            NSError *syncErr = nil;
            anisetteDataObj = [ctrl anisetteDataWithError:&syncErr];
        }
        if (!anisetteDataObj && [ctrl respondsToSelector:@selector(anisetteDataWithCompletion:)]) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [ctrl anisetteDataWithCompletion:^(id data, NSError *error) {
                anisetteDataObj = data;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }
    }

    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    NSString *clientTime = [iso stringFromDate:[NSDate date]];
    NSString *tz = [[NSTimeZone localTimeZone] abbreviation] ?: @"CST";

    if (anisetteDataObj && [anisetteDataObj oneTimePassword] && [anisetteDataObj machineID]) {
        return @{
            @"X-Apple-I-MD": [anisetteDataObj oneTimePassword],
            @"X-Apple-I-MD-M": [anisetteDataObj machineID],
            @"X-Apple-I-MD-RINFO": [NSString stringWithFormat:@"%llu", [anisetteDataObj routingInfo]],
            @"X-Apple-I-Client-Time": clientTime,
            @"X-Apple-I-TimeZone": tz,
            @"X-Apple-Locale": @"zh_CN"
        };
    }
    return @{
        @"X-Apple-I-Client-Time": clientTime,
        @"X-Apple-I-TimeZone": tz,
        @"X-Apple-Locale": @"zh_CN"
    };
}

- (void)installProvisioningProfileIntoSystemMIS:(NSData *)profileData {
    if (!profileData.length) return;
    void *misHandle = dlopen("/usr/lib/libmis.dylib", RTLD_LAZY);
    if (!misHandle) return;
    MISProfileCreateWithDataFunc createFunc = (MISProfileCreateWithDataFunc)dlsym(misHandle, "MISProfileCreateWithData");
    MISInstallProvisioningProfileFunc installFunc = (MISInstallProvisioningProfileFunc)dlsym(misHandle, "MISInstallProvisioningProfile");
    if (createFunc && installFunc) {
        CFTypeRef prof = createFunc(kCFAllocatorDefault, (__bridge CFDataRef)profileData);
        if (prof) {
            int ret = installFunc(prof);
            [self appendTimelineLog:[NSString stringWithFormat:@"[MIS-PROFILE] 已向系统 misagent 注册 7 天描述文件 (ret=%d)", ret] success:(ret == 0)];
            CFRelease(prof);
        }
    }
}

- (BOOL)verifyUnjailbrokenBootability:(NSString *)bundlePath {
    if (!bundlePath.length) return NO;
    NSString *provPath = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:provPath]) return NO;

    NSData *provData = [NSData dataWithContentsOfFile:provPath];
    if (!provData.length) return NO;

    void *misHandle = dlopen("/usr/lib/libmis.dylib", RTLD_LAZY);
    if (!misHandle) return YES; // 兜底
    MISProfileCreateWithDataFunc createFunc = (MISProfileCreateWithDataFunc)dlsym(misHandle, "MISProfileCreateWithData");
    if (createFunc) {
        CFTypeRef prof = createFunc(kCFAllocatorDefault, (__bridge CFDataRef)provData);
        if (prof) {
            CFRelease(prof);
            return YES;
        }
        return NO;
    }
    return YES;
}

- (NSArray<AuraAppInfo *> *)scanTargetApps {
    [self loadPreferences];
    NSMutableArray<AuraAppInfo *> *rawList = [NSMutableArray array];
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return rawList;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *allApps = [[wsClass defaultWorkspace] allInstalledApplications];

    for (id proxy in allApps) {
        // 过滤 1：检查 LaunchServices 安装状态与占位符状态，剔除已卸载残留记录
        if ([proxy respondsToSelector:@selector(isInstalled)] && ![proxy isInstalled]) continue;
        if ([proxy respondsToSelector:@selector(isPlaceholder)] && [proxy isPlaceholder]) continue;

        NSString *bid = [proxy applicationIdentifier] ?: @"";
        NSString *name = [proxy localizedName] ?: @"";
        NSString *bundlePath = [[proxy bundleURL] path] ?: @"";
        if (!bundlePath.length || [bid isEqualToString:@"com.aurasign.pro"]) continue;

        // 过滤 2：检查磁盘上 .app 目录、Info.plist 与主二进制可执行文件是否真实存在（彻底消灭已卸载幽灵软件）
        NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
        if (![fm fileExistsAtPath:bundlePath] || ![fm fileExistsAtPath:infoPlistPath]) continue;
        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *execName = infoDict[@"CFBundleExecutable"];
        if (!execName.length || ![fm fileExistsAtPath:[bundlePath stringByAppendingPathComponent:execName]]) continue;

        BOOL isDopamine = ([bid.lowercaseString containsString:@"dopamine"] || [name.lowercaseString containsString:@"dopamine"]);
        BOOL isRelaxin  = ([bid.lowercaseString containsString:@"relaxin"]  || [name.lowercaseString containsString:@"relaxin"]);
        NSString *provPath = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
        BOOL hasProv = [fm fileExistsAtPath:provPath];

        if (!isDopamine && !isRelaxin && ![[proxy applicationType] isEqualToString:@"User"]) continue;
        if (!isDopamine && !isRelaxin && !hasProv) continue;

        AuraAppInfo *item = [[AuraAppInfo alloc] init];
        item.appName = name.length ? name : (infoDict[@"CFBundleDisplayName"] ?: bid);
        item.bundleID = bid;
        item.version = [proxy shortVersionString] ?: (infoDict[@"CFBundleShortVersionString"] ?: @"1.0");
        item.bundlePath = bundlePath;
        item.isJailbreakLoader = (isDopamine || isRelaxin);
        item.isGuarded = [self isBundleIDGuarded:item.bundleID isLoader:item.isJailbreakLoader];

        if (hasProv) {
            NSDate *expDate = [self parseExpirationDateFromProvision:provPath];
            item.expirationDate = expDate ?: [NSDate distantPast];
            item.remainingDays = [item.expirationDate timeIntervalSinceNow] / 86400.0;
            item.isFakeSigned = (expDate == nil);
            item.isLibmisVerified = [self verifyUnjailbrokenBootability:bundlePath] && (item.remainingDays > 0);
        } else {
            item.expirationDate = [NSDate distantPast];
            item.remainingDays = 0.0;
            item.isFakeSigned = YES;
            item.isLibmisVerified = NO;
        }
        [rawList addObject:item];
    }

    // 智能去重：如果某个应用已经安装了带 .TeamID 的 7 天真证书有效版本，自动隐藏旧的假签名或过期副本
    NSMutableArray<AuraAppInfo *> *dedupList = [NSMutableArray array];
    for (AuraAppInfo *item in rawList) {
        BOOL hasBetterRealSignedCopy = NO;
        if (item.isFakeSigned || !item.isLibmisVerified || item.remainingDays <= 0.0) {
            for (AuraAppInfo *other in rawList) {
                if (other != item && other.isLibmisVerified && !other.isFakeSigned && other.remainingDays > 0.0) {
                    if ([other.appName isEqualToString:item.appName] ||
                        [other.bundleID hasPrefix:item.bundleID] ||
                        [item.bundleID hasPrefix:other.bundleID]) {
                        hasBetterRealSignedCopy = YES;
                        break;
                    }
                }
            }
        }
        if (!hasBetterRealSignedCopy) {
            [dedupList addObject:item];
        }
    }

    // 智能自动排序：
    // 1. 越狱加载器 (Dopamine / Relaxin) 永远置顶；
    // 2. 证书有效 (remainingDays > 0) 的软件排在上面，证书已过期 (remainingDays <= 0) 的软件自动沉底排在最下面；
    // 3. 同等状态下，已开启守护 (isGuarded) 的排在前面。
    [dedupList sortUsingComparator:^NSComparisonResult(AuraAppInfo *a, AuraAppInfo *b) {
        if (a.isJailbreakLoader != b.isJailbreakLoader) {
            return a.isJailbreakLoader ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL aValid = (!a.isFakeSigned && a.remainingDays > 0.0);
        BOOL bValid = (!b.isFakeSigned && b.remainingDays > 0.0);
        if (aValid != bValid) {
            return aValid ? NSOrderedAscending : NSOrderedDescending; // 有效的在上，过期的自动沉底在下
        }
        if (a.isGuarded != b.isGuarded) {
            return a.isGuarded ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.remainingDays != b.remainingDays) {
            return (a.remainingDays > b.remainingDays) ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.appName localizedCompare:b.appName];
    }];

    // 更新最近一个已守护应用的到期时间戳缓存（供 aurasignd 省电免扫盘使用）
    NSTimeInterval minExp = 0;
    for (AuraAppInfo *app in dedupList) {
        if (app.isGuarded || app.isJailbreakLoader) {
            NSTimeInterval expTs = (app.isFakeSigned || app.remainingDays <= 0.0)
                ? 100.0
                : [app.expirationDate timeIntervalSince1970];
            if (minExp == 0 || expTs < minExp) {
                minExp = expTs;
            }
        }
    }
    if (minExp > 0 && fabs(minExp - _earliestGuardedExpTimestamp) > 60.0) {
        _earliestGuardedExpTimestamp = minExp;
        [self savePreferences];
    }

    return dedupList;
}

- (NSDate *)parseExpirationDateFromProvision:(NSString *)provPath {
    NSData *raw = [NSData dataWithContentsOfFile:provPath];
    if (!raw.length) return nil;
    NSString *xmlStr = [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
    NSRange start = [xmlStr rangeOfString:@"<?xml"];
    NSRange end = [xmlStr rangeOfString:@"</plist>"];
    if (start.location != NSNotFound && end.location != NSNotFound && end.location > start.location) {
        NSString *plistPart = [xmlStr substringWithRange:NSMakeRange(start.location, end.location + end.length - start.location)];
        NSData *plistData = [plistPart dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:NULL];
        if ([dict[@"ExpirationDate"] isKindOfClass:[NSDate class]]) {
            return dict[@"ExpirationDate"];
        }
    }
    return nil;
}

- (AuraShieldStatus)evaluateGlobalShieldStatus:(NSString **)outSummary {
    NSArray<AuraAppInfo *> *apps = [self scanTargetApps];
    double minLoaderDays = 7.0;
    BOOL foundLoader = NO;

    for (AuraAppInfo *app in apps) {
        if (app.isJailbreakLoader) {
            foundLoader = YES;
            if (app.isFakeSigned || !app.isLibmisVerified || app.remainingDays <= 0.0) {
                if (outSummary) {
                    *outSummary = [NSString stringWithFormat:@"⚠️ 高危：检测到【%@】当前为假签名或证书已过期！若现在关机重启将无法打开，请点击下方【⚡ 立即修复】！", app.appName];
                }
                return AuraShieldStatusDanger;
            }
            if (app.remainingDays < minLoaderDays) minLoaderDays = app.remainingDays;
        }
    }

    if (!foundLoader) {
        if (outSummary) *outSummary = @"已就绪 · 请先绑定您的免费 Apple ID，随后可为越狱工具与侧载应用开启 7 天真证书自动续签";
        return AuraShieldStatusSafe;
    }

    if (minLoaderDays < 2.5) {
        if (outSummary) *outSummary = [NSString stringWithFormat:@"即将续签 · 越狱工具剩余 %.1f 天，后台将在联网时自动重置回 7 天", minLoaderDays];
        return AuraShieldStatusWarning;
    }

    if (outSummary) {
        int days = (int)minLoaderDays;
        int hours = (int)((minLoaderDays - days) * 24);
        *outSummary = [NSString stringWithFormat:@"已通过未越狱开机校验 (libmis: OK) · 剩余 %d天 %d小时，随时重启手机均可安全使用", days, hours];
    }
    return AuraShieldStatusSafe;
}

- (void)recursivelyFixInstalldPermissions:(NSString *)rootPath {
    chown(rootPath.UTF8String, 501, 501);
    chmod(rootPath.UTF8String, 0777);
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:rootPath];
    for (NSString *relPath in enumerator) {
        NSString *fullPath = [rootPath stringByAppendingPathComponent:relPath];
        chown(fullPath.UTF8String, 501, 501);
        chmod(fullPath.UTF8String, 0755);
    }
}

- (BOOL)createNativeIPAFromStageRoot:(NSString *)stageRoot toIpaPath:(NSString *)ipaPath {
    FILE *fp = fopen(ipaPath.UTF8String, "wb");
    if (!fp) return NO;

    NSMutableData *centralDirData = [NSMutableData data];
    uint16_t entryCount = 0;

    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:stageRoot];
    for (NSString *relPath in enumerator) {
        if (![relPath hasPrefix:@"Payload/"]) continue;
        if ([relPath containsString:@".zsign_cache"]) continue;

        NSString *fullPath = [stageRoot stringByAppendingPathComponent:relPath];
        struct stat st;
        if (lstat(fullPath.UTF8String, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) continue;

        NSData *fileData = nil;
        uint32_t externalAttr = (0100755 << 16);
        uint16_t versionNeeded = 20;

        if (S_ISLNK(st.st_mode)) {
            char linkTarget[1024] = {0};
            ssize_t linkLen = readlink(fullPath.UTF8String, linkTarget, sizeof(linkTarget) - 1);
            if (linkLen <= 0) continue;
            fileData = [NSData dataWithBytes:linkTarget length:linkLen];
            externalAttr = (0120755 << 16);
        } else {
            fileData = [NSData dataWithContentsOfFile:fullPath];
            if (!fileData) continue;
        }

        const char *nameUTF8 = relPath.UTF8String;
        uint16_t nameLen = (uint16_t)strlen(nameUTF8);
        uint32_t fileLen = (uint32_t)fileData.length;
        uint32_t crc = aura_crc32_compute((const uint8_t *)fileData.bytes, fileLen);
        uint32_t localOffset = (uint32_t)ftell(fp);

        AuraZipLocalHeader lh = {
            .signature = 0x04034b50,
            .versionNeeded = versionNeeded,
            .flags = 0,
            .compression = 0,
            .modTime = 0,
            .modDate = 0x5421,
            .crc32 = crc,
            .compressedSize = fileLen,
            .uncompressedSize = fileLen,
            .fileNameLen = nameLen,
            .extraFieldLen = 0
        };
        fwrite(&lh, sizeof(lh), 1, fp);
        fwrite(nameUTF8, 1, nameLen, fp);
        if (fileLen > 0) fwrite(fileData.bytes, 1, fileLen, fp);

        AuraZipCentralHeader ch = {
            .signature = 0x02014b50,
            .versionMadeBy = 0x0314,
            .versionNeeded = versionNeeded,
            .flags = 0,
            .compression = 0,
            .modTime = 0,
            .modDate = 0x5421,
            .crc32 = crc,
            .compressedSize = fileLen,
            .uncompressedSize = fileLen,
            .fileNameLen = nameLen,
            .extraFieldLen = 0,
            .fileCommentLen = 0,
            .diskNumberStart = 0,
            .internalAttrs = 0,
            .externalAttrs = externalAttr,
            .localHeaderOffset = localOffset
        };
        [centralDirData appendBytes:&ch length:sizeof(ch)];
        [centralDirData appendBytes:nameUTF8 length:nameLen];
        entryCount++;
    }

    uint32_t cdOffset = (uint32_t)ftell(fp);
    uint32_t cdSize = (uint32_t)centralDirData.length;
    if (cdSize > 0) fwrite(centralDirData.bytes, 1, cdSize, fp);

    AuraZipEndRecord eocd = {
        .signature = 0x06054b50,
        .diskNumber = 0,
        .centralDirDisk = 0,
        .numEntriesThisDisk = entryCount,
        .numEntriesTotal = entryCount,
        .centralDirSize = cdSize,
        .centralDirOffset = cdOffset,
        .commentLen = 0
    };
    fwrite(&eocd, sizeof(eocd), 1, fp);
    fclose(fp);
    chown(ipaPath.UTF8String, 501, 501);
    chmod(ipaPath.UTF8String, 0666);
    return (entryCount > 0);
}

- (BOOL)installAndSignIPAFileAtPath:(NSString *)ipaFilePath error:(NSError **)outError {
    NSString *fileName = ipaFilePath.lastPathComponent ?: @"IPA安装包";
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaFilePath]) {
        NSString *msg = @"找不到待签名的 IPA 安装包文件";
        [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"❌ 导入【%@】失败", fileName]
                                    detail:[NSString stringWithFormat:@"原因：%@", msg]
                                   success:NO];
        if (outError) *outError = [NSError errorWithDomain:@"AuraSign" code:404 userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }

    NSString *unzipDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:unzipDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *unzipBin = AURA_NS_JBROOT(@"/usr/bin/unzip");
    if (![[NSFileManager defaultManager] fileExistsAtPath:unzipBin]) unzipBin = @"/usr/bin/unzip";

    const char *args[] = {unzipBin.UTF8String, "-q", "-o", ipaFilePath.UTF8String, "-d", unzipDir.UTF8String, NULL};
    pid_t pid = 0;
    int status = 0;
    if (posix_spawn(&pid, unzipBin.UTF8String, NULL, NULL, (char *const *)args, environ) == 0) {
        waitpid(pid, &status, 0);
    }

    NSString *payloadPath = [unzipDir stringByAppendingPathComponent:@"Payload"];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadPath error:nil];
    NSString *foundAppPath = nil;
    for (NSString *sub in items) {
        if ([sub.pathExtension.lowercaseString isEqualToString:@"app"]) {
            foundAppPath = [payloadPath stringByAppendingPathComponent:sub];
            break;
        }
    }

    if (!foundAppPath) {
        [[NSFileManager defaultManager] removeItemAtPath:unzipDir error:nil];
        NSString *msg = @"解压 IPA 失败：安装包损坏或未找到 Payload/*.app 目录";
        [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"❌ 解压【%@】失败", fileName]
                                    detail:[NSString stringWithFormat:@"原因：%@", msg]
                                   success:NO];
        if (outError) *outError = [NSError errorWithDomain:@"AuraSign" code:422 userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[foundAppPath stringByAppendingPathComponent:@"Info.plist"]];
    AuraAppInfo *tempApp = [[AuraAppInfo alloc] init];
    tempApp.appName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: fileName;
    tempApp.bundleID = info[@"CFBundleIdentifier"] ?: @"com.aurasign.imported";
    tempApp.version = info[@"CFBundleShortVersionString"] ?: @"1.0";
    tempApp.bundlePath = foundAppPath;
    tempApp.isJailbreakLoader = ([tempApp.bundleID.lowercaseString containsString:@"dopamine"] || [tempApp.bundleID.lowercaseString containsString:@"relaxin"]);

    BOOL ok = [self fastResignApp:tempApp error:outError];
    [[NSFileManager defaultManager] removeItemAtPath:unzipDir error:nil];
    return ok;
}

- (BOOL)fastResignApp:(AuraAppInfo *)app error:(NSError **)outError {
    AuraAppleDeveloperAPI *api = [AuraAppleDeveloperAPI sharedAPI];
    if (![api hasValidAccountInKeychain]) {
        NSString *msg = @"尚未绑定 Apple ID，请先前往底部「⚙️ 设置」页登录您的免费 Apple ID";
        [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"❌ 【%@】签名未开始", app.appName]
                                    detail:[NSString stringWithFormat:@"原因：%@", msg]
                                   success:NO];
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:401 userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    [self setSigningLockActive:YES];

    NSString *requestedBundleID = app.bundleID;
    NSString *resolvedBundleID = requestedBundleID;
    NSError *profErr = nil;
    NSData *realProfileData = [api requestReal7DayProvisioningProfileForBundleID:requestedBundleID
                                                                         appName:app.appName
                                                               outResolvedBundle:&resolvedBundleID
                                                                           error:&profErr];
    if (!realProfileData || realProfileData.length == 0) {
        [self setSigningLockActive:NO];
        if (outError) *outError = profErr;
        NSString *errMsg = profErr.localizedDescription ?: @"从苹果服务器获取 7 天描述文件失败（请检查网络或本周 10 个 AppID 额度）";
        [self appendTimelineLog:[NSString stringWithFormat:@"[SIGN-ERR] 【%@】获取描述文件失败：%@", app.appName, errMsg] success:NO];
        [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"❌ 【%@】获取证书失败", app.appName]
                                    detail:[NSString stringWithFormat:@"原因：%@", errMsg]
                                   success:NO];
        return NO;
    }

    [self installProvisioningProfileIntoSystemMIS:realProfileData];

    NSString *publicStaging = @"/var/mobile/Media/PublicStaging";
    [[NSFileManager defaultManager] createDirectoryAtPath:publicStaging withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    chown(publicStaging.UTF8String, 501, 501);

    NSString *stageRoot = [publicStaging stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *payloadDir = [stageRoot stringByAppendingPathComponent:@"Payload"];
    [[NSFileManager defaultManager] createDirectoryAtPath:payloadDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];

    NSString *appFolderName = [app.bundlePath lastPathComponent];
    NSString *stagedAppPath = [payloadDir stringByAppendingPathComponent:appFolderName];
    [[NSFileManager defaultManager] copyItemAtPath:app.bundlePath toPath:stagedAppPath error:nil];

    [self recursivelyFixInstalldPermissions:stageRoot];

    if (!app.isJailbreakLoader) {
        [[NSFileManager defaultManager] removeItemAtPath:[stagedAppPath stringByAppendingPathComponent:@"PlugIns"] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[stagedAppPath stringByAppendingPathComponent:@"Watch"] error:nil];
    }

    NSString *infoPlistPath = [stagedAppPath stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];
    if (infoDict) {
        infoDict[@"CFBundleIdentifier"] = resolvedBundleID;
        infoDict[@"UIFileSharingEnabled"] = @YES;
        [infoDict removeObjectForKey:@"MinimumOSVersion"];
        [infoDict writeToFile:infoPlistPath atomically:YES];
    }

    NSError *zsignErr = nil;
    BOOL zsignOK = [api performRealZSignOnAppBundle:stagedAppPath profileData:realProfileData error:&zsignErr];
    if (!zsignOK) {
        [[NSFileManager defaultManager] removeItemAtPath:stageRoot error:nil];
        [self setSigningLockActive:NO];
        if (outError) *outError = zsignErr;
        NSString *errMsg = zsignErr.localizedDescription ?: @"zsign 二进制签名未通过";
        [self appendTimelineLog:[NSString stringWithFormat:@"[ZSIGN-ERR] 【%@】签名失败：%@", app.appName, errMsg] success:NO];
        [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"❌ 【%@】签名未通过", app.appName]
                                    detail:[NSString stringWithFormat:@"原因：%@", errMsg]
                                   success:NO];
        return NO;
    }

    [self recursivelyFixInstalldPermissions:stageRoot];

    NSString *signedIpaPath = [stageRoot stringByAppendingPathComponent:@"signed.ipa"];
    BOOL ipaCreated = [self createNativeIPAFromStageRoot:stageRoot toIpaPath:signedIpaPath];

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [wsClass defaultWorkspace];
    BOOL installSuccess = NO;
    NSError *lsError = nil;

    if (ipaCreated && [[NSFileManager defaultManager] fileExistsAtPath:signedIpaPath] &&
        [workspace respondsToSelector:@selector(installApplication:withOptions:error:)]) {
        NSDictionary *ipaOpts = @{
            @"AllowInstallLocalProvisioned": @YES,
            @"IsUserInitiated": @YES,
            @"CFBundleIdentifier": resolvedBundleID
        };
        installSuccess = [workspace installApplication:[NSURL fileURLWithPath:signedIpaPath] withOptions:ipaOpts error:&lsError];
        [self appendTimelineLog:[NSString stringWithFormat:@"[LS-INSTALL-IPA] 【%@】installed=%d, err=%@",
            app.appName, installSuccess, lsError.localizedDescription ?: @"nil"] success:installSuccess];
    }

    if (!installSuccess && [[NSFileManager defaultManager] fileExistsAtPath:stagedAppPath] &&
        [workspace respondsToSelector:@selector(installApplication:withOptions:error:)]) {
        lsError = nil;
        NSDictionary *devOpts = @{
            @"AllowInstallLocalProvisioned": @YES,
            @"IsUserInitiated": @YES,
            @"CFBundleIdentifier": resolvedBundleID,
            @"PackageType": @"Developer"
        };
        installSuccess = [workspace installApplication:[NSURL fileURLWithPath:stagedAppPath] withOptions:devOpts error:&lsError];
        [self appendTimelineLog:[NSString stringWithFormat:@"[LS-INSTALL-DEV] 【%@】installed=%d, err=%@",
            app.appName, installSuccess, lsError.localizedDescription ?: @"nil"] success:installSuccess];
    }

    [[NSFileManager defaultManager] removeItemAtPath:stageRoot error:nil];
    [self setSigningLockActive:NO];

    if (!installSuccess) {
        NSString *installErrMsg = lsError.localizedDescription ?: @"系统 installd 拒绝安装（请检查是否已满 3 个免费证书应用上限）";
        [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"❌ 【%@】安装未通过", app.appName]
                                    detail:[NSString stringWithFormat:@"原因：%@", installErrMsg]
                                   success:NO];
        if (outError) {
            *outError = lsError ?: [NSError errorWithDomain:@"AuraSign" code:-1 userInfo:@{NSLocalizedDescriptionKey: installErrMsg}];
        }
        return NO;
    }

    // 若原本已开启守护且 BundleID 加上了 .TeamID 后缀，同步更新守护列表
    if ([_guardedBundleIDs containsObject:app.bundleID] && ![_guardedBundleIDs containsObject:resolvedBundleID]) {
        [_guardedBundleIDs removeObject:app.bundleID];
        [_guardedBundleIDs addObject:resolvedBundleID];
        [self savePreferences];
    }

    [self appendTimelineLog:[NSString stringWithFormat:@"🎉 [RESIGN-SUCCESS] 【%@】已成功签入 7 天苹果真证书并完成安装！(BundleID:%@)", app.appName, resolvedBundleID] success:YES];
    [self appendSimpleUserLogWithTitle:[NSString stringWithFormat:@"✅ 【%@】签名成功", app.appName]
                                detail:[NSString stringWithFormat:@"已签入满血 7 天苹果真证书并通过开机校验 (可用额度: %@)", [[AuraAppleDeveloperAPI sharedAPI] availableAppIdQuotaText]]
                               success:YES];
    [self sendSystemNotificationWithTitle:@"✅ 续签 · 签名完成"
                                     body:[NSString stringWithFormat:@"【%@】已签入满血 7 天苹果真证书并通过未越狱开机校验！", app.appName]];
    return YES;
}

- (void)performEmergencyResignAllWithCompletion:(void(^)(BOOL success, NSString *message))completion {
    if (![[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
        if (completion) completion(NO, @"尚未绑定 Apple ID，请先在【守护中心】点击【立即登录】！");
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSArray<AuraAppInfo *> *apps = [self scanTargetApps];
        NSInteger successCount = 0;
        NSString *lastErr = nil;
        for (AuraAppInfo *app in apps) {
            if (!app.isGuarded && !app.isJailbreakLoader) continue;

            NSError *err = nil;
            if ([self fastResignApp:app error:&err]) {
                successCount++;
            } else {
                lastErr = err.localizedDescription;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (successCount > 0) {
                if (completion) completion(YES, [NSString stringWithFormat:@"✅ 已成功为 %ld 款已守护应用刷新满血 7 天苹果真证书！", (long)successCount]);
            } else {
                if (completion) completion(NO, lastErr ?: @"没有需要续签的已守护应用或签名失败");
            }
        });
    });
}

#pragma mark - 白话文用户日志与底层诊断日志

- (NSString *)simpleLogFilePath {
    NSString *dir = AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro");
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    return [dir stringByAppendingPathComponent:@"user_simple_logs.plist"];
}

- (void)appendSimpleUserLogWithTitle:(NSString *)title detail:(NSString *)detail success:(BOOL)success {
    @synchronized (self) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm";
        NSDictionary *entry = @{
            @"time": [df stringFromDate:[NSDate date]],
            @"title": title ?: @"",
            @"detail": detail ?: @"",
            @"success": @(success)
        };
        NSString *path = [self simpleLogFilePath];
        NSMutableArray *list = [[NSArray arrayWithContentsOfFile:path] mutableCopy] ?: [NSMutableArray array];
        [list insertObject:entry atIndex:0];
        if (list.count > 50) [list removeLastObject];
        [list writeToFile:path atomically:YES];
        chmod(path.UTF8String, 0666);
        chown(path.UTF8String, 501, 501);
    }
}

- (NSArray<NSDictionary *> *)readSimpleUserLogs {
    @synchronized (self) {
        return [NSArray arrayWithContentsOfFile:[self simpleLogFilePath]] ?: @[];
    }
}

- (void)clearAllLogs {
    @synchronized (self) {
        [[NSFileManager defaultManager] removeItemAtPath:[self simpleLogFilePath] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[self logFilePath] error:nil];
        [gRuntimeMemoryLogs removeAllObjects];
    }
}

static NSMutableArray<NSDictionary *> *gRuntimeMemoryLogs = nil;

- (NSString *)logFilePath {
    NSString *dir = AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro");
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    chmod(dir.UTF8String, 0777);
    return [dir stringByAppendingPathComponent:@"timeline.plist"];
}

- (NSArray<NSDictionary *> *)readAuditTimelineLogs {
    @synchronized (self) {
        if (!gRuntimeMemoryLogs) gRuntimeMemoryLogs = [NSMutableArray array];
        NSArray *diskLogs = [NSArray arrayWithContentsOfFile:[self logFilePath]] ?: @[];
        if (gRuntimeMemoryLogs.count == 0) return diskLogs;
        NSMutableArray *merged = [NSMutableArray arrayWithArray:gRuntimeMemoryLogs];
        for (NSDictionary *d in diskLogs) {
            if (![merged containsObject:d] && merged.count < 80) [merged addObject:d];
        }
        return merged;
    }
}

- (void)appendTimelineLog:(NSString *)event success:(BOOL)success {
    @synchronized (self) {
        if (!gRuntimeMemoryLogs) gRuntimeMemoryLogs = [NSMutableArray array];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss";
        NSDictionary *entry = @{
            @"time": [df stringFromDate:[NSDate date]],
            @"event": event ?: @"",
            @"success": @(success)
        };
        [gRuntimeMemoryLogs insertObject:entry atIndex:0];
        if (gRuntimeMemoryLogs.count > 60) [gRuntimeMemoryLogs removeLastObject];

        NSString *path = [self logFilePath];
        NSMutableArray *diskLogs = [[NSArray arrayWithContentsOfFile:path] mutableCopy] ?: [NSMutableArray array];
        [diskLogs insertObject:entry atIndex:0];
        if (diskLogs.count > 60) [diskLogs removeLastObject];
        [diskLogs writeToFile:path atomically:YES];
        chmod(path.UTF8String, 0666);
        chown(path.UTF8String, 501, 501);
    }
}

@end
