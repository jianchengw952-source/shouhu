#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>
#import "AuraSignEngine.h"
#import "AuraLiquidGlassView.h"

@interface UIImage (AuraSBIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface BBBulletinRequest : NSObject
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *bulletinID;
@property (nonatomic, copy) NSString *recordID;
@property (nonatomic, copy) NSString *publisherBulletinID;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, assign) BOOL clearable;
@end

@interface BBServer : NSObject
- (void)publishBulletinRequest:(id)req destinations:(unsigned long long)dest alwaysToLockScreen:(BOOL)lock;
- (void)_publishBulletinRequest:(id)req forSectionID:(id)sec forDestinations:(unsigned long long)dest;
@end

static BBServer *gAuraBBServer = nil;
static UIWindow *gAuraBannerWindow = nil;

// 在 SpringBoard 顶层弹出与系统完全一致的「灵签 Pro」原生通知横幅
static void AuraShowNativeBannerInSpringBoard(NSString *title, NSString *body) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 尝试同步写入系统 BBServer 通知中心
        if (gAuraBBServer) {
            Class reqCls = objc_getClass("BBBulletinRequest");
            if (reqCls) {
                BBBulletinRequest *req = [[reqCls alloc] init];
                NSString *uuid = [[NSUUID UUID] UUIDString];
                req.sectionID = @"com.aurasign.pro";
                req.title = title ?: @"续签";
                req.message = body ?: @"";
                req.date = [NSDate date];
                req.bulletinID = uuid;
                req.recordID = uuid;
                req.publisherBulletinID = uuid;
                req.clearable = YES;
                if ([gAuraBBServer respondsToSelector:@selector(publishBulletinRequest:destinations:alwaysToLockScreen:)]) {
                    [gAuraBBServer publishBulletinRequest:req destinations:14 alwaysToLockScreen:NO];
                } else if ([gAuraBBServer respondsToSelector:@selector(_publishBulletinRequest:forSectionID:forDestinations:)]) {
                    [gAuraBBServer _publishBulletinRequest:req forSectionID:@"com.aurasign.pro" forDestinations:14];
                }
            }
        }

        // 2. 播放 iOS 原生通知提示音 (1007) 与震动
        AudioServicesPlaySystemSound(1007);

        // 3. 弹出 iOS 17 原生风格「灵签 Pro」顶部横幅窗口 (100% 必弹保障)
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat bannerW = MIN(screenW - 24.0, 390.0);
        CGFloat bannerH = 86.0;
        CGFloat bannerX = (screenW - bannerW) / 2.0;

        if (!gAuraBannerWindow) {
            UIWindowScene *activeScene = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    activeScene = (UIWindowScene *)scene;
                    break;
                }
            }
            if (activeScene) {
                gAuraBannerWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
            } else {
                gAuraBannerWindow = [[UIWindow alloc] initWithFrame:CGRectMake(bannerX, -130, bannerW, bannerH)];
            }
            gAuraBannerWindow.windowLevel = UIWindowLevelStatusBar + 250.0;
            gAuraBannerWindow.backgroundColor = [UIColor clearColor];
            gAuraBannerWindow.clipsToBounds = NO;
        }

        for (UIView *sub in gAuraBannerWindow.subviews) [sub removeFromSuperview];
        gAuraBannerWindow.frame = CGRectMake(bannerX, -130.0, bannerW, bannerH);
        gAuraBannerWindow.hidden = NO;

        AuraLiquidGlassView *pill = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(0, 0, bannerW, bannerH) cornerRadius:24.0];
        pill.tintLevel = 0.35f;

        UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 14, 22, 22)];
        iconView.layer.cornerRadius = 5.5;
        iconView.clipsToBounds = YES;
        UIImage *customIcon = [UIImage imageWithContentsOfFile:AURA_NS_JBROOT(@"/Applications/AuraSignPro.app/AppIcon60x60@3x.png")];
        if (!customIcon && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
            customIcon = [UIImage _applicationIconImageForBundleIdentifier:@"com.aurasign.pro" format:2 scale:[UIScreen mainScreen].scale];
        }
        iconView.image = customIcon;
        [pill addSubview:iconView];

        UILabel *appNameLbl = [[UILabel alloc] initWithFrame:CGRectMake(42, 14, 140, 20)];
        appNameLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        appNameLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        appNameLbl.text = @"续签";
        [pill addSubview:appNameLbl];

        UILabel *nowLbl = [[UILabel alloc] initWithFrame:CGRectMake(bannerW - 64, 14, 48, 20)];
        nowLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        nowLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.50];
        nowLbl.textAlignment = NSTextAlignmentRight;
        nowLbl.text = @"现在";
        [pill addSubview:nowLbl];

        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 37, bannerW - 28, 19)];
        titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.text = title ?: @"续签";
        [pill addSubview:titleLbl];

        UILabel *bodyLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 56, bannerW - 28, 22)];
        bodyLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        bodyLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
        bodyLbl.text = body ?: @"";
        [pill addSubview:bodyLbl];

        [gAuraBannerWindow addSubview:pill];

        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
            gAuraBannerWindow.frame = CGRectMake(bannerX, 50.0, bannerW, bannerH);
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.30 animations:^{
                    gAuraBannerWindow.frame = CGRectMake(bannerX, -130.0, bannerW, bannerH);
                } completion:^(BOOL done) {
                    gAuraBannerWindow.hidden = YES;
                }];
            });
        }];
    });
}

%hook BBServer
- (id)initWithQueue:(id)queue {
    id orig = %orig;
    gAuraBBServer = orig;
    return orig;
}
- (id)init {
    id orig = %orig;
    gAuraBBServer = orig;
    return orig;
}
%end

@interface SBPowerDownViewController : UIViewController
@end

%hook SBPowerDownViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    if (!engine.rebootShieldEnabled) return;

    NSString *summary = nil;
    AuraShieldStatus status = [engine evaluateGlobalShieldStatus:&summary];
    if (status == AuraShieldStatusDanger) {
        UIViewController *hostVC = (UIViewController *)self;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🛑 越狱防失联安全拦截"
                                                                       message:@"检测到您的【Dopamine / Relaxin】苹果证书已过期或属于假签名！\n\n如果现在关机或重启，开机后将无法打开越狱工具！"
                                                                preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"⚡ 立即自动续签并解除拦截 (推荐)"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"⏳ 正在极速续签..."
                                                                                   message:@"正在连接苹果服务器签发 7 天真证书并校验 libmis，请稍候..."
                                                                            preferredStyle:UIAlertControllerStyleAlert];
            [hostVC presentViewController:progressAlert animated:YES completion:^{
                [[AuraSignEngine sharedEngine] performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                    [progressAlert dismissViewControllerAnimated:YES completion:^{
                        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                        [gen notificationOccurred:success ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];

                        NSString *resTitle = success ? @"✅ 续签成功 · 可安全关机" : @"❌ 续签失败 · 切勿关机！";
                        NSString *resMsg = success
                            ? @"越狱工具已签入满血 7 天苹果真证书并通过未越狱开机校验，您现在可以放心拉动滑块关机或重启！"
                            : [NSString stringWithFormat:@"原因：%@\n\n请先取消关机，连接网络后打开「续签」修复后再重启！", message ?: @"网络异常"];

                        UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:resTitle
                                                                                          message:resMsg
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                        [resAlert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
                        [hostVC presentViewController:resAlert animated:YES completion:nil];
                    }];
                }];
            }];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消关机/重启"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        [hostVC presentViewController:alert animated:YES completion:nil];
    }
}

%end

%ctor {
    %init;
    int token = 0;
    notify_register_dispatch("com.aurasign.pro.pushBanner", &token, dispatch_get_main_queue(), ^(int t) {
        NSString *bannerFile = AURA_NS_JBROOT(@"/var/mobile/Library/AuraSignPro/pending_banner.plist");
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:bannerFile];
        if (dict) {
            AuraShowNativeBannerInSpringBoard(dict[@"title"], dict[@"body"]);
        }
    });
}
