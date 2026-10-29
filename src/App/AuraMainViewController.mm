// src/App/AuraMainViewController.mm (全面重做 UI 与两步登录交互版)
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"
#import "AuraLiquidGlassView.h"

// 声明系统获取已安装应用真实高清图标私有接口
@interface UIImage (AuraAppIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface AuraMainViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation AuraMainViewController {
    NSInteger _currentTab; // 0: 🛡️守护中心 | 1: 🛠️签名工坊 | 2: 🛍️精选源商店
    UIView *_topHeaderBar;
    UILabel *_headerTitleLabel;
    UILabel *_headerSubLabel;
    UITableView *_tableView;
    NSArray<AuraAppInfo *> *_installedApps;
    NSArray<AuraRepoAppItem *> *_storeCatalog;
    AuraLiquidGlassView *_bottomLiquidPillBar;
    UIView *_tabActiveIndicator;
    NSMutableArray<NSString *> *_pendingInjectedDebPaths;
    UIView *_loadingOverlay;
    UILabel *_loadingTextLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _pendingInjectedDebPaths = [NSMutableArray array];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.11 alpha:1.0];
    [self setupDynamicMeshBackground];
    [self setupTopHeaderBar];

    CGFloat topY = 104.0;
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY) style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 115, 0);
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
        (id)[UIColor colorWithRed:0.06 green:0.32 blue:0.30 alpha:0.70].CGColor,
        (id)[UIColor colorWithRed:0.04 green:0.07 blue:0.14 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.16 blue:0.32 alpha:0.90].CGColor
    ];
    mesh.startPoint = CGPointMake(0.1, 0.0);
    mesh.endPoint = CGPointMake(0.9, 1.0);
    [self.view.layer insertSublayer:mesh atIndex:0];
}

// 顶部安全区大标题栏（完美避开刘海屏/灵动岛状态栏）
- (void)setupTopHeaderBar {
    _topHeaderBar = [[UIView alloc] initWithFrame:CGRectMake(0, 48, self.view.bounds.size.width, 54)];
    _topHeaderBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 2, 240, 28)];
    _headerTitleLabel.font = [UIFont systemFontOfSize:23 weight:UIFontWeightHeavy];
    _headerTitleLabel.textColor = [UIColor whiteColor];
    _headerTitleLabel.text = @"灵签 Pro · 守护中心";
    [_topHeaderBar addSubview:_headerTitleLabel];

    _headerSubLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 30, 260, 18)];
    _headerSubLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _headerSubLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    _headerSubLabel.text = @"Dopamine & Relaxin 全自动 7 天真证书保活";
    [_topHeaderBar addSubview:_headerSubLabel];

    UIButton *logBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    logBtn.frame = CGRectMake(self.view.bounds.size.width - 96, 10, 78, 32);
    logBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    logBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    logBtn.layer.cornerRadius = 16;
    [logBtn setTitle:@"📜 日志" forState:UIControlStateNormal];
    [logBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    logBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [logBtn addTarget:self action:@selector(showTimelineLogsAlert) forControlEvents:UIControlEventTouchUpInside];
    [_topHeaderBar addSubview:logBtn];

    [self.view addSubview:_topHeaderBar];
}

// 底部悬浮水滴导航栏（带液态选中滑块背景）
- (void)setupFloatingLiquidPillTabBar {
    CGFloat w = self.view.bounds.size.width - 36;
    _bottomLiquidPillBar = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(18, self.view.bounds.size.height - 86, w, 60) cornerRadius:30];
    _bottomLiquidPillBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    _bottomLiquidPillBar.tintLevel = [AuraSignEngine sharedEngine].liquidGlassTintLevel;

    CGFloat btnW = w / 3.0;
    _tabActiveIndicator = [[UIView alloc] initWithFrame:CGRectMake(6, 6, btnW - 12, 48)];
    _tabActiveIndicator.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.48 alpha:0.42];
    _tabActiveIndicator.layer.cornerRadius = 24;
    [_bottomLiquidPillBar addSubview:_tabActiveIndicator];

    NSArray *titles = @[@"🛡️ 守护中心", @"🛠️ 签名工坊", @"🛍️ 精选商店"];
    for (int i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * btnW, 0, btnW, 60);
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
    NSArray *headerTitles = @[@"灵签 Pro · 守护中心", @"灵签 Pro · 签名工坊", @"灵签 Pro · 精选源商店"];
    _headerTitleLabel.text = headerTitles[_currentTab];

    CGFloat btnW = _bottomLiquidPillBar.bounds.size.width / 3.0;
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
        _tabActiveIndicator.frame = CGRectMake(_currentTab * btnW + 6, 6, btnW - 12, 48);
    } completion:nil];

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

#pragma mark - 居中毛玻璃加载转圈框 (防止异步操作时界面无反馈)

- (void)showLoadingHUD:(NSString *)text {
    if (!_loadingOverlay) {
        _loadingOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
        _loadingOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];

        AuraLiquidGlassView *box = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - 210)/2.0, (self.view.bounds.size.height - 120)/2.0, 210, 120) cornerRadius:24];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        spinner.color = [UIColor whiteColor];
        spinner.center = CGPointMake(105, 45);
        [spinner startAnimating];
        [box addSubview:spinner];

        _loadingTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 76, 186, 34)];
        _loadingTextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _loadingTextLabel.textColor = [UIColor whiteColor];
        _loadingTextLabel.textAlignment = NSTextAlignmentCenter;
        _loadingTextLabel.numberOfLines = 2;
        [box addSubview:_loadingTextLabel];

        [_loadingOverlay addSubview:box];
    }
    _loadingTextLabel.text = text ?: @"正在处理...";
    [self.view addSubview:_loadingOverlay];
}

- (void)hideLoadingHUD {
    [_loadingOverlay removeFromSuperview];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_currentTab == 0) return 4; // 0:护盾 | 1:AppleID账号卡片 | 2:已装应用列表 | 3:原生UISwitch开关设置
    if (_currentTab == 1) return 2;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_currentTab == 0) {
        if (section == 1) return @"  👤 APPLE ID 免费签名凭证";
        if (section == 2) return @"  👑 越狱工具与已守护应用 (最多 3 个真证书槽位)";
        if (section == 3) return @"  ⚙️ 自动化续签与防失联安全防线";
    } else if (_currentTab == 1) {
        return (section == 0) ? @"  📦 IPA 导入与克隆多开" : @"  💉 插件注入与智能省额度设置";
    } else {
        return (section == 0) ? @"  👑 越狱官方最新版免 VPN 急救舱" : @"  🔥 全网精选免翻墙直装软件源";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_currentTab == 0) {
        if (section == 0) return 1;
        if (section == 1) return 1;
        if (section == 2) return MAX(1, _installedApps.count);
        return 5; // 0:自动续签开关 | 1:低电量开关 | 2:低电量规则调节 | 3:关机拦截开关 | 4:液态玻璃滑块
    }
    if (_currentTab == 1) return 3;
    if (section == 0) return 3;
    return MAX(0, (NSInteger)_storeCatalog.count - 3);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0) {
        if (indexPath.section == 0) return 118;
        if (indexPath.section == 1) return 82;
        if (indexPath.section == 2) return 112;
        return 72;
    }
    if (_currentTab == 2) return 102;
    return 76;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat cardW = self.view.bounds.size.width - 32;
    CGFloat rowH = [self tableView:tableView heightForRowAtIndexPath:indexPath] - 10;
    AuraLiquidGlassView *card = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(16, 5, cardW, rowH) cornerRadius:20];
    card.tintLevel = [AuraSignEngine sharedEngine].liquidGlassTintLevel;
    [cell.contentView addSubview:card];

    AuraSignEngine *engine = [AuraSignEngine sharedEngine];

    // ==================== Tab 0: 🛡️ 守护中心 ====================
    if (_currentTab == 0) {
        // Section 0: 顶部安全护盾
        if (indexPath.section == 0) {
            NSString *summary = nil;
            AuraShieldStatus st = [engine evaluateGlobalShieldStatus:&summary];
            card.accentGlowColor = (st == AuraShieldStatusDanger)
                ? [UIColor colorWithRed:0.75 green:0.12 blue:0.18 alpha:1.0]
                : [UIColor colorWithRed:0.06 green:0.52 blue:0.38 alpha:1.0];

            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cardW - 36, 24)];
            title.font = [UIFont systemFontOfSize:17.5 weight:UIFontWeightHeavy];
            title.textColor = [UIColor whiteColor];
            title.text = (st == AuraShieldStatusDanger) ? @"🔴 警告：切勿此时关机重启！" : @"🟢 重启安全护盾 · 已受保护";
            [card addSubview:title];

            UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(18, 42, cardW - 36, 54)];
            sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
            sub.numberOfLines = 3;
            sub.text = summary;
            [card addSubview:sub];
        }
        // Section 1: Apple ID 独立登录卡片 (带醒目按钮)
        else if (indexPath.section == 1) {
            BOOL loggedIn = [[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain];
            UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cardW - 126, 22)];
            t.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
            t.textColor = [UIColor whiteColor];
            t.text = loggedIn ? [[AuraAppleDeveloperAPI sharedAPI] currentAppleIDEmail] : @"尚未绑定 Apple ID";
            [card addSubview:t];

            UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(18, 38, cardW - 126, 22)];
            s.font = [UIFont systemFontOfSize:12];
            s.textColor = loggedIn ? [UIColor colorWithRed:0.4 green:0.95 blue:0.65 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.7];
            s.text = loggedIn
                ? [NSString stringWithFormat:@"✓ 1年期证书有效 · 已用 %lu/3 个签名槽位", (unsigned long)_installedApps.count]
                : @"绑定个人免费账号以激活 7 天真证书自动续签";
            [card addSubview:s];

            UIButton *loginBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            loginBtn.frame = CGRectMake(cardW - 102, 18, 86, 36);
            loginBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.56 blue:0.98 alpha:0.95];
            loginBtn.layer.cornerRadius = 18;
            [loginBtn setTitle:(loggedIn ? @"切换账号" : @"立即登录") forState:UIControlStateNormal];
            [loginBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            loginBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            [loginBtn addTarget:self action:@selector(showStep1AppleIDLoginAlert) forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:loginBtn];
        }
        // Section 2: 已守护应用卡片 (带真实桌面图标 + 7天彩色进度条 + 一键续签按钮)
        else if (indexPath.section == 2) {
            if (_installedApps.count == 0) {
                UILabel *empty = [[UILabel alloc] initWithFrame:card.bounds];
                empty.textAlignment = NSTextAlignmentCenter;
                empty.textColor = [UIColor whiteColor];
                empty.text = @"未检测到个人证书应用 · 可在【精选商店】一键安装";
                [card addSubview:empty];
            } else {
                AuraAppInfo *app = _installedApps[indexPath.row];

                // 读取并展示应用真实的桌面图标
                UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 16, 52, 52)];
                iconView.layer.cornerRadius = 12;
                iconView.clipsToBounds = YES;
                iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
                if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
                    UIImage *appIcon = [UIImage _applicationIconImageForBundleIdentifier:app.bundleID format:2 scale:[UIScreen mainScreen].scale];
                    if (appIcon) iconView.image = appIcon;
                }
                [card addSubview:iconView];

                UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(78, 12, cardW - 186, 22)];
                nameLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
                nameLbl.textColor = [UIColor whiteColor];
                nameLbl.text = [NSString stringWithFormat:@"%@%@ (v%@)", app.isJailbreakLoader ? @"👑 " : @"", app.appName, app.version];
                [card addSubview:nameLbl];

                UILabel *statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(78, 36, cardW - 186, 34)];
                statusLbl.font = [UIFont systemFontOfSize:12];
                statusLbl.numberOfLines = 2;
                statusLbl.textColor = app.isFakeSigned ? [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.85];
                statusLbl.text = app.isFakeSigned
                    ? @"⚠️ 当前为巨魔/假签名 (重启即死)\n请点右侧按钮转为苹果7天真证书"
                    : [NSString stringWithFormat:@"✅ 真证书有效 (libmis:OK) · 剩 %.1f 天", app.remainingDays];
                [card addSubview:statusLbl];

                // 7天可视化彩色进度条
                UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                bar.frame = CGRectMake(78, 78, cardW - 190, 6);
                bar.layer.cornerRadius = 3;
                bar.clipsToBounds = YES;
                float prog = app.isFakeSigned ? 0.05f : fmin(fmax(app.remainingDays / 7.0f, 0.08f), 1.0f);
                bar.progress = prog;
                bar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
                bar.progressTintColor = app.isFakeSigned ? [UIColor systemRedColor] : [UIColor colorWithRed:0.18 green:0.85 blue:0.55 alpha:1.0];
                [card addSubview:bar];

                UIButton *resignBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                resignBtn.frame = CGRectMake(cardW - 104, 30, 92, 40);
                resignBtn.backgroundColor = app.isFakeSigned
                    ? [UIColor colorWithRed:0.90 green:0.28 blue:0.25 alpha:0.95]
                    : [UIColor colorWithRed:0.12 green:0.68 blue:0.48 alpha:0.95];
                resignBtn.layer.cornerRadius = 20;
                [resignBtn setTitle:(app.isFakeSigned ? @"一键转真签" : @"⚡ 立即续签") forState:UIControlStateNormal];
                [resignBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                resignBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                resignBtn.tag = indexPath.row;
                [resignBtn addTarget:self action:@selector(onFastResignTapped:) forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:resignBtn];
            }
        }
        // Section 3: 全部使用真正的 iOS 原生 UISwitch 滑动开关！
        else {
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, cardW - 96, 42)];
            lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
            lbl.textColor = [UIColor whiteColor];
            lbl.numberOfLines = 2;
            [card addSubview:lbl];

            if (indexPath.row == 0) {
                lbl.text = [NSString stringWithFormat:@"⚡ 后台静默自动续签\n证书剩余少于 %ld 天时联网自动续回 7 天", (long)engine.normalRenewThresholdDays];
                UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 16, 51, 31)];
                sw.on = engine.autoRenewEnabled;
                sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                sw.tag = 200;
                [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                [card addSubview:sw];
            } else if (indexPath.row == 1) {
                lbl.text = @"🔋 低电量 (<5%) 紧急抢救续签开关\n防止手机没电自动关机后证书过期失联";
                UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 16, 51, 31)];
                sw.on = engine.lowBatteryRescueEnabled;
                sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                sw.tag = 201;
                [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                [card addSubview:sw];
            } else if (indexPath.row == 2) {
                lbl.text = [NSString stringWithFormat:@"⏱️ 低电量抢救触发天数设置\n当电量 <%ld%% 且证书少于【%ld 天】时自动续签",
                            (long)engine.lowBatteryTriggerPercent, (long)engine.lowBatteryThresholdDays];
                UIButton *cfgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                cfgBtn.frame = CGRectMake(cardW - 88, 15, 74, 32);
                cfgBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
                cfgBtn.layer.cornerRadius = 16;
                [cfgBtn setTitle:[NSString stringWithFormat:@"<%ld天 ▾", (long)engine.lowBatteryThresholdDays] forState:UIControlStateNormal];
                [cfgBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                cfgBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                [cfgBtn addTarget:self action:@selector(onConfigureLowBatteryRuleTapped) forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:cfgBtn];
            } else if (indexPath.row == 3) {
                lbl.text = @"🛑 关机/重启掉签系统级强拦截\n证书过期时尝试关机重启将弹窗拦截";
                UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 16, 51, 31)];
                sw.on = engine.rebootShieldEnabled;
                sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                sw.tag = 202;
                [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                [card addSubview:sw];
            } else {
                lbl.text = @"💎 iOS 27 液态玻璃质感滑块\n通透果冻风 ⇄ 深邃磨砂风";
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(cardW - 132, 16, 116, 30)];
                slider.minimumValue = 0.0f;
                slider.maximumValue = 1.0f;
                slider.value = engine.liquidGlassTintLevel;
                [slider addTarget:self action:@selector(onLiquidGlassSliderChanged:) forControlEvents:UIControlEventValueChanged];
                [card addSubview:slider];
            }
        }
    }
    // ==================== Tab 1: 🛠️ 签名工坊 ====================
    else if (_currentTab == 1) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cardW - 96, 42)];
        lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.numberOfLines = 2;
        [card addSubview:lbl];

        if (indexPath.section == 0) {
            NSArray *items = @[
                @"📦 导入外部 IPA / TIPA 安装包\n点击从「文件」选择安装包并签入 7 天真证书",
                @"📲 一键全量重签本机已守护应用\n立即将所有核心应用重置回满血 7 天有效期",
                @"🔥 一键应用克隆多开 (分身制作)\n自定义软件名称与独立沙盒标识符实现双开"
            ];
            lbl.text = items[indexPath.row];

            UIButton *actBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            actBtn.frame = CGRectMake(cardW - 82, 18, 68, 30);
            actBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
            actBtn.layer.cornerRadius = 15;
            [actBtn setTitle:(indexPath.row == 0 ? @"选择文件" : (indexPath.row == 1 ? @"立即刷新" : @"制作分身")) forState:UIControlStateNormal];
            [actBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            actBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            actBtn.userInteractionEnabled = NO;
            [card addSubview:actBtn];
        } else {
            if (indexPath.row == 0) {
                lbl.text = @"🧠 自动精简手表/小组件零件 (省80%额度)\n开启后 1 个软件只扣 1 个额度，不影响主功能";
                UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 18, 51, 31)];
                sw.on = engine.smartStripExtensions;
                sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                sw.tag = 203;
                [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                [card addSubview:sw];
            } else if (indexPath.row == 1) {
                lbl.text = [NSString stringWithFormat:@"💉 挂载越狱 .deb / .dylib 插件注入包\n当前已挂载 %lu 个插件 (将在下次签装时注入)", (unsigned long)_pendingInjectedDebPaths.count];
            } else {
                lbl.text = @"🗑️ 清空已挂载的待注入插件队列\n恢复默认纯净签名状态";
            }
        }
    }
    // ==================== Tab 2: 🛍️ 免 VPN 精选源商店 ====================
    else {
        NSInteger idx = (indexPath.section == 0) ? indexPath.row : (indexPath.row + 3);
        AuraRepoAppItem *item = _storeCatalog[idx];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cardW - 120, 22)];
        title.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
        title.textColor = [UIColor whiteColor];
        title.text = [NSString stringWithFormat:@"%@ · %@", item.name, item.version];
        [card addSubview:title];

        UILabel *desc = [[UILabel alloc] initWithFrame:CGRectMake(18, 36, cardW - 120, 44)];
        desc.font = [UIFont systemFontOfSize:12];
        desc.textColor = [UIColor colorWithWhite:1.0 alpha:0.82];
        desc.numberOfLines = 2;
        desc.text = item.summary;
        [card addSubview:desc];

        UIButton *getBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        getBtn.frame = CGRectMake(cardW - 96, 26, 80, 36);
        getBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.96 alpha:0.95];
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

#pragma mark - 原生 UISwitch 开关事件处理

- (void)onSwitchToggled:(UISwitch *)sender {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    if (sender.tag == 200) engine.autoRenewEnabled = sender.isOn;
    else if (sender.tag == 201) engine.lowBatteryRescueEnabled = sender.isOn;
    else if (sender.tag == 202) engine.rebootShieldEnabled = sender.isOn;
    else if (sender.tag == 203) engine.smartStripExtensions = sender.isOn;
    [engine savePreferences];
}

#pragma mark - 列表点击事件

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0) {
        if (indexPath.section == 1) {
            [self showStep1AppleIDLoginAlert];
        } else if (indexPath.section == 3 && indexPath.row == 2) {
            [self onConfigureLowBatteryRuleTapped];
        }
    }
    else if (_currentTab == 1) {
        if ((indexPath.section == 0 && indexPath.row == 0) || (indexPath.section == 1 && indexPath.row == 1)) {
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        } else if (indexPath.section == 0 && indexPath.row == 1) {
            [self showLoadingHUD:@"正在全量刷新 7 天真证书..."];
            [[AuraSignEngine sharedEngine] performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                [self hideLoadingHUD];
                [self reloadAllData];
                [self showSimpleToast:message];
            }];
        } else if (indexPath.section == 0 && indexPath.row == 2) {
            [self showCloneAppPrompt];
        } else if (indexPath.section == 1 && indexPath.row == 2) {
            [_pendingInjectedDebPaths removeAllObjects];
            [_tableView reloadData];
            [self showSimpleToast:@"已清空待注入插件队列"];
        }
    }
}

#pragma mark - 两步走 Apple ID 登录流程（先填账号密码获取验证码 ➔ 再弹出 6 位双重认证码窗口）

- (void)showStep1AppleIDLoginAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"👤 第 1 步：输入 Apple ID"
                                                                   message:@"请输入您的个人免费 Apple ID 账号与密码，点击【获取双重认证码】后苹果会将 6 位验证码发送至您的手机。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 邮箱 (如 xxx@icloud.com)";
        tf.keyboardType = UIKeyboardTypeEmailAddress;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 密码";
        tf.secureTextEntry = YES;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"下一步：获取双重认证码" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *email = alert.textFields[0].text ?: @"";
        NSString *pass  = alert.textFields[1].text ?: @"";
        if (!email.length || !pass.length) {
            [self showSimpleToast:@"⚠️ 账号和密码不能为空"];
            return;
        }
        [self showLoadingHUD:@"正在连接苹果服务器请求验证码..."];
        [[AuraAppleDeveloperAPI sharedAPI] loginWithAppleID:email password:pass twoFactorCode:nil completion:^(BOOL success, BOOL need2FA, NSString *errorMsg) {
            [self hideLoadingHUD];
            if (success) {
                [self reloadAllData];
                [self showSimpleToast:@"✅ Apple ID 绑定成功，1年期证书已就绪！"];
            } else if (need2FA) {
                // 自动进入第 2 步：弹出 6 位双重认证验证码输入框！
                [self showStep2TwoFactorCodeAlertWithEmail:email password:pass];
            } else {
                [self showSimpleToast:errorMsg ?: @"登录失败"];
            }
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showStep2TwoFactorCodeAlertWithEmail:(NSString *)email password:(NSString *)password {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🔐 第 2 步：输入双重认证码"
                                                                   message:@"请在下方输入您手机弹窗收到的 6 位数字双重认证验证码（若无需验证码可直接点完成绑定）："
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"请输入 6 位数字验证码";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.textAlignment = NSTextAlignmentCenter;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"完成绑定并生成证书" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *code = alert.textFields[0].text ?: @"000000";
        [self showLoadingHUD:@"正在验证并签发 1 年期证书..."];
        [[AuraAppleDeveloperAPI sharedAPI] loginWithAppleID:email password:password twoFactorCode:code completion:^(BOOL success, BOOL need2FA, NSString *errorMsg) {
            [self hideLoadingHUD];
            [self reloadAllData];
            [self showSimpleToast:success ? @"✅ Apple ID 绑定成功，1年期证书已生成！" : (errorMsg ?: @"绑定失败")];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"返回上一步" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 异步立即续签、低电量天数配置、文件导入与商店下载

- (void)onFastResignTapped:(UIButton *)sender {
    AuraAppInfo *app = _installedApps[sender.tag];
    [self showLoadingHUD:[NSString stringWithFormat:@"正在为【%@】签入 7 天真证书...", app.appName]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *err = nil;
        BOOL ok = [[AuraSignEngine sharedEngine] fastResignApp:app
                                                  stripPlugIns:[AuraSignEngine sharedEngine].smartStripExtensions
                                                    customName:nil
                                                customBundleID:nil
                                                  injectedDebs:_pendingInjectedDebPaths
                                                         error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideLoadingHUD];
            [_pendingInjectedDebPaths removeAllObjects];
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
            [self reloadAllData];
            [self showSimpleToast:ok
                ? [NSString stringWithFormat:@"✅【%@】已刷新满血 7 天苹果真证书 (libmis 校验通过)", app.appName]
                : (err.localizedDescription ?: @"续签失败")];
        });
    });
}

- (void)onConfigureLowBatteryRuleTapped {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"🔋 低电量抢救触发天数设置"
                                                                   message:[NSString stringWithFormat:@"当手机电量不到 %ld%% 时，证书剩余少于多少天自动触发 1.5 秒紧急续签：",
                                                                            (long)engine.lowBatteryTriggerPercent]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSInteger days = 1; days <= 7; days++) {
        NSString *title = [NSString stringWithFormat:@"证书剩余少于【%ld 天】时自动抢救续签%@",
                           (long)days, (days == engine.lowBatteryThresholdDays ? @" ✓" : @"")];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            engine.lowBatteryThresholdDays = days;
            [engine savePreferences];
            [_tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
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
        [self showLoadingHUD:@"正在解压并签入 7 天真证书..."];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            BOOL ok = [[AuraSignEngine sharedEngine] installAndSignIPAFileAtPath:localCopy
                                                                      customName:nil
                                                                  customBundleID:nil
                                                                    injectedDebs:_pendingInjectedDebPaths
                                                                           error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingHUD];
                [_pendingInjectedDebPaths removeAllObjects];
                [self reloadAllData];
                [self showSimpleToast:ok ? @"✅ IPA 已成功签入 7 天真证书并安装至桌面！" : (err.localizedDescription ?: @"IPA 签名安装失败")];
            });
        });
    }
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
        NSString *cName = alert.textFields[0].text;
        NSString *cBid  = alert.textFields[1].text;
        [self showLoadingHUD:@"正在制作多开分身并签名..."];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [[AuraSignEngine sharedEngine] fastResignApp:target
                                            stripPlugIns:[AuraSignEngine sharedEngine].smartStripExtensions
                                              customName:cName
                                          customBundleID:cBid
                                            injectedDebs:_pendingInjectedDebPaths
                                                   error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingHUD];
                [_pendingInjectedDebPaths removeAllObjects];
                [self reloadAllData];
                [self showSimpleToast:@"✅ 多开分身签名安装完成！"];
            });
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onStoreGetButtonTapped:(UIButton *)sender {
    AuraRepoAppItem *item = _storeCatalog[sender.tag];
    [self showLoadingHUD:[NSString stringWithFormat:@"正在免 VPN 下载并签装【%@】...", item.name]];
    [[AuraSignEngine sharedEngine] downloadAndSignRepoItem:item completion:^(BOOL success, NSString *message) {
        [self hideLoadingHUD];
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [a dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
