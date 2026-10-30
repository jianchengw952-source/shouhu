// src/Core/AuraAppleDeveloperAPI.h
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface AuraAppleDeveloperAPI : NSObject

+ (instancetype)sharedAPI;

- (BOOL)hasValidAccountInKeychain;
- (NSString *)currentAppleIDEmail;
- (NSString *)currentTeamID;
- (NSString *)realDeviceUDID;
- (void)logoutCurrentAccount;
- (NSString *)availableAppIdQuotaText;

// 标准 Apple GSA SRP6a 认证 + 兑换 com.apple.gs.xcode.auth 开发者专属令牌
// 当 twoFactorCode 为 nil 时执行第1步并触发苹果本机 6位验证码弹窗 (回调 need2FA = YES)
// 当传入 6位 twoFactorCode 时完成第2步兑换 Xcode 令牌并签发 1年期真证书
- (void)loginWithAppleID:(NSString *)email
                password:(NSString *)password
           twoFactorCode:(NSString *)twoFactorCode
              completion:(void(^)(BOOL success, BOOL need2FA, NSString *errorMsg))completion;

- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                        outResolvedBundle:(NSString **)outResolvedBundleID
                                                    error:(NSError **)outError;

- (BOOL)performRealZSignOnAppBundle:(NSString *)appBundlePath
                        profileData:(NSData *)mobileProvisionData
                              error:(NSError **)outError;

@end
