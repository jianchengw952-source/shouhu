#pragma once
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
    #include <roothide.h>
    #define AURA_NS_JBROOT(nsPath) jbroot(nsPath)
#else
    static inline NSString* AURA_NS_JBROOT(NSString *path) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
            return [@"/var/jb" stringByAppendingPathComponent:path];
        }
        NSString *containers = @"/var/containers/Bundle/Application";
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:containers error:nil];
        for (NSString *item in items) {
            if ([item hasPrefix:@".jbroot-"]) {
                return [[containers stringByAppendingPathComponent:item] stringByAppendingPathComponent:path];
            }
        }
        return [@"/var/jb" stringByAppendingPathComponent:path];
    }
#endif

#define AURA_PREFS_PATH AURA_NS_JBROOT(@"/var/mobile/Library/Preferences/com.aurasign.pro.plist")
#define AURA_VAULT_DIR  AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro/Vault")
