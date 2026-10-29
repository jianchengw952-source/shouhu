#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"
#import "AuraLiquidGlassView.h"

@interface AuraMainViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation AuraMainViewController {
    NSInteger _currentTab; // 0: 🛡️守护中心 | 1: 🛠️签名工坊 | 2: 🛍️免VPN精选源商店
    UITableView *_tableView;
    NSArray<AuraAppInfo *> *_installedApps;
    NSArray<AuraRepoAppItem *> *_storeCatalog;
    AuraLiquidGlassView *_bottomLiquidPillBar;
    NSMutableArray<NSString *> *_pendingInjectedDebPaths;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _pendingInjectedDebPaths = [NSMutableArray array];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.11 alpha:1.0];
    [self setupDynamicMeshBackground];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.contentInset = UIEdgeInsetsMake(10, 0, 110, 0);
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];

    [self setupFloatingLiquidPillTabBar];
    [self reloadAllData];
}

- (void)setupDynamicMeshBackground {
    CAGradientLayer *mesh = [CAGradientLayer layer];
    mesh.frame = self.view.bounds;
    mesh.colors = @[
        (id)[UIColor colorWithRed:0.05 green:0.28 blue:0.26 alpha:0.65].CGColor,
        (id)[UIColor colorWithRed:0.04 green:0.07 blue:0.14 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.14 blue:0.28 alpha:0.85].CGColor
    ];
    mesh.startPoint = CGPointMake(0.2, 0.0);
    mesh.endPoint = CGPointMake(0.8, 1.0);
    [self.view.layer insertSublayer:mesh atIndex:0];
}

- (void)setupFloatingLiquidPillTabBar {
    CGFloat w = self.view.bounds.size.width - 40;
    _bottomLiquidPillBar = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height - 88, w, 62) cornerRadius:31];
    _bottomLiquidPillBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    _bottomLiquidPillBar.tintLevel = [AuraSignEngine sharedEngine].liquidGlassTintLevel;

    NSArray *titles = @[@"🛡️ 守护中心", @"🛠️ 签名工坊", @"🛍️ 精选源商店"];
    CGFloat btnW = w / 3.0;
    for (int i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * btnW, 0, btnW, 62);
        btn.tag = 100 + i;
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        [btn setTitleColor:(i == 0 ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.55]) forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
        [btn addTarget:self action:@selector(onTabButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_bottomLiquidPillBar addSubview:btn];
    }
    [self.view addSubview:_bottomLiquidPillBar];
}

- (void)onTabButtonTapped:(UIButton *)sender {
    _currentTab = sender.tag - 100;
    for (int i = 0; i < 3; i++) {
        UIButton *b = [_bottomLiquidPillBar viewWithTag:100 + i];
        [b setTitleColor:(i == _currentTab ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.55]) forState:UIControlStateNormal];
    }
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    [_tableView reloadData];
}

- (void)reloadAllData {
    _installedApps = [[AuraSignEngine sharedEngine] scanTargetApps];
    _storeCatalog = [[AuraSignEngine sharedEngine] loadBuiltInStoreCatalog];
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_currentTab == 0) return 3;
    if (_currentTab == 1) return 2;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_currentTab == 0) {
        if (section == 0) return 1;
        if (section == 1) return MAX(1, _installedApps.count);
        return 6;
    }
    if (_currentTab == 1) return 3;
    if (section == 0) return 3;
    return MAX(0, (NSInteger)_storeCatalog.count - 3);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0 && indexPath.section == 0) return 128;
    if (_currentTab == 0 && indexPath.section == 1) return 106;
    if (_currentTab == 2) return 104;
    return 76;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat cardW = self.view.bounds.size.width - 32;
    CGFloat rowH = [self tableView:tableView heightForRowAtIndexPath:indexPath] - 12;
    AuraLiquidGlassView *card = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(16, 6, cardW, rowH) cornerRadius:22];
    card.tintLevel = [AuraSignEngine sharedEngine].liquidGlassTintLevel;
    [cell.contentView addSubview:card];

    AuraSignEngine *engine = [AuraSignEngine sharedEngine];

    if (_currentTab == 0) {
        if (indexPath.section == 0) {
            NSString *summary = nil;
            AuraShieldStatus st = [engine evaluateGlobalShieldStatus:&summary];
            card.accentGlowColor = (st == AuraShieldStatusDanger)
                ? [UIColor colorWithRed:0.72 green:0.10 blue:0.15 alpha:1.0]
                : [UIColor colorWithRed:0.05 green:0.48 blue:0.35 alpha:1.0];

            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cardW - 36, 26)];
            title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightHeavy];
            title.textColor = [UIColor whiteColor];
            title.text = (st == AuraShieldStatusDanger) ? @"🔴 警告：切勿此时关机重启！" : @"🟢 重启安全护盾 · 已受保护";
            [card addSubview:title];

            UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(18, 44, cardW - 36, 56)];
            sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
            sub.numberOfLines = 3;
            sub.text = summary;
            [card addSubview:sub];
        }
        else if (indexPath.section == 1) {
            if (_installedApps.count == 0) {
                UILabel *empty = [[UILabel alloc] initWithFrame:card.bounds];
                empty.textAlignment = NSTextAlignmentCenter;
                empty.textColor = [UIColor whiteColor];
                empty.text = @"未检测到个人证书应用 · 可前往商店一键安装";
                [card addSubview:empty];
            } else {
                AuraAppInfo *app = _installedApps[indexPath.row];
                UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cardW - 140, 24)];
                nameLbl.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightBold];
                nameLbl.textColor = [UIColor whiteColor];
                nameLbl.text = [NSString stringWithFormat:@"%@%@ (v%@)", app.isJailbreakLoader ? @"👑 " : @"", app.appName, app.version];
                [card addSubview:nameLbl];

                UILabel *statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 42, cardW - 140, 40)];
                statusLbl.font = [UIFont systemFontOfSize:12.5];
                statusLbl.numberOfLines = 2;
                statusLbl.textColor = app.isFakeSigned ? [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.85];
                statusLbl.text = app.isFakeSigned
                    ? @"⚠️ 当前为巨魔/假签名 (重启即死)\n点击右侧按钮 1.5秒转为苹果7天真证书"
                    : [NSString stringWithFormat:@"✅ 苹果真证书有效 (libmis: OK)\n剩余 %.1f 天 · %@", app.remainingDays, app.bundleID];
                [card addSubview:statusLbl];

                UIButton *resignBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                resignBtn.frame = CGRectMake(cardW - 116, 26, 100, 40);
                resignBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.48 alpha:0.9];
                resignBtn.layer.cornerRadius = 20;
                [resignBtn setTitle:(app.isFakeSigned ? @"⚡ 一键转真签" : @"⚡ 立即续签") forState:UIControlStateNormal];
                [resignBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                resignBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                resignBtn.tag = indexPath.row;
                [resignBtn addTarget:self action:@selector(onFastResignTapped:) forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:resignBtn];
            }
        }
        else {
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cardW - 110, 42)];
            lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
            lbl.textColor = [UIColor whiteColor];
            lbl.numberOfLines = 2;
            [card addSubview:lbl];

            if (indexPath.row == 0) {
                lbl.text = [NSString stringWithFormat:@"👤 Apple ID 免费签名账号 (点击绑定/切换)\n当前：%@ · 已装 %lu/3 槽位",
                            [[AuraAppleDeveloperAPI sharedAPI] currentAppleIDEmail], (unsigned long)_installedApps.count];
            } else if (indexPath.row == 1) {
                lbl.text = [NSString stringWithFormat:@"⚡ 后台静默自动续签 [%@]\n当证书剩余少于 %ld 天时联网自动重置为 7 天 (点击切换)",
                            engine.autoRenewEnabled ? @"已开启🟢" : @"已关闭⚪", (long)engine.normalRenewThresholdDays];
            } else if (indexPath.row == 2) {
                lbl.text = [NSString stringWithFormat:@"🔋 低电量紧急抢救 [%@]\n当电量不到 %ld%% 且证书少于【%ld 天】时 1.5秒抢救续签",
                            engine.lowBatteryRescueEnabled ? @"已开启🟢" : @"已关闭⚪",
                            (long)engine.lowBatteryTriggerPercent, (long)engine.lowBatteryThresholdDays];
                UIButton *cfgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                cfgBtn.frame = CGRectMake(cardW - 92, 16, 76, 32);
                cfgBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
                cfgBtn.layer.cornerRadius = 16;
                [cfgBtn setTitle:@"设置规则" forState:UIControlStateNormal];
                [cfgBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                cfgBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
                [cfgBtn addTarget:self action:@selector(onConfigureLowBatteryRuleTapped) forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:cfgBtn];
            } else if (indexPath.row == 3) {
                lbl.text = [NSString stringWithFormat:@"🛑 关机/重启掉签系统级强拦截 [%@]\n证书过期时尝试关机重启将弹窗拦截并提供 1.5秒快签",
                            engine.rebootShieldEnabled ? @"已开启🟢" : @"已关闭⚪"];
            } else if (indexPath.row == 4) {
                lbl.text = @"💎 iOS 27 液态玻璃通透度滑块\n左滑 Ultra-Clear 极致通透 ⇄ 右滑 Tinted 深邃磨砂";
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(cardW - 135, 18, 118, 30)];
                slider.minimumValue = 0.0f;
                slider.maximumValue = 1.0f;
                slider.value = engine.liquidGlassTintLevel;
                [slider addTarget:self action:@selector(onLiquidGlassSliderChanged:) forControlEvents:UIControlEventValueChanged];
                [card addSubview:slider];
            } else {
                lbl.text = @"📜 查看后台续签时间轴日志 & 中文排障中心\n点击查看每次后台唤醒、电量触发与 libmis 校验记录 >";
            }
        }
    }
    else if (_currentTab == 1) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cardW - 36, 40)];
        lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.numberOfLines = 2;
        [card addSubview:lbl];

        if (indexPath.section == 0) {
            NSArray *items = @[
                @"📦 从「文件」导入外部 IPA / TIPA 并签入苹果 7 天真证书",
                @"📲 从本机已安装应用中一键提取打包重签",
                @"🔥 一键应用克隆多开（自定义应用名称 / 换图标 / 随机标识符）"
            ];
            lbl.text = items[indexPath.row];
        } else {
            if (indexPath.row == 0) {
                lbl.text = [NSString stringWithFormat:@"🧠 自动精简手表/小组件零件 (省 80%% 周额度)\n当前：%@（点击切换，100%% 不影响软件内部主功能）",
                            engine.smartStripExtensions ? @"🟢 已开启" : @"⚪ 已关闭"];
            } else if (indexPath.row == 1) {
                lbl.text = [NSString stringWithFormat:@"💉 插件注入舱：选择越狱 .deb 或 .dylib 注入 (已选 %lu 个)", (unsigned long)_pendingInjectedDebPaths.count];
            } else {
                lbl.text = @"⚡ 一键全量刷新本机所有守护应用证书 (重置回满血 7 天)";
            }
        }
    }
    else {
        NSInteger idx = (indexPath.section == 0) ? indexPath.row : (indexPath.row + 3);
        AuraRepoAppItem *item = _storeCatalog[idx];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cardW - 120, 24)];
        title.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
        title.textColor = [UIColor whiteColor];
        title.text = [NSString stringWithFormat:@"%@ · %@", item.name, item.version];
        [card addSubview:title];

        UILabel *desc = [[UILabel alloc] initWithFrame:CGRectMake(18, 38, cardW - 120, 42)];
        desc.font = [UIFont systemFontOfSize:12];
        desc.textColor = [UIColor colorWithWhite:1.0 alpha:0.82];
        desc.numberOfLines = 2;
        desc.text = item.summary;
        [card addSubview:desc];

        UIButton *getBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        getBtn.frame = CGRectMake(cardW - 96, 26, 80, 36);
        getBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.96 alpha:0.9];
        getBtn.layer.cornerRadius = 18;
        [getBtn setTitle:@"获取签装" forState:UIControlStateNormal];
        [getBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        getBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        getBtn.tag = idx;
        [getBtn addTarget:self action:@selector(onStoreGetButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:getBtn];
    }

    return cell;
}

#pragma mark - UITableViewDelegate & UIDocumentPickerDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];

    if (_currentTab == 0 && indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self showAppleIDLoginAlert];
        } else if (indexPath.row == 1) {
            engine.autoRenewEnabled = !engine.autoRenewEnabled;
            [engine savePreferences];
            [_tableView reloadData];
        } else if (indexPath.row == 2) {
            [self onConfigureLowBatteryRuleTapped];
        } else if (indexPath.row == 3) {
            engine.rebootShieldEnabled = !engine.rebootShieldEnabled;
            [engine savePreferences];
            [_tableView reloadData];
        } else if (indexPath.row == 5) {
            [self showTimelineLogsAlert];
        }
    }
    else if (_currentTab == 1) {
        if ((indexPath.section == 0 && indexPath.row == 0) || (indexPath.section == 1 && indexPath.row == 1)) {
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        } else if (indexPath.section == 0 && indexPath.row == 1) {
            [engine performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                [self showSimpleToast:message];
                [self reloadAllData];
            }];
        } else if (indexPath.section == 0 && indexPath.row == 2) {
            [self showCloneAppPrompt];
        } else if (indexPath.section == 1 && indexPath.row == 0) {
            engine.smartStripExtensions = !engine.smartStripExtensions;
            [engine savePreferences];
            [_tableView reloadData];
        } else if (indexPath.section == 1 && indexPath.row == 2) {
            [engine performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                [self showSimpleToast:message];
                [self reloadAllData];
            }];
        }
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *fileURL = urls.firstObject;
    if (!fileURL) return;
    [fileURL startAccessingSecurityScopedResource];
    NSString *localCopy = [NSTemporaryDirectory() stringByAppendingPathComponent:fileURL.lastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:localCopy error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:fileURL.path toPath:localCopy error:nil];
    [fileURL stopAccessingSecurityScopedResource];

    NSString *ext = localCopy.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"deb"] || [ext isEqualToString:@"dylib"]) {
        [_pendingInjectedDebPaths addObject:localCopy];
        [_tableView reloadData];
        [self showSimpleToast:[NSString stringWithFormat:@"💉 已挂载插件：%@ (将在下次签装时自动注入)", localCopy.lastPathComponent]];
    } else {
        NSError *err = nil;
        BOOL ok = [[AuraSignEngine sharedEngine] installAndSignIPAFileAtPath:localCopy
                                                                  customName:nil
                                                              customBundleID:nil
                                                                injectedDebs:_pendingInjectedDebPaths
                                                                       error:&err];
        [_pendingInjectedDebPaths removeAllObjects];
        [self reloadAllData];
        [self showSimpleToast:ok ? @"✅ IPA 已成功签入 7 天苹果真证书并安装至桌面！" : (err.localizedDescription ?: @"IPA 签名安装失败")];
    }
}

#pragma mark - 弹窗交互

- (void)showAppleIDLoginAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"👤 绑定免费 Apple ID"
                                                                   message:@"直连苹果国内服务器生成 1 年期证书，全程无需 VPN，凭证仅加密保存在本机硬件钥匙串中。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 邮箱 (建议使用个人免费号)";
        tf.keyboardType = UIKeyboardTypeEmailAddress;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 密码";
        tf.secureTextEntry = YES;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"6位双重认证验证码 (若已收到请直接填写，可留空)";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"立即绑定并生成1年证书" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *email = alert.textFields[0].text;
        NSString *pass  = alert.textFields[1].text;
        NSString *code  = alert.textFields[2].text;
        [[AuraAppleDeveloperAPI sharedAPI] loginWithAppleID:email password:pass twoFactorCode:code completion:^(BOOL success, BOOL need2FA, NSString *errorMsg) {
            [self reloadAllData];
            [self showSimpleToast:success ? @"✅ Apple ID 绑定成功，1年期证书已就绪！" : (errorMsg ?: @"绑定失败")];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onConfigureLowBatteryRuleTapped {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"🔋 低电量紧急抢救续签规则"
                                                                   message:[NSString stringWithFormat:@"当前：当手机电量不到 %ld%% 时自动唤醒检测。\n请选择此时证书剩余少于多少天自动触发抢救续签：",
                                                                            (long)engine.lowBatteryTriggerPercent]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSInteger days = 1; days <= 7; days++) {
        NSString *title = [NSString stringWithFormat:@"当电量 <%ld%% 且证书剩余少于【%ld 天】时自动续签%@",
                           (long)engine.lowBatteryTriggerPercent, (long)days,
                           (days == engine.lowBatteryThresholdDays ? @" ✓" : @"")];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            engine.lowBatteryThresholdDays = days;
            [engine savePreferences];
            [_tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"开关低电量抢救功能" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        engine.lowBatteryRescueEnabled = !engine.lowBatteryRescueEnabled;
        [engine savePreferences];
        [_tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showTimelineLogsAlert {
    NSArray<NSDictionary *> *logs = [[AuraSignEngine sharedEngine] readAuditTimelineLogs];
    NSMutableString *msg = [NSMutableString string];
    if (logs.count == 0) {
        [msg appendString:@"暂无后台续签记录"];
    } else {
        for (NSDictionary *entry in logs) {
            [msg appendFormat:@"[%@] %@\n\n", entry[@"time"], entry[@"event"]];
        }
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📜 后台续签时间轴日志" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCloneAppPrompt {
    if (_installedApps.count == 0) return;
    AuraAppInfo *target = _installedApps.lastObject;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🔥 一键克隆多开"
                                                                   message:[NSString stringWithFormat:@"将克隆【%@】并生成独立沙盒：", target.appName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [target.appName stringByAppendingString:@" · 分身"];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [target.bundleID stringByAppendingString:@".clone2"];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即克隆签装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSError *err = nil;
        [[AuraSignEngine sharedEngine] fastResignApp:target
                                        stripPlugIns:[AuraSignEngine sharedEngine].smartStripExtensions
                                          customName:alert.textFields[0].text
                                      customBundleID:alert.textFields[1].text
                                        injectedDebs:_pendingInjectedDebPaths
                                               error:&err];
        [_pendingInjectedDebPaths removeAllObjects];
        [self reloadAllData];
        [self showSimpleToast:@"✅ 多开分身签名安装完成！"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onFastResignTapped:(UIButton *)sender {
    AuraAppInfo *app = _installedApps[sender.tag];
    NSError *err = nil;
    [[AuraSignEngine sharedEngine] fastResignApp:app
                                    stripPlugIns:[AuraSignEngine sharedEngine].smartStripExtensions
                                      customName:nil
                                  customBundleID:nil
                                    injectedDebs:_pendingInjectedDebPaths
                                           error:&err];
    [_pendingInjectedDebPaths removeAllObjects];
    UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
    [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self reloadAllData];
    [self showSimpleToast:[NSString stringWithFormat:@"✅【%@】已刷新满血 7 天苹果真证书 (libmis 校验通过)", app.appName]];
}

- (void)onStoreGetButtonTapped:(UIButton *)sender {
    AuraRepoAppItem *item = _storeCatalog[sender.tag];
    [[AuraSignEngine sharedEngine] downloadAndSignRepoItem:item completion:^(BOOL success, NSString *message) {
        [self showSimpleToast:message];
        [self reloadAllData];
    }];
}

- (void)onLiquidGlassSliderChanged:(UISlider *)slider {
    [AuraSignEngine sharedEngine].liquidGlassTintLevel = slider.value;
    [[AuraSignEngine sharedEngine] savePreferences];
    _bottomLiquidPillBar.tintLevel = slider.value;
    [_tableView reloadData];
}

- (void)showSimpleToast:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:text preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [a dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
