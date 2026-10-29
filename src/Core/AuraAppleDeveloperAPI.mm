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
typedef CFTypeRef (*CTServerConnectionCreateFunc)(CFAllocatorRef, void *, void *);
typedef int (*CTServerConnectionSetCellularUsagePolicyFunc)(CFTypeRef, CFStringRef, CFDictionaryRef);

@interface NSObject (AuraAuthKitRealAPI)
- (void)setUsername:(NSString *)username;
- (void)_setPassword:(NSString *)password;
- (void)setIsUsernameEditable:(BOOL)editable;
- (void)setServiceType:(NSInteger)type;
- (void)setServiceIdentifier:(NSString *)identifier;
- (void)setServiceIdentifiers:(NSArray<NSString *> *)identifiers;
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

- (instancetype)init {
    if (self = [super init]) {
        [self unlockMainlandChinaNetworkPermission];
    }
    return self;
}

// 【关键修复】：自动调用 CoreTelephony 为 com.aurasign.pro 解锁国行 iPhone 的无线局域网与蜂窝数据权限！
- (void)unlockMainlandChinaNetworkPermission {
    void *ctHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    if (!ctHandle) return;

    CTServerConnectionCreateFunc createConn = (CTServerConnectionCreateFunc)dlsym(ctHandle, "_CTServerConnectionCreate");
    CTServerConnectionSetCellularUsagePolicyFunc setPolicy = (CTServerConnectionSetCellularUsagePolicyFunc)dlsym(ctHandle, "_CTServerConnectionSetCellularUsagePolicy");

    if (createConn && setPolicy) {
        CFTypeRef conn = createConn(kCFAllocatorDefault, NULL, NULL);
        if (conn) {
            NSDictionary *policy = @{
                @"kCTCellularDataUsagePolicy": @"kCTCellularDataUsagePolicyAlwaysAllow",
                @"kCTWiFiDataUsagePolicy": @"kCTCellularDataUsagePolicyAlwaysAllow"
            };
            setPolicy(conn, CFSTR("com.aurasign.pro"), (__bridge CFDictionaryRef)policy);
            CFRelease(conn);
        }
    }
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
        return NO;
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
        r2 = [self runProcess:openssl args:@[@"pkcs12", @"-export", @"-out", p12Path, @"-inkey", keyPath, @"-in", pemPath, @"-passout", @"pass:"]];
    }
    return (r1 == 0 && r2 == 0 && [[NSFileManager defaultManager] fileExistsAtPath:p12Path]);
}

#pragma mark - 苹果 QH65B2 开发者中心请求（配备自动解锁联网 + CFNetwork 底层通道）

- (NSDictionary *)sendQH65B2Request:(NSString *)actionPath
                           bodyDict:(NSDictionary *)bodyDict
                            session:(NSDictionary *)session
                           outError:(NSError **)outError {
    [self unlockMainlandChinaNetworkPermission];

    NSString *urlStr = [NSString stringWithFormat:@"https://developerservices2.apple.com/QH65B2/ios/%@?clientId=XABBG36SBA", actionPath];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20.0];
    req.HTTPMethod = @"POST";
    req.allowsCellularAccess = YES;

    NSDictionary *anisette = [[AuraSignEngine sharedEngine] fetchNativeAnisetteHeaders];
    [anisette enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:k];
    }];
    NSString *udid = [self realDeviceUDID];
    if (udid.length) {
        [req setValue:udid forHTTPHeaderField:@"X-Mme-Device-Id"];
    }
    if ([session[@"adsid"] length]) {
        [req setValue:session[@"adsid"] forHTTPHeaderField:@"X-Apple-I-Identity-Id"];
    }
    if ([session[@"xcodeToken"] length]) {
        [req setValue:session[@"xcodeToken"] forHTTPHeaderField:@"X-Apple-GS-Token"];
    }
    [req setValue:@"Xcode" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"15.2 (15C500b)" forHTTPHeaderField:@"X-Xcode-Version"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Accept"];

    NSMutableDictionary *fullBody = [NSMutableDictionary dictionaryWithDictionary:bodyDict ?: @{}];
    fullBody[@"clientId"] = @"XABBG36SBA";
    fullBody[@"protocolVersion"] = @"QH65B2";
    fullBody[@"requestId"] = [[NSUUID UUID] UUIDString];
    NSData *xmlBodyData = [NSPropertyListSerialization dataWithPropertyList:fullBody format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    req.HTTPBody = xmlBodyData;

    // 使用独立 Ephemeral Session 并关闭 waitsForConnectivity，避免国行 symptomd 误判离线
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.allowsCellularAccess = YES;
    cfg.waitsForConnectivity = NO;
    NSURLSession *customSession = [NSURLSession sessionWithConfiguration:cfg];

    __block NSDictionary *respDict = nil;
    __block NSError *netErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[customSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        netErr = err;
        if (data.length) {
            id obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) respDict = obj;
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    // 若国行系统仍然拦截 NSURLSession 报 -1009 (offline)，自动使用 openssl s_client / curl 命令行通道绕过系统 App 防火墙！
    if (netErr && !respDict) {
        NSString *curlBin = [self findBinaryNamed:@"curl"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:curlBin]) {
            NSString *reqFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aura_req.plist"];
            NSString *respFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aura_resp.plist"];
            [xmlBodyData writeToFile:reqFile atomically:YES];

            NSMutableArray *curlArgs = [NSMutableArray arrayWithObjects:@"-s", @"-k", @"-X", @"POST", urlStr,
                                        @"-H", @"Content-Type: text/x-xml-plist",
                                        @"-H", @"User-Agent: Xcode",
                                        @"-H", @"X-Xcode-Version: 15.2 (15C500b)", nil];
            [req.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
                [curlArgs addObjectsFromArray:@[@"-H", [NSString stringWithFormat:@"%@: %@", k, v]]];
            }];
            [curlArgs addObjectsFromArray:@[@"--data-binary", [NSString stringWithFormat:@"@%@", reqFile], @"-o", respFile]];

            if ([self runProcess:curlBin args:curlArgs] == 0) {
                NSData *curlData = [NSData dataWithContentsOfFile:respFile];
                if (curlData.length) {
                    id obj = [NSPropertyListSerialization propertyListWithData:curlData options:0 format:NULL error:NULL];
                    if ([obj isKindOfClass:[NSDictionary class]]) {
                        respDict = obj;
                        netErr = nil;
                    }
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:reqFile error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:respFile error:nil];
        }
    }

    if (netErr && outError) {
        *outError = [NSError errorWithDomain:@"AuraSign" code:netErr.code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"网络请求被系统拦截 (%ld): 请在系统「设置 -> 无线局域网 -> 使用无线局域网与蜂窝移动网的应用」中允许【灵签 Pro】联网，或重启一次越狱环境", (long)netErr.code]}];
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
    if (code == 1100) return @"苹果会话令牌未通过校验 (1100)，请确认账号密码正确并完成双重认证";
    if (code == 7460) return @"该账号在其他电脑上生成的证书已满 (7460)，正在自动为您吊销旧证书并重新签发...";
    if (code == 9401) return @"该软件标识符已被占用 (9401)，正在自动附加您的专属 TeamID 后缀...";
    if (code == 9427) return @"本周免费账号的 10 个 App ID 注册额度已满 (9427)，请等待满 7 天自动释放或换用其他免费小号";
    return [NSString stringWithFormat:@"苹果服务器返回 (%ld): %@", (long)code, raw];
}

- (void)authenticateWithSystemSheetFromViewController:(UIViewController *)presentingVC
                                         initialEmail:(NSString *)email
                                      initialPassword:(NSString *)password
                                           completion:(void(^)(BOOL success, NSString *errorMsg))completion {

    [self unlockMainlandChinaNetworkPermission];
    void *akHandle = dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY);
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
            [ctx setServiceType:1];
        }
        if ([ctx respondsToSelector:@selector(setServiceIdentifier:)]) {
            [ctx setServiceIdentifier:@"com.apple.gs.xcode.auth"];
        }
        if ([ctx respondsToSelector:@selector(setServiceIdentifiers:)]) {
            [ctx setServiceIdentifiers:@[@"com.apple.gs.xcode.auth", @"com.apple.gs.idms.auth"]];
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

        NSString * __strong *kAltDSIDPtr = akHandle ? (NSString * __strong *)dlsym(akHandle, "AKAuthenticationAlternateDSIDKey") : NULL;
        NSString * __strong *kDSIDPtr    = akHandle ? (NSString * __strong *)dlsym(akHandle, "AKAuthenticationDSIDKey") : NULL;
        NSString * __strong *kIdmsPtr    = akHandle ? (NSString * __strong *)dlsym(akHandle, "AKAuthenticationIDMSTokenKey") : NULL;
        NSString * __strong *kPassPtr    = akHandle ? (NSString * __strong *)dlsym(akHandle, "AKAuthenticationPasswordKey") : NULL;
        NSString * __strong *kMasterPtr  = akHandle ? (NSString * __strong *)dlsym(akHandle, "AKAuthenticationMasterTokenKey") : NULL;

        NSString *realEmail = results[@"AKUsername"] ?: results[@"username"] ?: email ?: @"";

        NSString *adsid = nil;
        if (kAltDSIDPtr && *kAltDSIDPtr && results[*kAltDSIDPtr]) adsid = [NSString stringWithFormat:@"%@", results[*kAltDSIDPtr]];
        if (!adsid.length) adsid = results[@"AKAltDSID"] ?: results[@"altDSID"];
        if (!adsid.length && kDSIDPtr && *kDSIDPtr && results[*kDSIDPtr]) adsid = [NSString stringWithFormat:@"%@", results[*kDSIDPtr]];
        if (!adsid.length) adsid = results[@"AKDSID"] ?: results[@"dsid"] ?: @"";

        NSString *xcodeToken = nil;
        id rawIdmsObj = (kIdmsPtr && *kIdmsPtr) ? results[*kIdmsPtr] : nil;
        if (!rawIdmsObj) rawIdmsObj = results[@"AKIdmsToken"] ?: results[@"idmsToken"] ?: results[@"AKTokens"] ?: results[@"tokens"];

        if ([rawIdmsObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *tokenDict = (NSDictionary *)rawIdmsObj;
            xcodeToken = tokenDict[@"com.apple.gs.xcode.auth"]
                      ?: tokenDict[@"com.apple.gs.idms.auth"]
                      ?: [tokenDict allValues].firstObject;
        } else if ([rawIdmsObj isKindOfClass:[NSString class]]) {
            xcodeToken = (NSString *)rawIdmsObj;
        }

        if (![xcodeToken isKindOfClass:[NSString class]] || xcodeToken.length == 0) {
            id masterObj = (kMasterPtr && *kMasterPtr) ? results[*kMasterPtr] : (results[@"AKMasterToken"] ?: results[@"masterToken"]);
            id passObj   = (kPassPtr && *kPassPtr) ? results[*kPassPtr] : (results[@"AKPassword"] ?: results[@"password"]);
            if ([masterObj isKindOfClass:[NSString class]] && [masterObj length] > 0) {
                xcodeToken = masterObj;
            } else if ([passObj isKindOfClass:[NSString class]] && [passObj length] > 0) {
                xcodeToken = passObj;
            }
        }

        if (![xcodeToken isKindOfClass:[NSString class]] || xcodeToken.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, @"认证已返回但未包含有效开发者令牌");
            });
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSMutableDictionary *sess = [NSMutableDictionary dictionaryWithDictionary:@{
                @"email": realEmail,
                @"adsid": adsid ?: @"",
                @"xcodeToken": xcodeToken,
                @"udid": [self realDeviceUDID],
                @"updatedAt": [NSDate date]
            }];

            NSError *stepErr = nil;
            NSDictionary *teamsResp = [self sendQH65B2Request:@"listTeams.action" bodyDict:@{} session:sess outError:&stepErr];
            NSArray *teams = teamsResp[@"teams"];
            if (![teams isKindOfClass:[NSArray class]] || teams.count == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, stepErr.localizedDescription ?: @"未能获取个人开发者 TeamID");
                });
                return;
            }
            NSString *teamId = teams[0][@"teamId"];
            sess[@"teamId"] = teamId;

            NSString *udid = [self realDeviceUDID];
            if (udid.length) {
                [self sendQH65B2Request:@"addDevice.action" bodyDict:@{
                    @"teamId": teamId,
                    @"deviceNumber": udid,
                    @"name": [[UIDevice currentDevice] name] ?: @"iPhone"
                } session:sess outError:NULL];
            }

            NSString *csrContent = [self generatePrivateKeyAndCSRPEMForEmail:realEmail];
            NSError *csrErr = nil;
            NSDictionary *certResp = [self sendQH65B2Request:@"submitDevelopmentCSR.action" bodyDict:@{
                @"teamId": teamId,
                @"csrContent": csrContent
            } session:sess outError:&csrErr];

            NSData *derCert = certResp[@"certRequest"][@"certificate"][@"certContent"];

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
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"✅ 已绑定 Apple ID: %@ (TeamID: %@)", realEmail, teamId] success:YES];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, nil);
            });
        });
    }];
}

- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                        outResolvedBundle:(NSString **)outResolvedBundleID
                                                    error:(NSError **)outError {
    if (![self hasValidAccountInKeychain]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:401 userInfo:@{NSLocalizedDescriptionKey: @"请先在【守护中心】点击【立即登录】绑定您的免费 Apple ID"}];
        }
        return nil;
    }

    NSDictionary *sess = [NSDictionary dictionaryWithContentsOfFile:[self sessionFilePath]];
    NSString *teamId = sess[@"teamId"];
    NSString *targetBundleID = bundleID ?: @"com.aurasign.app";

    if (![targetBundleID hasSuffix:teamId] && [targetBundleID componentsSeparatedByString:@"."].count <= 3) {
        targetBundleID = [NSString stringWithFormat:@"%@.%@", targetBundleID, teamId];
    }
    if (outResolvedBundleID) *outResolvedBundleID = targetBundleID;

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
