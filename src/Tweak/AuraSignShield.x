#import <UIKit/UIKit.h>
#import "AuraSignEngine.h"
#import "AuraLiquidGlassView.h"

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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🛑 越狱防失联安全拦截"
                                                                       message:@"检测到您的【Dopamine / Relaxin】苹果证书已过期或属于假签名！\n\n如果现在关机或重启，开机后将无法点开越狱工具！"
                                                                preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"⚡ 立即 1.5秒自动续签并安全重启 (推荐)"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [[AuraSignEngine sharedEngine] performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                [gen impactOccurred];
            }];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消关机/重启"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
    }
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    BOOL isTargetLoader = ([bid.lowercaseString containsString:@"dopamine"] || [bid.lowercaseString containsString:@"relaxin"]);
    if (!isTargetLoader) return;

    UIViewController *selfVC = (UIViewController *)self;
    if (selfVC.parentViewController != nil && ![selfVC isKindOfClass:[UINavigationController class]]) return;
    if ([selfVC.view viewWithTag:992701]) return;

    NSString *summary = nil;
    AuraShieldStatus status = [[AuraSignEngine sharedEngine] evaluateGlobalShieldStatus:&summary];

    CGFloat width = selfVC.view.bounds.size.width - 36.0;
    AuraLiquidGlassView *capsule = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(18.0, selfVC.view.bounds.size.height - 86.0, width, 44.0) cornerRadius:22.0];
    capsule.tag = 992701;
    capsule.accentGlowColor = (status == AuraShieldStatusDanger)
        ? [UIColor colorWithRed:0.75 green:0.12 blue:0.18 alpha:1.0]
        : [UIColor colorWithRed:0.06 green:0.52 blue:0.38 alpha:1.0];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, width - 32, 44)];
    lbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor whiteColor];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.text = (status == AuraShieldStatusDanger)
        ? @"🔴 警告：当前为假签名或已过期 · 请打开灵签Pro一键转正"
        : @"🛡️ 灵签守护中 · 苹果7天真证书有效 (libmis 已校验)";
    [capsule addSubview:lbl];

    [selfVC.view addSubview:capsule];
}

%end
