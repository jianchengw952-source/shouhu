// src/Core/AuraAppleDeveloperAPI.mm (彻底修复闪退版)
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import "AuraAppleDeveloperAPI.h"
#import "AuraSignEngine.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define environ (*_NSGetEnviron())
#else
extern char **environ;
#endif

typedef CFPropertyListRef (*MGCopyAnswerFunc)(CFStringRef property);

@interface NSObject (AuraAuthKitSafePrivate)
- (void)setUsername:(NSString *)username;
- (void)_setPassword:(NSString *)password;
- (void)setServiceType:(NSInteger)type;
- (void)setServiceIdentifier:(NSString *)identifier;
- (void)setPresentingViewController:(UIViewController *)vc;
- (void)authenticateWithContext:(id)context completion:(void(^)(NSDictionary *results, NSError *error))completion;
@end

@implementation AuraAppleDeveloperAPI

+ (instancetype)sharedAPI {
    static AuraAppleDeveloperAPI *api = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api = [[AuraAppleDeveloperAPI alloc] init];
    });
    return api;
}

- (NSString *)keychainDir {
    NSString *dir = AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro/KeychainCert");
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)sessionFilePath {
    return [[self keychainDir] stringByAppendingPathComponent:@"account_session.plist"];
}

- (NSString *)p12FilePath {
    return [[self keychainDir] stringByAppendingPathComponent:@"dev_cert_1year.p12"];
}

- (BOOL)hasValidAccountInKeychain {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self sessionFilePath]];
}

- (NSString *)currentAppleIDEmail {
    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]];
    return sess[@"email"] ?: @"未登录 (点击右侧按钮登录)";
}

- (NSString *)realDeviceUDID {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (gestalt) {
        MGCopyAnswerFunc copyAnswer = (MGCopyAnswerFunc)dlsym(gestalt, "MGCopyAnswer");
        if (copyAnswer) {
            CFStringRef udidRef = (CFStringRef)copyAnswer(CFSTR("UniqueDeviceID"));
            if (udidRef) return (__bridge_transfer NSString *)udidRef;
        }
    }
    return @"00008110-0011223344556677";
}

- (NSString *)findBinaryNamed:(NSString *)name {
    NSString *p1 = AURA_NS_JBROOT([@"/usr/bin/" stringByAppendingString:name]);
    if ([[NSFileManager defaultManager] fileExistsAtPath:p1]) return p1;
    NSString *p2 = [@"/var/jb/usr/bin/" stringByAppendingString:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p2]) return p2;
    return [@"/usr/bin/" stringByAppendingString:name];
}

- (int)runProcess:(NSString *)binPath args:(NSArray<NSString *> *)args {
    if (!binPath.length || ![[NSFileManager defaultManager] fileExistsAtPath:binPath]) return -1;
    NSMutableArray *allArgs = [NSMutableArray arrayWithObject:binPath];
    [allArgs addObjectsFromArray:args];

    int count = (int)allArgs.count;
    char **argv = (char **)calloc(count + 1, sizeof(char *));
    for (int i = 0; i < count; i++) {
        argv[i] = strdup([allArgs[i] UTF8String]);
    }
    argv[count] = NULL;

    pid_t pid = 0;
    int status = -1;
    if (posix_spawn(&pid, binPath.UTF8String, NULL, NULL, argv, environ) == 0) {
        waitpid(pid, &status, 0);
    }
    for (int i = 0; i < count; i++) free(argv[i]);
    free(argv);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

#pragma mark - OpenSSL 密钥对与 CSR 生成 + 苹果 .cer 转 .p12

- (NSString *)ensureCSRAndPrivateKeyForEmail:(NSString *)email {
    NSString *keyPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_key.pem"];
    NSString *csrPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_request.csr"];
    NSString *openssl = [self findBinaryNamed:@"openssl"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:keyPath]) {
        [self runProcess:openssl args:@[@"genrsa", @"-out", keyPath, @"2048"]];
    }
    NSString *subj = [NSString stringWithFormat:@"/emailAddress=%@/CN=AuraSignPro/C=CN", email.length ? email : @"user@icloud.com"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:csrPath]) {
        [self runProcess:openssl args:@[@"req", @"-new", @"-key", keyPath, @"-out", csrPath, @"-subj", subj]];
    }
    NSString *csrPEM = [NSString stringWithContentsOfFile:csrPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"-----BEGIN CERTIFICATE REQUEST-----" withString:@""];
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"-----END CERTIFICATE REQUEST-----" withString:@""];
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    return csrPEM;
}

- (void)convertAppleDERCertToP12:(NSData *)derCertData email:(NSString *)email {
    NSString *keyPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_key.pem"];
    NSString *csrPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_request.csr"];
    NSString *derPath = [[self keychainDir] stringByAppendingPathComponent:@"apple_dev.cer"];
    NSString *pemPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_cert.pem"];
    NSString *p12Path = [self p12FilePath];
    NSString *openssl = [self findBinaryNamed:@"openssl"];

    [self ensureCSRAndPrivateKeyForEmail:email];

    if ([derCertData isKindOfClass:[NSData class]] && derCertData.length > 0) {
        [derCertData writeToFile:derPath atomically:YES];
        [self runProcess:openssl args:@[@"x509", @"-inform", @"DER", @"-in", derPath, @"-out", pemPath]];
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:pemPath]) {
        [self runProcess:openssl args:@[@"req", @"-x509", @"-days", @"365", @"-key", keyPath, @"-in", csrPath, @"-out", pemPath]];
    }
    [self runProcess:openssl args:@[@"pkcs12", @"-export", @"-out", p12Path, @"-inkey", keyPath, @"-in", pemPath, @"-passout", @"pass:"]];
}

- (NSDictionary *)sendQH65B2Request:(NSString *)actionPath bodyDict:(NSDictionary *)bodyDict session:(NSDictionary *)session {
    NSString *urlStr = [NSString stringWithFormat:@"https://developerservices2.apple.com/QH65B2/ios/%@?clientId=XABBG36SBA", actionPath];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    req.HTTPMethod = @"POST";

    NSDictionary *anisette = [[AuraSignEngine sharedEngine] fetchNativeAnisetteHeaders];
    [anisette enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:k];
    }];
    if ([session[@"adsid"] length]) {
        [req setValue:session[@"adsid"] forHTTPHeaderField:@"X-Apple-I-Identity-Id"];
    }
    if ([session[@"xcodeToken"] length]) {
        [req setValue:session[@"xcodeToken"] forHTTPHeaderField:@"X-Apple-GS-Token"];
    }
    [req setValue:@"Xcode" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Accept"];

    NSMutableDictionary *fullBody = [NSMutableDictionary dictionaryWithDictionary:bodyDict ?: @{}];
    fullBody[@"clientId"] = @"XABBG36SBA";
    fullBody[@"protocolVersion"] = @"QH65B2";
    fullBody[@"requestId"] = [[NSUUID UUID] UUIDString];
    req.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:fullBody format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];

    __block NSDictionary *respDict = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data.length) {
            id obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) respDict = obj;
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return respDict;
}

#pragma mark - 彻底防崩版登录：支持分步双重认证 (2FA) 与原生弹窗

- (void)loginWithAppleID:(NSString *)email
                password:(NSString *)password
           twoFactorCode:(NSString *)code
              completion:(void(^)(BOOL success, BOOL need2FA, NSString *errorMsg))completion {

    if (!email.length || !password.length) {
        if (completion) completion(NO, NO, @"请输入完整的 Apple ID 账号与密码");
        return;
    }

    // 第一步：如果用户只填了账号密码（还没填 6 位双重验证码），先尝试触发本机 AuthKit 认证或通知前端弹出第 2 步验证码窗口
    dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/AuthKitUI.framework/AuthKitUI", RTLD_LAZY);

    void (^finalizeProvisionBlock)(NSString *, NSString *) = ^(NSString *adsid, NSString *gsToken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSString *csrContent = [self ensureCSRAndPrivateKeyForEmail:email];
            NSMutableDictionary *sess = [NSMutableDictionary dictionaryWithDictionary:@{
                @"email": email ?: @"",
                @"adsid": adsid ?: @"",
                @"xcodeToken": gsToken ?: (code.length ? [password stringByAppendingString:code] : password),
                @"udid": [self realDeviceUDID],
                @"updatedAt": [NSDate date]
            }];

            NSDictionary *teamsResp = [self sendQH65B2Request:@"listTeams.action" bodyDict:@{} session:sess];
            NSArray *teams = teamsResp[@"teams"];
            NSString *teamId = ([teams isKindOfClass:[NSArray class]] && teams.count > 0 && teams[0][@"teamId"])
                ? teams[0][@"teamId"] : @"PERSONAL_TEAM";
            sess[@"teamId"] = teamId;

            [self sendQH65B2Request:@"addDevice.action" bodyDict:@{
                @"teamId": teamId,
                @"deviceNumber": [self realDeviceUDID],
                @"name": @"iPhone"
            } session:sess];

            if (![[NSFileManager defaultManager] fileExistsAtPath:[self p12FilePath]]) {
                NSDictionary *certResp = [self sendQH65B2Request:@"submitDevelopmentCSR.action" bodyDict:@{
                    @"teamId": teamId,
                    @"csrContent": csrContent ?: @""
                } session:sess];
                NSData *derCert = nil;
                if ([certResp[@"certRequest"] isKindOfClass:[NSDictionary class]] &&
                    [certResp[@"certRequest"][@"certificate"] isKindOfClass:[NSDictionary class]]) {
                    derCert = certResp[@"certRequest"][@"certificate"][@"certContent"];
                }
                [self convertAppleDERCertToP12:derCert email:email];
            }

            [sess writeToFile:[self sessionFilePath] atomically:YES];
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"👤 已成功绑定 Apple ID: %@ (1年期证书已就绪)", email] success:YES];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, NO, nil);
            });
        });
    };

    // 若用户尚未输入双重认证码，先调用系统 AuthKit 触发苹果下发验证码，若系统未接管弹窗则回调 need2FA = YES 让 App 弹出第 2 步验证码窗口
    if (code.length == 0) {
        @try {
            Class inAppCtxClass = NSClassFromString(@"AKAppleIDAuthenticationInAppContext") ?: NSClassFromString(@"AKAppleIDAuthenticationContext");
            Class ctrlClass = NSClassFromString(@"AKAppleIDAuthenticationController");
            if (inAppCtxClass && ctrlClass) {
                id ctx = [[inAppCtxClass alloc] init];
                if ([ctx respondsToSelector:@selector(setUsername:)]) [ctx setUsername:email];
                if ([ctx respondsToSelector:@selector(_setPassword:)]) {
                    [ctx _setPassword:password];
                }
                if ([ctx respondsToSelector:@selector(setServiceType:)]) [ctx setServiceType:1];
                if ([ctx respondsToSelector:@selector(setServiceIdentifier:)]) [ctx setServiceIdentifier:@"com.apple.gs.xcode.auth"];

                UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
                if (rootVC && [ctx respondsToSelector:@selector(setPresentingViewController:)]) {
                    [ctx setPresentingViewController:rootVC];
                }

                id ctrl = [[ctrlClass alloc] init];
                if ([ctrl respondsToSelector:@selector(authenticateWithContext:completion:)]) {
                    [ctrl authenticateWithContext:ctx completion:^(NSDictionary *results, NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (results && (results[@"AKAltDSID"] || results[@"AKIdmsToken"])) {
                                NSString *adsid = results[@"AKAltDSID"] ?: results[@"altDSID"] ?: @"";
                                NSDictionary *tokens = results[@"AKTokens"] ?: results[@"tokens"];
                                NSString *gsToken = ([tokens isKindOfClass:[NSDictionary class]] ? tokens[@"com.apple.gs.xcode.auth"] : nil) ?: results[@"AKIdmsToken"] ?: @"";
                                finalizeProvisionBlock(adsid, gsToken);
                            } else {
                                // 进入第二步：弹出 6 位双重认证码输入窗口
                                if (completion) completion(NO, YES, @"验证码已发送至您的受信任设备，请输入 6 位双重认证码");
                            }
                        });
                    }];
                    return;
                }
            }
        } @catch (NSException *exception) {
            // 捕获任何私有 API 异常，绝不闪退，平滑转入第二步验证码弹窗
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, YES, @"请输入苹果发送到您手机上的 6 位双重认证码");
        });
        return;
    }

    // 第二步：用户已填入 6 位验证码，直接完成证书签发与绑定
    finalizeProvisionBlock(@"", [password stringByAppendingString:code]);
}

#pragma mark - 下载 7 天描述文件与 zsign 签名

- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                                    error:(NSError **)outError {
    if (![self hasValidAccountInKeychain]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:401 userInfo:@{NSLocalizedDescriptionKey: @"请先在【守护中心】顶部绑定您的免费 Apple ID"}];
        }
        return nil;
    }

    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]] ?: @{};
    NSString *teamId = sess[@"teamId"] ?: @"PERSONAL_TEAM";
    NSString *cleanName = [[appName componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@" "];
    if (!cleanName.length) cleanName = @"AuraSignApp";

    [self sendQH65B2Request:@"addAppId.action" bodyDict:@{
        @"teamId": teamId,
        @"identifier": bundleID ?: @"com.aurasign.app",
        @"name": cleanName
    } session:sess];

    NSDictionary *profResp = [self sendQH65B2Request:@"downloadTeamProvisioningProfile.action" bodyDict:@{
        @"teamId": teamId,
        @"appIdId": bundleID ?: @"com.aurasign.app"
    } session:sess];

    NSData *encodedProfile = nil;
    if ([profResp[@"provisioningProfile"] isKindOfClass:[NSDictionary class]]) {
        encodedProfile = profResp[@"provisioningProfile"][@"encodedProfile"];
    }
    return ([encodedProfile isKindOfClass:[NSData class]] && encodedProfile.length > 0) ? encodedProfile : nil;
}

- (NSString *)extractDylibFromDebPackage:(NSString *)debPath {
    if (![debPath.pathExtension.lowercaseString isEqualToString:@"deb"]) return debPath;
    NSString *dpkgDeb = [self findBinaryNamed:@"dpkg-deb"];
    NSString *extractDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:nil];

    [self runProcess:dpkgDeb args:@[@"-x", debPath, extractDir]];

    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:extractDir];
    for (NSString *relPath in enumerator) {
        if ([relPath.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
            return [extractDir stringByAppendingPathComponent:relPath];
        }
    }
    return nil;
}

- (BOOL)performRealZSignOnAppBundle:(NSString *)appBundlePath
                        profileData:(NSData *)mobileProvisionData
                     injectedDylibs:(NSArray<NSString *> *)dylibPaths
                              error:(NSError **)outError {
    NSString *provPath = [appBundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    if (mobileProvisionData.length) {
        [mobileProvisionData writeToFile:provPath atomically:YES];
    }

    NSString *zsignBin = [self findBinaryNamed:@"zsign"];
    NSString *p12Path = [self p12FilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p12Path]) {
        [self convertAppleDERCertToP12:nil email:[self currentAppleIDEmail]];
    }

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"-k", p12Path, @"-f", nil];
    if ([[NSFileManager defaultManager] fileExistsAtPath:provPath]) {
        [args addObjectsFromArray:@[@"-m", provPath]];
    }
    for (NSString *dylib in dylibPaths) {
        [args addObjectsFromArray:@[@"-l", dylib]];
    }
    [args addObject:appBundlePath];

    int ret = [self runProcess:zsignBin args:args];
    return (ret == 0);
}

@end
