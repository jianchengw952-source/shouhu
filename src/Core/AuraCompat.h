#pragma once
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string.h>

static inline NSString* AURA_NS_JBROOT(NSString *path) {
    NSString *relPath = path ?: @"";

    // 1. 优先通过 dladdr 检查当前二进制是否运行在 Relaxin (RootHide) 的 .jbroot-XXXX 目录中
    Dl_info info;
    if (dladdr((const void *)&AURA_NS_JBROOT, &info) && info.dli_fname) {
        NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
        NSRange jbrootRange = [selfPath rangeOfString:@"/.jbroot-"];
        if (jbrootRange.location != NSNotFound) {
            NSString *afterPrefix = [selfPath substringFromIndex:jbrootRange.location + 1];
            NSRange slashRange = [afterPrefix rangeOfString:@"/"];
            NSString *jbrootFolder = (slashRange.location != NSNotFound)
                ? [afterPrefix substringToIndex:slashRange.location]
                : afterPrefix;
            NSString *rootDir = [[selfPath substringToIndex:jbrootRange.location] stringByAppendingPathComponent:jbrootFolder];
            return [rootDir stringByAppendingPathComponent:relPath];
        }
    }

    // 2. Dopamine 标准无根越狱环境：直接走原有的 /var/jb 路径（100% 保持不变）
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        return [@"/var/jb" stringByAppendingPathComponent:relPath];
    }

    // 3. 兜底扫描 .jbroot-*
    NSString *containers = @"/var/containers/Bundle/Application";
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:containers error:nil];
    for (NSString *item in items) {
        if ([item hasPrefix:@".jbroot-"]) {
            return [[containers stringByAppendingPathComponent:item] stringByAppendingPathComponent:relPath];
        }
    }
    return [@"/var/jb" stringByAppendingPathComponent:relPath];
}

#define AURA_PREFS_PATH AURA_NS_JBROOT(@"/var/mobile/Library/Preferences/com.aurasign.pro.plist")
#define AURA_VAULT_DIR  AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro/Vault")
