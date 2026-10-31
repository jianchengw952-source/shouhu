// src/Core/AuraSignEngine.h
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
@property (nonatomic, assign) BOOL isGuarded; // 是否纳入自动守护槽位 (最多 3 个)
@end

@interface AuraSignEngine : NSObject

+ (instancetype)sharedEngine;

@property (nonatomic, assign) BOOL autoRenewEnabled;
@property (nonatomic, assign) NSInteger normalRenewThresholdDays;     // 默认剩余 < 5 天自动续签 (1~6天可调)
@property (nonatomic, assign) BOOL lowBatteryRescueEnabled;           // 低电量抢救开关
@property (nonatomic, assign) NSInteger lowBatteryTriggerPercent;     // 默认 5%
@property (nonatomic, assign) NSInteger lowBatteryThresholdDays;      // 默认 5 天 (1~7 天自定义)
@property (nonatomic, assign) BOOL rebootShieldEnabled;               // 关机/重启掉签强拦截开关
@property (nonatomic, assign) BOOL notificationEnabled;               // 签名完成系统横幅通知开关
@property (nonatomic, assign) BOOL smartStripExtensions;              // 强制开启 YES
@property (nonatomic, assign) CGFloat liquidGlassTintLevel;           // 固定 0.25

- (void)loadPreferences;
- (void)savePreferences;

// 极致省电：仅通过内存缓存时间戳判断是否已进入续签期，未到期时避免扫描应用列表与磁盘
- (BOOL)hasAnyGuardedAppApproachingExpirationInMemory;

// 方案 1 翡翠灵盾图标生成与部署
- (void)generateAndInstallScheme1AppIcons;

// 3 槽位自动守护管理
- (BOOL)isBundleIDGuarded:(NSString *)bundleID isLoader:(BOOL)isLoader;
- (BOOL)toggleGuardForApp:(AuraAppInfo *)app allApps:(NSArray<AuraAppInfo *> *)allApps outError:(NSString **)outError;

// iOS 原生系统级横幅通知 (像普通 App 一样顶部弹窗响铃通知)
- (void)requestSystemNotificationPermission;
- (void)sendSystemNotificationWithTitle:(NSString *)title body:(NSString *)body;

// 读取简单易懂的白话文日志列表 (每个元素包含 time, title, detail, success)
- (NSArray<NSDictionary *> *)readSimpleUserLogs;
- (void)appendSimpleUserLogWithTitle:(NSString *)title detail:(NSString *)detail success:(BOOL)success;
- (void)clearAllLogs;

// 进程互斥锁，防止手动单点签名时后台 aurasignd 同时运行
- (BOOL)isSigningLockActive;

- (NSArray<AuraAppInfo *> *)scanTargetApps;
- (AuraShieldStatus)evaluateGlobalShieldStatus:(NSString **)outSummary;
- (BOOL)verifyUnjailbrokenBootability:(NSString *)bundlePath;

- (NSDictionary<NSString *, NSString *> *)fetchNativeAnisetteHeaders;

- (BOOL)fastResignApp:(AuraAppInfo *)app error:(NSError **)outError;
- (BOOL)installAndSignIPAFileAtPath:(NSString *)ipaFilePath error:(NSError **)outError;
- (void)performEmergencyResignAllWithCompletion:(void(^)(BOOL success, NSString *message))completion;

- (NSArray<NSDictionary *> *)readAuditTimelineLogs;
- (void)appendTimelineLog:(NSString *)event success:(BOOL)success;

@end
