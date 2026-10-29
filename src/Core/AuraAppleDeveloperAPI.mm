// src/Core/AuraAppleDeveloperAPI.mm
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/SecRandom.h>
#import "AuraAppleDeveloperAPI.h"
#import "AuraSignEngine.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define environ (*_NSGetEnviron())
#else
extern char **environ;
#endif

typedef CFPropertyListRef (*MGCopyAnswerFunc)(CFStringRef property);
typedef CFTypeRef (*CTServerConnectionCreateFunc)(CFAllocatorRef, void *, void *);
typedef int (*CTServerConnectionSetCellularUsagePolicyFunc)(CFTypeRef, CFStringRef, CFDictionaryRef);

// 动态加载 OpenSSL libcrypto.dylib BIGNUM 与 AES-256-GCM 函数指针声明 (用于 GSA SRP6a 与 spd/et 解密)
typedef void BIGNUM;
typedef void BN_CTX;
typedef void EVP_CIPHER_CTX;
typedef void EVP_CIPHER;

typedef BIGNUM* (*BN_new_fn)(void);
typedef void (*BN_free_fn)(BIGNUM *);
typedef BN_CTX* (*BN_CTX_new_fn)(void);
typedef void (*BN_CTX_free_fn)(BN_CTX *);
typedef BIGNUM* (*BN_bin2bn_fn)(const unsigned char *, int, BIGNUM *);
typedef int (*BN_bn2bin_fn)(const BIGNUM *, unsigned char *);
typedef int (*BN_num_bits_fn)(const BIGNUM *);
typedef int (*BN_set_word_fn)(BIGNUM *, unsigned long);
typedef int (*BN_add_fn)(BIGNUM *, const BIGNUM *, const BIGNUM *);
typedef int (*BN_mul_fn)(BIGNUM *, const BIGNUM *, const BIGNUM *, BN_CTX *);
typedef int (*BN_mod_mul_fn)(BIGNUM *, const BIGNUM *, const BIGNUM *, const BIGNUM *, BN_CTX *);
typedef int (*BN_mod_sub_fn)(BIGNUM *, const BIGNUM *, const BIGNUM *, const BIGNUM *, BN_CTX *);
typedef int (*BN_mod_exp_fn)(BIGNUM *, const BIGNUM *, const BIGNUM *, const BIGNUM *, BN_CTX *);

typedef EVP_CIPHER_CTX* (*EVP_CIPHER_CTX_new_fn)(void);
typedef void (*EVP_CIPHER_CTX_free_fn)(EVP_CIPHER_CTX *);
typedef const EVP_CIPHER* (*EVP_aes_256_gcm_fn)(void);
typedef int (*EVP_DecryptInit_ex_fn)(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *, const unsigned char *, const unsigned char *);
typedef int (*EVP_CIPHER_CTX_ctrl_fn)(EVP_CIPHER_CTX *, int, int, void *);
typedef int (*EVP_DecryptUpdate_fn)(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
typedef int (*EVP_DecryptFinal_ex_fn)(EVP_CIPHER_CTX *, unsigned char *, int *);

#define EVP_CTRL_GCM_SET_IVLEN 0x9
#define EVP_CTRL_GCM_SET_TAG   0x11

// RFC 5054 2048-bit 标准素数 N (Apple GSA SRP6a 专用)
static const char *kRFC5054_2048_N_Hex =
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050"
    "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50"
    "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8"
    "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B"
    "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748"
    "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6"
    "AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"
    "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73";

@implementation AuraAppleDeveloperAPI {
    void *_cryptoHandle;
}

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
        [self loadOpenSSLCryptoLibrary];
    }
    return self;
}

- (void *)loadOpenSSLCryptoLibrary {
    if (_cryptoHandle) return _cryptoHandle;
    NSArray *paths = @[
        AURA_NS_JBROOT(@"/usr/lib/libcrypto.3.dylib"),
        AURA_NS_JBROOT(@"/usr/lib/libcrypto.dylib"),
        AURA_NS_JBROOT(@"/usr/lib/libcrypto.1.1.dylib"),
        @"/var/jb/usr/lib/libcrypto.3.dylib",
        @"/var/jb/usr/lib/libcrypto.dylib"
    ];
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            _cryptoHandle = dlopen(p.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
            if (_cryptoHandle) break;
        }
    }
    return _cryptoHandle;
}

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
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
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
    for (int i = 0; i < count; i++) argv[i] = strdup([allArgs[i] UTF8String]);
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

#pragma mark - 密码学辅助函数 (SHA256 / HMAC-SHA256 / BIGNUM Padded / AES-256-GCM)

- (NSData *)sha256Data:(NSData *)input {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, hash);
    return [NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH];
}

- (NSData *)hmacSHA256WithKey:(NSData *)key data:(NSData *)data {
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, mac);
    return [NSData dataWithBytes:mac length:CC_SHA256_DIGEST_LENGTH];
}

- (NSData *)dataFromHexString:(const char *)hex {
    size_t len = strlen(hex);
    NSMutableData *data = [NSMutableData dataWithCapacity:len / 2];
    char byteChars[3] = {'\0', '\0', '\0'};
    for (size_t i = 0; i + 1 < len; i += 2) {
        byteChars[0] = hex[i];
        byteChars[1] = hex[i + 1];
        unsigned char wholeByte = (unsigned char)strtol(byteChars, NULL, 16);
        [data appendBytes:&wholeByte length:1];
    }
    return data;
}

- (NSData *)bnToPaddedData:(BIGNUM *)bn padLength:(int)padLen {
    BN_num_bits_fn num_bits = (BN_num_bits_fn)dlsym(_cryptoHandle, "BN_num_bits");
    BN_bn2bin_fn bn2bin     = (BN_bn2bin_fn)dlsym(_cryptoHandle, "BN_bn2bin");
    int numBytes = (num_bits(bn) + 7) / 8;
    int totalLen = MAX(numBytes, padLen);
    NSMutableData *outData = [NSMutableData dataWithLength:totalLen];
    unsigned char *ptr = (unsigned char *)outData.mutableBytes;
    bn2bin(bn, ptr + (totalLen - numBytes));
    return outData;
}

- (NSData *)aes256GCMDecryptCiphertext:(const unsigned char *)cipher
                             cipherLen:(int)cipherLen
                                   key:(const unsigned char *)key
                                    iv:(const unsigned char *)iv
                                 ivLen:(int)ivLen
                                   tag:(const unsigned char *)tag {
    EVP_CIPHER_CTX_new_fn ctx_new   = (EVP_CIPHER_CTX_new_fn)dlsym(_cryptoHandle, "EVP_CIPHER_CTX_new");
    EVP_CIPHER_CTX_free_fn ctx_free = (EVP_CIPHER_CTX_free_fn)dlsym(_cryptoHandle, "EVP_CIPHER_CTX_free");
    EVP_aes_256_gcm_fn aes_gcm      = (EVP_aes_256_gcm_fn)dlsym(_cryptoHandle, "EVP_aes_256_gcm");
    EVP_DecryptInit_ex_fn dec_init  = (EVP_DecryptInit_ex_fn)dlsym(_cryptoHandle, "EVP_DecryptInit_ex");
    EVP_CIPHER_CTX_ctrl_fn ctx_ctrl = (EVP_CIPHER_CTX_ctrl_fn)dlsym(_cryptoHandle, "EVP_CIPHER_CTX_ctrl");
    EVP_DecryptUpdate_fn dec_upd    = (EVP_DecryptUpdate_fn)dlsym(_cryptoHandle, "EVP_DecryptUpdate");
    EVP_DecryptFinal_ex_fn dec_fin  = (EVP_DecryptFinal_ex_fn)dlsym(_cryptoHandle, "EVP_DecryptFinal_ex");

    if (!ctx_new || !aes_gcm || !dec_init) return nil;

    EVP_CIPHER_CTX *ctx = ctx_new();
    NSMutableData *plain = [NSMutableData dataWithLength:cipherLen + 16];
    int outLen = 0, finalLen = 0;

    dec_init(ctx, aes_gcm(), NULL, NULL, NULL);
    ctx_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, ivLen, NULL);
    dec_init(ctx, NULL, NULL, key, iv);
    dec_upd(ctx, (unsigned char *)plain.mutableBytes, &outLen, cipher, cipherLen);
    ctx_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag);
    int ret = dec_fin(ctx, (unsigned char *)plain.mutableBytes + outLen, &finalLen);
    ctx_free(ctx);

    if (ret <= 0) return nil;
    plain.length = outLen + finalLen;
    return plain;
}

#pragma mark - 核心：向 https://gsa.apple.com/grandslam/GsService2 执行 SRP6a 认证并兑换 com.apple.gs.xcode.auth 令牌

- (NSDictionary *)sendGSAServiceRequest:(NSDictionary *)requestDict {
    NSDictionary *rootPlist = @{
        @"Header": @{@"Version": @"1.0.1"},
        @"Request": requestDict
    };
    NSData *bodyData = [NSPropertyListSerialization dataWithPropertyList:rootPlist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2"]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20.0];
    req.HTTPMethod = @"POST";
    req.HTTPBody = bodyData;
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"akd/1.0 CFNetwork/1474 Darwin/23.0.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"<iPhone15,2> <iPhone OS;17.0.3;21A360> <com.apple.akd/1.0 (com.apple.akd/1.0)>" forHTTPHeaderField:@"X-MMe-Client-Info"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.waitsForConnectivity = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __block NSDictionary *respDict = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data.length) {
            NSDictionary *parsed = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                respDict = parsed[@"Response"] ?: parsed;
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    return respDict;
}

// 触发苹果向本机弹出系统级 6 位双重认证码窗口
- (void)triggerTrustedDevice2FAPushWithADSID:(NSString *)adsid idmsToken:(NSString *)idmsToken anisette:(NSDictionary *)anisette {
    NSString *rawToken = [NSString stringWithFormat:@"%@:%@", adsid, idmsToken];
    NSString *b64Token = [[rawToken dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gsa.apple.com/auth/verify/trusteddevice"]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    req.HTTPMethod = @"GET";
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"akd/1.0 CFNetwork/1474 Darwin/23.0.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"<iPhone15,2> <iPhone OS;17.0.3;21A360> <com.apple.akd/1.0 (com.apple.akd/1.0)>" forHTTPHeaderField:@"X-MMe-Client-Info"];
    [req setValue:b64Token forHTTPHeaderField:@"X-Apple-Identity-Token"];
    [anisette enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:k];
    }];
    NSString *udid = [self realDeviceUDID];
    if (udid.length) [req setValue:udid forHTTPHeaderField:@"X-Mme-Device-Id"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
}

- (void)loginWithAppleID:(NSString *)email
                password:(NSString *)password
           twoFactorCode:(NSString *)twoFactorCode
              completion:(void(^)(BOOL success, BOOL need2FA, NSString *errorMsg))completion {

    [self unlockMainlandChinaNetworkPermission];
    if (![self loadOpenSSLCryptoLibrary]) {
        if (completion) completion(NO, NO, @"未找到 OpenSSL libcrypto.dylib，请确认 Sileo 中已安装 openssl");
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *username = [[email stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        NSString *effectivePass = (twoFactorCode.length > 0) ? [password stringByAppendingString:twoFactorCode] : password;

        NSDictionary *anisette = [[AuraSignEngine sharedEngine] fetchNativeAnisetteHeaders];
        NSString *udid = [self realDeviceUDID];
        NSDictionary *cpd = @{
            @"bootstrap": @YES,
            @"icscrec": @YES,
            @"loc": @"zh_CN",
            @"pbe": @NO,
            @"prkgen": @YES,
            @"svct": @"iCloud",
            @"X-Apple-I-Client-Time": anisette[@"X-Apple-I-Client-Time"] ?: @"",
            @"X-Apple-I-MD": anisette[@"X-Apple-I-MD"] ?: @"",
            @"X-Apple-I-MD-M": anisette[@"X-Apple-I-MD-M"] ?: @"",
            @"X-Apple-I-MD-RINFO": @([anisette[@"X-Apple-I-MD-RINFO"] longLongValue]),
            @"X-Apple-I-TimeZone": anisette[@"X-Apple-I-TimeZone"] ?: @"CST",
            @"X-Mme-Device-Id": udid ?: @""
        };

        // 绑定 libcrypto BIGNUM 函数
        BN_new_fn bn_new       = (BN_new_fn)dlsym(_cryptoHandle, "BN_new");
        BN_free_fn bn_free     = (BN_free_fn)dlsym(_cryptoHandle, "BN_free");
        BN_CTX_new_fn ctx_new  = (BN_CTX_new_fn)dlsym(_cryptoHandle, "BN_CTX_new");
        BN_CTX_free_fn ctx_free= (BN_CTX_free_fn)dlsym(_cryptoHandle, "BN_CTX_free");
        BN_bin2bn_fn bin2bn    = (BN_bin2bn_fn)dlsym(_cryptoHandle, "BN_bin2bn");
        BN_set_word_fn set_w   = (BN_set_word_fn)dlsym(_cryptoHandle, "BN_set_word");
        BN_add_fn bn_add       = (BN_add_fn)dlsym(_cryptoHandle, "BN_add");
        BN_mul_fn bn_mul       = (BN_mul_fn)dlsym(_cryptoHandle, "BN_mul");
        BN_mod_mul_fn mod_mul  = (BN_mod_mul_fn)dlsym(_cryptoHandle, "BN_mod_mul");
        BN_mod_sub_fn mod_sub  = (BN_mod_sub_fn)dlsym(_cryptoHandle, "BN_mod_sub");
        BN_mod_exp_fn mod_exp  = (BN_mod_exp_fn)dlsym(_cryptoHandle, "BN_mod_exp");

        BN_CTX *bnCtx = ctx_new();
        NSData *N_data = [self dataFromHexString:kRFC5054_2048_N_Hex];
        BIGNUM *bn_N = bin2bn((const unsigned char *)N_data.bytes, (int)N_data.length, NULL);
        BIGNUM *bn_g = bn_new();
        set_w(bn_g, 2);

        // 生成 32 字节客户端随机数 a，并计算 A = (g ^ a) mod N
        unsigned char a_bytes[32];
        SecRandomCopyBytes(kSecRandomDefault, 32, a_bytes);
        BIGNUM *bn_a = bin2bn(a_bytes, 32, NULL);
        BIGNUM *bn_A = bn_new();
        mod_exp(bn_A, bn_g, bn_a, bn_N, bnCtx);
        NSData *A_data = [self bnToPaddedData:bn_A padLength:256];

        // ==================== GSA Step 1: init ====================
        [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-INIT] 正在向 gsa.apple.com 发起 SRP6a 握手 (%@, 2FA=%@)",
            username, twoFactorCode.length ? @"已带验证码" : @"首轮"] success:YES];

        NSDictionary *initResp = [self sendGSAServiceRequest:@{
            @"A2k": A_data,
            @"cpd": cpd,
            @"o": @"init",
            @"ps": @[@"s2k", @"s2k_fo"],
            @"u": username
        }];

        NSData *salt = initResp[@"s"];
        NSData *B_data = initResp[@"B"];
        NSInteger iterations = [initResp[@"i"] integerValue];
        NSString *serverCookie = initResp[@"c"];
        NSString *proto = initResp[@"sp"] ?: @"s2k";

        if (!salt.length || !B_data.length || iterations <= 0) {
            NSInteger ec = [initResp[@"Status"][@"ec"] integerValue];
            NSString *em = initResp[@"Status"][@"em"] ?: @"GSA init 未返回盐值";
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-INIT-ERR] ec=%ld, em=%@", (long)ec, em] success:NO];
            bn_free(bn_N); bn_free(bn_g); bn_free(bn_a); bn_free(bn_A); ctx_free(bnCtx);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, NO, [NSString stringWithFormat:@"苹果 GSA 握手失败 (%ld): %@", (long)ec, em]);
            });
            return;
        }

        // ==================== GSA Step 2: 计算 S, K, M1 并发送 complete ====================
        // 1. 计算 k = SHA256(N || PAD(g, 256))
        NSMutableData *kInput = [NSMutableData dataWithData:N_data];
        NSMutableData *gPadded = [NSMutableData dataWithLength:256];
        ((unsigned char *)gPadded.mutableBytes)[255] = 0x02;
        [kInput appendData:gPadded];
        NSData *kHash = [self sha256Data:kInput];
        BIGNUM *bn_k = bin2bn((const unsigned char *)kHash.bytes, 32, NULL);

        // 2. 计算 u = SHA256(PAD(A, 256) || PAD(B, 256))
        BIGNUM *bn_B = bin2bn((const unsigned char *)B_data.bytes, (int)B_data.length, NULL);
        NSData *B_padded = [self bnToPaddedData:bn_B padLength:256];
        NSMutableData *uInput = [NSMutableData dataWithData:A_data];
        [uInput appendData:B_padded];
        NSData *uHash = [self sha256Data:uInput];
        BIGNUM *bn_u = bin2bn((const unsigned char *)uHash.bytes, 32, NULL);

        // 3. 计算密码 PBKDF2 与 x = SHA256(s || PBKDF2(passHash, s, i))
        NSData *passRawHash = [self sha256Data:[effectivePass dataUsingEncoding:NSUTF8StringEncoding]];
        NSData *pbkdfPassInput = passRawHash;
        if ([proto isEqualToString:@"s2k_fo"]) {
            NSMutableString *hexPass = [NSMutableString stringWithCapacity:64];
            const unsigned char *pBytes = (const unsigned char *)passRawHash.bytes;
            for (int idx = 0; idx < 32; idx++) [hexPass appendFormat:@"%02x", pBytes[idx]];
            pbkdfPassInput = [hexPass dataUsingEncoding:NSUTF8StringEncoding];
        }
        unsigned char pbkdfOut[32];
        CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)pbkdfPassInput.bytes, pbkdfPassInput.length,
                             (const uint8_t *)salt.bytes, salt.length,
                             kCCPRFHmacAlgSHA256, (uint)iterations, pbkdfOut, 32);

        NSMutableData *xInput = [NSMutableData dataWithData:salt];
        [xInput appendBytes:pbkdfOut length:32];
        NSData *xHash = [self sha256Data:xInput];
        BIGNUM *bn_x = bin2bn((const unsigned char *)xHash.bytes, 32, NULL);

        // 4. 计算 S = ((B - k * (g^x mod N)) ^ (a + u * x)) mod N
        BIGNUM *bn_v = bn_new();
        BIGNUM *bn_kv = bn_new();
        BIGNUM *bn_base = bn_new();
        BIGNUM *bn_ux = bn_new();
        BIGNUM *bn_exp = bn_new();
        BIGNUM *bn_S = bn_new();

        mod_exp(bn_v, bn_g, bn_x, bn_N, bnCtx);
        mod_mul(bn_kv, bn_k, bn_v, bn_N, bnCtx);
        mod_sub(bn_base, bn_B, bn_kv, bn_N, bnCtx);
        bn_mul(bn_ux, bn_u, bn_x, bnCtx);
        bn_add(bn_exp, bn_a, bn_ux);
        mod_exp(bn_S, bn_base, bn_exp, bn_N, bnCtx);

        NSData *S_padded = [self bnToPaddedData:bn_S padLength:256];
        NSData *K_data = [self sha256Data:S_padded];

        // 5. 计算客户端证明 M1 = SHA256((H(N)^H(g)) || H(username) || s || A || B || K)
        NSData *HN = [self sha256Data:N_data];
        unsigned char gByte = 0x02;
        NSData *Hg = [self sha256Data:[NSData dataWithBytes:&gByte length:1]];
        unsigned char hXor[32];
        for (int idx = 0; idx < 32; idx++) {
            hXor[idx] = ((const unsigned char *)HN.bytes)[idx] ^ ((const unsigned char *)Hg.bytes)[idx];
        }
        NSData *HI = [self sha256Data:[username dataUsingEncoding:NSUTF8StringEncoding]];

        NSMutableData *m1Input = [NSMutableData dataWithBytes:hXor length:32];
        [m1Input appendData:HI];
        [m1Input appendData:salt];
        [m1Input appendData:A_data];
        [m1Input appendData:B_padded];
        [m1Input appendData:K_data];
        NSData *M1_data = [self sha256Data:m1Input];

        // 释放临时 BIGNUM
        bn_free(bn_N); bn_free(bn_g); bn_free(bn_a); bn_free(bn_A);
        bn_free(bn_k); bn_free(bn_B); bn_free(bn_u); bn_free(bn_x);
        bn_free(bn_v); bn_free(bn_kv); bn_free(bn_base); bn_free(bn_ux);
        bn_free(bn_exp); bn_free(bn_S); ctx_free(bnCtx);

        NSDictionary *compResp = [self sendGSAServiceRequest:@{
            @"M1": M1_data,
            @"c": serverCookie ?: @"",
            @"cpd": cpd,
            @"o": @"complete",
            @"u": username
        }];

        NSInteger ec = [compResp[@"Status"][@"ec"] integerValue];
        NSString *em = compResp[@"Status"][@"em"] ?: @"";
        NSString *authType = compResp[@"Status"][@"au"] ?: @"";
        NSData *spdData = compResp[@"spd"];

        [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-COMPLETE] ec=%ld, au=%@, spdLen=%lu, em=%@",
            (long)ec, authType, (unsigned long)spdData.length, em] success:(ec == 0 || spdData.length > 0)];

        if (ec == -22406) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, NO, @"Apple ID 账号或密码不正确 (-22406)，请重新输入");
            });
            return;
        }

        // 解密 spd 数据包 (AES-256-GCM: key = HMAC(K, "extra data key:"), iv = HMAC(K, "extra data iv:")[0..15])
        NSDictionary *spdDict = nil;
        if ([spdData isKindOfClass:[NSData class]] && spdData.length > 16) {
            NSData *extraKey = [self hmacSHA256WithKey:K_data data:[@"extra data key:" dataUsingEncoding:NSUTF8StringEncoding]];
            NSData *extraIV  = [self hmacSHA256WithKey:K_data data:[@"extra data iv:" dataUsingEncoding:NSUTF8StringEncoding]];
            int cipherLen = (int)spdData.length - 16;
            const unsigned char *rawSpd = (const unsigned char *)spdData.bytes;
            NSData *decSpd = [self aes256GCMDecryptCiphertext:rawSpd
                                                    cipherLen:cipherLen
                                                          key:(const unsigned char *)extraKey.bytes
                                                           iv:(const unsigned char *)extraIV.bytes
                                                        ivLen:16
                                                          tag:(rawSpd + cipherLen)];
            if (decSpd.length) {
                spdDict = [NSPropertyListSerialization propertyListWithData:decSpd options:0 format:NULL error:NULL];
            }
        }

        NSString *adsid = spdDict[@"adsid"] ?: @"";
        NSString *idmsToken = spdDict[@"GsIdmsToken"] ?: @"";
        NSData *skData = spdDict[@"sk"];
        NSData *spdCookie = spdDict[@"c"];

        // 若苹果要求双重认证 (au == trustedDeviceSecondaryAuth) 且当前尚未填入 6位验证码：立即触发本机弹出6位验证码并进入第2步！
        if (([authType containsString:@"SecondaryAuth"] || ec == -22411) && twoFactorCode.length == 0) {
            if (adsid.length && idmsToken.length) {
                [self triggerTrustedDevice2FAPushWithADSID:adsid idmsToken:idmsToken anisette:anisette];
            }
            [[AuraSignEngine sharedEngine] appendTimelineLog:@"[GSA-2FA] 已触发苹果向本机推送 6 位双重认证码弹窗，等待用户输入" success:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, YES, @"验证码已推送至您的手机屏幕，请输入收到的 6 位数字验证码");
            });
            return;
        }

        if (!adsid.length || !idmsToken.length || ![skData isKindOfClass:[NSData class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, (twoFactorCode.length == 0), [NSString stringWithFormat:@"需要完成双重认证 (%ld: %@)", (long)ec, em]);
            });
            return;
        }

        // ==================== GSA Step 3: 发送 apptokens 兑换真正的 com.apple.gs.xcode.auth 令牌 ====================
        NSString *appName = @"com.apple.gs.xcode.auth";
        NSMutableData *chkInput = [NSMutableData dataWithData:[@"apptokens" dataUsingEncoding:NSUTF8StringEncoding]];
        [chkInput appendData:[adsid dataUsingEncoding:NSUTF8StringEncoding]];
        [chkInput appendData:[appName dataUsingEncoding:NSUTF8StringEncoding]];
        NSData *checksum = [self hmacSHA256WithKey:skData data:chkInput];

        NSDictionary *appTokResp = [self sendGSAServiceRequest:@{
            @"app": @[appName],
            @"c": spdCookie ?: [NSData data],
            @"checksum": checksum,
            @"cpd": cpd,
            @"o": @"apptokens",
            @"t": idmsToken,
            @"u": adsid
        }];

        NSData *etData = appTokResp[@"et"];
        NSString *xcodeToken = nil;
        if ([etData isKindOfClass:[NSData class]] && etData.length > 35) {
            const unsigned char *etBytes = (const unsigned char *)etData.bytes;
            // et 格式: 3字节头 "xyz" + 16字节 IV + 密文 + 16字节 GCM Tag
            const unsigned char *ivPtr = etBytes + 3;
            int cipherLen = (int)etData.length - 3 - 16 - 16;
            const unsigned char *cipherPtr = etBytes + 19;
            const unsigned char *tagPtr = etBytes + etData.length - 16;

            NSData *decEt = [self aes256GCMDecryptCiphertext:cipherPtr
                                                   cipherLen:cipherLen
                                                         key:(const unsigned char *)skData.bytes
                                                          iv:ivPtr
                                                       ivLen:16
                                                         tag:tagPtr];
            if (decEt.length) {
                NSDictionary *etDict = [NSPropertyListSerialization propertyListWithData:decEt options:0 format:NULL error:NULL];
                xcodeToken = etDict[@"t"][@"com.apple.gs.xcode.auth"][@"token"];
            }
        }

        [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-XCODE-TOKEN] 成功兑换 com.apple.gs.xcode.auth 专属令牌! 长度=%lu",
            (unsigned long)xcodeToken.length] success:(xcodeToken.length > 0)];

        if (!xcodeToken.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, NO, @"未能从 GSA 解密出 com.apple.gs.xcode.auth 令牌，请点击复制诊断日志");
            });
            return;
        }

        // ==================== Step 4: 用真正的 com.apple.gs.xcode.auth 令牌请求 QH65B2 开发者中心 ====================
        NSMutableDictionary *sess = [NSMutableDictionary dictionaryWithDictionary:@{
            @"email": username,
            @"adsid": adsid,
            @"xcodeToken": xcodeToken,
            @"udid": udid ?: @"",
            @"updatedAt": [NSDate date]
        }];

        NSError *stepErr = nil;
        NSDictionary *teamsResp = [self sendQH65B2Request:@"listTeams.action" bodyDict:@{} session:sess outError:&stepErr];
        NSArray *teams = teamsResp[@"teams"];
        if (![teams isKindOfClass:[NSArray class]] || teams.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, NO, stepErr.localizedDescription ?: @"未能获取个人开发者 TeamID");
            });
            return;
        }
        NSString *teamId = teams[0][@"teamId"];
        sess[@"teamId"] = teamId;

        if (udid.length) {
            [self sendQH65B2Request:@"addDevice.action" bodyDict:@{
                @"teamId": teamId,
                @"deviceNumber": udid,
                @"name": [[UIDevice currentDevice] name] ?: @"iPhone"
            } session:sess outError:NULL];
        }

        NSString *csrContent = [self generatePrivateKeyAndCSRPEMForEmail:username];
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
                if (completion) completion(NO, NO, csrErr.localizedDescription ?: @"向苹果申请 1 年期开发证书失败");
            });
            return;
        }

        [sess writeToFile:[self sessionFilePath] atomically:YES];
        [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"🎉 [LOGIN-SUCCESS] 成功绑定 %@ (TeamID: %@, 1年期真证书已签发!)", username, teamId] success:YES];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(YES, NO, nil);
        });
    });
}

#pragma mark - 其余 QH65B2 请求、CSR生成、AppID与描述文件下载、zsign 签名保持完整

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
    if (![derCertData isKindOfClass:[NSData class]] || derCertData.length == 0) return NO;
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
    if (udid.length) [req setValue:udid forHTTPHeaderField:@"X-Mme-Device-Id"];
    if ([session[@"adsid"] length]) [req setValue:session[@"adsid"] forHTTPHeaderField:@"X-Apple-I-Identity-Id"];
    if ([session[@"xcodeToken"] length]) [req setValue:session[@"xcodeToken"] forHTTPHeaderField:@"X-Apple-GS-Token"];
    [req setValue:@"Xcode" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"15.2 (15C500b)" forHTTPHeaderField:@"X-Xcode-Version"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Accept"];

    [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[QH65B2-REQ] %@ | ADSID=%@ | XcodeTokenLen=%lu",
        actionPath, session[@"adsid"] ?: @"空", (unsigned long)[session[@"xcodeToken"] length]] success:YES];

    NSMutableDictionary *fullBody = [NSMutableDictionary dictionaryWithDictionary:bodyDict ?: @{}];
    fullBody[@"clientId"] = @"XABBG36SBA";
    fullBody[@"protocolVersion"] = @"QH65B2";
    fullBody[@"requestId"] = [[NSUUID UUID] UUIDString];
    req.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:fullBody format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.waitsForConnectivity = NO;
    NSURLSession *customSession = [NSURLSession sessionWithConfiguration:cfg];

    __block NSDictionary *respDict = nil;
    __block NSError *netErr = nil;
    __block NSInteger httpCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[customSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        netErr = err;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) httpCode = [(NSHTTPURLResponse *)resp statusCode];
        if (data.length) {
            id obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) respDict = obj;
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    if (netErr && outError) {
        *outError = [NSError errorWithDomain:@"AuraSign" code:netErr.code userInfo:@{NSLocalizedDescriptionKey: netErr.localizedDescription}];
        return nil;
    }

    NSInteger resultCode = [respDict[@"resultCode"] integerValue];
    NSString *rawResultStr = respDict[@"resultString"] ?: @"";
    NSString *rawUserStr   = respDict[@"userString"] ?: @"";
    [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[QH65B2-RESP] %@ | HTTP=%ld | resultCode=%ld | msg=%@",
        actionPath, (long)httpCode, (long)resultCode, rawUserStr.length ? rawUserStr : rawResultStr] success:(resultCode == 0)];

    if (resultCode != 0 && outError) {
        NSString *appleMsg = rawUserStr.length ? rawUserStr : (rawResultStr.length ? rawResultStr : @"未知苹果接口错误");
        *outError = [NSError errorWithDomain:@"AuraApplePortal" code:resultCode userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"苹果返回 (%ld): %@", (long)resultCode, appleMsg]}];
    }
    return respDict;
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
