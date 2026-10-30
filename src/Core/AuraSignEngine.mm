// src/Core/AuraSignEngine.mm (采用 iOS 17 原生 LSApplicationWorkspace installApplication:withOptions:error: + libmis 注册完整版)
#import <CoreFoundation/CoreFoundation.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define environ (*_NSGetEnviron())
#else
extern char **environ;
#endif

@interface NSObject (AuraDynamicPrivateAPIs)
- (id)anisetteDataWithError:(NSError **)error;
- (void)anisetteDataWithCompletion:(void(^)(id data, NSError *error))completion;
- (NSString *)machineID;
- (NSString *)oneTimePassword;
- (unsigned long long)routingInfo;
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)installApplication:(NSURL *)path withOptions:(NSDictionary *)options error:(NSError **)error;
- (NSString *)applicationIdentifier;
- (NSURL *)bundleURL;
- (NSString *)shortVersionString;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

typedef int (*MISValidateSignatureFunc)(CFStringRef file, CFDictionaryRef options, CFDictionaryRef *info);
typedef CFTypeRef (*MISProfileCreateWithDataFunc)(CFAllocatorRef alloc, CFDataRef data);
typedef int (*MISInstallProvisioningProfileFunc)(CFTypeRef profile);

@implementation AuraAppInfo
@end

@implementation AuraRepoAppItem
@end

@implementation AuraSignEngine

+ (instancetype)sharedEngine {
    static AuraSignEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AuraSignEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        [self loadPreferences];
    }
    return self;
}

- (void)loadPreferences {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:AURA_PREFS_PATH] ?: @{};
    _autoRenewEnabled = dict[@"autoRenewEnabled"] ? [dict[@"autoRenewEnabled"] boolValue] : YES;
    _normalRenewThresholdDays = dict[@"normalRenewThresholdDays"] ? [dict[@"normalRenewThresholdDays"] integerValue] : 5;
    _lowBatteryRescueEnabled = dict[@"lowBatteryRescueEnabled"] ? [dict[@"lowBatteryRescueEnabled"] boolValue] : YES;
    _lowBatteryTriggerPercent = dict[@"lowBatteryTriggerPercent"] ? [dict[@"lowBatteryTriggerPercent"] integerValue] : 5;
    _lowBatteryThresholdDays = dict[@"lowBatteryThresholdDays"] ? [dict[@"lowBatteryThresholdDays"] integerValue] : 5;
    _smartStripExtensions = dict[@"smartStripExtensions"] ? [dict[@"smartStripExtensions"] boolValue] : YES;
    _rebootShieldEnabled = dict[@"rebootShieldEnabled"] ? [dict[@"rebootShieldEnabled"] boolValue] : YES;
    _liquidGlassTintLevel = dict[@"liquidGlassTintLevel"] ? [dict[@"liquidGlassTintLevel"] floatValue] : 0.25f;
}

- (void)savePreferences {
    NSString *dir = [AURA_PREFS_PATH stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *dict = @{
        @"autoRenewEnabled": @(_autoRenewEnabled),
        @"normalRenewThresholdDays": @(_normalRenewThresholdDays),
        @"lowBatteryRescueEnabled": @(_lowBatteryRescueEnabled),
        @"lowBatteryTriggerPercent": @(_lowBatteryTriggerPercent),
        @"lowBatteryThresholdDays": @(_lowBatteryThresholdDays),
        @"smartStripExtensions": @(_smartStripExtensions),
        @"rebootShieldEnabled": @(_rebootShieldEnabled),
        @"liquidGlassTintLevel": @(_liquidGlassTintLevel)
    };
    [dict writeToFile:AURA_PREFS_PATH atomically:YES];
}

- (NSDictionary<NSString *, NSString *> *)fetchNativeAnisetteHeaders {
    __block id anisetteDataObj = nil;
    __block NSError *aniErr = nil;

    Class ctrlClass = NSClassFromString(@"AKAnisetteProvisioningController");
    if (ctrlClass) {
        id ctrl = [[ctrlClass alloc] init];
        if ([ctrl respondsToSelector:@selector(anisetteDataWithError:)]) {
            NSError *syncErr = nil;
            anisetteDataObj = [ctrl anisetteDataWithError:&syncErr];
            aniErr = syncErr;
        }
        if (!anisetteDataObj && [ctrl respondsToSelector:@selector(anisetteDataWithCompletion:)]) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [ctrl anisetteDataWithCompletion:^(id data, NSError *error) {
                anisetteDataObj = data;
                aniErr = error;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }
    }

    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    NSString *clientTime = [iso stringFromDate:[NSDate date]];
    NSString *tz = [[NSTimeZone localTimeZone] abbreviation] ?: @"CST";

    if (anisetteDataObj && [anisetteDataObj oneTimePassword] && [anisetteDataObj machineID]) {
        NSString *otp = [anisetteDataObj oneTimePassword];
        NSString *mid = [anisetteDataObj machineID];
        NSString *rinfo = [NSString stringWithFormat:@"%llu", [anisetteDataObj routingInfo]];
        return @{
            @"X-Apple-I-MD": otp,
            @"X-Apple-I-MD-M": mid,
            @"X-Apple-I-MD-RINFO": rinfo,
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

// 将 7 天 .mobileprovision 直接注册进未越狱系统 misagent 信任库
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
    NSString *mobileProv = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:mobileProv]) return NO;

    void *misHandle = dlopen("/usr/lib/libmis.dylib", RTLD_LAZY);
    if (!misHandle) return NO;
    MISValidateSignatureFunc validateFunc = (MISValidateSignatureFunc)dlsym(misHandle, "MISValidateSignatureAndCopyInfo");
    if (!validateFunc) return NO;

    CFDictionaryRef info = NULL;
    NSDictionary *opts = @{@"CheckCertValidity": @YES, @"RespectUppTrust": @YES};
    int status = validateFunc((__bridge CFStringRef)bundlePath, (__bridge CFDictionaryRef)opts, &info);
    if (info) CFRelease(info);
    return (status == 0);
}

- (NSArray<AuraAppInfo *> *)scanTargetApps {
    NSMutableArray<AuraAppInfo *> *result = [NSMutableArray array];
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return result;

    NSArray *allApps = [[wsClass defaultWorkspace] allInstalledApplications];
    for (id proxy in allApps) {
        NSString *bid = [proxy applicationIdentifier] ?: @"";
        NSString *name = [proxy localizedName] ?: @"";
        NSString *bundlePath = [[proxy bundleURL] path] ?: @"";
        if (!bundlePath.length || [bid isEqualToString:@"com.aurasign.pro"]) continue;

        BOOL isDopamine = ([bid.lowercaseString containsString:@"dopamine"] || [name.lowercaseString containsString:@"dopamine"]);
        BOOL isRelaxin  = ([bid.lowercaseString containsString:@"relaxin"]  || [name.lowercaseString containsString:@"relaxin"]);
        NSString *provPath = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
        BOOL hasProv = [[NSFileManager defaultManager] fileExistsAtPath:provPath];

        if (!isDopamine && !isRelaxin && ![[proxy applicationType] isEqualToString:@"User"]) continue;
        if (!isDopamine && !isRelaxin && !hasProv) continue;

        AuraAppInfo *item = [[AuraAppInfo alloc] init];
        item.appName = name.length ? name : bid;
        item.bundleID = bid;
        item.version = [proxy shortVersionString] ?: @"1.0";
        item.bundlePath = bundlePath;
        item.isJailbreakLoader = (isDopamine || isRelaxin);

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

        if (item.isJailbreakLoader) {
            [result insertObject:item atIndex:0];
        } else {
            [result addObject:item];
        }
    }
    return result;
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
                    *outSummary = [NSString stringWithFormat:@"⚠️ 高危：检测到【%@】当前为假签名或证书已过期！若现在关机重启将无法打开越狱工具，请点击下方【⚡ 立即修复】！", app.appName];
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
        *outSummary = [NSString stringWithFormat:@"已通过未越狱开机校验 (libmis: OK) · 剩余 %d天 %d小时，随时重启手机均可安全激活越狱", days, hours];
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

- (BOOL)installAndSignIPAFileAtPath:(NSString *)ipaFilePath
                         customName:(NSString *)customName
                     customBundleID:(NSString *)customBundleID
                       injectedDebs:(NSArray<NSString *> *)debOrDylibPaths
                              error:(NSError **)outError {
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaFilePath]) {
        if (outError) *outError = [NSError errorWithDomain:@"AuraSign" code:404 userInfo:@{NSLocalizedDescriptionKey: @"找不到待签名的 IPA 安装包文件"}];
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
        if (outError) *outError = [NSError errorWithDomain:@"AuraSign" code:422 userInfo:@{NSLocalizedDescriptionKey: @"解压 IPA 失败：包内未找到 Payload/*.app 目录"}];
        return NO;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[foundAppPath stringByAppendingPathComponent:@"Info.plist"]];
    AuraAppInfo *tempApp = [[AuraAppInfo alloc] init];
    tempApp.appName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"App";
    tempApp.bundleID = info[@"CFBundleIdentifier"] ?: @"com.aurasign.imported";
    tempApp.version = info[@"CFBundleShortVersionString"] ?: @"1.0";
    tempApp.bundlePath = foundAppPath;
    tempApp.isJailbreakLoader = ([tempApp.bundleID.lowercaseString containsString:@"dopamine"] || [tempApp.bundleID.lowercaseString containsString:@"relaxin"]);

    BOOL ok = [self fastResignApp:tempApp stripPlugIns:self.smartStripExtensions customName:customName customBundleID:customBundleID injectedDebs:debOrDylibPaths error:outError];
    [[NSFileManager defaultManager] removeItemAtPath:unzipDir error:nil];
    return ok;
}

#pragma mark - 【关键修复】：使用 iOS 17 原生 LSApplicationWorkspace installApplication:withOptions:error: 安装！

- (BOOL)fastResignApp:(AuraAppInfo *)app
        stripPlugIns:(BOOL)strip
          customName:(NSString *)customName
      customBundleID:(NSString *)customBundleID
        injectedDebs:(NSArray<NSString *> *)debOrDylibPaths
               error:(NSError **)outError {

    AuraAppleDeveloperAPI *api = [AuraAppleDeveloperAPI sharedAPI];
    if (![api hasValidAccountInKeychain]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:401 userInfo:@{NSLocalizedDescriptionKey: @"您尚未绑定 Apple ID！请先在【守护中心】点击【立即登录】绑定您的免费 Apple ID"}];
        }
        [self appendTimelineLog:[NSString stringWithFormat:@"[SIGN-ABORT] 【%@】签名中止：尚未登录绑定 Apple ID", app.appName] success:NO];
        return NO;
    }

    NSString *requestedBundleID = (customBundleID.length && !app.isJailbreakLoader) ? customBundleID : app.bundleID;
    NSString *resolvedBundleID = requestedBundleID;
    NSData *realProfileData = [api requestReal7DayProvisioningProfileForBundleID:requestedBundleID
                                                                         appName:app.appName
                                                               outResolvedBundle:&resolvedBundleID
                                                                           error:outError];
    if (!realProfileData || realProfileData.length == 0) {
        NSString *errMsg = (outError && *outError) ? (*outError).localizedDescription : @"未能从苹果获取 7 天描述文件";
        [self appendTimelineLog:[NSString stringWithFormat:@"[SIGN-ERR] 【%@】获取苹果描述文件失败：%@", app.appName, errMsg] success:NO];
        return NO;
    }

    // 1. 先将该 7 天描述文件注册进系统 misagent 信任库
    [self installProvisioningProfileIntoSystemMIS:realProfileData];

    // 2. 准备暂存目录
    NSString *publicStaging = @"/var/mobile/Media/PublicStaging";
    [[NSFileManager defaultManager] createDirectoryAtPath:publicStaging withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    chown(publicStaging.UTF8String, 501, 501);

    NSString *stageRoot = [publicStaging stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *payloadDir = [stageRoot stringByAppendingPathComponent:@"Payload"];
    [[NSFileManager defaultManager] createDirectoryAtPath:payloadDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];

    NSString *appFolderName = [app.bundlePath lastPathComponent];
    NSString *stagedAppPath = [payloadDir stringByAppendingPathComponent:appFolderName];
    [[NSFileManager defaultManager] copyItemAtPath:app.bundlePath toPath:stagedAppPath error:nil];

    if (strip && !app.isJailbreakLoader) {
        [[NSFileManager defaultManager] removeItemAtPath:[stagedAppPath stringByAppendingPathComponent:@"PlugIns"] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[stagedAppPath stringByAppendingPathComponent:@"Watch"] error:nil];
    }

    NSString *infoPlistPath = [stagedAppPath stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];
    if (infoDict) {
        if (customName.length && !app.isJailbreakLoader) {
            infoDict[@"CFBundleDisplayName"] = customName;
        }
        infoDict[@"CFBundleIdentifier"] = resolvedBundleID;
        infoDict[@"UIFileSharingEnabled"] = @YES;
        [infoDict removeObjectForKey:@"MinimumOSVersion"];
        [infoDict writeToFile:infoPlistPath atomically:YES];
    }

    NSMutableArray<NSString *> *dylibRelPaths = [NSMutableArray array];
    if (debOrDylibPaths.count > 0) {
        NSString *frameworksDir = [stagedAppPath stringByAppendingPathComponent:@"Frameworks"];
        [[NSFileManager defaultManager] createDirectoryAtPath:frameworksDir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *rawPath in debOrDylibPaths) {
            NSString *actualDylibPath = [api extractDylibFromDebPackage:rawPath];
            if (actualDylibPath.length && [[NSFileManager defaultManager] fileExistsAtPath:actualDylibPath]) {
                NSString *dest = [frameworksDir stringByAppendingPathComponent:actualDylibPath.lastPathComponent];
                [[NSFileManager defaultManager] copyItemAtPath:actualDylibPath toPath:dest error:nil];
                [dylibRelPaths addObject:[@"@executable_path/Frameworks/" stringByAppendingString:actualDylibPath.lastPathComponent]];
            }
        }
    }

    // 3. 调用 zsign 对 stagedAppPath 进行真证书签名并输出 signed.ipa
    BOOL zsignOK = [api performRealZSignOnAppBundle:stagedAppPath profileData:realProfileData injectedDylibs:dylibRelPaths error:outError];
    if (!zsignOK) {
        [[NSFileManager defaultManager] removeItemAtPath:stageRoot error:nil];
        NSString *errMsg = (outError && *outError) ? (*outError).localizedDescription : @"zsign 二进制签名未通过";
        [self appendTimelineLog:[NSString stringWithFormat:@"[ZSIGN-ERR] 【%@】签名失败：%@", app.appName, errMsg] success:NO];
        return NO;
    }

    [self recursivelyFixInstalldPermissions:stageRoot];
    NSString *signedIpaPath = [payloadDir stringByAppendingPathComponent:@"signed.ipa"];

    // 4. 调用 iOS 17 原生 LSApplicationWorkspace installApplication:withOptions:error: 安装！
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [wsClass defaultWorkspace];
    BOOL installSuccess = NO;
    NSError *lsError = nil;

    // 通道 A：通过 signed.ipa 标准 Customer 模式安装
    if ([[NSFileManager defaultManager] fileExistsAtPath:signedIpaPath] &&
        [workspace respondsToSelector:@selector(installApplication:withOptions:error:)]) {
        NSDictionary *ipaOpts = @{
            @"CFBundleIdentifier": resolvedBundleID,
            @"PackageType": @"Customer"
        };
        installSuccess = [workspace installApplication:[NSURL fileURLWithPath:signedIpaPath] withOptions:ipaOpts error:&lsError];
        [self appendTimelineLog:[NSString stringWithFormat:@"[LS-INSTALL-IPA] 【%@】installed=%d, err=%@",
            app.appName, installSuccess, lsError.localizedDescription ?: @"nil"] success:installSuccess];
    }

    // 通道 B：若通道 A 未成功，通过 stagedAppPath (.app 目录) Developer 模式安装
    if (!installSuccess && [[NSFileManager defaultManager] fileExistsAtPath:stagedAppPath] &&
        [workspace respondsToSelector:@selector(installApplication:withOptions:error:)]) {
        lsError = nil;
        NSDictionary *devOpts = @{
            @"CFBundleIdentifier": resolvedBundleID,
            @"PackageType": @"Developer"
        };
        installSuccess = [workspace installApplication:[NSURL fileURLWithPath:stagedAppPath] withOptions:devOpts error:&lsError];
        [self appendTimelineLog:[NSString stringWithFormat:@"[LS-INSTALL-DEV] 【%@】installed=%d, err=%@",
            app.appName, installSuccess, lsError.localizedDescription ?: @"nil"] success:installSuccess];
    }

    [[NSFileManager defaultManager] removeItemAtPath:stageRoot error:nil];

    if (!installSuccess) {
        if (outError) {
            *outError = lsError ?: [NSError errorWithDomain:@"AuraSign" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"LSApplicationWorkspace 安装未通过，请复制诊断日志查看详情"}];
        }
        return NO;
    }

    [self appendTimelineLog:[NSString stringWithFormat:@"🎉 [RESIGN-SUCCESS] 【%@】已成功签入 7 天苹果真证书并完成覆盖安装！(BundleID:%@)", app.appName, resolvedBundleID] success:YES];
    return YES;
}

- (void)downloadAndSignRepoItem:(AuraRepoAppItem *)item
                       progress:(void(^)(NSString *stageText))progressBlock
                     completion:(void(^)(BOOL success, NSString *message))completion {
    if (completion) completion(NO, @"商店模块已移除");
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
            NSError *err = nil;
            if ([self fastResignApp:app stripPlugIns:self.smartStripExtensions customName:nil customBundleID:nil injectedDebs:nil error:&err]) {
                successCount++;
            } else {
                lastErr = err.localizedDescription;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (successCount > 0) {
                if (completion) completion(YES, [NSString stringWithFormat:@"✅ 已成功为 %ld 款应用刷新满血 7 天苹果真证书！", (long)successCount]);
            } else {
                if (completion) completion(NO, lastErr ?: @"没有可续签的应用或签名失败");
            }
        });
    });
}

- (NSString *)accelerateURLForMainlandChina:(NSString *)originalURL {
    return originalURL ?: @"";
}

- (NSArray<AuraRepoAppItem *> *)loadBuiltInStoreCatalog {
    return @[];
}

- (void)addCustomRepoFromURL:(NSString *)repoURLString completion:(void(^)(BOOL success, NSInteger addedCount, NSString *errorMsg))completion {
    if (completion) completion(NO, 0, nil);
}

#pragma mark - 深度诊断日志系统

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
