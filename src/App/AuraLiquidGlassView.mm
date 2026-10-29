#import "AuraLiquidGlassView.h"
#import <QuartzCore/QuartzCore.h>

@implementation AuraLiquidGlassView {
    UIVisualEffectView *_blurView;
    UIView *_tintOverlay;
    CAGradientLayer *_specularRimLayer;
    CAShapeLayer *_rimMaskLayer;
    CGFloat _cornerRadius;
}

- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)radius {
    if (self = [super initWithFrame:frame]) {
        _cornerRadius = radius;
        self.layer.cornerRadius = radius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blurView];

        _tintOverlay = [[UIView alloc] initWithFrame:self.bounds];
        _tintOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _tintOverlay.userInteractionEnabled = NO;
        [self addSubview:_tintOverlay];

        _specularRimLayer = [CAGradientLayer layer];
        _specularRimLayer.startPoint = CGPointMake(0.0, 0.0);
        _specularRimLayer.endPoint = CGPointMake(1.0, 1.0);
        _specularRimLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.65].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.40].CGColor
        ];
        [self.layer addSublayer:_specularRimLayer];

        _rimMaskLayer = [CAShapeLayer layer];
        _rimMaskLayer.fillColor = [UIColor clearColor].CGColor;
        _rimMaskLayer.strokeColor = [UIColor whiteColor].CGColor;
        _rimMaskLayer.lineWidth = 1.4;
        _specularRimLayer.mask = _rimMaskLayer;

        [self setTintLevel:0.25f];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _specularRimLayer.frame = self.bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.7, 0.7) cornerRadius:_cornerRadius];
    _rimMaskLayer.path = path.CGPath;
}

- (void)setTintLevel:(CGFloat)tintLevel {
    _tintLevel = fmin(fmax(tintLevel, 0.0), 1.0);
    UIColor *baseColor = _accentGlowColor ?: [UIColor colorWithRed:0.08 green:0.12 blue:0.18 alpha:1.0];
    _tintOverlay.backgroundColor = [baseColor colorWithAlphaComponent:(0.10 + _tintLevel * 0.58)];
}

- (void)setAccentGlowColor:(UIColor *)accentGlowColor {
    _accentGlowColor = accentGlowColor;
    [self setTintLevel:_tintLevel];
}

- (void)playShimmerSuccessAnimation {
    CABasicAnimation *flash = [CABasicAnimation animationWithKeyPath:@"opacity"];
    flash.fromValue = @(1.0);
    flash.toValue = @(0.3);
    flash.duration = 0.25;
    flash.autoreverses = YES;
    flash.repeatCount = 2;
    [_specularRimLayer addAnimation:flash forKey:@"liquidShimmer"];
}

@end
