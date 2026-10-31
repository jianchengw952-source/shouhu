// src/Daemon/aurasignd.mm
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/stat.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"

extern "C" int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK 5

typedef CFTypeRef (*IOPSCopyPowerSourcesInfoFunc)(void);
typedef CFArrayRef (*IOPSCopyPowerSourcesListFunc)(CFTypeRef blob);
typedef CFDictionaryRef (*IOPSGetPowerSourceDescriptionFunc)(CFTypeRef blob, CFTypeRef ps);

static void ensureSharedDirPermissions(void) {
    NSString *baseDir = AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro");
    NSString *certDir = [baseDir stringByAppendingPathComponent:@"KeychainCert"];
    NSString *logFile = [baseDir stringByAppendingPathComponent:@"timeline.plist"];
    NSString *simpleLogFile = [baseDir stringByAppendingPathComponent:@"user_simple_logs.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:certDir withIntermediateDirectories:YES attributes:nil error:nil];
    chown(baseDir.UTF8String, 501, 501);
    chmod(baseDir.UTF8String, 0777);
    chown(certDir.UTF8String, 501, 501);
    chmod(certDir.UTF8String, 0777);
    if ([[NSFileManager defaultManager] fileExistsAtPath:logFile]) {
        chown(logFile.UTF8String, 501, 501);
        chmod(logFile.UTF8String, 0666);
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:simpleLogFile]) {
        chown(simpleLogFile.UTF8String, 501, 501);
        chmod(simpleLogFile.UTF8String, 0666);
    }
}

static NSInteger getHardwareBatteryPercent(BOOL *outIsCharging) {
    static void *iokitHandle = NULL;
    static IOPSCopyPowerSourcesInfoFunc copyInfo = NULL;
    static IOPSCopyPowerSourcesListFunc copyList = NULL;
    static IOPSGetPowerSourceDescriptionFunc getDesc = NULL;

    if (!iokitHandle) {
        iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (iokitHandle) {
            copyInfo = (IOPSCopyPowerSourcesInfoFunc)dlsym(iokitHandle, "IOPSCopyPowerSourcesInfo");
            copyList = (IOPSCopyPowerSourcesListFunc)dlsym(iokitHandle, "IOPSCopyPowerSourcesList");
            getDesc  = (IOPSGetPowerSourceDescriptionFunc)dlsym(iokitHandle, "IOPSGetPowerSourceDescription");
        }
    }
    if (!copyInfo || !copyList || !getDesc) return 100;

    CFTypeRef blob = copyInfo();
    if (!blob) return 100;
    CFArrayRef sources = copyList(blob);
    if (!sources || CFArrayGetCount(sources) == 0) {
        if (sources) CFRelease(sources);
        CFRelease(blob);
        return 100;
    }

    CFDictionaryRef desc = getDesc(blob, CFArrayGetValueAtIndex(sources, 0));
    NSInteger percent = 100;
    if (desc) {
        NSDictionary *dict = (__bridge NSDictionary *)desc;
        NSNumber *cur = dict[@"Current Capacity"];
        NSNumber *max = dict[@"Max Capacity"];
        NSString *state = dict[@"Power Source State"];
        if (outIsCharging) *outIsCharging = [state isEqualToString:@"AC Power"];
        if (cur && max && max.integerValue > 0) {
            percent = (cur.integerValue * 100) / max.integerValue;
        }
    }
    CFRelease(sources);
    CFRelease(blob);
    return percent;
}

static NSTimeInterval gLastLowBatteryRescueTime = 0;

static void runDaemonSignCheck(BOOL isFromBatteryNotification) {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];

    // 【极致省电 1】：如果是电量变化通知触发，第 1 行直接在内存中检查硬件电量！
    // 平时从 100% 掉到 6% 的全过程中，0 磁盘读写、0 权限修复、0 应用扫描，瞬间返回！
    BOOL isCharging = NO;
    NSInteger currentBattery = 100;
    if (isFromBatteryNotification) {
        currentBattery = getHardwareBatteryPercent(&isCharging);
        if (isCharging || currentBattery >= engine.lowBatteryTriggerPercent) {
            return;
        }
        // 实时同步最新设置开关
        [engine loadPreferences];
        if (!engine.lowBatteryRescueEnabled || currentBattery >= engine.lowBatteryTriggerPercent) {
            return;
        }
        // 30 分钟冷却防抖，避免在 4%、3%、2% 时重复触发
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastLowBatteryRescueTime < 1800.0) {
            return;
        }
    } else {
        // 【极致省电 2】：常规巡检先同步开关并检查内存到期时间戳缓存
        [engine loadPreferences];
        if (!engine.autoRenewEnabled) {
            return; // 用户已关闭后台静默自动续签开关，严格停止后台定时续签
        }
        if (![engine hasAnyGuardedAppApproachingExpirationInMemory]) {
            return; // 内存缓存显示所有守护应用均未进入续签期，免扫盘直接返回！
        }
    }

    if ([engine isSigningLockActive]) {
        return;
    }

    if (![[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
        return;
    }

    ensureSharedDirPermissions();
    if (isFromBatteryNotification) {
        gLastLowBatteryRescueTime = [[NSDate date] timeIntervalSince1970];
    }

    NSArray<AuraAppInfo *> *apps = [engine scanTargetApps];
    for (AuraAppInfo *app in apps) {
        if (!app.isGuarded && !app.isJailbreakLoader) continue;

        BOOL shouldSign = NO;
        NSString *reason = nil;

        if (isFromBatteryNotification) {
            if (app.remainingDays < (double)engine.lowBatteryThresholdDays) {
                shouldSign = YES;
                reason = [NSString stringWithFormat:@"🔋 低电量抢救续签：硬件电量 %ld%% (<%ld%%)，且【%@】剩余 %.1f天 (<%ld天)",
                          (long)currentBattery, (long)engine.lowBatteryTriggerPercent,
                          app.appName, app.remainingDays, (long)engine.lowBatteryThresholdDays];
            }
        } else if (engine.autoRenewEnabled) {
            if (app.isJailbreakLoader && (app.isFakeSigned || !app.isLibmisVerified || app.remainingDays <= 0.0)) {
                shouldSign = YES;
                reason = [NSString stringWithFormat:@"🚨 检测到【%@】为假签或已过期，后台自动转正修复", app.appName];
            } else if (app.remainingDays < (double)engine.normalRenewThresholdDays) {
                shouldSign = YES;
                reason = [NSString stringWithFormat:@"⏱️ 定时静默续签：【%@】剩余 %.1f天 (<%ld天)",
                          app.appName, app.remainingDays, (long)engine.normalRenewThresholdDays];
            }
        }

        if (shouldSign) {
            [engine appendTimelineLog:reason success:YES];
            NSError *err = nil;
            BOOL ok = [engine fastResignApp:app error:&err];
            if (ok) {
                [engine appendSimpleUserLogWithTitle:(isFromBatteryNotification ? @"🔋 低电量紧急抢救成功" : @"⚡ 后台自动续签成功")
                                              detail:[NSString stringWithFormat:@"后台已自动为您将【%@】续签至满血 7 天有效期", app.appName]
                                             success:YES];
            } else if (err) {
                [engine sendSystemNotificationWithTitle:@"⚠️ angel Sign续签 · 自动续签未完成"
                                                   body:[NSString stringWithFormat:@"【%@】后台续签失败：%@", app.appName, err.localizedDescription ?: @"请检查网络"]];
            }
            ensureSharedDirPermissions();
        }
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--gen-icon") == 0) {
            [[AuraSignEngine sharedEngine] generateAndInstallScheme1AppIcons];
            return 0;
        }

        memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, getpid(), 64, NULL, 0);
        ensureSharedDirPermissions();

        // 启动时先加载一次配置缓存
        [[AuraSignEngine sharedEngine] loadPreferences];
        runDaemonSignCheck(NO);

        int notifyToken = 0;
        notify_register_dispatch("com.apple.system.powersources.percent", &notifyToken, dispatch_get_main_queue(), ^(int token) {
            runDaemonSignCheck(YES);
        });

        // 【极致省电 3】：6 小时 (21600s) 巡检周期 + 30 分钟 (1800s) 系统休眠唤醒合并 (tolerance)，绝不单独唤醒待机睡眠中的 CPU
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:21600.0 repeats:YES block:^(NSTimer * _Nonnull t) {
            runDaemonSignCheck(NO);
        }];
        timer.tolerance = 1800.0;

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
