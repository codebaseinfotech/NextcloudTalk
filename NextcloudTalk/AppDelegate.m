/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "AppDelegate.h"

#import "AFNetworkReachabilityManager.h"
#import "AFNetworkActivityIndicatorManager.h"

#import <Intents/Intents.h>
#import <UserNotifications/UserNotifications.h>
#import <AudioToolbox/AudioToolbox.h>

#import <BackgroundTasks/BGTaskScheduler.h>
#import <BackgroundTasks/BGTaskRequest.h>
#import <BackgroundTasks/BGTask.h>

#import <SDWebImage/SDImageCache.h>

#import "NCAppBranding.h"
#import "NCDatabaseManager.h"
#import "NCKeyChainController.h"
#import "NCNotificationController.h"
#import "NCPushNotification.h"
#import "NCSettingsController.h"
#import "NCUserInterfaceController.h"

#import "NextcloudTalk-Swift.h"

@import UICKeyChainStore;
@import OneSignalFramework;
@import FirebaseCore;

@interface AppDelegate ()

@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, strong) BGTaskHelper *keepAliveBGTask;
@property (nonatomic, strong) UILabel *debugLabel;
@property (nonatomic, strong) NSTimer *debugLabelTimer;
@property (nonatomic, strong) NSTimer *fileDescriptorTimer;

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
#if DEBUG
    [AFNetworkActivityIndicatorManager sharedManager].enabled = YES;
#endif
    [[AFNetworkReachabilityManager sharedManager] startMonitoring];

    // Set notification delegate for foreground notifications
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;

    // Firebase Setup
    [FIRApp configure];
    NSLog(@"Firebase initialized");

    // Fetch Remote Config
    [[RemoteConfigManager shared] fetchRemoteConfigWithCompletion:^(BOOL success) {
        NSLog(@"📱 Remote Config fetch completed: %@", success ? @"YES" : @"NO");
        if (success) {
            // Try to subscribe for push notifications now that noti_base_url is available
            // This fixes the race condition on first install where tokens arrive before Remote Config completes
            // Add a delay to ensure all initialization is complete
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSLog(@"🔔 [DEBUG CALL] Remote Config completed - checking for push notification subscription (after delay)");
                [self checkForPushNotificationSubscriptionIgnoringBackground];
            });
        }
    }];

    // OneSignal Push Notification Setup
    [OneSignal initialize:@"0f4eb378-54a6-47f4-ad11-0b9288aba8fc" withLaunchOptions:launchOptions];
    [OneSignal.User.pushSubscription addObserver:self];
    [OneSignal.Notifications addForegroundLifecycleListener:self];
    [OneSignal.Notifications addClickListener:self];
    NSLog(@"OneSignal initialized with App ID");

    // Log subscription info after a delay to ensure it's ready
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *subscriptionId = OneSignal.User.pushSubscription.id;
        NSString *pushToken = OneSignal.User.pushSubscription.token;
        NSLog(@"OneSignal Subscription ID: %@", subscriptionId);
        NSLog(@"OneSignal Push Token: %@", pushToken);
        NSLog(@"OneSignal OptedIn: %d", OneSignal.User.pushSubscription.optedIn);
    });

    
    // Add OneSignal Tags
    [OneSignal.User addTagWithKey:@"device_type" value:@"ios"];

    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    if (activeAccount && activeAccount.userId) {
        [OneSignal.User addTagWithKey:@"user_id" value:activeAccount.userId];
        // Set OneSignal External ID for targeting users
        [OneSignal login:activeAccount.userId];
        NSLog(@"OneSignal: Logged in with external ID: %@", activeAccount.userId);
    }

    [OneSignal.Notifications requestPermission:^(BOOL accepted) {
        NSLog(@"OneSignal: User accepted notifications: %d", accepted);
    } fallbackToSettings:YES];

    [[NCNotificationController sharedInstance] requestAuthorization];
    
    [application registerForRemoteNotifications];
    
    pushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    pushRegistry.delegate = self;
    pushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];

    [[WebRTCCommon shared] dispatch:^{
        NSLog(@"Configure Audio Session");
        [NCAudioController shared];
    }];
    
    NSLog(@"Configure App Settings");
    [NCSettingsController sharedInstance];

    // Perform cleanup only once in app lifecycle
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^(void){
        @autoreleasepool {
            [NCLog removeOldLogfiles];
            [[SDImageCache sharedImageCache].diskCache removeExpiredData];
            [[NCSettingsController sharedInstance] createAccountsFile];
        }
    });

    UIDevice *currentDevice = [UIDevice currentDevice];
    [NCLog log:[NSString stringWithFormat:@"Starting %@, version %@, %@ %@, model %@", NSBundle.mainBundle.bundleIdentifier, [NCAppBranding getAppVersionString], currentDevice.systemName, currentDevice.systemVersion, currentDevice.model]];

    // Init rooms manager to start receiving NSNotificationCenter notifications
    [NCRoomsManager shared];

    [self registerBackgroundFetchTask];
    [self registerBackgroundProcessingTask];

    [NCUserInterfaceController sharedInstance].mainViewController = (NCSplitViewController *) self.window.rootViewController;
    [NCUserInterfaceController sharedInstance].roomsTableViewController = [NCUserInterfaceController sharedInstance].mainViewController.viewControllers.firstObject.childViewControllers.firstObject;
    [NCUserInterfaceController sharedInstance].mainViewController.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;

    NSArray *arguments = [[NSProcessInfo processInfo] arguments];

    if ([arguments containsObject:@"-TestEnvironment"]) {
        UIView *mainView = [NCUserInterfaceController sharedInstance].mainViewController.view;

        self.debugLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 30, 200, 20)];
        self.debugLabel.font = [UIFont systemFontOfSize:[UIFont smallSystemFontSize]];
        self.debugLabel.translatesAutoresizingMaskIntoConstraints = NO;

        [mainView addSubview:self.debugLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.debugLabel.topAnchor constraintEqualToAnchor:mainView.safeAreaLayoutGuide.topAnchor constant:-15],
            [self.debugLabel.leadingAnchor constraintEqualToAnchor:mainView.safeAreaLayoutGuide.leadingAnchor constant:5],
            [self.debugLabel.trailingAnchor constraintEqualToAnchor:mainView.safeAreaLayoutGuide.trailingAnchor]
        ]];

        __weak typeof(self) weakSelf = self;
        self.debugLabelTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            [weakSelf.debugLabel setText:[AllocationTracker shared].description];
        }];
    }

    // Comment out the following code to log the number of open socket file descriptors
    /*
     self.fileDescriptorTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [[WebRTCCommon shared] printNumberOfOpenSocketDescriptors];
    }];
     */

    // When we include VLCKit we need to manually call this because otherwise, device rotation might not work
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    
    return YES;
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(nonnull NSUserActivity *)userActivity restorationHandler:(nonnull void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler
{
    BOOL audioCallIntent = [userActivity.interaction.intent isKindOfClass:[INStartAudioCallIntent class]];
    BOOL videoCallIntent = [userActivity.interaction.intent isKindOfClass:[INStartVideoCallIntent class]];
    if (audioCallIntent || videoCallIntent) {
        INPerson *person = [[(INStartAudioCallIntent*)userActivity.interaction.intent contacts] firstObject];
        NSString *roomToken = person.personHandle.value;
        if (roomToken) {
            [[NCUserInterfaceController sharedInstance] presentCallKitCallInRoom:roomToken withVideoEnabled:videoCallIntent];
        }
    }

    // A INSendMessageIntent is usually a Siri/Shortcut suggestion and automatically created when we donate a INSendMessageIntent
    if ([userActivity.interaction.intent isKindOfClass:[INSendMessageIntent class]]) {
        // For a INSendMessageIntent we don't receive a conversationIdentifier, see NCIntentController
        INSendMessageIntent *intent = (INSendMessageIntent *)userActivity.interaction.intent;
        INPerson *recipient = intent.recipients.firstObject;

        if (recipient && recipient.customIdentifier && recipient.customIdentifier.length > 0) {
            NCRoom *room = [[NCDatabaseManager sharedInstance] roomWithInternalId:recipient.customIdentifier];

            if (room) {
                [[NCRoomsManager shared] startChatInRoom:room];
            }
        }
    }

    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
}


- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.

    [self keepExternalSignalingConnectionAliveTemporarily];
    [self scheduleAppRefresh];
    [self scheduleBackgroundProcessing];
}


- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
}


- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.

    [self checkForDisconnectedExternalSignalingConnection];

    [[NCNotificationController sharedInstance] removeAllNotificationsForAccountId:[[NCDatabaseManager sharedInstance] activeAccount].accountId];

    // Retry push notification subscription for accounts that haven't been subscribed yet
    // This helps with first install where subscription might fail due to timing issues
    for (TalkAccount *account in [[NCDatabaseManager sharedInstance] allAccounts]) {
        if (account.lastPushSubscription == 0) {
            NSLog(@"🔔 [DEBUG CALL] applicationDidBecomeActive - Retrying push subscription for account: %@", account.accountId);
            [[NCSettingsController sharedInstance] subscribeForPushNotificationsForAccountId:account.accountId withCompletionBlock:nil];
        }
    }
}

- (void)applicationProtectedDataDidBecomeAvailable:(UIApplication *)application
{
    if ([[CallKitManager sharedInstance].calls count] > 0) {
        [NCLog log:@"Protected data did become available"];
    }
}

- (void)applicationProtectedDataWillBecomeUnavailable:(UIApplication *)application
{
    if ([[CallKitManager sharedInstance].calls count] > 0) {
        [NCLog log:@"Protected data did become unavailable"];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];

    // Invalidate a potentially existing label timer
    [self.debugLabelTimer invalidate];

    [self.fileDescriptorTimer invalidate];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = urlComponents.scheme;
    if ([scheme isEqualToString:@"nextcloudtalk"]) {
        NSString *action = urlComponents.host;
        if ([action isEqualToString:@"open-conversation"]) {
            [[NCUserInterfaceController sharedInstance] presentChatForURL:urlComponents];
            return YES;
        } else if ([action isEqualToString:@"login"] && multiAccountEnabled) {
            NSArray *queryItems = urlComponents.queryItems;
            NSString *server = [NCUtils valueForKey:@"server" fromQueryItems:queryItems];
            NSString *user = [NCUtils valueForKey:@"user" fromQueryItems:queryItems];
            
            if (server) {
                [[NCUserInterfaceController sharedInstance] presentLoginViewControllerForServerURL:server withUser:user];
            }
            return YES;
        }
    }
    
    return NO;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    if (_shouldLockInterfaceOrientation) {
        if (_lockedInterfaceOrientation == UIInterfaceOrientationPortrait) {
            return UIInterfaceOrientationMaskPortrait;
        } else if (_lockedInterfaceOrientation == UIInterfaceOrientationLandscapeLeft) {
            return UIInterfaceOrientationMaskLandscapeLeft;
        } else if (_lockedInterfaceOrientation == UIInterfaceOrientationLandscapeRight) {
            return UIInterfaceOrientationMaskLandscapeRight;
        }
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)setShouldLockInterfaceOrientation:(BOOL)shouldLockInterfaceOrientation
{
    _shouldLockInterfaceOrientation = shouldLockInterfaceOrientation;
    _lockedInterfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
}

#pragma mark - Push Notifications Registration

- (void)checkForPushNotificationSubscription
{
    NSLog(@"🔔 [DEBUG CALL] checkForPushNotificationSubscription called");
    NSLog(@"🔔 [DEBUG CALL] normalPushToken: %@", normalPushToken ? @"SET" : @"NOT SET");
    NSLog(@"🔔 [DEBUG CALL] pushKitToken: %@", pushKitToken ? @"SET" : @"NOT SET");

    if (!normalPushToken || !pushKitToken) {
        NSLog(@"🔔 [DEBUG CALL] ⚠️ Waiting for both tokens before subscribing");
        return;
    }

    NSLog(@"🔔 [DEBUG CALL] ✅ Both tokens available - storing in keychain");

    // Store new Normal Push & PushKit tokens in Keychain
    UICKeyChainStore *keychain = [UICKeyChainStore keyChainStoreWithService:bundleIdentifier accessGroup:groupIdentifier];
    [keychain setString:normalPushToken forKey:kNCNormalPushTokenKey];
    [keychain setString:pushKitToken forKey:kNCPushKitTokenKey];

    BOOL isAppInBackground = [[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground;
    NSLog(@"🔔 [DEBUG CALL] App in background: %@", isAppInBackground ? @"YES" : @"NO");

    // Subscribe only if both tokens have been generated and app is not running in the background (do not try to subscribe
    // when the app is running in background e.g. when the app is launched due to a VoIP push notification)
    if (!isAppInBackground) {
        NSLog(@"🔔 [DEBUG CALL] 📤 Subscribing for push notifications for all accounts...");
        // Try to subscribe for push notifications in all accounts
        for (TalkAccount *account in [[NCDatabaseManager sharedInstance] allAccounts]) {
            NSLog(@"🔔 [DEBUG CALL] Subscribing account: %@", account.accountId);
            [[NCSettingsController sharedInstance] subscribeForPushNotificationsForAccountId:account.accountId withCompletionBlock:nil];
        }
    } else {
        NSLog(@"🔔 [DEBUG CALL] ⚠️ App in background - skipping subscription");
    }
}

- (void)checkForPushNotificationSubscriptionIgnoringBackground
{
    NSLog(@"🔔 [DEBUG CALL] checkForPushNotificationSubscriptionIgnoringBackground called");
    NSLog(@"🔔 [DEBUG CALL] normalPushToken: %@", normalPushToken ? @"SET" : @"NOT SET");
    NSLog(@"🔔 [DEBUG CALL] pushKitToken: %@", pushKitToken ? @"SET" : @"NOT SET");

    if (!normalPushToken || !pushKitToken) {
        NSLog(@"🔔 [DEBUG CALL] ⚠️ Waiting for both tokens before subscribing");
        return;
    }

    NSLog(@"🔔 [DEBUG CALL] ✅ Both tokens available - storing in keychain");

    // Store new Normal Push & PushKit tokens in Keychain
    UICKeyChainStore *keychain = [UICKeyChainStore keyChainStoreWithService:bundleIdentifier accessGroup:groupIdentifier];
    [keychain setString:normalPushToken forKey:kNCNormalPushTokenKey];
    [keychain setString:pushKitToken forKey:kNCPushKitTokenKey];

    // Force subscription regardless of background state (for first install after Remote Config loads)
    NSLog(@"🔔 [DEBUG CALL] 📤 Force subscribing for push notifications for all accounts (ignoring background state)...");
    for (TalkAccount *account in [[NCDatabaseManager sharedInstance] allAccounts]) {
        NSLog(@"🔔 [DEBUG CALL] Subscribing account: %@", account.accountId);
        [[NCSettingsController sharedInstance] subscribeForPushNotificationsForAccountId:account.accountId withCompletionBlock:nil];
    }
}

#pragma mark - Normal Push Notifications Delegate Methods

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    NSLog(@"🔔 [DEBUG CALL] ========== Normal Push Token Received ==========");

    if([deviceToken length] == 0) {
        NSLog(@"🔔 [DEBUG CALL] ❌ Failed to create Normal Push token - token is empty!");
        return;
    }

    normalPushToken = [self stringWithDeviceToken:deviceToken];
    NSLog(@"🔔 [DEBUG CALL] ✅ Normal push token: %@", normalPushToken);

    [self checkForPushNotificationSubscription];
    [self registerInteractivePushNotification];
}

- (void)registerInteractivePushNotification
{
    // Reply directly to a chat notification action/category
    UNTextInputNotificationAction *replyAction = [UNTextInputNotificationAction actionWithIdentifier:NCNotificationActionReplyToChat
                                                                                          title:NSLocalizedString(@"Reply", nil)
                                                                                        options:UNNotificationActionOptionAuthenticationRequired];
    
    UNNotificationCategory *chatCategory = [UNNotificationCategory categoryWithIdentifier:@"CATEGORY_CHAT"
                                                                              actions:@[replyAction]
                                                                    intentIdentifiers:@[]
                                                                              options:UNNotificationCategoryOptionNone];

    // Recording actions/category
    UNNotificationAction *recordingShareAction = [UNNotificationAction actionWithIdentifier:NCNotificationActionShareRecording
                                                                                      title:NSLocalizedString(@"Share to chat", nil)
                                                                                    options:UNNotificationActionOptionAuthenticationRequired];

    UNNotificationAction *recordingDismissAction = [UNNotificationAction actionWithIdentifier:NCNotificationActionDismissRecordingNotification
                                                                                      title:NSLocalizedString(@"Dismiss notification", nil)
                                                                                    options:UNNotificationActionOptionAuthenticationRequired | UNNotificationActionOptionDestructive];

    UNNotificationCategory *recordingCategory = [UNNotificationCategory categoryWithIdentifier:@"CATEGORY_RECORDING"
                                                                                       actions:@[recordingShareAction, recordingDismissAction]
                                                                             intentIdentifiers:@[]
                                                                                       options:UNNotificationCategoryOptionNone];

    // Federation invitation
    UNNotificationAction *federationAccept = [UNNotificationAction actionWithIdentifier:NCNotificationActionFederationInvitationAccept
                                                                                  title:NSLocalizedString(@"Accept", nil)
                                                                                options:UNNotificationActionOptionAuthenticationRequired];

    UNNotificationAction *federationReject = [UNNotificationAction actionWithIdentifier:NCNotificationActionFederationInvitationReject
                                                                                  title:NSLocalizedString(@"Reject", nil)
                                                                                options:UNNotificationActionOptionAuthenticationRequired | UNNotificationActionOptionDestructive];

    UNNotificationCategory *federationCategory = [UNNotificationCategory categoryWithIdentifier:@"CATEGORY_FEDERATION"
                                                                                       actions:@[federationAccept, federationReject]
                                                                             intentIdentifiers:@[]
                                                                                       options:UNNotificationCategoryOptionNone];

    NSSet *categories = [NSSet setWithObjects:chatCategory, recordingCategory, federationCategory, nil];
    [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:categories];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    // Called when a background notification is delivered.
    NSString *message = [userInfo objectForKey:@"subject"];
    NSString *signature = [userInfo objectForKey:@"signature"];

    if (!message || !signature) {
        return;
    }

    for (TalkAccount *account in [[NCDatabaseManager sharedInstance] allAccounts]) {
        NSString *decryptedMessage = [NCPushNotificationsUtils decryptPushNotificationWithMessageBase64:message withSignatureBase64:signature forAccount:account];
        if (decryptedMessage) {
            NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:decryptedMessage withAccountId:account.accountId];
            [[NCNotificationController sharedInstance] processBackgroundPushNotification:pushNotification];

            break;
        }
    }

    // Check if the other notifications are still current and try to remove them otherwise
    [[NCNotificationController sharedInstance] checkNotificationExistanceWithCompletionBlock:^(NSError *error) {
        completionHandler(UIBackgroundFetchResultNewData);
    }];
}


#pragma mark - PushKit Delegate Methods

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type
{
    NSLog(@"🔔 [DEBUG CALL] ========== PushKit Credentials Updated ==========");
    NSLog(@"🔔 [DEBUG CALL] Push type: %@", type);

    if([credentials.token length] == 0) {
        NSLog(@"🔔 [DEBUG CALL] ❌ Failed to create PushKit token - token is empty!");
        return;
    }

    pushKitToken = [self stringWithDeviceToken:credentials.token];
    NSLog(@"🔔 [DEBUG CALL] ✅ PushKit (VoIP) token received: %@", pushKitToken);
    NSLog(@"🔔 [DEBUG CALL] Normal push token: %@", normalPushToken ? normalPushToken : @"NOT SET YET");

    [self checkForPushNotificationSubscription];
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion
{
    NSLog(@"🔔 [DEBUG CALL] ========== VoIP PUSH RECEIVED ==========");
    [NCLog log:@"Received PushKit notification"];

    NSString *message = [payload.dictionaryPayload objectForKey:@"subject"];
    NSString *signature = [payload.dictionaryPayload objectForKey:@"signature"];

    NSLog(@"🔔 [DEBUG CALL] Payload keys: %@", [payload.dictionaryPayload allKeys]);
    NSLog(@"🔔 [DEBUG CALL] Message present: %@, Signature present: %@", message ? @"YES" : @"NO", signature ? @"YES" : @"NO");

    if (message && signature) {
        NSArray *allAccounts = [[NCDatabaseManager sharedInstance] allAccounts];
        NSLog(@"🔔 [DEBUG CALL] Number of accounts to try: %lu", (unsigned long)allAccounts.count);

        for (TalkAccount *account in allAccounts) {
            NSLog(@"🔔 [DEBUG CALL] Trying to decrypt for account: %@", account.accountId);
            NSString *decryptedMessage = [NCPushNotificationsUtils decryptPushNotificationWithMessageBase64:message withSignatureBase64:signature forAccount:account];

            if (!decryptedMessage) {
                NSLog(@"🔔 [DEBUG CALL] Decryption FAILED for account: %@", account.accountId);
                continue;
            }

            NSLog(@"🔔 [DEBUG CALL] Decryption SUCCESS for account: %@", account.accountId);
            NSLog(@"🔔 [DEBUG CALL] Decrypted message: %@", decryptedMessage);

            NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:decryptedMessage withAccountId:account.accountId];

            NSLog(@"🔔 [DEBUG CALL] Push notification created: %@", pushNotification ? @"YES" : @"NO");
            if (pushNotification) {
                NSLog(@"🔔 [DEBUG CALL] Push notification type: %ld (Call type = %d)", (long)pushNotification.type, NCPushNotificationTypeCall);
                NSLog(@"🔔 [DEBUG CALL] Room token: %@", pushNotification.roomToken);
                NSLog(@"🔔 [DEBUG CALL] Subject: %@", pushNotification.subject);
            }

            if (pushNotification && pushNotification.type == NCPushNotificationTypeCall) {
                NSLog(@"🔔 [DEBUG CALL] ✅ This IS a CALL notification - showing incoming call");
                [[NCNotificationController sharedInstance] showIncomingCallForPushNotification:pushNotification];
                completion();
                return;
            } else {
                NSLog(@"🔔 [DEBUG CALL] ⚠️ This is NOT a call notification, type: %ld", (long)pushNotification.type);
            }
        }
    } else {
        NSLog(@"🔔 [DEBUG CALL] ❌ Message or signature is missing!");
    }

    NSLog(@"🔔 [DEBUG CALL] ⚠️ Falling back to showIncomingCallForOldAccount");
    [[NCNotificationController sharedInstance] showIncomingCallForOldAccount];
    [[NCSettingsController sharedInstance] setDidReceiveCallsFromOldAccount:YES];
    completion();
}

- (NSString *)stringWithDeviceToken:(NSData *)deviceToken
{
    const char *data = [deviceToken bytes];
    NSMutableString *token = [NSMutableString string];

    for (NSUInteger i = 0; i < [deviceToken length]; i++) {
        [token appendFormat:@"%02.2hhX", data[i]];
    }

    return [token copy];
}

#pragma mark - OneSignal Push Subscription Observer

- (void)onPushSubscriptionDidChangeWithState:(OSPushSubscriptionChangedState *)state {
    NSString *subscriptionId = state.current.id;
    NSString *pushToken = state.current.token;

    NSLog(@"OneSignal Subscription ID: %@", subscriptionId);
    NSLog(@"OneSignal Push Token: %@", pushToken);

    // You can send the subscriptionId to your server here if needed
}

#pragma mark - OSNotificationLifecycleListener (OneSignal Foreground)

- (void)onWillDisplayNotification:(OSNotificationWillDisplayEvent *)event {
    NSLog(@"📩 OneSignal: Will display notification: %@", event.notification.body);

    NSDictionary *additionalData = event.notification.additionalData;
    NSString *notificationConversationToken = additionalData[@"conversation_token"];
    NSString *eventType = additionalData[@"event"];
    NSString *callerName = additionalData[@"caller_name"];

    NSLog(@"📩 OneSignal: Event type: %@, Conversation token: %@", eventType, notificationConversationToken);

    // Check if this is a CALL notification (one-to-one or group call)
    BOOL isCallNotification = [eventType isEqualToString:@"call"] ||
                              [eventType isEqualToString:@"incoming_call"] ||
                              [eventType isEqualToString:@"start_call"] ||
                              [event.notification.body containsString:@"is calling you"] ||
                              [event.notification.body containsString:@"started a call"];
    
    

    if (isCallNotification && notificationConversationToken && notificationConversationToken.length > 0) {
        NSLog(@"📞 OneSignal: CALL notification detected! Triggering CallKit and ringtone...");

        // Prevent the regular notification banner - we'll show CallKit instead
        [event preventDefault];

        // Get caller display name
        NSString *displayName = callerName ?: event.notification.title ?: @"Incoming call";

        // Get account ID (use active account)
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        NSString *accountId = activeAccount.accountId;

        NSLog(@"📞 OneSignal: Showing CallKit for room: %@, caller: %@, account: %@", notificationConversationToken, displayName, accountId);

        // Trigger CallKit and ringtone on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Start playing ringtone
            [self playRingtone];

            if ([CallKitManager isCallKitAvailable]) {
                [[CallKitManager sharedInstance] reportIncomingCall:notificationConversationToken
                                                    withDisplayName:displayName
                                                       forAccountId:accountId];
            } else {
                // Fallback: show local notification if CallKit is not available
                NSLog(@"📞 OneSignal: CallKit not available, showing local notification");
                [event.notification display];
            }
        });

        return;
    }

    // Check if user is currently in an active chat with the same conversation (for non-call notifications)
    if (notificationConversationToken && notificationConversationToken.length > 0) {
        // Get current active chat's room token
        ChatViewController *currentChat = [NCRoomsManager shared].chatViewController;
        NSString *currentRoomToken = currentChat.room.token;

        if (currentRoomToken && [currentRoomToken isEqualToString:notificationConversationToken]) {
            // User is currently viewing this conversation, suppress the notification
            NSLog(@"📩 OneSignal: Suppressing notification - user is in active chat with token: %@", notificationConversationToken);
            [event preventDefault];
            return;
        }
    }

    // Display the notification
    [event.notification display];
}

#pragma mark - OSNotificationClickListener (OneSignal Click)

- (void)onClickNotification:(OSNotificationClickEvent *)event {
    NSLog(@"📩 OneSignal: Notification clicked!");

    OSNotification *notification = event.notification;
    NSDictionary *additionalData = notification.additionalData;

    NSLog(@"📩 OneSignal: Additional data: %@", additionalData);

    // Handle conversation_token from OneSignal notification payload
    NSString *conversationToken = additionalData[@"conversation_token"];
    NSString *eventType = additionalData[@"event"];
    NSString *callerName = additionalData[@"caller_name"];

    // Check if this is a CALL notification (one-to-one or group call)
    BOOL isCallNotification = [eventType isEqualToString:@"call"] ||
                              [eventType isEqualToString:@"incoming_call"] ||
                              [eventType isEqualToString:@"start_call"] ||
                              [notification.body containsString:@"is calling you"] ||
                              [notification.body containsString:@"started a call"];

    if (conversationToken && conversationToken.length > 0) {
        NSLog(@"📩 OneSignal: Processing notification for token: %@, event: %@", conversationToken, eventType);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (isCallNotification) {
                // For call notifications, show CallKit or join the call
                NSLog(@"📞 OneSignal: Call notification clicked - triggering CallKit");

                NSString *displayName = callerName ?: notification.title ?: @"Incoming call";
                TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];

                // Play ringtone
                [self playRingtone];

                if ([CallKitManager isCallKitAvailable]) {
                    [[CallKitManager sharedInstance] reportIncomingCall:conversationToken
                                                        withDisplayName:displayName
                                                           forAccountId:activeAccount.accountId];
                } else {
                    // If CallKit not available, join the call directly
                    [[NCRoomsManager shared] startCallWithToken:conversationToken
                                                  withAccountId:activeAccount.accountId
                                                      withVideo:YES
                                                 enabledAtStart:YES
                                                    asInitiator:NO
                                                       silently:NO
                                               recordingConsent:NO
                                              withVoiceChatMode:NO];
                }
            } else {
                // For chat notifications, navigate to chat
                [[NCRoomsManager shared] startChatWithRoomToken:conversationToken];
            }
        });
    } else {
        NSLog(@"📩 OneSignal: No conversation_token found in notification data");
    }
}

#pragma mark - UNUserNotificationCenterDelegate (Foreground Notifications)

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // Show notification even when app is in foreground
    NSLog(@"📩 Foreground notification received: %@", notification.request.content.body);
    NSLog(@"📩 Notification userInfo: %@", notification.request.content.userInfo);

    // Check if user is currently in an active chat with the same conversation
    NSDictionary *userInfo = notification.request.content.userInfo;
    NSString *notificationConversationToken = userInfo[@"conversation_token"];

    if (notificationConversationToken && notificationConversationToken.length > 0) {
        // Get current active chat's room token
        ChatViewController *currentChat = [NCRoomsManager shared].chatViewController;
        NSString *currentRoomToken = currentChat.room.token;

        if (currentRoomToken && [currentRoomToken isEqualToString:notificationConversationToken]) {
            // User is currently viewing this conversation, suppress the notification
            NSLog(@"📩 Suppressing notification - user is in active chat with token: %@", notificationConversationToken);
            completionHandler(UNNotificationPresentationOptionNone);
            return;
        }
    }

    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
}

#pragma mark - BackgroundProcessing

- (void)registerBackgroundProcessingTask {
    NSString *processingTaskIdentifier = [NSString stringWithFormat:@"%@.processing", NSBundle.mainBundle.bundleIdentifier];

    // see: https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler?language=objc
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:processingTaskIdentifier
                                                          usingQueue:nil
                                                       launchHandler:^(__kindof BGTask * _Nonnull task) {
        [self handleBackgroundProcessing:task];
    }];
}

- (void)scheduleBackgroundProcessing
{
    NSString *processingTaskIdentifier = [NSString stringWithFormat:@"%@.processing", NSBundle.mainBundle.bundleIdentifier];

    BGProcessingTaskRequest *request = [[BGProcessingTaskRequest alloc] initWithIdentifier:processingTaskIdentifier];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:UIApplicationBackgroundFetchIntervalMinimum];
    request.requiresNetworkConnectivity = YES;
    request.requiresExternalPower = NO;

    NSError *error = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];

    if (error) {
        NSLog(@"Failed to submit background processing request: %@", error);
    }
}

- (void)handleBackgroundProcessing:(BGTask *)task
{
    [NCLog log:@"Performing background processing -> handleBackgroundProcessing"];

    // With BGTasks (iOS >= 13) we need to schedule another task when running in background
    [self scheduleBackgroundProcessing];

    BGTaskHelper *bgTask = [BGTaskHelper startBackgroundTaskWithName:@"NCBackgroundProcessing" expirationHandler:^(BGTaskHelper *task) {
        [NCLog log:@"ExpirationHandler NCBackgroundProcessing called"];
    }];

    // Check if the shown notifications are still available on the server
    [[NCNotificationController sharedInstance] checkNotificationExistanceWithCompletionBlock:^(NSError *error) {
        [NCLog log:@"CompletionHandler checkNotificationExistance"];

        [task setTaskCompletedWithSuccess:YES];
        [bgTask stopBackgroundTask];
    }];
}

#pragma mark - BackgroundFetch / AppRefresh

- (void)registerBackgroundFetchTask {
    NSString *refreshTaskIdentifier = [NSString stringWithFormat:@"%@.refresh", NSBundle.mainBundle.bundleIdentifier];

    // see: https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler?language=objc
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:refreshTaskIdentifier
                                                          usingQueue:nil
                                                       launchHandler:^(__kindof BGTask * _Nonnull task) {
        [self handleAppRefresh:task];
    }];
}

- (void)scheduleAppRefresh
{
    NSString *refreshTaskIdentifier = [NSString stringWithFormat:@"%@.refresh", NSBundle.mainBundle.bundleIdentifier];
    
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:refreshTaskIdentifier];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:UIApplicationBackgroundFetchIntervalMinimum];
    
    NSError *error = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];

    if (error) {
        NSLog(@"Failed to submit apprefresh request: %@", error);
    }
}

- (void)handleAppRefresh:(BGTask *)task
{
    [NCLog log:@"Performing background fetch -> handleAppRefresh"];
    
    // With BGTasks (iOS >= 13) we need to schedule another refresh when running in background
    [self scheduleAppRefresh];

    [self performBackgroundFetchWithCompletionHandler:^(BOOL errorOccurred) {
        [task setTaskCompletedWithSuccess:!errorOccurred];
    }];
}

// This method is called when you simulate a background fetch from the debug menu in XCode
// so we keep it around, although it's deprecated on iOS 13 onwards
- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    [NCLog log:@"Performing background fetch -> performFetchWithCompletionHandler"];

    [self performBackgroundFetchWithCompletionHandler:^(BOOL errorOccurred) {
         if (errorOccurred) {
             completionHandler(UIBackgroundFetchResultFailed);
         } else {
             completionHandler(UIBackgroundFetchResultNewData);
         }
     }];
}


- (void)performBackgroundFetchWithCompletionHandler:(void (^)(BOOL errorOccurred))completionHandler
{
    dispatch_group_t backgroundRefreshGroup = dispatch_group_create();
    __block BOOL errorOccurred = NO;
    __block BOOL expired = NO;

    BGTaskHelper *bgTask = [BGTaskHelper startBackgroundTaskWithName:@"NCBackgroundFetch" expirationHandler:^(BGTaskHelper *task) {
        [NCLog log:@"ExpirationHandler called"];

        /*
        expired = YES;
        completionHandler(YES);
        
        [task stopBackgroundTask];
         */
    }];

    [NCLog log:@"Start performBackgroundFetchWithCompletionHandler"];

    dispatch_group_enter(backgroundRefreshGroup);
    [[NCRoomsManager shared] resendOfflineMessagesWithCompletionBlock:^{
        [NCLog log:@"CompletionHandler resendOfflineMessagesWithCompletionBlock"];

        dispatch_group_leave(backgroundRefreshGroup);
    }];

    // Check if the shown notifications are still available on the server
    dispatch_group_enter(backgroundRefreshGroup);
    [[NCNotificationController sharedInstance] checkNotificationExistanceWithCompletionBlock:^(NSError *error) {
        [NCLog log:@"CompletionHandler checkNotificationExistance"];

        if (error) {
            errorOccurred = YES;
        }

        dispatch_group_leave(backgroundRefreshGroup);
    }];

    dispatch_group_enter(backgroundRefreshGroup);
    [[NCRoomsManager shared] updateRoomsAndChatsUpdatingUserStatus:NO onlyLastModified:YES withCompletionBlock:^(NSError *error) {
        [NCLog log:@"CompletionHandler updateRoomsAndChatsUpdatingUserStatus"];

        if (error) {
            errorOccurred = YES;
        }

        dispatch_group_leave(backgroundRefreshGroup);
    }];

    NSDateComponents *dayComponent = [[NSDateComponents alloc] init];
    dayComponent.day = -1;

    NSDate *thresholdDate = [[NSCalendar currentCalendar] dateByAddingComponents:dayComponent toDate:[NSDate date] options:0];
    NSInteger thresholdTimestamp = [thresholdDate timeIntervalSince1970];

    // Push proxy should be subscrided atleast every 24h
    // Check if we reached the threshold and start the subscription process
    for (TalkAccount *account in [[NCDatabaseManager sharedInstance] allAccounts]) {
        if (account.lastPushSubscription < thresholdTimestamp) {
            dispatch_group_enter(backgroundRefreshGroup);

            [[NCSettingsController sharedInstance] subscribeForPushNotificationsForAccountId:account.accountId withCompletionBlock:^(BOOL success) {
                if (!success) {
                    errorOccurred = YES;
                }

                dispatch_group_leave(backgroundRefreshGroup);
            }];
        }
    }

    dispatch_group_notify(backgroundRefreshGroup, dispatch_get_main_queue(), ^{
         [NCLog log:@"CompletionHandler performBackgroundFetchWithCompletionHandler dispatch_group_notify"];

         if (!expired) {
             completionHandler(errorOccurred);
         }

         [bgTask stopBackgroundTask];
     });
}

- (void)keepExternalSignalingConnectionAliveTemporarily
{
    [_keepAliveTimer invalidate];

    _keepAliveBGTask = [BGTaskHelper startBackgroundTaskWithName:@"NCWebSocketKeepAlive" expirationHandler:nil];
    _keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:NO block:^(NSTimer * _Nonnull timer) {
        // Stop the external signaling connections only if the app keeps in the background and not in a call
        if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground &&
            ![NCRoomsManager shared].callViewController) {
            [[NCSettingsController sharedInstance] disconnectAllExternalSignalingControllers];
        }

        // Disconnect is dispatched to the main queue, so in theory it can happen that we stop the background task
        // before the disconnect is run/completed. So we dispatch the stopBackgroundTask to main as well
        // to be sure it's called after everything else is run.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_keepAliveBGTask stopBackgroundTask];
        });
    }];

    [[NSRunLoop mainRunLoop] addTimer:_keepAliveTimer forMode:NSRunLoopCommonModes];
}

- (void)checkForDisconnectedExternalSignalingConnection
{
    [_keepAliveTimer invalidate];
    [_keepAliveBGTask stopBackgroundTask];

    [[NCSettingsController sharedInstance] connectDisconnectedExternalSignalingControllers];
}

#pragma mark - Ringtone Playback

- (void)playRingtone
{
    NSLog(@"📞 [RINGTONE] Playing ringtone...");

    // Stop any existing ringtone
    [self stopRingtone];

    // Configure audio session for playback
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionDuckOthers
                   error:&sessionError];
    [session setActive:YES error:&sessionError];

    if (sessionError) {
        NSLog(@"📞 [RINGTONE] Audio session error: %@", sessionError.localizedDescription);
    }

    // Try to load ringtone file from bundle
    NSURL *ringtoneURL = [[NSBundle mainBundle] URLForResource:@"ringtone" withExtension:@"mp3"];

    // Fallback to connecting sound if ringtone not found
    if (!ringtoneURL) {
        ringtoneURL = [[NSBundle mainBundle] URLForResource:@"connecting" withExtension:@"mp3"];
        NSLog(@"📞 [RINGTONE] Using connecting.mp3 as fallback ringtone");
    }

    if (ringtoneURL) {
        NSError *playerError = nil;
        self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:ringtoneURL error:&playerError];

        if (playerError) {
            NSLog(@"📞 [RINGTONE] Error creating audio player: %@", playerError.localizedDescription);
            return;
        }

        self.ringtonePlayer.numberOfLoops = -1; // Loop indefinitely
        self.ringtonePlayer.volume = 1.0;
        [self.ringtonePlayer prepareToPlay];
        [self.ringtonePlayer play];

        NSLog(@"📞 [RINGTONE] Ringtone started playing");
    } else {
        NSLog(@"📞 [RINGTONE] No ringtone file found, using system sound");
        // Fallback to system alert sound with vibration
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate);
        AudioServicesPlaySystemSound(1007); // Default SMS tone as fallback
    }
}

- (void)stopRingtone
{
    if (self.ringtonePlayer && self.ringtonePlayer.isPlaying) {
        NSLog(@"📞 [RINGTONE] Stopping ringtone");
        [self.ringtonePlayer stop];
        self.ringtonePlayer = nil;

        // Deactivate audio session
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:&error];
    }
}

@end
