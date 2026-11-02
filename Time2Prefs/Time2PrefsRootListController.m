//
//  Time2PrefsRootListController.m
//  设置面板：写入偏好 plist 后发 Darwin 通知，SpringBoard 端主线程实时生效
//

#import "Time2PrefsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.xiaoyu.time2.plist";
static NSString *const kPrefsChangedNotification = @"com.xiaoyu.time2.prefschanged";

@implementation Time2PrefsRootListController

- (NSMutableArray *)specifiers {
    _specifiers = [self loadSpecifiersFromPlistName:@"Time2Root" target:self];
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    id v = prefs[key];
    if (v == nil) v = [specifier propertyForKey:@"default"];
    return v;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary dictionary];
    [prefs setObject:value forKey:key];
    [prefs writeToFile:kPrefsPath atomically:YES];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kPrefsChangedNotification,
                                         NULL, NULL, YES);
    [self reloadSpecifiers];
}

#pragma mark - Actions

- (void)openSileo:(id)sender {
    NSURL *url = [NSURL URLWithString:@"sileo://package/com.xiaoyu.time2"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        NSURL *web = [NSURL URLWithString:@"https://github.com/sdfjkhwekfw/time2"];
        [[UIApplication sharedApplication] openURL:web options:@{} completionHandler:nil];
    }
}

- (void)openTelegram:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://t.me/"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)openQQ:(id)sender {
    NSURL *url = [NSURL URLWithString:@"mqqapi://card/show_pslcard?"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)respring:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重新加载"
                                                                   message:@"确定要注销 SpringBoard 吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.apple.springboard.restart"),
                                             NULL, NULL, YES);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
