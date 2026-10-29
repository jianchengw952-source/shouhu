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
    [[NSFileManager defaultManager] createDirectoryAtPath:certDir withIntermediateDirectories:YES attributes:nil error:nil];
    chown(baseDir.UTF8String, 501, 501);
    chmod(baseDir.UTF8String, 0777);
    chown(certDir.UTF8String, 501, 501);
    chmod(certDir.UTF8String, 0777);
    if ([[NSFileManager defaultManager] fileExistsAtPath:logFile]) {
        chown(logFile.UTF8String, 501, 501);
        chmod(logFile.UTF8String, 0666);
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

static void runDaemonSignCheck(BOOL isFromBatteryNotification) {
    ensureSharedDirPermissions();

    // 【关键修复 1】：如果用户还没在桌面 App 里绑定 Apple ID，后台进程直接静默返回，绝不每 2 分钟刷屏报错！
    if (![[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
        return;
    }

    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    BOOL isCharging = NO;
    NSInteger currentBattery = getHardwareBatteryPercent(&isCharging);

    // 【关键修复 2】：如果是电量变化触发的通知，且当前正在充电或电量 >= 5%（用户设定值），立即跳过，绝不空转！
    if (isFromBatteryNotification) {
        if (!engine.lowBatteryRescueEnabled || isCharging || currentBattery >= engine.lowBatteryTriggerPercent) {
            return;
        }
    }

    NSArray<AuraAppInfo *> *apps = [engine scanTargetApps];
    for (AuraAppInfo *app in apps) {
        BOOL shouldSign = NO;
        NSString *reason = nil;

        if (isFromBatteryNotification) {
            if (app.remainingDays < (double)engine.lowBatteryThresholdDays) {
                shouldSign = YES;
                reason = [NSString stringWithFormat:@"🔋 低电量抢救续签：硬件电量 %ld%% (<%ld%%)，且【%@】剩余 %.1f天 (<%ld天)",
                          (long)currentBattery, (long)engine.lowBatteryTriggerPercent,
                          app.appName, app.remainingDays, (long)engine.lowBatteryThresholdDays];
            }
        } else {
            if (app.isJailbreakLoader && (app.isFakeSigned || !app.isLibmisVerified || app.remainingDays <= 0.0)) {
                shouldSign = YES;
                reason = [NSString stringWithFormat:@"🚨 检测到【%@】为假签或已过期，后台自动转正修复", app.appName];
            } else if (engine.autoRenewEnabled && app.remainingDays < (double)engine.normalRenewThresholdDays) {
                shouldSign = YES;
                reason = [NSString stringWithFormat:@"⏱️ 定时静默续签：【%@】剩余 %.1f天 (<%ld天)",
                          app.appName, app.remainingDays, (long)engine.normalRenewThresholdDays];
            }
        }

        if (shouldSign) {
            [engine appendTimelineLog:reason success:YES];
            NSError *err = nil;
            [engine fastResignApp:app stripPlugIns:engine.smartStripExtensions customName:nil customBundleID:nil injectedDebs:nil error:&err];
            ensureSharedDirPermissions();
        }
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, getpid(), 256, NULL, 0);
        ensureSharedDirPermissions();
        runDaemonSignCheck(NO);

        int notifyToken = 0;
        notify_register_dispatch("com.apple.system.powersources.percent", &notifyToken, dispatch_get_main_queue(), ^(int token) {
            runDaemonSignCheck(YES);
        });

        [NSTimer scheduledTimerWithTimeInterval:7200.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            runDaemonSignCheck(NO);
        }];

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
