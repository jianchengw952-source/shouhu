#import <UIKit/UIKit.h>
#import "AuraSignEngine.h"

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
                            : [NSString stringWithFormat:@"原因：%@\n\n请先取消关机，连接网络后打开「灵签 Pro」修复后再重启！", message ?: @"网络异常"];

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
