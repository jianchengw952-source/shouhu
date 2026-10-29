#pragma once
#import <Foundation/Foundation.h>

@interface AuraAppleDeveloperAPI : NSObject

+ (instancetype)sharedAPI;

- (BOOL)hasValidAccountInKeychain;
- (NSString *)currentAppleIDEmail;
- (NSString *)realDeviceUDID;

- (void)loginWithAppleID:(NSString *)email
                password:(NSString *)password
           twoFactorCode:(NSString *)code
              completion:(void(^)(BOOL success, BOOL need2FA, NSString *errorMsg))completion;

- (NSData *)requestReal7DayProvisioningProfileForBundleID:(NSString *)bundleID
                                                  appName:(NSString *)appName
                                                    error:(NSError **)outError;

- (BOOL)performRealZSignOnAppBundle:(NSString *)appBundlePath
                        profileData:(NSData *)mobileProvisionData
                     injectedDylibs:(NSArray<NSString *> *)dylibPaths
                              error:(NSError **)outError;

- (NSString *)extractDylibFromDebPackage:(NSString *)debPath;

@end
