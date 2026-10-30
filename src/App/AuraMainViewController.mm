// src/App/AuraMainViewController.mm (账号移至⚙️设置页顶部 + 全流程错误白话文日志终极版)
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>
#import "AuraSignEngine.h"
#import "AuraAppleDeveloperAPI.h"
#import "AuraLiquidGlassView.h"

@interface UIImage (AuraAppIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface AuraMainViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation AuraMainViewController {
    NSInteger _currentTab; // 0: 🛡️ 签名 | 1: 📜 日志 | 2: ⚙️ 设置
    CAGradientLayer *_meshLayer;
    UIView *_topHeaderBar;
    UILabel *_headerTitleLabel;
    UILabel *_headerSubLabel;
    UIButton *_topRightActionButton;
    UITableView *_tableView;
    UIRefreshControl *_refreshControl;

    NSArray<AuraAppInfo *> *_installedApps;
    NSArray<NSDictionary *> *_simpleLogs;
    AuraShieldStatus _cachedShieldStatus;
    NSString *_cachedShieldSummary;
    NSMutableDictionary<NSString *, UIImage *> *_iconCache;

    AuraLiquidGlassView *_bottomLiquidPillBar;
    UIView *_tabActiveIndicator;
    UIView *_loadingOverlay;
    UILabel *_loadingTextLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _iconCache = [NSMutableDictionary dictionary];
    _cachedShieldStatus = AuraShieldStatusSafe;
    _cachedShieldSummary = @"正在后台检测越狱工具证书状态...";

    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.11 alpha:1.0];

    [self setupDynamicMeshBackground];
    [self setupTopHeaderBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.dataSource = self;
    _tableView.delegate = self;

    _refreshControl = [[UIRefreshControl alloc] init];
    _refreshControl.tintColor = [UIColor whiteColor];
    [_refreshControl addTarget:self action:@selector(reloadAllDataAsync) forControlEvents:UIControlEventValueChanged];
    _tableView.refreshControl = _refreshControl;
    [self.view addSubview:_tableView];

    [self setupFloatingLiquidPillTabBar];
    [[AuraSignEngine sharedEngine] requestSystemNotificationPermission];
    [self reloadAllDataAsync];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _meshLayer.frame = self.view.bounds;

    CGFloat safeTop = MAX(self.view.safeAreaInsets.top, 44.0);
    CGFloat safeBottom = MAX(self.view.safeAreaInsets.bottom, 16.0);
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;

    _topHeaderBar.frame = CGRectMake(0, safeTop, width, 56.0);
    _topRightActionButton.frame = CGRectMake(width - 108.0, 11.0, 92.0, 34.0);

    CGFloat pillW = width - 40.0;
    CGFloat pillY = height - safeBottom - 62.0;
    _bottomLiquidPillBar.frame = CGRectMake(20.0, pillY, pillW, 58.0);

    CGFloat tableTop = safeTop + 56.0;
    _tableView.frame = CGRectMake(0, tableTop, width, pillY - tableTop - 8.0);
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 16.0, 0);

    CGFloat btnW = pillW / 3.0;
    _tabActiveIndicator.frame = CGRectMake(_currentTab * btnW + 5.0, 6.0, btnW - 10.0, 46.0);
    for (int i = 0; i < 3; i++) {
        UIButton *b = [_bottomLiquidPillBar viewWithTag:100 + i];
        b.frame = CGRectMake(i * btnW, 0, btnW, 58.0);
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
    _headerTitleLabel.text = @"灵签 Pro · 签名";
    [_topHeaderBar addSubview:_headerTitleLabel];

    _headerSubLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 32, 250, 18)];
    _headerSubLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _headerSubLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.68];
    _headerSubLabel.text = @"Dopamine & Relaxin 全自动 7 天真证书保活";
    [_topHeaderBar addSubview:_headerSubLabel];

    _topRightActionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _topRightActionButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    _topRightActionButton.layer.cornerRadius = 17;
    [_topRightActionButton setTitle:@"🔄 刷新" forState:UIControlStateNormal];
    [_topRightActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _topRightActionButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [_topRightActionButton addTarget:self action:@selector(onTopRightButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_topHeaderBar addSubview:_topRightActionButton];

    [self.view addSubview:_topHeaderBar];
}

- (void)setupFloatingLiquidPillTabBar {
    _bottomLiquidPillBar = [[AuraLiquidGlassView alloc] initWithFrame:CGRectZero cornerRadius:29];
    _bottomLiquidPillBar.tintLevel = 0.25f;

    _tabActiveIndicator = [[UIView alloc] initWithFrame:CGRectZero];
    _tabActiveIndicator.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.48 alpha:0.48];
    _tabActiveIndicator.layer.cornerRadius = 23;
    [_bottomLiquidPillBar addSubview:_tabActiveIndicator];

    NSArray *titles = @[@"🛡️ 签名", @"📜 日志", @"⚙️ 设置"];
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
    if (_currentTab == 0) {
        _headerTitleLabel.text = @"灵签 Pro · 签名";
        [_topRightActionButton setTitle:@"🔄 刷新" forState:UIControlStateNormal];
    } else if (_currentTab == 1) {
        _headerTitleLabel.text = @"灵签 Pro · 日志";
        [_topRightActionButton setTitle:@"🛠️ 管理" forState:UIControlStateNormal];
        _simpleLogs = [[AuraSignEngine sharedEngine] readSimpleUserLogs];
    } else {
        _headerTitleLabel.text = @"灵签 Pro · 设置";
        [_topRightActionButton setTitle:@"🔄 刷新" forState:UIControlStateNormal];
    }

    CGFloat btnW = _bottomLiquidPillBar.bounds.size.width / 3.0;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:0 animations:^{
        _tabActiveIndicator.frame = CGRectMake(_currentTab * btnW + 5.0, 6.0, btnW - 10.0, 46.0);
    } completion:nil];

    for (int i = 0; i < 3; i++) {
        UIButton *b = [_bottomLiquidPillBar viewWithTag:100 + i];
        [b setTitleColor:(i == _currentTab ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.55]) forState:UIControlStateNormal];
    }
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    [_tableView reloadData];
}

- (void)onTopRightButtonTapped {
    if (_currentTab == 1) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"📜 日志管理"
                                                                       message:@"您可以清空当前日志，或在遇到故障时复制底层诊断报告："
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"🗑️ 清空全部日志记录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[AuraSignEngine sharedEngine] clearAllLogs];
            _simpleLogs = @[];
            [_tableView reloadData];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"📋 复制底层技术诊断报告" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = [self buildFullDiagnosticReportString];
            [self showResultAlertWithTitle:@"已复制" message:@"底层技术诊断报告已复制到剪贴板"];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    } else {
        [self reloadAllDataAsync];
    }
}

- (void)reloadAllDataAsync {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AuraSignEngine *engine = [AuraSignEngine sharedEngine];
        NSArray<AuraAppInfo *> *apps = [engine scanTargetApps];
        NSArray<NSDictionary *> *logs = [engine readSimpleUserLogs];
        NSString *summary = nil;
        AuraShieldStatus st = [engine evaluateGlobalShieldStatus:&summary];

        CGFloat screenScale = [UIScreen mainScreen].scale;
        for (AuraAppInfo *app in apps) {
            if (app.bundleID.length && !_iconCache[app.bundleID]) {
                if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
                    UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:app.bundleID format:2 scale:screenScale];
                    if (img) {
                        @synchronized (_iconCache) {
                            _iconCache[app.bundleID] = img;
                        }
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            _installedApps = apps;
            _simpleLogs = logs;
            _cachedShieldStatus = st;
            _cachedShieldSummary = summary ?: @"";
            if (_refreshControl.isRefreshing) {
                [_refreshControl endRefreshing];
            }
            [_tableView reloadData];
        });
    });
}

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

#pragma mark - UITableView 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_currentTab == 0) return 3; // 0:护盾卡片 | 1:需要签名的软件 | 2:快捷操作
    if (_currentTab == 1) return 1; // 0:白话文日志列表
    return 3;                       // 0:Apple ID账号凭证 | 1:自动续签策略 | 2:安全防线与系统通知
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
        if (section == 1) lbl.text = @"👑 需要签名的软件 (最多勾选 3 个自动守护槽位)";
        else if (section == 2) lbl.text = @"📦 快捷导入与全量续签";
    } else if (_currentTab == 1) {
        lbl.text = @"📜 签名与登录状态记录 (包含全部成功与失败原因)";
    } else {
        if (section == 0) lbl.text = @"👤 APPLE ID 免费签名凭证";
        else if (section == 1) lbl.text = @"⚡ 自动续签策略设置";
        else lbl.text = @"🛑 安全防线与系统通知";
    }
    [header addSubview:lbl];
    return header;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_currentTab == 0) {
        if (section == 0) return 1;
        if (section == 1) return MAX(1, _installedApps.count);
        return 2;
    } else if (_currentTab == 1) {
        return MAX(1, _simpleLogs.count);
    } else {
        if (section == 0) return 1;
        if (section == 1) return 4;
        return 3;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0) {
        if (indexPath.section == 0) return 120;
        if (indexPath.section == 1) return 118;
        return 78;
    } else if (_currentTab == 1) {
        return 86;
    } else {
        if (indexPath.section == 0) return 90;
        return 80;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat cardW = self.view.bounds.size.width - 32;
    CGFloat rowH = [self tableView:tableView heightForRowAtIndexPath:indexPath] - 10;
    AuraLiquidGlassView *card = [[AuraLiquidGlassView alloc] initWithFrame:CGRectMake(16, 5, cardW, rowH) cornerRadius:20];
    card.tintLevel = 0.25f;
    [cell.contentView addSubview:card];

    AuraSignEngine *engine = [AuraSignEngine sharedEngine];

    if (_currentTab == 0) {
        // ==================== 第 1 页：🛡️ 签名 ====================
        if (indexPath.section == 0) {
            card.accentGlowColor = (_cachedShieldStatus == AuraShieldStatusDanger)
                ? [UIColor colorWithRed:0.75 green:0.12 blue:0.18 alpha:1.0]
                : [UIColor colorWithRed:0.06 green:0.52 blue:0.38 alpha:1.0];

            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cardW - 36, 24)];
            title.font = [UIFont systemFontOfSize:17.5 weight:UIFontWeightHeavy];
            title.textColor = [UIColor whiteColor];
            title.text = (_cachedShieldStatus == AuraShieldStatusDanger) ? @"🔴 警告：切勿此时关机重启！" : @"🟢 重启安全护盾 · 已受保护";
            [card addSubview:title];

            UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(18, 40, cardW - 36, 58)];
            sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
            sub.numberOfLines = 3;
            sub.text = _cachedShieldSummary;
            [card addSubview:sub];
        }
        else if (indexPath.section == 1) {
            if (_installedApps.count == 0) {
                UILabel *empty = [[UILabel alloc] initWithFrame:card.bounds];
                empty.textAlignment = NSTextAlignmentCenter;
                empty.textColor = [UIColor whiteColor];
                empty.text = @"正在扫描本机越狱工具与个人证书应用...";
                [card addSubview:empty];
            } else {
                AuraAppInfo *app = _installedApps[indexPath.row];
                BOOL isExpiredOrInvalid = (app.isFakeSigned || app.remainingDays <= 0.0 || !app.isLibmisVerified);

                UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 16, 52, 52)];
                iconView.layer.cornerRadius = 12;
                iconView.clipsToBounds = YES;
                iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
                @synchronized (_iconCache) {
                    if (app.bundleID.length && _iconCache[app.bundleID]) {
                        iconView.image = _iconCache[app.bundleID];
                    }
                }
                [card addSubview:iconView];

                UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(76, 12, cardW - 184, 22)];
                nameLbl.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
                nameLbl.textColor = [UIColor whiteColor];
                nameLbl.text = [NSString stringWithFormat:@"%@%@ (v%@)", app.isJailbreakLoader ? @"👑 " : @"", app.appName, app.version];
                [card addSubview:nameLbl];

                UILabel *statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(76, 35, cardW - 182, 36)];
                statusLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
                statusLbl.numberOfLines = 2;

                if (app.isFakeSigned) {
                    statusLbl.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
                    statusLbl.text = @"⚠️ 当前为巨魔/假签名 (重启即死)\n请点右侧按钮转为苹果7天真证书";
                } else if (app.remainingDays <= 0.0) {
                    statusLbl.textColor = [UIColor colorWithRed:1.0 green:0.48 blue:0.42 alpha:1.0];
                    statusLbl.text = [NSString stringWithFormat:@"❌ 证书已过期 %.0f 天 (仅靠越狱运行)\n重启将打不开 · 请点右侧重签真证书", fabs(app.remainingDays)];
                } else {
                    statusLbl.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.70 alpha:1.0];
                    statusLbl.text = [NSString stringWithFormat:@"✅ 苹果真证书有效 (libmis:OK)\n剩余 %.1f 天 · 重启可正常打开", app.remainingDays];
                }
                [card addSubview:statusLbl];

                UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                bar.frame = CGRectMake(76, 82, cardW - 186, 6);
                bar.layer.cornerRadius = 3;
                bar.clipsToBounds = YES;
                float prog = isExpiredOrInvalid ? 0.06f : fmin(fmax(app.remainingDays / 7.0f, 0.08f), 1.0f);
                bar.progress = prog;
                bar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
                bar.progressTintColor = isExpiredOrInvalid ? [UIColor systemRedColor] : [UIColor colorWithRed:0.18 green:0.85 blue:0.55 alpha:1.0];
                [card addSubview:bar];

                UIButton *guardBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                guardBtn.frame = CGRectMake(cardW - 102, 14, 90, 24);
                guardBtn.layer.cornerRadius = 12;
                guardBtn.tag = indexPath.row;
                guardBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
                if (app.isJailbreakLoader) {
                    guardBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.55 blue:0.42 alpha:0.65];
                    [guardBtn setTitle:@"🔒 核心必守" forState:UIControlStateNormal];
                    [guardBtn setTitleColor:[UIColor colorWithRed:0.6 green:1.0 blue:0.8 alpha:1.0] forState:UIControlStateNormal];
                } else if (app.isGuarded) {
                    guardBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.56 blue:0.98 alpha:0.45];
                    [guardBtn setTitle:@"🛡️ 自动守护中" forState:UIControlStateNormal];
                    [guardBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                } else {
                    guardBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
                    [guardBtn setTitle:@"➕ 设为守护" forState:UIControlStateNormal];
                    [guardBtn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.65] forState:UIControlStateNormal];
                }
                [guardBtn addTarget:self action:@selector(onToggleGuardTapped:) forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:guardBtn];

                UIButton *resignBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                resignBtn.frame = CGRectMake(cardW - 102, 46, 90, 38);
                resignBtn.backgroundColor = isExpiredOrInvalid
                    ? [UIColor colorWithRed:0.90 green:0.28 blue:0.25 alpha:0.95]
                    : [UIColor colorWithRed:0.12 green:0.68 blue:0.48 alpha:0.95];
                resignBtn.layer.cornerRadius = 19;
                [resignBtn setTitle:(isExpiredOrInvalid ? @"⚡ 立即修复" : @"⚡ 立即续签") forState:UIControlStateNormal];
                [resignBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                resignBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                resignBtn.tag = indexPath.row;
                [resignBtn addTarget:self action:@selector(onFastResignTapped:) forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:resignBtn];
            }
        }
        else {
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 11, cardW - 104, 46)];
            lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
            lbl.textColor = [UIColor whiteColor];
            lbl.numberOfLines = 2;
            lbl.text = (indexPath.row == 0)
                ? @"📦 导入外部 IPA / TIPA 安装包\n从「文件」选择安装包并签入 7 天苹果真证书"
                : @"📲 一键全量续签已守护应用\n立即将所有已勾选守护的应用重置回满血 7 天";
            [card addSubview:lbl];

            UIButton *actBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            actBtn.frame = CGRectMake(cardW - 84, 19, 70, 30);
            actBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
            actBtn.layer.cornerRadius = 15;
            [actBtn setTitle:(indexPath.row == 0 ? @"选择文件" : @"立即刷新") forState:UIControlStateNormal];
            [actBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            actBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            actBtn.userInteractionEnabled = NO;
            [card addSubview:actBtn];
        }
    }
    else if (_currentTab == 1) {
        // ==================== 第 2 页：📜 日志 (包含全部成功与失败原因) ====================
        if (_simpleLogs.count == 0) {
            UILabel *empty = [[UILabel alloc] initWithFrame:card.bounds];
            empty.textAlignment = NSTextAlignmentCenter;
            empty.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
            empty.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
            empty.text = @"暂无记录 · 您的登录、签名与自动续签结果都会在此显示";
            [card addSubview:empty];
        } else {
            NSDictionary *entry = _simpleLogs[indexPath.row];
            BOOL ok = [entry[@"success"] boolValue];

            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, cardW - 110, 20)];
            titleLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
            titleLbl.textColor = ok ? [UIColor colorWithRed:0.45 green:0.95 blue:0.70 alpha:1.0] : [UIColor colorWithRed:1.0 green:0.48 blue:0.42 alpha:1.0];
            titleLbl.text = entry[@"title"] ?: @"事件记录";
            [card addSubview:titleLbl];

            UILabel *timeLbl = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 96, 12, 80, 18)];
            timeLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
            timeLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
            timeLbl.textAlignment = NSTextAlignmentRight;
            timeLbl.text = entry[@"time"] ?: @"";
            [card addSubview:timeLbl];

            UILabel *detailLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, cardW - 32, 36)];
            detailLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
            detailLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
            detailLbl.numberOfLines = 2;
            detailLbl.text = entry[@"detail"] ?: @"";
            [card addSubview:detailLbl];
        }
    }
    else {
        // ==================== 第 3 页：⚙️ 设置 (Section 0 为 Apple ID 账号卡片) ====================
        if (indexPath.section == 0) {
            AuraAppleDeveloperAPI *api = [AuraAppleDeveloperAPI sharedAPI];
            BOOL loggedIn = [api hasValidAccountInKeychain];

            UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cardW - 122, 22)];
            t.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
            t.textColor = [UIColor whiteColor];
            t.text = loggedIn ? [api currentAppleIDEmail] : @"尚未绑定 Apple ID";
            [card addSubview:t];

            UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(18, 36, cardW - 122, 34)];
            s.font = [UIFont systemFontOfSize:11.5];
            s.numberOfLines = 2;
            s.textColor = loggedIn ? [UIColor colorWithRed:0.4 green:0.95 blue:0.65 alpha:1.0] : [UIColor colorWithRed:1.0 green:0.75 blue:0.35 alpha:1.0];
            s.text = loggedIn
                ? [NSString stringWithFormat:@"✓ TeamID: %@\n%@", [api currentTeamID], [api availableAppIdQuotaText]]
                : @"⚠️ 请点击右侧【立即登录】调起苹果认证获取 7 天真证书";
            [card addSubview:s];

            UIButton *loginBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            loginBtn.frame = CGRectMake(cardW - 100, 22, 84, 36);
            loginBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.56 blue:0.98 alpha:0.95];
            loginBtn.layer.cornerRadius = 18;
            [loginBtn setTitle:(loggedIn ? @"切换账号" : @"立即登录") forState:UIControlStateNormal];
            [loginBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            loginBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            [loginBtn addTarget:self action:@selector(onAppleIDLoginButtonTapped) forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:loginBtn];
        } else {
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, cardW - 100, 46)];
            lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
            lbl.textColor = [UIColor whiteColor];
            lbl.numberOfLines = 2;
            [card addSubview:lbl];

            if (indexPath.section == 1) {
                if (indexPath.row == 0) {
                    lbl.text = [NSString stringWithFormat:@"⚡ 后台静默自动续签\n证书剩余少于 %ld 天时联网自动续回 7 天", (long)engine.normalRenewThresholdDays];
                    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 20, 51, 31)];
                    sw.on = engine.autoRenewEnabled;
                    sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                    sw.tag = 200;
                    [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                    [card addSubview:sw];
                } else if (indexPath.row == 1) {
                    lbl.text = [NSString stringWithFormat:@"📅 常规静默续签触发天数设置\n当已守护应用剩余少于【%ld 天】时自动续签", (long)engine.normalRenewThresholdDays];
                    UIButton *cfgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                    cfgBtn.frame = CGRectMake(cardW - 88, 19, 74, 32);
                    cfgBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
                    cfgBtn.layer.cornerRadius = 16;
                    [cfgBtn setTitle:[NSString stringWithFormat:@"<%ld天 ▾", (long)engine.normalRenewThresholdDays] forState:UIControlStateNormal];
                    [cfgBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    cfgBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                    [cfgBtn addTarget:self action:@selector(onConfigureNormalRenewRuleTapped) forControlEvents:UIControlEventTouchUpInside];
                    [card addSubview:cfgBtn];
                } else if (indexPath.row == 2) {
                    lbl.text = @"🔋 低电量 (<5%) 紧急抢救续签开关\n防止手机没电自动关机后证书过期失联";
                    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 20, 51, 31)];
                    sw.on = engine.lowBatteryRescueEnabled;
                    sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                    sw.tag = 201;
                    [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                    [card addSubview:sw];
                } else {
                    lbl.text = [NSString stringWithFormat:@"⏱️ 低电量抢救触发天数设置\n当电量 <%ld%% 且证书少于【%ld 天】时紧急续签",
                                (long)engine.lowBatteryTriggerPercent, (long)engine.lowBatteryThresholdDays];
                    UIButton *cfgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                    cfgBtn.frame = CGRectMake(cardW - 88, 19, 74, 32);
                    cfgBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
                    cfgBtn.layer.cornerRadius = 16;
                    [cfgBtn setTitle:[NSString stringWithFormat:@"<%ld天 ▾", (long)engine.lowBatteryThresholdDays] forState:UIControlStateNormal];
                    [cfgBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    cfgBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                    [cfgBtn addTarget:self action:@selector(onConfigureLowBatteryRuleTapped) forControlEvents:UIControlEventTouchUpInside];
                    [card addSubview:cfgBtn];
                }
            } else {
                if (indexPath.row == 0) {
                    lbl.text = @"🛑 关机/重启掉签系统级强拦截\n证书过期时尝试关机重启将弹窗拦截并提供续签";
                    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 20, 51, 31)];
                    sw.on = engine.rebootShieldEnabled;
                    sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                    sw.tag = 202;
                    [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                    [card addSubview:sw];
                } else if (indexPath.row == 1) {
                    lbl.text = @"🔔 签名完成系统横幅通知\n以「灵签 Pro」名义在屏幕顶部弹出通知与提示音";
                    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 68, 20, 51, 31)];
                    sw.on = engine.notificationEnabled;
                    sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:1.0];
                    sw.tag = 203;
                    [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
                    [card addSubview:sw];
                } else {
                    lbl.text = @"📨 发送测试系统横幅通知\n点击立即测试「灵签 Pro」顶部横幅弹窗与提示音";
                    UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                    testBtn.frame = CGRectMake(cardW - 88, 19, 74, 32);
                    testBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
                    testBtn.layer.cornerRadius = 16;
                    [testBtn setTitle:@"点击测试" forState:UIControlStateNormal];
                    [testBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    testBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
                    testBtn.userInteractionEnabled = NO;
                    [card addSubview:testBtn];
                }
            }
        }
    }

    return cell;
}

- (void)onToggleGuardTapped:(UIButton *)sender {
    if (sender.tag >= _installedApps.count) return;
    AuraAppInfo *app = _installedApps[sender.tag];
    NSString *errMsg = nil;
    if ([[AuraSignEngine sharedEngine] toggleGuardForApp:app allApps:_installedApps outError:&errMsg]) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen impactOccurred];
        [_tableView reloadData];
    } else if (errMsg.length) {
        [self showResultAlertWithTitle:@"提示" message:errMsg];
    }
}

- (void)onSwitchToggled:(UISwitch *)sender {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    if (sender.tag == 200) engine.autoRenewEnabled = sender.isOn;
    else if (sender.tag == 201) engine.lowBatteryRescueEnabled = sender.isOn;
    else if (sender.tag == 202) engine.rebootShieldEnabled = sender.isOn;
    else if (sender.tag == 203) engine.notificationEnabled = sender.isOn;
    [engine savePreferences];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_currentTab == 0) {
        if (indexPath.section == 2 && indexPath.row == 0) {
            if (![[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
                [self onAppleIDLoginButtonTapped];
                return;
            }
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        } else if (indexPath.section == 2 && indexPath.row == 1) {
            if (![[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
                [self onAppleIDLoginButtonTapped];
                return;
            }
            [self showLoadingHUD:@"正在连接苹果服务器刷新已守护应用..."];
            [[AuraSignEngine sharedEngine] performEmergencyResignAllWithCompletion:^(BOOL success, NSString *message) {
                [self hideLoadingHUD];
                [self reloadAllDataAsync];
                [self showResultAlertWithTitle:(success ? @"✅ 刷新完成" : @"⚠️ 操作提示") message:message];
            }];
        }
    } else if (_currentTab == 2) {
        if (indexPath.section == 0) {
            [self onAppleIDLoginButtonTapped];
        } else if (indexPath.section == 1 && indexPath.row == 1) {
            [self onConfigureNormalRenewRuleTapped];
        } else if (indexPath.section == 1 && indexPath.row == 3) {
            [self onConfigureLowBatteryRuleTapped];
        } else if (indexPath.section == 2 && indexPath.row == 2) {
            [AuraSignEngine sharedEngine].notificationEnabled = YES;
            [[AuraSignEngine sharedEngine] savePreferences];
            [[AuraSignEngine sharedEngine] sendSystemNotificationWithTitle:@"✅ 证书续签成功 (测试通知)"
                                                                      body:@"【Dopamine】已成功签入满血 7 天苹果真证书并通过开机校验！"];
        }
    }
}

- (void)onConfigureNormalRenewRuleTapped {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"📅 常规静默续签触发天数设置"
                                                                   message:@"当后台检测到已守护应用的证书剩余少于多少天时，自动联网重置回 7 天："
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger days = 1; days <= 6; days++) {
        NSString *title = [NSString stringWithFormat:@"证书剩余少于【%ld 天】时自动静默续签%@",
                           (long)days, (days == engine.normalRenewThresholdDays ? @" ✓" : @"")];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            engine.normalRenewThresholdDays = days;
            [engine savePreferences];
            [_tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onConfigureLowBatteryRuleTapped {
    AuraSignEngine *engine = [AuraSignEngine sharedEngine];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"🔋 低电量抢救触发天数设置"
                                                                   message:[NSString stringWithFormat:@"当手机电量不到 %ld%% 时，证书剩余少于多少天自动触发紧急续签：",
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

- (void)onAppleIDLoginButtonTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"👤 第 1 步：登录 Apple ID"
                                                                   message:@"请输入您的个人免费 Apple ID 与密码。若您的账号开启了双重认证，点击下一步后手机屏幕将弹出 6 位验证码。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 邮箱 (如 571322016@qq.com)";
        tf.keyboardType = UIKeyboardTypeEmailAddress;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Apple ID 密码";
        tf.secureTextEntry = YES;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"下一步" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *email = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *pass  = alert.textFields[1].text ?: @"";
        if (!email.length || !pass.length) {
            [self showResultAlertWithTitle:@"提示" message:@"请输入完整的 Apple ID 邮箱与密码"];
            return;
        }
        [self showLoadingHUD:@"正在向苹果 GSA 发起加密握手..."];
        [[AuraAppleDeveloperAPI sharedAPI] loginWithAppleID:email password:pass twoFactorCode:nil completion:^(BOOL success, BOOL need2FA, NSString *errorMsg) {
            [self hideLoadingHUD];
            [self reloadAllDataAsync];
            if (success) {
                [[AuraSignEngine sharedEngine] appendSimpleUserLogWithTitle:@"👤 Apple ID 绑定成功"
                                                                     detail:[NSString stringWithFormat:@"已成功登录 %@ 并激活 1 年期个人开发证书 (TeamID: %@)", email, [[AuraAppleDeveloperAPI sharedAPI] currentTeamID]]
                                                                    success:YES];
                [self reloadAllDataAsync];
                [self showResultAlertWithTitle:@"🎉 绑定成功"
                                       message:[NSString stringWithFormat:@"已成功获取苹果 TeamID (%@) 并签发 1 年期真证书！现在您可以前往「签名」页点击【立即修复/续签】。", [[AuraAppleDeveloperAPI sharedAPI] currentTeamID]]];
            } else if (need2FA) {
                [self showStep2TwoFactorPromptWithEmail:email password:pass];
            } else {
                [self showResultAlertWithTitle:@"❌ 登录未通过" message:(errorMsg ?: @"请前往「日志」页查看具体原因")];
            }
        }];
    }]];

    if ([[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"退出当前账号" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[AuraAppleDeveloperAPI sharedAPI] logoutCurrentAccount];
            [self reloadAllDataAsync];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showStep2TwoFactorPromptWithEmail:(NSString *)email password:(NSString *)password {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🔐 第 2 步：输入 6 位双重认证码"
                                                                   message:@"苹果已向您的手机推送双重认证弹窗，请点击系统弹窗上的「允许」，并将显示的 6 位数字验证码填入下方："
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"6 位数字验证码";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.textAlignment = NSTextAlignmentCenter;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"验证并生成 1 年真证书" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *code = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (code.length != 6) {
            [self showResultAlertWithTitle:@"提示" message:@"请输入完整的 6 位数字验证码"];
            return;
        }
        [self showLoadingHUD:@"正在兑换 Xcode 开发者令牌并签发证书..."];
        [[AuraAppleDeveloperAPI sharedAPI] loginWithAppleID:email password:password twoFactorCode:code completion:^(BOOL success, BOOL need2FA, NSString *errorMsg) {
            [self hideLoadingHUD];
            [self reloadAllDataAsync];
            if (success) {
                [[AuraSignEngine sharedEngine] appendSimpleUserLogWithTitle:@"👤 Apple ID 绑定成功"
                                                                     detail:[NSString stringWithFormat:@"已通过双重认证登录 %@ 并激活 1 年期个人开发证书", email]
                                                                    success:YES];
                [self reloadAllDataAsync];
                [self showResultAlertWithTitle:@"🎉 绑定成功"
                                       message:[NSString stringWithFormat:@"已成功获取苹果 TeamID (%@) 并签发 1 年期真证书！现在您可以前往「签名」页点击【立即修复/续签】。", [[AuraAppleDeveloperAPI sharedAPI] currentTeamID]]];
            } else {
                [self showResultAlertWithTitle:@"❌ 验证未通过" message:(errorMsg ?: @"请前往「日志」页查看具体原因")];
            }
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 单独点击某个软件的「立即修复 / 立即续签」：未登录时自动引导登录，已登录时严格只签所点击的这 1 个软件
- (void)onFastResignTapped:(UIButton *)sender {
    if (![[AuraAppleDeveloperAPI sharedAPI] hasValidAccountInKeychain]) {
        [self onAppleIDLoginButtonTapped];
        return;
    }

    AuraAppInfo *app = _installedApps[sender.tag];
    [self showLoadingHUD:[NSString stringWithFormat:@"正在向苹果申请 7 天描述文件并重签\n【%@】...", app.appName]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *err = nil;
        BOOL ok = [[AuraSignEngine sharedEngine] fastResignApp:app error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideLoadingHUD];
            [self reloadAllDataAsync];
            if (ok) {
                UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                [self showResultAlertWithTitle:@"✅ 续签成功"
                                       message:[NSString stringWithFormat:@"【%@】已成功签入苹果官方 7 天真证书并通过 libmis 未越狱开机校验！", app.appName]];
            } else {
                [self showResultAlertWithTitle:@"❌ 签名未完成" message:(err.localizedDescription ?: @"请切到「📜 日志」页查看具体失败原因")];
            }
        });
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *fileURL = urls.firstObject;
    if (!fileURL) return;
    [fileURL startAccessingSecurityScopedResource];
    NSString *localCopy = [NSTemporaryDirectory() stringByAppendingPathComponent:fileURL.lastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:localCopy error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:fileURL.path toPath:localCopy error:nil];
    [fileURL stopAccessingSecurityScopedResource];

    [self showLoadingHUD:@"正在解压并向苹果申请 7 天真证书..."];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *err = nil;
        BOOL ok = [[AuraSignEngine sharedEngine] installAndSignIPAFileAtPath:localCopy error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideLoadingHUD];
            [self reloadAllDataAsync];
            if (ok) {
                [self showResultAlertWithTitle:@"✅ 安装完成" message:@"IPA 已成功签入 7 天苹果真证书并安装至桌面！"];
            } else {
                [self showResultAlertWithTitle:@"❌ 签名安装未通过" message:(err.localizedDescription ?: @"请切到「📜 日志」页查看具体原因")];
            }
        });
    });
}

- (NSString *)buildFullDiagnosticReportString {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"=== AuraSign Pro 深度诊断报告 ===\n"];
    [report appendFormat:@"iOS版本: %@\n", [[UIDevice currentDevice] systemVersion]];
    [report appendFormat:@"越狱目录: %@\n", AURA_NS_JBROOT(@"/")];
    [report appendFormat:@"UDID获取: %@\n", [[AuraAppleDeveloperAPI sharedAPI] realDeviceUDID].length ? @"成功" : @"空"];
    [report appendFormat:@"--------------------------------\n"];

    NSArray<NSDictionary *> *logs = [[AuraSignEngine sharedEngine] readAuditTimelineLogs];
    if (logs.count == 0) {
        [report appendString:@"(暂无底层运行日志记录)\n"];
    } else {
        for (NSDictionary *entry in logs) {
            [report appendFormat:@"[%@] %@\n", entry[@"time"], entry[@"event"]];
        }
    }
    return report;
}

- (void)showResultAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if ([title containsString:@"❌"] || [title containsString:@"⚠️"]) {
        [a addAction:[UIAlertAction actionWithTitle:@"📋 复制详细诊断日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = [self buildFullDiagnosticReportString];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
