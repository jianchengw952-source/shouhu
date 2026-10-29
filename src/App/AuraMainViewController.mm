// src/App/AuraMainViewController.mm
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"
#import "AuraLiquidGlassView.h"

@interface UIImage (AuraAppIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface AuraMainViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation AuraMainViewController {
    NSInteger _currentTab; // 0: 🛡️守护中心 | 1: 🛠️签名工坊 | 2: 🛍️精选商店
    CAGradientLayer *_meshLayer;
    UIView *_topHeaderBar;
    UILabel *_headerTitleLabel;
    UILabel *_headerSubLabel;
    UIButton *_topRightActionButton;
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

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];

    [self setupFloatingLiquidPillTabBar];
    [self reloadAllData];
}

// 严格根据真机 safeAreaInsets (灵动岛/刘海高度与底部指示条高度) 动态计算坐标，绝不遮挡！
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _meshLayer.frame = self.view.bounds;

    CGFloat safeTop = MAX(self.view.safeAreaInsets.top, 44.0);
    CGFloat safeBottom = MAX(self.view.safeAreaInsets.bottom, 16.0);
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;

    _topHeaderBar.frame = CGRectMake(0, safeTop, width, 56.0);
    _topRightActionButton.frame = CGRectMake(width - 104.0, 11.0, 88.0, 34.0);

    CGFloat tableTop = safeTop + 56.0;
    _tableView.frame = CGRectMake(0, tableTop, width, height - tableTop);
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, safeBottom + 84.0, 0);

    CGFloat pillW = width - 36.0;
    _bottomLiquidPillBar.frame = CGRectMake(18.0, height - safeBottom - 64.0, pillW, 60.0);
    CGFloat btnW = pillW / 3.0;
    _tabActiveIndicator.frame = CGRectMake(_currentTab * btnW + 6.0, 6.0, btnW - 12.0, 48.0);
    for (int i = 0; i < 3; i++) {
        UIButton *b = [_bottomLiquidPillBar viewWithTag:100 + i];
        b.frame = CGRectMake(i * btnW, 0, btnW, 60.0);
    }
}

- (void)setupDynamicMeshBackground {
    _meshLayer = [CAGradientLayer layer];
    _meshLayer.colors = @[
        (id)[UIColor colorWithRed:0.06 green:0.32 blue:0.30 alpha:0.70].CGColor,
        (id)[UIColor colorWithRed:0.04 green:0.07 blue:0.14 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.16 blue:0.32 alpha:0.90].CGColor
    ];
    _meshLayer.startPoint = CGPointMake(0.1, 0.0);
    _meshLayer.endPoint = CGPointMake(0.9, 1.0);
    [self.view.layer insertSublayer:_meshLayer atIndex:0];
}

- (void)setupTopHeaderBar {
    _topHeaderBar = [[UIView alloc] initWithFrame:CGRectZero];

    _headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 4, 240, 28)];
    _headerTitleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    _headerTitleLabel.textColor = [UIColor whiteColor];
    _headerTitleLabel.text = @"灵签 Pro · 守护中心";
    [_topHeaderBar addSubview:_headerTitleLabel];

    _headerSubLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 32, 250, 18)];
    _headerSubLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _headerSubLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.68];
    _headerSubLabel.text = @"Dopamine & Relaxin 全自动 7 天真证书保活";
    [_topHeaderBar addSubview:_headerSubLabel];

    _topRightActionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _topRightActionButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    _topRightActionButton.layer.cornerRadius = 17;
    [_topRightActionButton setTitle:@"📜 日志" forState:UIControlStateNormal];
    [_topRightActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _topRightActionButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [_topRightActionButton addTarget:self action:@selector(onTopRightButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_topHeaderBar addSubview:_topRightActionButton];

    [self.view addSubview:_topHeaderBar];
}

- (void)onTopRightButtonTapped {
    if (_currentTab == 2) {
        [self showAddCustomRepoAlert];
    } else {
        [self showTimelineLogsAlert];
    }
}

- (void)setupFloatingLiquidPillTabBar {
    _bottomLiquidPillBar = [[AuraLiquidGlassView alloc] initWithFrame:CGRectZero cornerRadius:30];
    _bottomLiquidPillBar.tintLevel = [AuraSignEngine sharedEngine].liquidGlassTintLevel;

    _tabActiveIndicator = [[UIView alloc] initWithFrame:CGRectZero];
    _tabActiveIndicator.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.48 alpha:0.45];
    _tabActiveIndicator.layer.cornerRadius = 24;
    [_bottomLiquidPillBar addSubview:_tabActiveIndicator];

    NSArray *titles = @[@"🛡️ 守护中心", @"🛠️ 签名工坊", @"🛍️ 精选商店"];
    for (int i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
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
    NSArray *headerTitles = @[@"灵签 Pro · 守护中心", @"灵签 Pro · 签名工坊", @"灵签 Pro · 精选商店"];
    _headerTitleLabel.text = headerTitles[_currentTab];
    [_topRightActionButton setTitle:(_currentTab == 2 ? @"➕ 添加源" : @"📜 日志") forState:UIControlStateNormal];

    CGFloat btnW = _bottomLiquidPillBar.bounds.size.width / 3.0;
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
        _tabActiveIndicator.frame = CGRectMake(_currentTab * btnW + 6.0, 6.0, btnW - 12.0, 48.0);
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

#pragma mark - 居中毛玻璃加载框

- (void)showLoadingHUD:(NSString *)text {
    if (!_loadingOverlay) {
        _loadingOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
        _loadingOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _loadingOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.52];

        AuraLiquidGlassView *box = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - 230)/2.0, (self.view.bounds.size.height - 130)/2.0, 230, 130) cornerRadius:24];
        box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;

        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        spinner.color = [UIColor whiteColor];
        spinner.center = CGPointMake(115, 45);
        [spinner startAnimating];
        [box addSubview:spinner];

        _loadingTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 74, 202, 44)];
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

#pragma mark - UITableView 分组标题与数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_currentTab == 0) return 4;
    if (_currentTab == 1) return 2;
    return 2;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (_currentTab == 0 && section == 0) return 6.0;
    return 32.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (_currentTab == 0 && section == 0) return nil;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 32)];
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(22, 6, tableView.bounds.size.width - 44, 20)];
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    lbl.textColor = [UIColor colorWithRed:0.45 green:0.92 blue:0.75 alpha:0.95];

    if (_currentTab == 0) {
        if (section == 1) lbl.text = @"👤 APPLE ID 免费签名凭证";
        else if (section == 2) lbl.text = @"👑 越狱工具与已守护应用 (最多 3 个真证书槽位)";
        else if (section == 3) lbl.text = @"⚙️ 自动化续签与防失联安全防线";
    } else if (_currentTab == 1) {
        lbl.text = (section == 0) ? @"📦 IPA 导入与克隆多开" : @"💉 插件注入与智能省额度设置";
    } else {
        lbl.text = (section == 0) ? @"👑 越狱官方最新版免 VPN 急救舱" : @"🔥 开源精选与自定义软件源 (点右上角可添加源)";
    }
    [header addSubview:lbl];
    return header;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_currentTab == 0) {
        if (section == 0) return 1;
        if (section == 1) return 1;
        if (section == 2) return MAX(1, _installedApps.count);
        return 5;
    }
    if (_currentTab == 1) return 3;
    if (section == 0) return 3;
    return MAX(0, (NSInteger)_storeCatalog.count - 3);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0) {
        if (indexPath.section == 0) return 118;
        if (indexPath.section == 1) return 84;
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

    if (_currentTab == 0) {
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

            UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(18, 40, cardW - 36, 56)];
            sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
            sub.numberOfLines = 3;
            sub.text = summary;
            [card addSubview:sub];
        }
        else if (indexPath.section == 1) {
            AuraAppleDeveloperAPI *api = [AuraAppleDeveloperAPI sharedAPI];
            BOOL loggedIn = [api hasValidAccountInKeychain];

            UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cardW - 126, 22)];
            t.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
            t.textColor = [UIColor whiteColor];
            t.text = loggedIn ? [api currentAppleIDEmail] : @"尚未绑定 Apple ID";
            [card addSubview:t];

            UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(18, 38, cardW - 126, 24)];
            s.font = [UIFont systemFontOfSize:12];
            s.textColor = loggedIn ? [UIColor colorWithRed:0.4 green:0.95 blue:0.65 alpha:1.0] : [UIColor colorWithRed:1.0 green:0.75 blue:0.35 alpha:1.0];
            s.text = loggedIn
                ? [NSString stringWithFormat:@"✓ TeamID: %@ · 1年真证书就绪", [api currentTeamID]]
                : @"⚠️ 请点击右侧【立即登录】调起苹果认证获取真证书";
            [card addSubview:s];

            UIButton *loginBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            loginBtn.frame = CGRectMake(cardW - 102, 19, 86, 36);
            loginBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.56 blue:0.98 alpha:0.95];
            loginBtn.layer.cornerRadius = 18;
            [loginBtn setTitle:(loggedIn ? @"切换账号" : @"立即登录") forState:UIControlStateNormal];
            [loginBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            loginBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            [loginBtn addTarget:self action:@selector(onAppleIDLoginButtonTapped) forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:loginBtn];
        }
        else if (indexPath.section == 2) {
            if (_installedApps.count == 0) {
                UILabel *empty = [[UILabel alloc] initWithFrame:card.bounds];
                empty.textAlignment = NSTextAlignmentCenter;
                empty.textColor = [UIColor whiteColor];
                empty.text = @"未检测到个人证书应用 · 可在【精选商店】一键安装";
                [card addSubview:empty];
            } else {
                AuraAppInfo *app = _installedApps[indexPath.row];

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

#pragma mark - 原生 UISwitch 与列表点击事件

- (void)onSwitchToggled:(UISwitch *)sender {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    if (sender.tag == 200) engine.autoRenewEnabled = sender.isOn;
    else if (sender.tag == 201) engine.lowBatteryRescueEnabled = sender.isOn;
    else if (sender.tag == 202) engine.rebootShieldEnabled = sender.isOn;
    else if (sender.tag == 203) engine.smartStripExtensions = sender.isOn;
    [engine savePreferences];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0) {
        if (indexPath.section == 1) {
            [self onAppleIDLoginButtonTapped];
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
            [self showLoadingHUD:@"正在连接苹果服务器刷新 7 天证书..."];
            [[AuraSignEngine sharedEngine] performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                [self hideLoadingHUD];
                [self reloadAllData];
                [self showResultAlertWithTitle:(success ? @"✅ 刷新完成" : @"⚠️ 操作提示") message:message];
            }];
        } else if (indexPath.section == 0 && indexPath.row == 2) {
            [self showCloneAppPrompt];
        } else if (indexPath.section == 1 && indexPath.row == 2) {
            [_pendingInjectedDebPaths removeAllObjects];
            [_tableView reloadData];
            [self showResultAlertWithTitle:@"提示" message:@"已清空待注入插件队列"];
        }
    }
}

#pragma mark - 调起 iOS 系统原生 Apple ID 登录与双重认证流程

- (void)onAppleIDLoginButtonTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"👤 绑定个人免费 Apple ID"
                                                                   message:@"输入您的 Apple ID 与密码后，系统将自动调起苹果双重认证（2FA）并向苹果开发者服务器申请 1 年期真证书。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 邮箱 (如 xxx@icloud.com)";
        tf.keyboardType = UIKeyboardTypeEmailAddress;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 密码";
        tf.secureTextEntry = YES;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"登录并获取双重认证" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *email = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *pass  = alert.textFields[1].text ?: @"";
        if (!email.length) {
            [self showResultAlertWithTitle:@"提示" message:@"请输入您的 Apple ID 邮箱"];
            return;
        }
        [self showLoadingHUD:@"正在连接苹果认证服务并申请证书..."];
        [[AuraAppleDeveloperAPI sharedAPI] authenticateWithSystemSheetFromViewController:self
                                                                            initialEmail:email
                                                                         initialPassword:pass
                                                                              completion:^(BOOL success, NSString *errorMsg) {
            [self hideLoadingHUD];
            [self reloadAllData];
            if (success) {
                [self showResultAlertWithTitle:@"✅ 绑定成功"
                                       message:[NSString stringWithFormat:@"已成功获取苹果 TeamID (%@) 并生成 1 年期开发证书！现在您可以直接点击应用右侧的【立即续签】。", [[AuraAppleDeveloperAPI sharedAPI] currentTeamID]]];
            } else {
                [self showResultAlertWithTitle:@"❌ 绑定未通过" message:(errorMsg ?: @"请检查账号密码重试")];
            }
        }];
    }]];

    if ([[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"退出当前账号" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[AuraAppleDeveloperAPI sharedAPI] logoutCurrentAccount];
            [self reloadAllData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 添加自定义软件源 (支持全网 AltStore / 轻松签 / Feather JSON 格式)

- (void)showAddCustomRepoAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"➕ 添加第三方软件源"
                                                                   message:@"支持粘贴任何标准 JSON 软件源地址（兼容轻松签、Feather、AltStore 源格式）："
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://.../repo.json";
        tf.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"解析并添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *url = alert.textFields[0].text ?: @"";
        if (!url.length) return;
        [self showLoadingHUD:@"正在解析软件源..."];
        [[AuraSignEngine sharedEngine] addCustomRepoFromURL:url completion:^(BOOL success, NSInteger addedCount, NSString *errorMsg) {
            [self hideLoadingHUD];
            [self reloadAllData];
            if (success) {
                [self showResultAlertWithTitle:@"✅ 添加成功" message:[NSString stringWithFormat:@"已从该软件源成功导入 %ld 款应用！", (long)addedCount]];
            } else {
                [self showResultAlertWithTitle:@"❌ 添加失败" message:errorMsg];
            }
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 立即续签、低电量天数配置、文件导入与商店下载

- (void)onFastResignTapped:(UIButton *)sender {
    AuraAppInfo *app = _installedApps[sender.tag];
    [self showLoadingHUD:[NSString stringWithFormat:@"正在向苹果申请 7 天描述文件并重签\n【%@】...", app.appName]];

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
            [self reloadAllData];
            if (ok) {
                UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                [self showResultAlertWithTitle:@"✅ 续签成功"
                                       message:[NSString stringWithFormat:@"【%@】已成功签入苹果官方 7 天真证书并通过 libmis 未越狱开机校验！", app.appName]];
            } else {
                [self showResultAlertWithTitle:@"❌ 签名未完成" message:(err.localizedDescription ?: @"未知错误")];
            }
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
        [self showResultAlertWithTitle:@"💉 插件已挂载" message:[NSString stringWithFormat:@"已挂载：%@\n将在您下次签名或导入 IPA 时自动注入！", localCopy.lastPathComponent]];
    } else {
        [self showLoadingHUD:@"正在解压并向苹果申请 7 天真证书..."];
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
                if (ok) {
                    [self showResultAlertWithTitle:@"✅ 安装完成" message:@"IPA 已成功签入 7 天苹果真证书并安装至桌面！"];
                } else {
                    [self showResultAlertWithTitle:@"❌ 签名安装未通过" message:(err.localizedDescription ?: @"请先确认已登录绑定 Apple ID")];
                }
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
    if (_installedApps.count == 0) {
        [self showResultAlertWithTitle:@"提示" message:@"未检测到可克隆的应用"];
        return;
    }
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
        [self showLoadingHUD:@"正在制作多开分身并申请苹果证书..."];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            BOOL ok = [[AuraSignEngine sharedEngine] fastResignApp:target
                                                      stripPlugIns:[AuraSignEngine sharedEngine].smartStripExtensions
                                                        customName:cName
                                                    customBundleID:cBid
                                                      injectedDebs:_pendingInjectedDebPaths
                                                             error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingHUD];
                [_pendingInjectedDebPaths removeAllObjects];
                [self reloadAllData];
                if (ok) {
                    [self showResultAlertWithTitle:@"✅ 多开完成" message:@"分身应用已签入 7 天真证书并安装至桌面！"];
                } else {
                    [self showResultAlertWithTitle:@"❌ 多开失败" message:(err.localizedDescription ?: @"签名未通过")];
                }
            });
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onStoreGetButtonTapped:(UIButton *)sender {
    AuraRepoAppItem *item = _storeCatalog[sender.tag];
    [self showLoadingHUD:[NSString stringWithFormat:@"准备下载【%@】...", item.name]];
    [[AuraSignEngine sharedEngine] downloadAndSignRepoItem:item progress:^(NSString *stageText) {
        _loadingTextLabel.text = stageText;
    } completion:^(BOOL success, NSString *message) {
        [self hideLoadingHUD];
        [self reloadAllData];
        [self showResultAlertWithTitle:(success ? @"✅ 签装完成" : @"❌ 签装提示") message:message];
    }];
}

- (void)onLiquidGlassSliderChanged:(UISlider *)slider {
    [AuraSignEngine sharedEngine].liquidGlassTintLevel = slider.value;
    [[AuraSignEngine sharedEngine] savePreferences];
    _bottomLiquidPillBar.tintLevel = slider.value;
    [_tableView reloadData];
}

- (void)showResultAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
