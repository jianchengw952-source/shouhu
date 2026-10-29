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

// 调起 iOS 系统原生 Apple ID 登录与双重认证弹窗，并向苹果服务器验明 TeamID 与签发 1 年期真证书
- (void)authenticateWithSystemSheetFromViewController:(UIViewController *)presentingVC
                                         initialEmail:(NSString *)email
                                      initialPassword:(NSString *)password
                                           completion:(void(^)(BOOL success, NSString *errorMsg))completion;

// 真实走完苹果 QH65B2 协议：查找/注册 AppID 主键 -> 下载苹果官方 CMS 签名的 7 天 .mobileprovision
- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                        outResolvedBundle:(NSString **)outResolvedBundleID
                                                    error:(NSError **)outError;

// 调用真实 zsign 将苹果真证书 (.p12) 与 7 天描述文件签入应用包
- (BOOL)performRealZSignOnAppBundle:(NSString *)appBundlePath
                        profileData:(NSData *)mobileProvisionData
                     injectedDylibs:(NSArray<NSString *> *)dylibPaths
                              error:(NSError **)outError;

- (NSString *)extractDylibFromDebPackage:(NSString *)debPath;

@end
