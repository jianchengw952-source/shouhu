#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AuraCompat.h"

typedef NS_ENUM(NSInteger, AuraShieldStatus) {
    AuraShieldStatusSafe = 0,       // 🟢 绿色：已通过 libmis 未越狱开机校验，可随时安全重启
    AuraShieldStatusWarning = 1,    // 🟠 橙色：剩余时间少于设定阈值，待续签
    AuraShieldStatusDanger = 2      // 🔴 红色：已过期或属于假签名，严禁此时重启！
};

@interface AuraAppInfo : NSObject
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, strong) NSDate *expirationDate;
@property (nonatomic, assign) double remainingDays;
@property (nonatomic, assign) BOOL isJailbreakLoader;
@property (nonatomic, assign) BOOL isFakeSigned;
@property (nonatomic, assign) BOOL isLibmisVerified;
@end

@interface AuraRepoAppItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSString *downloadURL;
@property (nonatomic, assign) BOOL isOfficialJailbreakTool;
@end

@interface AuraSignEngine : NSObject

+ (instancetype)sharedEngine;

@property (nonatomic, assign) BOOL autoRenewEnabled;
@property (nonatomic, assign) NSInteger normalRenewThresholdDays;     // 默认剩余 < 5 天自动续签
@property (nonatomic, assign) BOOL lowBatteryRescueEnabled;           // 低电量抢救开关
@property (nonatomic, assign) NSInteger lowBatteryTriggerPercent;     // 默认 5% (支持 1%~20% 自定义)
@property (nonatomic, assign) NSInteger lowBatteryThresholdDays;      // 默认 5 天 (支持 1~7 天自定义)
@property (nonatomic, assign) BOOL smartStripExtensions;              // 智能剪除手表/小组件零件 (省 80% 额度)
@property (nonatomic, assign) BOOL rebootShieldEnabled;               // 关机/重启掉签强拦截开关
@property (nonatomic, assign) CGFloat liquidGlassTintLevel;           // iOS 27 液态玻璃通透度滑块 (0.0 ~ 1.0)

- (void)savePreferences;

- (NSArray<AuraAppInfo *> *)scanTargetApps;
- (AuraShieldStatus)evaluateGlobalShieldStatus:(NSString **)outSummary;
- (BOOL)verifyUnjailbrokenBootability:(NSString *)bundlePath;

- (NSDictionary<NSString *, NSString *> *)fetchNativeAnisetteHeaders;

- (BOOL)fastResignApp:(AuraAppInfo *)app
        stripPlugIns:(BOOL)strip
          customName:(NSString *)customName
      customBundleID:(NSString *)customBundleID
        injectedDebs:(NSArray<NSString *> *)debOrDylibPaths
               error:(NSError **)outError;

- (BOOL)installAndSignIPAFileAtPath:(NSString *)ipaFilePath
                         customName:(NSString *)customName
                     customBundleID:(NSString *)customBundleID
                       injectedDebs:(NSArray<NSString *> *)debOrDylibPaths
                              error:(NSError **)outError;

- (void)downloadAndSignRepoItem:(AuraRepoAppItem *)item
                     completion:(void(^)(BOOL success, NSString *message))completion;

- (void)performEmergencyResignAllWithCompletion:(void(^)(BOOL success, NSString *message))completion;

- (NSString *)accelerateURLForMainlandChina:(NSString *)originalURL;
- (NSArray<AuraRepoAppItem *> *)loadBuiltInStoreCatalog;
- (NSArray<NSDictionary *> *)readAuditTimelineLogs;
- (void)appendTimelineLog:(NSString *)event success:(BOOL)success;

@end
