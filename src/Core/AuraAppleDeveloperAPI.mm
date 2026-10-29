// src/Core/AuraAppleDeveloperAPI.mm
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

// 系统 AuthKit / AuthKitUI 真实私有方法声明
@interface NSObject (AuraAuthKitRealAPI)
- (void)setUsername:(NSString *)username;
- (void)_setPassword:(NSString *)password;
- (void)setIsUsernameEditable:(BOOL)editable;
- (void)setServiceType:(NSInteger)type;
- (void)setServiceIdentifier:(NSString *)identifier;
- (void)setPresentingViewController:(UIViewController *)vc;
- (void)setShouldOfferSecurityUpgrade:(BOOL)offer;
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
    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]];
    return (sess != nil &&
            [sess[@"teamId"] length] > 0 &&
            [sess[@"adsid"] length] > 0 &&
            [[NSFileManager defaultManager] fileExistsAtPath:[self p12FilePath]]);
}

- (NSString *)currentAppleIDEmail {
    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]];
    if (sess && [sess[@"email"] length] && [sess[@"teamId"] length]) {
        return sess[@"email"];
    }
    return @"未绑定 Apple ID";
}

- (NSString *)currentTeamID {
    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]];
    return sess[@"teamId"] ?: @"";
}

- (void)logoutCurrentAccount {
    [[NSFileManager defaultManager] removeItemAtPath:[self sessionFilePath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self p12FilePath] error:nil];
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
    return @"";
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

#pragma mark - 1. 生成 RSA 私钥与 CSR，并将苹果官方返回的真 .cer 转成 .p12 (绝不自签造假!)

- (NSString *)generatePrivateKeyAndCSRPEMForEmail:(NSString *)email {
    NSString *keyPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_key.pem"];
    NSString *csrPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_request.csr"];
    NSString *openssl = [self findBinaryNamed:@"openssl"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:keyPath]) {
        [self runProcess:openssl args:@[@"genrsa", @"-out", keyPath, @"2048"]];
    }
    NSString *subj = [NSString stringWithFormat:@"/emailAddress=%@/CN=AuraSignPro/C=US", email.length ? email : @"dev@icloud.com"];
    [self runProcess:openssl args:@[@"req", @"-new", @"-key", keyPath, @"-out", csrPath, @"-subj", subj]];

    NSString *csrPEM = [NSString stringWithContentsOfFile:csrPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"-----BEGIN CERTIFICATE REQUEST-----" withString:@""];
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"-----END CERTIFICATE REQUEST-----" withString:@""];
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    csrPEM = [csrPEM stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    return [csrPEM stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)exportRealAppleDERCertToP12:(NSData *)derCertData {
    if (![derCertData isKindOfClass:[NSData class]] || derCertData.length == 0) {
        return NO; // 绝不伪造自签名证书！没拿到苹果真 .cer 直接返回 NO
    }
    NSString *keyPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_key.pem"];
    NSString *derPath = [[self keychainDir] stringByAppendingPathComponent:@"apple_dev.cer"];
    NSString *pemPath = [[self keychainDir] stringByAppendingPathComponent:@"dev_cert.pem"];
    NSString *p12Path = [self p12FilePath];
    NSString *openssl = [self findBinaryNamed:@"openssl"];

    [derCertData writeToFile:derPath atomically:YES];
    int r1 = [self runProcess:openssl args:@[@"x509", @"-inform", @"DER", @"-in", derPath, @"-out", pemPath]];
    int r2 = [self runProcess:openssl args:@[@"pkcs12", @"-export", @"-legacy", @"-out", p12Path, @"-inkey", keyPath, @"-in", pemPath, @"-passout", @"pass:"]];
    if (r2 != 0) {
        // OpenSSL 1.1 兼容参数（不带 -legacy）
        r2 = [self runProcess:openssl args:@[@"pkcs12", @"-export", @"-out", p12Path, @"-inkey", keyPath, @"-in", pemPath, @"-passout", @"pass:"]];
    }
    return (r1 == 0 && r2 == 0 && [[NSFileManager defaultManager] fileExistsAtPath:p12Path]);
}

#pragma mark - 2. 苹果 QH65B2 开发者中心真实请求与错误码中文翻译

- (NSDictionary *)sendQH65B2Request:(NSString *)actionPath
                           bodyDict:(NSDictionary *)bodyDict
                            session:(NSDictionary *)session
                           outError:(NSError **)outError {
    NSString *urlStr = [NSString stringWithFormat:@"https://developerservices2.apple.com/QH65B2/ios/%@?clientId=XABBG36SBA", actionPath];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20.0];
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
    [req setValue:@"8.3" forHTTPHeaderField:@"X-Xcode-Version"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Accept"];

    NSMutableDictionary *fullBody = [NSMutableDictionary dictionaryWithDictionary:bodyDict ?: @{}];
    fullBody[@"clientId"] = @"XABBG36SBA";
    fullBody[@"protocolVersion"] = @"QH65B2";
    fullBody[@"requestId"] = [[NSUUID UUID] UUIDString];
    req.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:fullBody format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];

    __block NSDictionary *respDict = nil;
    __block NSError *netErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        netErr = err;
        if (data.length) {
            id obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) respDict = obj;
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    if (netErr && outError) {
        *outError = [NSError errorWithDomain:@"AuraSign" code:netErr.code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"网络请求失败: %@", netErr.localizedDescription]}];
        return nil;
    }

    NSInteger resultCode = [respDict[@"resultCode"] integerValue];
    if (resultCode != 0 && outError) {
        NSString *appleMsg = respDict[@"userString"] ?: respDict[@"resultString"] ?: @"未知苹果接口错误";
        NSString *cnReason = [self translateAppleErrorCode:resultCode rawMessage:appleMsg];
        *outError = [NSError errorWithDomain:@"AuraApplePortal" code:resultCode userInfo:@{NSLocalizedDescriptionKey: cnReason}];
    }
    return respDict;
}

- (NSString *)translateAppleErrorCode:(NSInteger)code rawMessage:(NSString *)raw {
    if (code == 1100) return @"登录凭证已过期或未通过双重认证 (1100)，请重新点击登录";
    if (code == 7460) return @"该账号在其他电脑上生成的证书已满 (7460)，正在为您自动清理旧证书并接管...";
    if (code == 9401) return @"该软件标识符 (Bundle ID) 已被占用 (9401)，正在自动附加您的专属 TeamID 后缀...";
    if (code == 9427) return @"本周免费账号的 10 个 App ID 注册额度已满 (9427)，请等待满 7 天自动释放或换用其他免费小号";
    return [NSString stringWithFormat:@"苹果服务器提示 (%ld): %@", (long)code, raw];
}

#pragma mark - 3. 调起 iOS 系统原生登录/双重认证窗口 + 完整 1 年期真证书签发

- (void)authenticateWithSystemSheetFromViewController:(UIViewController *)presentingVC
                                         initialEmail:(NSString *)email
                                      initialPassword:(NSString *)password
                                           completion:(void(^)(BOOL success, NSString *errorMsg))completion {

    dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/AuthKitUI.framework/AuthKitUI", RTLD_LAZY);

    Class inAppCtxClass = NSClassFromString(@"AKAppleIDAuthenticationInAppContext") ?: NSClassFromString(@"AKAppleIDAuthenticationContext");
    Class ctrlClass = NSClassFromString(@"AKAppleIDAuthenticationController");

    if (!inAppCtxClass || !ctrlClass) {
        if (completion) completion(NO, @"系统 AuthKit 组件加载失败");
        return;
    }

    id ctx = [[inAppCtxClass alloc] init];
    @try {
        if (email.length && [ctx respondsToSelector:@selector(setUsername:)]) {
            [ctx setUsername:email];
        }
        if (password.length && [ctx respondsToSelector:@selector(_setPassword:)]) {
            [ctx _setPassword:password];
        }
        if ([ctx respondsToSelector:@selector(setIsUsernameEditable:)]) {
            [ctx setIsUsernameEditable:YES];
        }
        if ([ctx respondsToSelector:@selector(setServiceType:)]) {
            [ctx setServiceType:1]; // GrandSlam
        }
        if ([ctx respondsToSelector:@selector(setServiceIdentifier:)]) {
            [ctx setServiceIdentifier:@"com.apple.gs.xcode.auth"];
        }
        if ([ctx respondsToSelector:@selector(setShouldOfferSecurityUpgrade:)]) {
            [ctx setShouldOfferSecurityUpgrade:NO];
        }
        if (presentingVC && [ctx respondsToSelector:@selector(setPresentingViewController:)]) {
            [ctx setPresentingViewController:presentingVC];
        }
    } @catch (NSException *ex) {}

    id ctrl = [[ctrlClass alloc] init];
    [ctrl authenticateWithContext:ctx completion:^(NSDictionary *results, NSError *authError) {
        if (authError || !results) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *errStr = authError.localizedDescription ?: @"用户取消或认证未通过";
                if (completion) completion(NO, [NSString stringWithFormat:@"Apple ID 认证未通过：%@", errStr]);
            });
            return;
        }

        // 提取真实的 ADSID 与 Xcode GSA Token
        NSString *realEmail = results[@"AKUsername"] ?: email ?: @"";
        NSString *adsid = results[@"AKAltDSID"] ?: results[@"altDSID"] ?: @"";
        NSDictionary *tokens = results[@"AKTokens"] ?: results[@"tokens"];
        NSString *xcodeToken = ([tokens isKindOfClass:[NSDictionary class]] ? tokens[@"com.apple.gs.xcode.auth"] : nil)
            ?: results[@"AKIdmsToken"] ?: @"";

        if (!adsid.length || !xcodeToken.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, @"未能从系统获取 Xcode 开发者令牌 (请确认 entitlements.xml 已签入 AuthKit 权限)");
            });
            return;
        }

        // 在后台线程向苹果 QH65B2 开发者中心验证 TeamID、注册本机 UDID 并签发 1 年期真证书
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSMutableDictionary *sess = [NSMutableDictionary dictionaryWithDictionary:@{
                @"email": realEmail,
                @"adsid": adsid,
                @"xcodeToken": xcodeToken,
                @"udid": [self realDeviceUDID],
                @"updatedAt": [NSDate date]
            }];

            // Step 1: 获取个人开发者 Team ID (必须拿到真 Team ID，绝不造假!)
            NSError *stepErr = nil;
            NSDictionary *teamsResp = [self sendQH65B2Request:@"listTeams.action" bodyDict:@{} session:sess outError:&stepErr];
            NSArray *teams = teamsResp[@"teams"];
            if (![teams isKindOfClass:[NSArray class]] || teams.count == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, stepErr.localizedDescription ?: @"该 Apple ID 尚未激活免费个人开发者团队，请重试");
                });
                return;
            }
            NSString *teamId = teams[0][@"teamId"];
            sess[@"teamId"] = teamId;

            // Step 2: 注册本机真 UDID 到该 Team 下 (addDevice.action)
            NSString *udid = [self realDeviceUDID];
            if (udid.length) {
                [self sendQH65B2Request:@"addDevice.action" bodyDict:@{
                    @"teamId": teamId,
                    @"deviceNumber": udid,
                    @"name": [[UIDevice currentDevice] name] ?: @"iPhone"
                } session:sess outError:NULL];
            }

            // Step 3: 生成 CSR 并申请苹果官方 1 年期 .cer 开发证书 (若遇 7460 证书上限自动清理旧证书重试)
            NSString *csrContent = [self generatePrivateKeyAndCSRPEMForEmail:realEmail];
            NSError *csrErr = nil;
            NSDictionary *certResp = [self sendQH65B2Request:@"submitDevelopmentCSR.action" bodyDict:@{
                @"teamId": teamId,
                @"csrContent": csrContent
            } session:sess outError:&csrErr];

            NSData *derCert = certResp[@"certRequest"][@"certificate"][@"certContent"];

            // 如果苹果返回 7460 (在其他电脑签过名导致证书数量满)，自动拉取旧证书并吊销后重新申请！
            if (!derCert && csrErr.code == 7460) {
                NSDictionary *listCerts = [self sendQH65B2Request:@"listAllDevelopmentCerts.action" bodyDict:@{@"teamId": teamId} session:sess outError:NULL];
                NSArray *certs = listCerts[@"certificates"];
                if ([certs isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *c in certs) {
                        NSString *serial = c[@"serialNumber"];
                        if (serial.length) {
                            [self sendQH65B2Request:@"revokeDevelopmentCert.action" bodyDict:@{@"teamId": teamId, @"serialNumber": serial} session:sess outError:NULL];
                        }
                    }
                }
                certResp = [self sendQH65B2Request:@"submitDevelopmentCSR.action" bodyDict:@{@"teamId": teamId, @"csrContent": csrContent} session:sess outError:&csrErr];
                derCert = certResp[@"certRequest"][@"certificate"][@"certContent"];
            }

            BOOL p12OK = [self exportRealAppleDERCertToP12:derCert];
            if (!p12OK && ![[NSFileManager defaultManager] fileExistsAtPath:[self p12FilePath]]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, csrErr.localizedDescription ?: @"向苹果申请 1 年期开发证书失败");
                });
                return;
            }

            [sess writeToFile:[self sessionFilePath] atomically:YES];
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"✅ 已绑定 Apple ID: %@ (真实 TeamID: %@)", realEmail, teamId] success:YES];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, nil);
            });
        });
    }];
}

#pragma mark - 4. 查找/注册真实 10 位 appIdId 主键，并下载带苹果 CMS 签名的 7 天 .mobileprovision

- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                        outResolvedBundle:(NSString **)outResolvedBundleID
                                                    error:(NSError **)outError {
    if (![self hasValidAccountInKeychain]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:401 userInfo:@{NSLocalizedDescriptionKey: @"尚未登录 Apple ID！请先在【守护中心】点击【立即登录】绑定您的免费 Apple ID"}];
        }
        return nil;
    }

    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]];
    NSString *teamId = sess[@"teamId"];
    NSString *targetBundleID = bundleID ?: @"com.aurasign.app";

    // 若 Bundle ID 尚未带有当前用户的 TeamID 后缀（例如从商店新下的原版 com.opa334.Dopamine），自动附加上 .TeamID 防止与全球他人重名报错 9401
    if (![targetBundleID hasSuffix:teamId] && [targetBundleID componentsSeparatedByString:@"."].count <= 3) {
        targetBundleID = [NSString stringWithFormat:@"%@.%@", targetBundleID, teamId];
    }
    if (outResolvedBundleID) *outResolvedBundleID = targetBundleID;

    // Step 4A: 先调用 listAppIds.action 查询该账号下是否已存在该 Bundle ID，取出其 10 位内部主键 appIdId
    NSString *realAppIdPrimaryKey = nil;
    NSDictionary *listResp = [self sendQH65B2Request:@"listAppIds.action" bodyDict:@{@"teamId": teamId} session:sess outError:NULL];
    NSArray *existingAppIds = listResp[@"appIds"];
    if ([existingAppIds isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in existingAppIds) {
            if ([item[@"identifier"] isEqualToString:targetBundleID] || [item[@"identifier"] isEqualToString:bundleID]) {
                realAppIdPrimaryKey = item[@"appIdId"];
                targetBundleID = item[@"identifier"];
                if (outResolvedBundleID) *outResolvedBundleID = targetBundleID;
                break;
            }
        }
    }

    // Step 4B: 若账号下尚未注册该 App ID，则调用 addAppId.action 注册并取出返回的 10 位 appIdId 主键
    if (!realAppIdPrimaryKey.length) {
        NSString *cleanName = [[appName componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@" "];
        cleanName = [cleanName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!cleanName.length) cleanName = @"AuraSignApp";

        NSError *addErr = nil;
        NSDictionary *addResp = [self sendQH65B2Request:@"addAppId.action" bodyDict:@{
            @"teamId": teamId,
            @"identifier": targetBundleID,
            @"name": cleanName
        } session:sess outError:&addErr];

        if ([addResp[@"appId"] isKindOfClass:[NSDictionary class]]) {
            realAppIdPrimaryKey = addResp[@"appId"][@"appIdId"];
        }
        if (!realAppIdPrimaryKey.length) {
            if (outError) *outError = addErr ?: [NSError errorWithDomain:@"AuraSign" code:9401 userInfo:@{NSLocalizedDescriptionKey: @"向苹果注册 App ID 失败"}];
            return nil;
        }
    }

    // Step 5: 传入真实的 10 位 appIdId 主键，下载带苹果官方 CMS 签名的 7 天 .mobileprovision！
    NSError *dlErr = nil;
    NSDictionary *profResp = [self sendQH65B2Request:@"downloadTeamProvisioningProfile.action" bodyDict:@{
        @"teamId": teamId,
        @"appIdId": realAppIdPrimaryKey
    } session:sess outError:&dlErr];

    NSData *encodedProfile = nil;
    if ([profResp[@"provisioningProfile"] isKindOfClass:[NSDictionary class]]) {
        encodedProfile = profResp[@"provisioningProfile"][@"encodedProfile"];
    }
    if (![encodedProfile isKindOfClass:[NSData class]] || encodedProfile.length == 0) {
        if (outError) *outError = dlErr ?: [NSError errorWithDomain:@"AuraSign" code:500 userInfo:@{NSLocalizedDescriptionKey: @"从苹果服务器下载 7 天描述文件失败"}];
        return nil;
    }
    return encodedProfile;
}

#pragma mark - 5. 越狱 .deb 解包与真实 zsign 签名校验

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
    if (!mobileProvisionData.length || ![[NSFileManager defaultManager] fileExistsAtPath:[self p12FilePath]]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:403 userInfo:@{NSLocalizedDescriptionKey: @"本地缺少有效的苹果开发证书 (.p12) 或 7 天描述文件，请先登录 Apple ID"}];
        }
        return NO;
    }

    NSString *provPath = [appBundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    [mobileProvisionData writeToFile:provPath atomically:YES];

    NSString *zsignBin = [self findBinaryNamed:@"zsign"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:zsignBin]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:404 userInfo:@{NSLocalizedDescriptionKey: @"未找到 zsign 签名核心，请在 Sileo 中安装 zsign"}];
        }
        return NO;
    }

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"-k", [self p12FilePath], @"-m", provPath, @"-f", nil];
    for (NSString *dylib in dylibPaths) {
        [args addObjectsFromArray:@[@"-l", dylib]];
    }
    [args addObject:appBundlePath];

    int ret = [self runProcess:zsignBin args:args];
    if (ret != 0 && outError) {
        *outError = [NSError errorWithDomain:@"AuraSign" code:ret userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"zsign 签名失败 (返回码: %d)", ret]}];
    }
    return (ret == 0);
}

@end
