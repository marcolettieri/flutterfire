// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <UserNotifications/UserNotifications.h>

#import "FLTFirebaseMessagingPlugin.h"
#import "UserAgent.h"

#import "Firebase/Firebase.h"

NSString *const kGCMMessageIDKey = @"gcm.message_id";

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
@interface FLTFirebaseMessagingPlugin () <FIRMessagingDelegate>
@end
#endif

static FlutterError *getFlutterError(NSError *error) {
  if (error == nil) return nil;
  return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %ld", (long)error.code]
                             message:error.domain
                             details:error.localizedDescription];
}

static NSObject<FlutterPluginRegistrar> *_registrar;

@implementation FLTFirebaseMessagingPlugin {
  FlutterMethodChannel *_channel;
  NSDictionary *_launchNotification;
  BOOL _resumingFromBackground;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  _registrar = registrar;
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/firebase_messaging"
                                  binaryMessenger:[registrar messenger]];
  FLTFirebaseMessagingPlugin *instance =
      [[FLTFirebaseMessagingPlugin alloc] initWithChannel:channel];
  [registrar addApplicationDelegate:instance];
  [registrar addMethodCallDelegate:instance channel:channel];

  SEL sel = NSSelectorFromString(@"registerLibrary:withVersion:");
  if ([FIRApp respondsToSelector:sel]) {
    [FIRApp performSelector:sel withObject:LIBRARY_NAME withObject:LIBRARY_VERSION];
  }
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel {
  self = [super init];

  if (self) {
    _channel = channel;
    _resumingFromBackground = NO;
    if (![FIRApp appNamed:@"__FIRAPP_DEFAULT"]) {
      NSLog(@"Configuring the default Firebase app...");
      [FIRApp configure];
      NSLog(@"Configured the default Firebase app %@.", [FIRApp defaultApp].name);
    }
    [FIRMessaging messaging].delegate = self;
    [self registerForNotification];

  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *method = call.method;
  if ([@"requestNotificationPermissions" isEqualToString:method]) {
    NSDictionary *arguments = call.arguments;
    if (@available(iOS 10.0, *)) {
      UNAuthorizationOptions authOptions = 0;
      NSNumber *provisional = arguments[@"provisional"];
      if ([arguments[@"sound"] boolValue]) {
        authOptions |= UNAuthorizationOptionSound;
      }
      if ([arguments[@"alert"] boolValue]) {
        authOptions |= UNAuthorizationOptionAlert;
      }
      if ([arguments[@"badge"] boolValue]) {
        authOptions |= UNAuthorizationOptionBadge;
      }

      NSNumber *isAtLeastVersion12;
      if (@available(iOS 12, *)) {
        isAtLeastVersion12 = [NSNumber numberWithBool:YES];
        if ([provisional boolValue]) authOptions |= UNAuthorizationOptionProvisional;
      } else {
        isAtLeastVersion12 = [NSNumber numberWithBool:NO];
      }

      [[UNUserNotificationCenter currentNotificationCenter]
          requestAuthorizationWithOptions:authOptions
                        completionHandler:^(BOOL granted, NSError *_Nullable error) {
                          if (error) {
                            result(getFlutterError(error));
                            return;
                          }
                          // This works for iOS >= 10. See
                          // [UIApplication:didRegisterUserNotificationSettings:notificationSettings]
                          // for ios < 10.
                          [[UNUserNotificationCenter currentNotificationCenter]
                              getNotificationSettingsWithCompletionHandler:^(
                                  UNNotificationSettings *_Nonnull settings) {
                                NSDictionary *settingsDictionary = @{
                                  @"sound" : [NSNumber numberWithBool:settings.soundSetting ==
                                                                      UNNotificationSettingEnabled],
                                  @"badge" : [NSNumber numberWithBool:settings.badgeSetting ==
                                                                      UNNotificationSettingEnabled],
                                  @"alert" : [NSNumber numberWithBool:settings.alertSetting ==
                                                                      UNNotificationSettingEnabled],
                                  @"provisional" :
                                      [NSNumber numberWithBool:granted && [provisional boolValue] &&
                                                               isAtLeastVersion12],
                                };
                                [self->_channel invokeMethod:@"onIosSettingsRegistered"
                                                   arguments:settingsDictionary];
                              }];
                          result([NSNumber numberWithBool:granted]);
                        }];

      [[UIApplication sharedApplication] registerForRemoteNotifications];
    } else {
      UIUserNotificationType notificationTypes = 0;
      if ([arguments[@"sound"] boolValue]) {
        notificationTypes |= UIUserNotificationTypeSound;
      }
      if ([arguments[@"alert"] boolValue]) {
        notificationTypes |= UIUserNotificationTypeAlert;
      }
      if ([arguments[@"badge"] boolValue]) {
        notificationTypes |= UIUserNotificationTypeBadge;
      }

      UIUserNotificationSettings *settings =
          [UIUserNotificationSettings settingsForTypes:notificationTypes categories:nil];
      [[UIApplication sharedApplication] registerUserNotificationSettings:settings];

      [[UIApplication sharedApplication] registerForRemoteNotifications];
      result([NSNumber numberWithBool:YES]);
    }
  } else if ([@"configure" isEqualToString:method]) {
    [FIRMessaging messaging].shouldEstablishDirectChannel = true;
    [[UIApplication sharedApplication] registerForRemoteNotifications];
    if (_launchNotification != nil && _launchNotification[kGCMMessageIDKey]) {
      [_channel invokeMethod:@"onLaunch" arguments:_launchNotification];
    }
    result(nil);
  } else if ([@"subscribeToTopic" isEqualToString:method]) {
    NSString *topic = call.arguments;
    [[FIRMessaging messaging] subscribeToTopic:topic
                                    completion:^(NSError *error) {
                                      result(getFlutterError(error));
                                    }];
  } else if ([@"unsubscribeFromTopic" isEqualToString:method]) {
    NSString *topic = call.arguments;
    [[FIRMessaging messaging] unsubscribeFromTopic:topic
                                        completion:^(NSError *error) {
                                          result(getFlutterError(error));
                                        }];
  } else if ([@"getToken" isEqualToString:method]) {
    [[FIRInstanceID instanceID]
        instanceIDWithHandler:^(FIRInstanceIDResult *_Nullable instanceIDResult,
                                NSError *_Nullable error) {
          if (error != nil) {
            NSLog(@"getToken, error fetching instanceID: %@", error);
            result(nil);
          } else {
            result(instanceIDResult.token);
          }
        }];
  } else if ([@"deleteInstanceID" isEqualToString:method]) {
    [[FIRInstanceID instanceID] deleteIDWithHandler:^void(NSError *_Nullable error) {
      if (error.code != 0) {
        NSLog(@"deleteInstanceID, error: %@", error);
        result([NSNumber numberWithBool:NO]);
      } else {
        [[UIApplication sharedApplication] unregisterForRemoteNotifications];
        result([NSNumber numberWithBool:YES]);
      }
    }];
  } else if ([@"autoInitEnabled" isEqualToString:method]) {
    BOOL value = [[FIRMessaging messaging] isAutoInitEnabled];
    result([NSNumber numberWithBool:value]);
  } else if ([@"setAutoInitEnabled" isEqualToString:method]) {
    NSNumber *value = call.arguments;
    [FIRMessaging messaging].autoInitEnabled = value.boolValue;
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
// Received data message on iOS 10 devices while app is in the foreground.
// Only invoked if method swizzling is enabled.
- (void)applicationReceivedRemoteMessage:(FIRMessagingRemoteMessage *)remoteMessage {
  [self didReceiveRemoteNotification:remoteMessage.appData];
}

// Received data message on iOS 10 devices while app is in the foreground.
// Only invoked if method swizzling is disabled and UNUserNotificationCenterDelegate has been
// registered in AppDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
    NS_AVAILABLE_IOS(10.0) {
  NSDictionary *userInfo = notification.request.content.userInfo;
  // Check to key to ensure we only handle messages from Firebase
  if (userInfo[kGCMMessageIDKey]) {
    [[FIRMessaging messaging] appDidReceiveMessage:userInfo];
    [_channel invokeMethod:@"onMessage" arguments:userInfo];
    completionHandler(UNNotificationPresentationOptionNone);
  }
}


- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler NS_AVAILABLE_IOS(10.0) {
    //NSLog(@" PUSH INFO %@", response);
  NSDictionary *userInfo = response.notification.request.content.userInfo;
    //NSLog(@" PUSH INFO2 %@", response);
  // Check to key to ensure we only handle messages from Firebase
  if (userInfo[kGCMMessageIDKey]) {
    [_channel invokeMethod:@"onResume" arguments:userInfo];
    completionHandler();
  }
    
}

#endif

- (void)didReceiveRemoteNotification:(NSDictionary *)userInfo {
  if (_resumingFromBackground) {
    [_channel invokeMethod:@"onResume" arguments:userInfo];
  } else {
    [_channel invokeMethod:@"onMessage" arguments:userInfo];
  }
}

#pragma mark - AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  if (launchOptions != nil) {
    _launchNotification = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
  }
  [self registerForNotification];
  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  _resumingFromBackground = YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
  _resumingFromBackground = NO;
  // Clears push notifications from the notification center, with the
  // side effect of resetting the badge count. We need to clear notifications
  // because otherwise the user could tap notifications in the notification
  // center while the app is in the foreground, and we wouldn't be able to
  // distinguish that case from the case where a message came in and the
  // user dismissed the notification center without tapping anything.
  // TODO(goderbauer): Revisit this behavior once we provide an API for managing
  // the badge number, or if we add support for running Dart in the background.
  // Setting badgeNumber to 0 is a no-op (= notifications will not be cleared)
  // if it is already 0,
  // therefore the next line is setting it to 1 first before clearing it again
  // to remove all
  // notifications.
  application.applicationIconBadgeNumber = 1;
  application.applicationIconBadgeNumber = 0;
}

- (BOOL)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {
  [self didReceiveRemoteNotification:userInfo];
  completionHandler(UIBackgroundFetchResultNoData);
  return YES;
}

- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
#ifdef DEBUG
  [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeSandbox];
#else
  [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeProd];
#endif

  [_channel invokeMethod:@"onToken" arguments:[FIRMessaging messaging].FCMToken];
}

// This will only be called for iOS < 10. For iOS >= 10, we make this call when we request
// permissions.
- (void)application:(UIApplication *)application
    didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
  NSDictionary *settingsDictionary = @{
    @"sound" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeSound],
    @"badge" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeBadge],
    @"alert" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeAlert],
    @"provisional" : [NSNumber numberWithBool:NO],
  };
  [_channel invokeMethod:@"onIosSettingsRegistered" arguments:settingsDictionary];
}

- (void)messaging:(nonnull FIRMessaging *)messaging
    didReceiveRegistrationToken:(nonnull NSString *)fcmToken {
  [_channel invokeMethod:@"onToken" arguments:fcmToken];
}

- (void)messaging:(FIRMessaging *)messaging
    didReceiveMessage:(FIRMessagingRemoteMessage *)remoteMessage {
  [_channel invokeMethod:@"onMessage" arguments:remoteMessage.appData];
}

-(void)application:(UIApplication *)application
handleActionWithIdentifier:(NSString *)identifier
forLocalNotification:(UILocalNotification *)notification
completionHandler:(void (^)(void))completionHandler
{
       //NSLog(@" PUSH ACTION IDENTIFIER %@", identifier);

}

- (void)application:(UIApplication *)application
   handleActionWithIdentifier:(NSString *)identifier
   forRemoteNotification:(NSDictionary *)userInfo
   completionHandler:(void (^)(void))completionHandler
{
   //NSLog(@" PUSH IDENTIFIER %@", identifier);
}
- (void)registerForNotification {
    
    //NSLog(@" PUSH REGISTER");
    // type 0
    UIMutableUserNotificationAction* declineAction = [[UIMutableUserNotificationAction alloc] init];
    [declineAction setIdentifier:@"decline_action_id"];
    [declineAction setTitle:NSLocalizedString(@"notexecute",@"notexecute")];
    [declineAction setActivationMode:UIUserNotificationActivationModeBackground];
    [declineAction setDestructive:NO];
    [declineAction setAuthenticationRequired:YES];
    UIMutableUserNotificationAction* replyAction = [[UIMutableUserNotificationAction alloc] init];
    [replyAction setIdentifier:@"send_action_id"];
    [replyAction setTitle:NSLocalizedString(@"execute",@"execute")];
    [replyAction setActivationMode:UIUserNotificationActivationModeBackground];
    [replyAction setDestructive:NO];
    [replyAction setAuthenticationRequired:YES];
    
    /*UIMutableUserNotificationAction* remind = [[UIMutableUserNotificationAction alloc] init];
    [remind setIdentifier:@"remind_action_id"];
    [remind setTitle:@"Ricordamelo dopo!"];
    [remind setActivationMode:UIUserNotificationActivationModeBackground];
    [remind setDestructive:YES];*/

    
    UIMutableUserNotificationCategory* declineReplyCategory = [[UIMutableUserNotificationCategory alloc] init];
    [declineReplyCategory setIdentifier:@"0_push"];
    [declineReplyCategory setActions:@[replyAction, declineAction] forContext:UIUserNotificationActionContextDefault];
    // end type 0
    
    /*
     // type 2
    UIMutableUserNotificationAction* open = [[UIMutableUserNotificationAction alloc] init];
    [open setIdentifier:@"open_action_id"];
    [open setTitle:@"Apri"];
    [open setAuthenticationRequired:NO];
    [open setActivationMode:UIUserNotificationActivationModeBackground];
    [open setDestructive:NO];
     // end type 2
    UIMutableUserNotificationCategory* declineReplyCategory2 = [[UIMutableUserNotificationCategory alloc] init];
    [declineReplyCategory2 setIdentifier:@"2_push"];
    [declineReplyCategory2 setActions:@[open] forContext:UIUserNotificationActionContextDefault];*/
    
    UNNotificationAction *open = [UNNotificationAction actionWithIdentifier:@"open_action_id"
    title:@"Apri" options:UNNotificationActionOptionNone];
    UNNotificationCategory *declineReplyCategory2 = [UNNotificationCategory categoryWithIdentifier:@"2_push"
    actions:@[open] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];

    // type 3
    UIMutableUserNotificationAction* confirm = [[UIMutableUserNotificationAction alloc] init];
    [confirm setIdentifier:@"confirm_action_id"];
    [confirm setTitle:NSLocalizedString(@"confirm",@"confirm")];
    [confirm setActivationMode:UIUserNotificationActivationModeBackground];
    [confirm setDestructive:NO];
    [confirm setAuthenticationRequired:YES];
    // end type 3
    
    UIMutableUserNotificationCategory* declineReplyCategory3 = [[UIMutableUserNotificationCategory alloc] init];
    [declineReplyCategory3 setIdentifier:@"3_push"];
    [declineReplyCategory3 setActions:@[confirm] forContext:UIUserNotificationActionContextDefault];
    
    UIMutableUserNotificationCategory* declineReplyCategory5 = [[UIMutableUserNotificationCategory alloc] init];
    [declineReplyCategory5 setIdentifier:@"5_push"];
    [declineReplyCategory5 setActions:@[confirm] forContext:UIUserNotificationActionContextDefault];

    //[declineReplyCategory setActions:@[replyAction] forContext:UIUserNotificationActionContextDefault];
    NSSet* categories = [NSSet setWithArray:@[declineReplyCategory2,declineReplyCategory,declineReplyCategory3,declineReplyCategory5]];
    //UIUserNotificationSettings* settings = [UIUserNotificationSettings settingsForTypes:(UIUserNotificationTypeBadge | UIUserNotificationTypeSound | UIUserNotificationTypeAlert) categories:categories];
    //[[UIApplication sharedApplication] registerUserNotificationSettings:settings];
    [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories: categories];
    
    
}
@end
