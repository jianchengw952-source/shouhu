// src/Core/AuraAppleDeveloperAPI.mm (移除伪造 LU/SRL-NO 请求头解决 403 empty 拦截 + 双通道自动适配终极版)
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <CommonCrypto/CommonCryptor.h>
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
    NSString *_pending2FAAdsid;
    NSString *_pending2FAIdmsToken;
    NSString *_cachedEmail;
    NSString *_cachedAdsid;
    NSString *_cachedXcodeToken;
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
    _cachedEmail = nil;
    _cachedAdsid = nil;
    _cachedXcodeToken = nil;
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

- (NSData *)executeCurlRequestWithURL:(NSString *)urlStr
                               method:(NSString *)httpMethod
                              headers:(NSDictionary<NSString *, NSString *> *)headers
                             bodyData:(NSData *)bodyData
                          outExitCode:(int *)outExitCode
                        outHttpStatus:(NSInteger *)outHttpStatus {
    NSString *curlBin = [self findBinaryNamed:@"curl"];
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *reqFile  = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"aura_req_%@.dat", uuid]];
    NSString *respFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"aura_resp_%@.dat", uuid]];
    NSString *hdrFile  = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"aura_hdr_%@.txt", uuid]];

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"-s", @"-k", @"--http1.1", @"--connect-timeout", @"15", @"--max-time", @"25", @"-D", hdrFile, @"-X", (httpMethod ?: @"POST"), urlStr, nil];

    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [args addObjectsFromArray:@[@"-H", [NSString stringWithFormat:@"%@: %@", k, v]]];
    }];

    if (bodyData.length > 0) {
        [bodyData writeToFile:reqFile atomically:YES];
        [args addObjectsFromArray:@[@"--data-binary", [NSString stringWithFormat:@"@%@", reqFile]]];
    }
    [args addObjectsFromArray:@[@"-o", respFile]];

    int ret = [self runProcess:curlBin args:args];
    if (outExitCode) *outExitCode = ret;

    if (outHttpStatus) {
        *outHttpStatus = 0;
        NSString *hdrStr = [NSString stringWithContentsOfFile:hdrFile encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [hdrStr componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            if ([line hasPrefix:@"HTTP/"]) {
                NSArray *parts = [line componentsSeparatedByString:@" "];
                if (parts.count >= 2) *outHttpStatus = [parts[1] integerValue];
            }
        }
    }

    NSData *respData = [NSData dataWithContentsOfFile:respFile];
    [[NSFileManager defaultManager] removeItemAtPath:reqFile error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:respFile error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:hdrFile error:nil];
    return respData;
}

#pragma mark - 密码学辅助函数

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

- (NSData *)aes256CBCDecryptData:(NSData *)cipherData key:(NSData *)keyData iv:(NSData *)ivData {
    if (!cipherData.length || keyData.length < 32 || ivData.length < 16) return nil;
    size_t bufferSize = cipherData.length + kCCBlockSizeAES128;
    NSMutableData *decrypted = [NSMutableData dataWithLength:bufferSize];
    size_t numBytesDecrypted = 0;

    CCCryptorStatus status = CCCrypt(kCCDecrypt,
                                     kCCAlgorithmAES,
                                     kCCOptionPKCS7Padding,
                                     keyData.bytes,
                                     kCCKeySizeAES256,
                                     ivData.bytes,
                                     cipherData.bytes,
                                     cipherData.length,
                                     decrypted.mutableBytes,
                                     bufferSize,
                                     &numBytesDecrypted);
    if (status == kCCSuccess) {
        decrypted.length = numBytesDecrypted;
        return decrypted;
    }
    return nil;
}

- (NSData *)aes256GCMDecryptETData:(NSData *)etData key:(NSData *)skData {
    if (etData.length <= 35 || skData.length < 32) return nil;
    EVP_CIPHER_CTX_new_fn ctx_new   = (EVP_CIPHER_CTX_new_fn)dlsym(_cryptoHandle, "EVP_CIPHER_CTX_new");
    EVP_CIPHER_CTX_free_fn ctx_free = (EVP_CIPHER_CTX_free_fn)dlsym(_cryptoHandle, "EVP_CIPHER_CTX_free");
    EVP_aes_256_gcm_fn aes_gcm      = (EVP_aes_256_gcm_fn)dlsym(_cryptoHandle, "EVP_aes_256_gcm");
    EVP_DecryptInit_ex_fn dec_init  = (EVP_DecryptInit_ex_fn)dlsym(_cryptoHandle, "EVP_DecryptInit_ex");
    EVP_CIPHER_CTX_ctrl_fn ctx_ctrl = (EVP_CIPHER_CTX_ctrl_fn)dlsym(_cryptoHandle, "EVP_CIPHER_CTX_ctrl");
    EVP_DecryptUpdate_fn dec_upd    = (EVP_DecryptUpdate_fn)dlsym(_cryptoHandle, "EVP_DecryptUpdate");
    EVP_DecryptFinal_ex_fn dec_fin  = (EVP_DecryptFinal_ex_fn)dlsym(_cryptoHandle, "EVP_DecryptFinal_ex");

    if (!ctx_new || !aes_gcm || !dec_init) return nil;

    const unsigned char *etBytes = (const unsigned char *)etData.bytes;
    const unsigned char *ivPtr = etBytes + 3;
    int cipherLen = (int)etData.length - 3 - 16 - 16;
    const unsigned char *cipherPtr = etBytes + 19;
    const unsigned char *tagPtr = etBytes + etData.length - 16;

    EVP_CIPHER_CTX *ctx = ctx_new();
    NSMutableData *plain = [NSMutableData dataWithLength:cipherLen + 16];
    int aadLen = 0, outLen = 0, finalLen = 0;

    dec_init(ctx, aes_gcm(), NULL, NULL, NULL);
    ctx_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 16, NULL);
    dec_init(ctx, NULL, NULL, (const unsigned char *)skData.bytes, ivPtr);
    dec_upd(ctx, NULL, &aadLen, etBytes, 3);
    dec_upd(ctx, (unsigned char *)plain.mutableBytes, &outLen, cipherPtr, cipherLen);
    ctx_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tagPtr);
    dec_fin(ctx, (unsigned char *)plain.mutableBytes + outLen, &finalLen);
    ctx_free(ctx);

    plain.length = cipherLen;
    return plain;
}

#pragma mark - GSA SRP6a 请求 (已验证 4秒一次通过)

- (NSDictionary *)sendGSAServiceRequest:(NSDictionary *)requestDict {
    NSDictionary *rootPlist = @{
        @"Header": @{@"Version": @"1.0.1"},
        @"Request": requestDict
    };
    NSData *bodyData = [NSPropertyListSerialization dataWithPropertyList:rootPlist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];

    BOOL isAppTokensRequest = [requestDict[@"o"] isEqualToString:@"apptokens"];
    NSDictionary *headers = nil;

    if (isAppTokensRequest) {
        headers = @{
            @"Content-Type": @"text/x-xml-plist",
            @"Accept": @"text/x-xml-plist",
            @"User-Agent": @"AuthKit/1 (com.apple.dt.Xcode/3594.4.1)",
            @"X-MMe-Client-Info": @"<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            @"X-Xcode-Version": @"27.0 (27A5218g)",
            @"X-Apple-App-Info": @"com.apple.gs.xcode.auth"
        };
    } else {
        headers = @{
            @"Content-Type": @"text/x-xml-plist",
            @"Accept": @"*/*",
            @"User-Agent": @"AuthKit/1 (com.apple.dt.Xcode/3594.4.1)",
            @"X-MMe-Client-Info": @"<iPhone15,2> <iPhone OS;17.0.3;21A360> <com.apple.akd/1.0 (com.apple.akd/1.0)>"
        };
    }

    int curlExit = 0;
    NSInteger httpStatus = 0;
    NSData *respData = nil;
    for (int attempt = 1; attempt <= 4; attempt++) {
        respData = [self executeCurlRequestWithURL:@"https://gsa.apple.com/grandslam/GsService2"
                                            method:@"POST"
                                           headers:headers
                                          bodyData:bodyData
                                       outExitCode:&curlExit
                                     outHttpStatus:&httpStatus];
        if (respData.length > 0) {
            NSDictionary *parsed = [NSPropertyListSerialization propertyListWithData:respData options:0 format:NULL error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                return parsed[@"Response"] ?: parsed;
            }
        }
        [NSThread sleepForTimeInterval:1.2];
    }

    NSString *rawPreview = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"non-utf8";
    if (rawPreview.length > 100) rawPreview = [rawPreview substringToIndex:100];
    [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-CURL-ERR] HTTP=%ld, exit=%d, len=%lu, raw=%@", (long)httpStatus, curlExit, (unsigned long)respData.length, rawPreview] success:NO];
    return nil;
}

- (void)triggerTrustedDevice2FAPushWithADSID:(NSString *)adsid idmsToken:(NSString *)idmsToken anisette:(NSDictionary *)anisette {
    NSString *rawToken = [NSString stringWithFormat:@"%@:%@", adsid, idmsToken];
    NSString *b64Token = [[rawToken dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];

    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:anisette];
    headers[@"Content-Type"] = @"text/x-xml-plist";
    headers[@"Accept"] = @"text/x-xml-plist";
    headers[@"User-Agent"] = @"AuthKit/1 (com.apple.dt.Xcode/3594.4.1)";
    headers[@"Accept-Language"] = @"zh-cn";
    headers[@"X-Apple-App-Info"] = @"com.apple.gs.xcode.auth";
    headers[@"X-Xcode-Version"] = @"27.0 (27A5218g)";
    headers[@"X-MMe-Client-Info"] = @"<iPhone15,2> <iPhone OS;17.0.3;21A360> <com.apple.akd/1.0 (com.apple.akd/1.0)>";
    headers[@"X-Apple-Identity-Token"] = b64Token;
    NSString *udid = [self realDeviceUDID];
    if (udid.length) headers[@"X-Mme-Device-Id"] = udid;

    [self executeCurlRequestWithURL:@"https://gsa.apple.com/auth/verify/trusteddevice"
                             method:@"GET"
                            headers:headers
                           bodyData:nil
                        outExitCode:NULL
                      outHttpStatus:NULL];
}

- (BOOL)validate2FACodeWithAltSignEndpoint:(NSString *)code adsid:(NSString *)adsid idmsToken:(NSString *)idmsToken anisette:(NSDictionary *)anisette {
    if (!adsid.length || !idmsToken.length || !code.length) return NO;
    NSString *rawToken = [NSString stringWithFormat:@"%@:%@", adsid, idmsToken];
    NSString *b64Token = [[rawToken dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];

    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:anisette];
    headers[@"Content-Type"] = @"text/x-xml-plist";
    headers[@"Accept"] = @"text/x-xml-plist";
    headers[@"User-Agent"] = @"AuthKit/1 (com.apple.dt.Xcode/3594.4.1)";
    headers[@"Accept-Language"] = @"zh-cn";
    headers[@"X-Apple-App-Info"] = @"com.apple.gs.xcode.auth";
    headers[@"X-Xcode-Version"] = @"27.0 (27A5218g)";
    headers[@"X-MMe-Client-Info"] = @"<iPhone15,2> <iPhone OS;17.0.3;21A360> <com.apple.akd/1.0 (com.apple.akd/1.0)>";
    headers[@"X-Apple-Identity-Token"] = b64Token;
    headers[@"security-code"] = code;
    NSString *udid = [self realDeviceUDID];
    if (udid.length) headers[@"X-Mme-Device-Id"] = udid;

    int curlExit = 0;
    NSData *resp = [self executeCurlRequestWithURL:@"https://gsa.apple.com/grandslam/GsService2/validate"
                                            method:@"GET"
                                           headers:headers
                                          bodyData:nil
                                       outExitCode:&curlExit
                                     outHttpStatus:NULL];
    NSDictionary *dict = resp.length ? [NSPropertyListSerialization propertyListWithData:resp options:0 format:NULL error:NULL] : nil;
    NSInteger ec = [dict[@"ec"] integerValue];
    [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-2FA-VALIDATE] 校验6位验证码: ec=%ld, em=%@", (long)ec, dict[@"em"] ?: @"OK"] success:(ec == 0)];
    return (ec == 0);
}

#pragma mark - 完整 GSA SRP6a 握手 + 缓存 196字节 Xcode 令牌 + 请求 /services/QH65B2/

- (void)loginWithAppleID:(NSString *)email
                password:(NSString *)password
           twoFactorCode:(NSString *)twoFactorCode
              completion:(void(^)(BOOL success, BOOL need2FA, NSString *errorMsg))completion {

    if (![self loadOpenSSLCryptoLibrary]) {
        if (completion) completion(NO, NO, @"未找到 OpenSSL libcrypto.dylib，请确认 Sileo 中已安装 openssl");
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *username = [[email stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        NSDictionary *anisette = [[AuraSignEngine sharedEngine] fetchNativeAnisetteHeaders];
        NSString *udid = [self realDeviceUDID];

        NSString *adsid = nil;
        NSString *xcodeToken = nil;

        if ([_cachedEmail isEqualToString:username] && _cachedAdsid.length > 0 && _cachedXcodeToken.length > 0 && twoFactorCode.length == 0) {
            adsid = _cachedAdsid;
            xcodeToken = _cachedXcodeToken;
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-CACHE] 直接复用已兑换成功的 196 字节 Xcode 令牌 (ADSID=%@)", adsid] success:YES];
        } else {
            if (twoFactorCode.length == 6 && _pending2FAAdsid.length && _pending2FAIdmsToken.length) {
                BOOL codeValid = [self validate2FACodeWithAltSignEndpoint:twoFactorCode adsid:_pending2FAAdsid idmsToken:_pending2FAIdmsToken anisette:anisette];
                if (!codeValid) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(NO, YES, @"6 位双重认证码校验未通过，请重新输入");
                    });
                    return;
                }
            }

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

            unsigned char a_bytes[32];
            if (SecRandomCopyBytes(kSecRandomDefault, 32, a_bytes) != 0) {
            arc4random_buf(a_bytes, 32);
        }
            BIGNUM *bn_a = bin2bn(a_bytes, 32, NULL);
            BIGNUM *bn_A = bn_new();
            mod_exp(bn_A, bn_g, bn_a, bn_N, bnCtx);
            NSData *A_padded = [self bnToPaddedData:bn_A padLength:256];

            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-INIT] 正在通过 curl 向 gsa.apple.com 发起 SRP6a 握手 (%@)", username] success:YES];

            NSDictionary *initResp = [self sendGSAServiceRequest:@{
                @"A2k": A_padded,
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

            NSMutableData *gPadded = [NSMutableData dataWithLength:256];
            ((unsigned char *)gPadded.mutableBytes)[255] = 0x02;
            NSMutableData *kInput = [NSMutableData dataWithData:N_data];
            [kInput appendData:gPadded];
            NSData *kHash = [self sha256Data:kInput];
            BIGNUM *bn_k = bin2bn((const unsigned char *)kHash.bytes, 32, NULL);

            BIGNUM *bn_B = bin2bn((const unsigned char *)B_data.bytes, (int)B_data.length, NULL);
            NSData *B_padded = [self bnToPaddedData:bn_B padLength:256];
            NSMutableData *uInput = [NSMutableData dataWithData:A_padded];
            [uInput appendData:B_padded];
            NSData *uHash = [self sha256Data:uInput];
            BIGNUM *bn_u = bin2bn((const unsigned char *)uHash.bytes, 32, NULL);

            NSData *passRawHash = [self sha256Data:[password dataUsingEncoding:NSUTF8StringEncoding]];
            NSData *pbkdfPassInput = passRawHash;
            if ([proto isEqualToString:@"s2k_fo"]) {
                NSMutableString *hexPass = [NSMutableString stringWithCapacity:64];
                const unsigned char *pBytes = (const unsigned char *)passRawHash.bytes;
                for (int idx = 0; idx < 32; idx++) [hexPass appendFormat:@"%02x", pBytes[idx]];
                pbkdfPassInput = [hexPass dataUsingEncoding:NSUTF8StringEncoding];
            }
            unsigned char pbkdfOut[32];
            int pbkdfRet = CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)pbkdfPassInput.bytes, pbkdfPassInput.length,
                                 (const uint8_t *)salt.bytes, salt.length,
                                 kCCPRFHmacAlgSHA256, (uint)iterations, pbkdfOut, 32);
            (void)pbkdfRet;

            NSMutableData *colonPass = [NSMutableData dataWithBytes:":" length:1];
            [colonPass appendBytes:pbkdfOut length:32];
            NSData *innerXHash = [self sha256Data:colonPass];

            NSMutableData *xInput = [NSMutableData dataWithData:salt];
            [xInput appendData:innerXHash];
            NSData *xHash = [self sha256Data:xInput];
            BIGNUM *bn_x = bin2bn((const unsigned char *)xHash.bytes, 32, NULL);

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

            NSData *HN = [self sha256Data:N_data];
            NSData *Hg = [self sha256Data:gPadded];
            unsigned char hXor[32];
            for (int idx = 0; idx < 32; idx++) {
                hXor[idx] = ((const unsigned char *)HN.bytes)[idx] ^ ((const unsigned char *)Hg.bytes)[idx];
            }
            NSData *HI = [self sha256Data:[username dataUsingEncoding:NSUTF8StringEncoding]];

            NSMutableData *m1Input = [NSMutableData dataWithBytes:hXor length:32];
            [m1Input appendData:HI];
            [m1Input appendData:salt];
            [m1Input appendData:A_padded];
            [m1Input appendData:B_padded];
            [m1Input appendData:K_data];
            NSData *M1_data = [self sha256Data:m1Input];

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

            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-COMPLETE] proto=%@, ec=%ld, au=%@, spdLen=%lu, em=%@",
                proto, (long)ec, authType, (unsigned long)spdData.length, em] success:(ec == 0 || spdData.length > 0)];

            if (ec == -22406) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, NO, @"Apple ID 账号或密码不正确 (-22406)，请重新核对密码");
                });
                return;
            }

            NSDictionary *spdDict = nil;
            if ([spdData isKindOfClass:[NSData class]] && spdData.length > 16) {
                NSData *extraKey = [self hmacSHA256WithKey:K_data data:[@"extra data key:" dataUsingEncoding:NSUTF8StringEncoding]];
                NSData *extraIVFull = [self hmacSHA256WithKey:K_data data:[@"extra data iv:" dataUsingEncoding:NSUTF8StringEncoding]];
                NSData *extraIV = [extraIVFull subdataWithRange:NSMakeRange(0, 16)];
                NSData *decSpd = [self aes256CBCDecryptData:spdData key:extraKey iv:extraIV];
                if (decSpd.length) {
                    spdDict = [NSPropertyListSerialization propertyListWithData:decSpd options:0 format:NULL error:NULL];
                }
            }

            adsid = spdDict[@"adsid"] ?: @"";
            NSString *idmsToken = spdDict[@"GsIdmsToken"] ?: @"";
            NSData *skData = spdDict[@"sk"];
            NSData *spdCookie = spdDict[@"c"];

            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-SPD-DEC] 解密 spd: adsid=%@, idmsLen=%lu, skLen=%lu",
                adsid.length ? adsid : @"空", (unsigned long)idmsToken.length, (unsigned long)skData.length] success:(adsid.length > 0)];

            if (adsid.length && idmsToken.length) {
                _pending2FAAdsid = adsid;
                _pending2FAIdmsToken = idmsToken;
            }

            if (([authType containsString:@"SecondaryAuth"] || [authType containsString:@"secondaryAuth"] || ec == -22411) && twoFactorCode.length == 0) {
                if (adsid.length && idmsToken.length) {
                    [self triggerTrustedDevice2FAPushWithADSID:adsid idmsToken:idmsToken anisette:anisette];
                }
                [[AuraSignEngine sharedEngine] appendTimelineLog:@"[GSA-2FA] 已触发苹果向本机推送 6 位验证码弹窗，等待输入" success:YES];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, YES, @"验证码已推送至您的手机屏幕，请输入收到的 6 位数字验证码");
                });
                return;
            }

            if (!adsid.length || !idmsToken.length || ![skData isKindOfClass:[NSData class]]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, (twoFactorCode.length == 0), [NSString stringWithFormat:@"双重认证未完成 (%ld: %@)", (long)ec, em]);
                });
                return;
            }

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

            NSInteger appTokEc = [appTokResp[@"Status"][@"ec"] integerValue];
            NSString *appTokEm = appTokResp[@"Status"][@"em"] ?: @"";
            NSData *etData = appTokResp[@"et"];

            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-APPTOKENS] ec=%ld, em=%@, etLen=%lu",
                (long)appTokEc, appTokEm, (unsigned long)etData.length] success:(etData.length > 0)];

            if ([etData isKindOfClass:[NSData class]] && etData.length > 35) {
                NSData *decEt = [self aes256GCMDecryptETData:etData key:skData];
                if (decEt.length) {
                    NSDictionary *etDict = [NSPropertyListSerialization propertyListWithData:decEt options:0 format:NULL error:NULL];
                    xcodeToken = etDict[@"t"][@"com.apple.gs.xcode.auth"][@"token"];
                }
            }

            if (!xcodeToken.length && [spdDict[@"t"] isKindOfClass:[NSDictionary class]]) {
                xcodeToken = spdDict[@"t"][@"com.apple.gs.xcode.auth"][@"token"];
            }

            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[GSA-XCODE-TOKEN] 兑换 com.apple.gs.xcode.auth 令牌结果: 长度=%lu",
                (unsigned long)xcodeToken.length] success:(xcodeToken.length > 0)];

            if (!xcodeToken.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, NO, [NSString stringWithFormat:@"兑换 Xcode 令牌失败 (%ld: %@)，请稍后重试", (long)appTokEc, appTokEm]);
                });
                return;
            }

            _cachedEmail = username;
            _cachedAdsid = adsid;
            _cachedXcodeToken = xcodeToken;
        }

        // ==================== Step 4: 用真正的 com.apple.gs.xcode.auth 令牌请求 /services/QH65B2/ ====================
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
                if (completion) completion(NO, NO, stepErr.localizedDescription ?: @"获取个人开发者 TeamID 失败，请复制日志查看详情");
            });
            return;
        }
        NSString *teamId = teams[0][@"teamId"];
        sess[@"teamId"] = teamId;

        if (udid.length) {
            [self sendQH65B2Request:@"ios/addDevice.action" bodyDict:@{
                @"teamId": teamId,
                @"deviceNumber": udid,
                @"name": [[UIDevice currentDevice] name] ?: @"iPhone"
            } session:sess outError:NULL];
        }

        NSString *csrContent = [self generatePrivateKeyAndCSRPEMForEmail:username];
        NSError *csrErr = nil;
        NSDictionary *certResp = [self sendQH65B2Request:@"ios/submitDevelopmentCSR.action" bodyDict:@{
            @"teamId": teamId,
            @"csrContent": csrContent,
            @"machineId": [[NSUUID UUID] UUIDString],
            @"machineName": @"AuraSignPro"
        } session:sess outError:&csrErr];

        NSData *derCert = certResp[@"certRequest"][@"certificate"][@"certContent"];

        if (!derCert && csrErr.code == 7460) {
            NSDictionary *listCerts = [self sendQH65B2Request:@"ios/listAllDevelopmentCerts.action" bodyDict:@{@"teamId": teamId} session:sess outError:NULL];
            NSArray *certs = listCerts[@"certificates"];
            if ([certs isKindOfClass:[NSArray class]]) {
                for (NSDictionary *c in certs) {
                    NSString *serial = c[@"serialNumber"];
                    if (serial.length) {
                        [self sendQH65B2Request:@"ios/revokeDevelopmentCert.action" bodyDict:@{@"teamId": teamId, @"serialNumber": serial} session:sess outError:NULL];
                    }
                }
            }
            certResp = [self sendQH65B2Request:@"ios/submitDevelopmentCSR.action" bodyDict:@{
                @"teamId": teamId,
                @"csrContent": csrContent,
                @"machineId": [[NSUUID UUID] UUIDString],
                @"machineName": @"AuraSignPro"
            } session:sess outError:&csrErr];
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

#pragma mark - OpenSSL 证书合成、/services/QH65B2/ 请求 (移除伪造 LU/SRL-NO + 双请求头自动适配)

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
    NSString *urlStr = [NSString stringWithFormat:@"https://developerservices2.apple.com/services/QH65B2/%@?clientId=XABBG36SBA", actionPath];

    // 【关键修复】：不再塞入任何伪造的 X-Apple-I-MD-LU 或 SRL-NO，保持与 08:53 通过校验时完全一致的原生 Anisette 头！
    NSDictionary *baseAnisette = [[AuraSignEngine sharedEngine] fetchNativeAnisetteHeaders];
    NSString *udid = [self realDeviceUDID];

    NSMutableDictionary *fullBody = [NSMutableDictionary dictionaryWithDictionary:bodyDict ?: @{}];
    fullBody[@"clientId"] = @"XABBG36SBA";
    fullBody[@"protocolVersion"] = @"QH65B2";
    fullBody[@"requestId"] = [[[NSUUID UUID] UUIDString] uppercaseString];
    NSData *xmlBodyData = [NSPropertyListSerialization dataWithPropertyList:fullBody format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];

    // 准备两套 Client-Info 组合（组合 1: 与本机 Anisette 一致的 iPhone 标识；组合 2: Mac15,7 标识），哪套返回有效 Plist 且 resultCode==0 就用哪套！
    NSArray *clientProfiles = @[
        @{
            @"ua": @"Xcode",
            @"ci": @"<iPhone15,2> <iPhone OS;17.0.3;21A360> <com.apple.akd/1.0 (com.apple.akd/1.0)>",
            @"xv": @"15.2 (15C500b)"
        },
        @{
            @"ua": @"Xcode",
            @"ci": @"<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            @"xv": @"27.0 (27A5218g)"
        },
        @{
            @"ua": @"AuthKit/1 (com.apple.dt.Xcode/3594.4.1)",
            @"ci": @"<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            @"xv": @"11.2 (11B41)"
        }
    ];

    int curlExit = 0;
    NSInteger httpStatus = 0;
    NSData *respData = nil;
    NSDictionary *respDict = nil;

    for (NSInteger i = 0; i < clientProfiles.count; i++) {
        NSDictionary *prof = clientProfiles[i];
        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:baseAnisette];
        if (udid.length) headers[@"X-Mme-Device-Id"] = udid;
        if ([session[@"adsid"] length]) headers[@"X-Apple-I-Identity-Id"] = session[@"adsid"];
        if ([session[@"xcodeToken"] length]) headers[@"X-Apple-GS-Token"] = session[@"xcodeToken"];
        headers[@"X-Apple-App-Info"] = @"com.apple.gs.xcode.auth";
        headers[@"User-Agent"] = prof[@"ua"];
        headers[@"X-Xcode-Version"] = prof[@"xv"];
        headers[@"X-MMe-Client-Info"] = prof[@"ci"];
        headers[@"Content-Type"] = @"text/x-xml-plist";
        headers[@"Accept"] = @"text/x-xml-plist";

        respData = [self executeCurlRequestWithURL:urlStr
                                            method:@"POST"
                                           headers:headers
                                          bodyData:xmlBodyData
                                       outExitCode:&curlExit
                                     outHttpStatus:&httpStatus];

        if (respData.length > 0) {
            id obj = [NSPropertyListSerialization propertyListWithData:respData options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                respDict = (NSDictionary *)obj;
                NSInteger rc = [respDict[@"resultCode"] integerValue];
                [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[QH65B2-TRY%ld] %@ | HTTP=%ld | resultCode=%ld | keys=%@",
                    (long)(i + 1), actionPath, (long)httpStatus, (long)rc, [respDict.allKeys componentsJoinedByString:@","]] success:(rc == 0)];
                if (rc == 0) break;
            } else {
                NSString *rawStr = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"non-utf8";
                if (rawStr.length > 80) rawStr = [rawStr substringToIndex:80];
                [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[QH65B2-TRY%ld] %@ | HTTP=%ld | 非Plist: %@",
                    (long)(i + 1), actionPath, (long)httpStatus, rawStr] success:NO];
            }
        } else {
            [[AuraSignEngine sharedEngine] appendTimelineLog:[NSString stringWithFormat:@"[QH65B2-TRY%ld] %@ | HTTP=%ld | exit=%d | 响应为空",
                (long)(i + 1), actionPath, (long)httpStatus, curlExit] success:NO];
        }
    }

    if (!respDict) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AuraSign" code:httpStatus userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"苹果开发者中心返回 HTTP %ld，请复制诊断日志查看详情", (long)httpStatus]}];
        }
        return nil;
    }

    NSInteger resultCode = [respDict[@"resultCode"] integerValue];
    NSString *rawResultStr = respDict[@"resultString"] ?: @"";
    NSString *rawUserStr   = respDict[@"userString"] ?: @"";
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
    NSDictionary *listResp = [self sendQH65B2Request:@"ios/listAppIds.action" bodyDict:@{@"teamId": teamId} session:sess outError:NULL];
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
        NSDictionary *addResp = [self sendQH65B2Request:@"ios/addAppId.action" bodyDict:@{
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
    NSDictionary *profResp = [self sendQH65B2Request:@"ios/downloadTeamProvisioningProfile.action" bodyDict:@{
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
