/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <UIKit/UIKit.h>
#import <PushKit/PushKit.h>
#import <AVFoundation/AVFoundation.h>
@import OneSignalFramework;

@interface AppDelegate : UIResponder <UIApplicationDelegate, PKPushRegistryDelegate, OSPushSubscriptionObserver, UNUserNotificationCenterDelegate, OSNotificationLifecycleListener>
{
    PKPushRegistry *pushRegistry;
    NSString *normalPushToken;
    NSString *pushKitToken;
}
@property (strong, nonatomic) UIWindow *window;
@property (assign, nonatomic) BOOL shouldLockInterfaceOrientation;
@property (assign, nonatomic) UIInterfaceOrientation lockedInterfaceOrientation;
@property (strong, nonatomic) AVAudioPlayer *ringtonePlayer;

- (void)keepExternalSignalingConnectionAliveTemporarily;
- (void)playRingtone;
- (void)stopRingtone;

@end

