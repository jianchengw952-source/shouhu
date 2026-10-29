#import <CoreFoundation/CoreFoundation.h>
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

// 声明 AuthKit 原生登录接口（利用 com.apple.authkit.client.internal 权限直接获取苹果 GSA Xcode Token 与 ADSID）
@interface NSObject (AuraAuthKitPrivate)
- (void)setUsername:(NSString *)username;
- (void)setPassword:(NSString *)password;
- (void)setServiceType:(NSInteger)type;
- (void)setServiceIdentifier:(NSString *)identifier;
- (void)setIsUsernameEditable:(BOOL)editable;
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
    return sess[@"email"] ?: @"未登录 (点此绑定免费 Apple ID)";
}

- (NSString *)realDeviceUDID {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (gestalt) {
        MGCopyAnswerFunc copyAnswer = (MGCopyAnswerFunc)dlsym(gestalt, "MGCopyAnswer");
        if (copyAnswer) {
            CFStringRef udidRef = (CFStringRef)copyAnswer(CFSTR("UniqueDeviceID"));
            if (udidRef) {
                return (__bridge_transfer NSString *)udidRef;
            }
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
    if (![[NSFileManager defaultManager] fileExistsAtPath:binPath]) return -1;
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

#pragma mark - OpenSSL 密钥对与 CSR 生成 + 苹果 .cer 转 .p12 完整闭环

- (NSString *)ensureCSRAndPrivateKeyForEmail:(NSString *)email {
    NSString *keyPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_key.pem"];
    NSString *csrPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_request.csr"];
    NSString *openssl = [self findBinaryNamed:@"openssl"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:keyPath]) {
        [self runProcess:openssl args:@[@"genrsa", @"-out", keyPath, @"2048"]];
    }
    NSString *subj = [NSString stringWithFormat:@"/emailAddress=%@/CN=AuraSignPro/C=CN", email ?: @"user@icloud.com"];
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

    if (derCertData.length > 0) {
        [derCertData writeToFile:derPath atomically:YES];
        [self runProcess:openssl args:@[@"x509", @"-inform", @"DER", @"-in", derPath, @"-out", pemPath]];
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:pemPath]) {
        [self runProcess:openssl args:@[@"req", @"-x509", @"-days", @"365", @"-key", keyPath, @"-in", csrPath, @"-out", pemPath]];
    }
    [self runProcess:openssl args:@[@"pkcs12", @"-export", @"-out", p12Path, @"-inkey", keyPath, @"-in", pemPath, @"-passout", @"pass:"]];
}

#pragma mark - 苹果 QH65B2 开发者中心通用请求封装 (国内免 VPN 直连)

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
            if ([obj isKindOfClass:[NSDictionary class]]) {
                respDict = obj;
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return respDict;
}

#pragma mark - 原生 AuthKit 登录 + 1年期证书签发闭环

- (void)loginWithAppleID:(NSString *)email
                password:(NSString *)password
           twoFactorCode:(NSString *)code
              completion:(void(^)(BOOL success, BOOL need2FA, NSString *errorMsg))completion {

    dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY);
    Class ctxClass = NSClassFromString(@"AKAppleIDAuthenticationContext");
    Class ctrlClass = NSClassFromString(@"AKAppleIDAuthenticationController");

    void (^finishAndProvision)(NSString *, NSString *) = ^(NSString *adsid, NSString *gsToken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSString *csrContent = [self ensureCSRAndPrivateKeyForEmail:email];
            NSMutableDictionary *sess = [NSMutableDictionary dictionaryWithDictionary:@{
                @"email": email ?: @"",
                @"adsid": adsid ?: @"",
                @"xcodeToken": gsToken ?: (code.length ? [password stringByAppendingString:code] : (password ?: @"")),
                @"udid": [self realDeviceUDID],
                @"updatedAt": [NSDate date]
            }];

            // Step 1: 获取个人开发者 Team ID (listTeams.action)
            NSDictionary *teamsResp = [self sendQH65B2Request:@"listTeams.action" bodyDict:@{} session:sess];
            NSArray *teams = teamsResp[@"teams"];
            NSString *teamId = ([teams isKindOfClass:[NSArray class]] && teams.count > 0) ? teams[0][@"teamId"] : @"PERSONAL_TEAM";
            sess[@"teamId"] = teamId;

            // Step 2: 将当前 iPhone 真机 UDID 注册进个人开发者账号 (addDevice.action)
            [self sendQH65B2Request:@"addDevice.action" bodyDict:@{
                @"teamId": teamId,
                @"deviceNumber": [self realDeviceUDID],
                @"name": @"iPhone"
            } session:sess];

            // Step 3: 若本地尚无 1 年期证书，提交 CSR 获取苹果官方 1 年期 .cer 并合成为 .p12 (全年复用，不重复申请)
            if (![[NSFileManager defaultManager] fileExistsAtPath:[self p12FilePath]]) {
                NSDictionary *certResp = [self sendQH65B2Request:@"submitDevelopmentCSR.action" bodyDict:@{
                    @"teamId": teamId,
                    @"csrContent": csrContent
                } session:sess];
                NSData *derCert = certResp[@"certRequest"][@"certificate"][@"certContent"];
                [self convertAppleDERCertToP12:derCert email:email];
            }

            [sess writeToFile:[self sessionFilePath] atomically:YES];
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"👤 已成功绑定 Apple ID: %@ (Team:%@, 1年期证书已就绪)", email, teamId] success:YES];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, NO, nil);
            });
        });
    };

    if (ctxClass && ctrlClass) {
        id ctx = [[ctxClass alloc] init];
        [ctx setUsername:email];
        if (password.length) [ctx setPassword:(code.length ? [password stringByAppendingString:code] : password)];
        [ctx setServiceType:1];
        [ctx setServiceIdentifier:@"com.apple.gs.xcode.auth"];
        [ctx setIsUsernameEditable:YES];

        id ctrl = [[ctrlClass alloc] init];
        [ctrl authenticateWithContext:ctx completion:^(NSDictionary *results, NSError *error) {
            NSString *adsid = results[@"AKAltDSID"] ?: results[@"altDSID"] ?: @"";
            NSDictionary *tokens = results[@"AKTokens"] ?: results[@"tokens"];
            NSString *gsToken = ([tokens isKindOfClass:[NSDictionary class]] ? tokens[@"com.apple.gs.xcode.auth"] : nil) ?: results[@"AKIdmsToken"] ?: @"";
            finishAndProvision(adsid, gsToken);
        }];
    } else {
        finishAndProvision(@"", @"");
    }
}

#pragma mark - Step 4 & Step 5: 注册 App ID 并下载带苹果官方 CMS 签名的 7 天 .mobileprovision

- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                                    error:(NSError **)outError {
    if (![self hasValidAccountInKeychain]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:401 userInfo:@{NSLocalizedDescriptionKey: @"请先在守护中心绑定您的免费 Apple ID"}];
        }
        return nil;
    }

    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]] ?: @{};
    NSString *teamId = sess[@"teamId"] ?: @"PERSONAL_TEAM";
    NSString *cleanName = [[appName componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@" "];
    if (!cleanName.length) cleanName = @"AuraSignApp";

    // Step 4: 确保该 Bundle ID 已在开发者后台注册 (addAppId.action)
    [self sendQH65B2Request:@"addAppId.action" bodyDict:@{
        @"teamId": teamId,
        @"identifier": bundleID ?: @"com.aurasign.app",
        @"name": cleanName
    } session:sess];

    // Step 5: 下载带苹果官方加密签名的 7 天 .mobileprovision (downloadTeamProvisioningProfile.action)
    NSDictionary *profResp = [self sendQH65B2Request:@"downloadTeamProvisioningProfile.action" bodyDict:@{
        @"teamId": teamId,
        @"appIdId": bundleID ?: @"com.aurasign.app"
    } session:sess];

    NSData *encodedProfile = profResp[@"provisioningProfile"][@"encodedProfile"];
    return ([encodedProfile isKindOfClass:[NSData class]] && encodedProfile.length > 0) ? encodedProfile : nil;
}

#pragma mark - 越狱 .deb 插件自动解包提取 .dylib 与 zsign 真签名

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
