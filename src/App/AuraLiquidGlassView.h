#pragma once
#import <UIKit/UIKit.h>

@interface AuraLiquidGlassView : UIView
@property (nonatomic, assign) CGFloat tintLevel;
@property (nonatomic, strong) UIColor *accentGlowColor;

- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)playShimmerSuccessAnimation;
@end
