#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
#import <sys/stat.h>

static const NSTimeInterval DSDisplaySleepRetryInterval = 5.0;
static const NSTimeInterval DSAutomaticDisplaySleepIdleCheckInterval = 30.0;
static const NSTimeInterval DSAutomaticDisplaySleepMinimumRequestInterval = 60.0;
static const CGFloat DSMenuBarIconWidth = 23.0;
static const CGFloat DSMenuBarIconHeight = 13.0;
static NSString * const DSAutomaticDisplaySleepMinutesKey = @"AutomaticDisplaySleepMinutes";
static NSString * const DSPrivilegedHelperName = @"local.dontsleep.pmset-helper";
static NSString * const DSPrivilegedHelperPath = @"/Library/PrivilegedHelperTools/local.dontsleep.pmset-helper";

typedef NS_ENUM(NSInteger, DSSleepState) {
    DSSleepStateUnknown,
    DSSleepStateEnabled,
    DSSleepStatePartiallyEnabled,
    DSSleepStateDisabled
};

@interface DSCommandRunner : NSObject
+ (NSString *)outputForExecutable:(NSString *)executable
                         arguments:(NSArray<NSString *> *)arguments
                             error:(NSError **)error;
@end

@implementation DSCommandRunner

+ (NSString *)outputForExecutable:(NSString *)executable
                         arguments:(NSArray<NSString *> *)arguments
                             error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];

    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    if (![task launchAndReturnError:error]) {
        return nil;
    }

    [task waitUntilExit];

    NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        if (error != NULL) {
            NSString *message = stderrOutput.length > 0 ? stderrOutput : output;
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            };
            *error = [NSError errorWithDomain:@"DontSleep.Command" code:task.terminationStatus userInfo:userInfo];
        }

        return nil;
    }

    return output;
}

@end

@interface DSAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSImage *appIcon;
@property (nonatomic, strong) NSMenuItem *stateItem;
@property (nonatomic, strong) NSMenuItem *toggleItem;
@property (nonatomic, strong) NSMenuItem *automaticDisplaySleepItem;
@property (nonatomic, strong) NSMenuItem *quitItem;
@property (nonatomic, strong) NSTimer *lidMonitorTimer;
@property (nonatomic, strong) NSTimer *automaticDisplaySleepTimer;
@property (nonatomic, strong) id monitorActivity;
@property (nonatomic, strong) id keepAwakeActivity;
@property (nonatomic) DSSleepState state;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL hasObservedLidState;
@property (nonatomic) BOOL lastObservedLidClosed;
@property (nonatomic) BOOL didRequestDisplaySleepForClosedLid;
@property (nonatomic) BOOL displaySleepRequestInFlight;
@property (nonatomic) BOOL didDimBuiltInDisplayForClosedLid;
@property (nonatomic) BOOL hasSavedBuiltInDisplayBrightness;
@property (nonatomic) BOOL terminationDisableInProgress;
@property (nonatomic) BOOL terminationSleepDisableComplete;
@property (nonatomic) float savedBuiltInDisplayBrightness;
@property (nonatomic, strong) NSDate *lastDisplaySleepRequestAt;
@property (nonatomic, strong) NSDate *lastAutomaticDisplaySleepRequestAt;
@property (nonatomic) NSInteger automaticDisplaySleepMinutes;
@end

@implementation DSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.appIcon = [DSAppDelegate bundledAppIcon];
    if (self.appIcon != nil) {
        NSApp.applicationIconImage = self.appIcon;
    }

    self.state = DSSleepStateUnknown;
    self.automaticDisplaySleepMinutes = [DSAppDelegate savedAutomaticDisplaySleepMinutes];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:30.0];
    self.menu = [[NSMenu alloc] initWithTitle:@"Don't Sleep"];
    self.menu.autoenablesItems = NO;

    self.stateItem = [[NSMenuItem alloc] initWithTitle:@"상태 확인 중..." action:nil keyEquivalent:@""];
    self.stateItem.enabled = NO;

    self.toggleItem = [[NSMenuItem alloc] initWithTitle:@"켜짐: 잠들지 않기"
                                                 action:@selector(toggleSleepPrevention:)
                                          keyEquivalent:@""];
    self.toggleItem.target = self;

    self.automaticDisplaySleepItem = [[NSMenuItem alloc] initWithTitle:@"화면 꺼짐: 화면은 끄되 잠들지 않기"
                                                                 action:nil
                                                          keyEquivalent:@""];
    self.automaticDisplaySleepItem.submenu = [self automaticDisplaySleepMenu];

    self.quitItem = [[NSMenuItem alloc] initWithTitle:@"완전히 종료 : 기존 설정으로 변경"
                                               action:@selector(quit:)
                                        keyEquivalent:@"q"];
    self.quitItem.target = self;

    [self.menu addItem:self.stateItem];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:self.toggleItem];
    [self.menu addItem:self.automaticDisplaySleepItem];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:self.quitItem];

    self.statusItem.menu = self.menu;
    self.statusItem.button.toolTip = @"Don't Sleep";

    [self updateMenu];
    [self refreshState:nil];
    [self startLidMonitor];
    self.monitorActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityBackground
                                                                        reason:@"Monitor MacBook lid state for display sleep"];
    [self appendDebugLog:@"app launched"];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self restoreBuiltInDisplayBrightnessIfNeeded];
    [self.lidMonitorTimer invalidate];
    self.lidMonitorTimer = nil;
    [self.automaticDisplaySleepTimer invalidate];
    self.automaticDisplaySleepTimer = nil;
    if (self.keepAwakeActivity != nil) {
        [NSProcessInfo.processInfo endActivity:self.keepAwakeActivity];
        self.keepAwakeActivity = nil;
    }
    if (self.monitorActivity != nil) {
        [NSProcessInfo.processInfo endActivity:self.monitorActivity];
        self.monitorActivity = nil;
    }
    [self appendDebugLog:@"app terminating"];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;

    DSSleepState currentState = [DSAppDelegate currentSleepState];
    self.state = currentState;

    if (self.terminationSleepDisableComplete || currentState == DSSleepStateDisabled) {
        return NSTerminateNow;
    }

    if (self.terminationDisableInProgress) {
        return NSTerminateLater;
    }

    self.terminationDisableInProgress = YES;
    self.busy = YES;
    [self updateMenu];
    [self appendDebugLog:@"termination requested; disabling sleep prevention first"];

    __weak typeof(self) weakSelf = self;
    [self setSleepPreventionEnabled:NO completion:^(NSError *error) {
        DSAppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) {
            [NSApp replyToApplicationShouldTerminate:NO];
            return;
        }

        strongSelf.terminationDisableInProgress = NO;
        strongSelf.busy = NO;

        if (error != nil) {
            [strongSelf appendDebugLog:@"termination blocked; could not disable sleep prevention: %@", error.localizedDescription ?: @"unknown"];
            [strongSelf updateMenu];
            [strongSelf showError:error];
            [NSApp replyToApplicationShouldTerminate:NO];
            return;
        }

        strongSelf.terminationSleepDisableComplete = YES;
        strongSelf.state = DSSleepStateDisabled;
        [strongSelf updateKeepAwakeActivity];
        [strongSelf updateAutomaticDisplaySleepTimer];
        [strongSelf updateMenu];
        [strongSelf appendDebugLog:@"sleep prevention disabled before termination"];
        [NSApp replyToApplicationShouldTerminate:YES];
    }];

    return NSTerminateLater;
}

- (void)refreshState:(id)sender {
    (void)sender;

    if (self.busy) {
        return;
    }

    self.busy = YES;
    [self updateMenu];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *customError = nil;
        NSString *customOutput = [DSCommandRunner outputForExecutable:@"/usr/bin/pmset"
                                                             arguments:@[@"-g", @"custom"]
                                                                 error:&customError] ?: @"";

        NSError *currentError = nil;
        NSString *currentOutput = [DSCommandRunner outputForExecutable:@"/usr/bin/pmset"
                                                              arguments:@[@"-g"]
                                                                  error:&currentError] ?: @"";

        NSString *combinedOutput = [customOutput stringByAppendingFormat:@"\n%@", currentOutput];
        DSSleepState nextState = [DSAppDelegate stateFromOutput:combinedOutput];

        dispatch_async(dispatch_get_main_queue(), ^{
            DSAppDelegate *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }

            strongSelf.state = nextState;
            strongSelf.busy = NO;
            [strongSelf updateKeepAwakeActivity];
            [strongSelf updateAutomaticDisplaySleepTimer];
            [strongSelf updateMenu];
            [strongSelf monitorLidState:nil];
        });
    });
}

- (void)toggleSleepPrevention:(id)sender {
    (void)sender;

    if (self.busy) {
        return;
    }

    BOOL shouldEnable = self.state != DSSleepStateEnabled;

    self.busy = YES;
    [self updateMenu];

    __weak typeof(self) weakSelf = self;
    [self setSleepPreventionEnabled:shouldEnable completion:^(NSError *error) {
        DSAppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        strongSelf.busy = NO;

        if (error != nil) {
            [strongSelf updateMenu];
            [strongSelf showError:error];
            return;
        }

        strongSelf.state = shouldEnable ? DSSleepStateEnabled : DSSleepStateDisabled;
        [strongSelf updateKeepAwakeActivity];
        [strongSelf updateAutomaticDisplaySleepTimer];
        [strongSelf updateMenu];
        [strongSelf refreshState:nil];
    }];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)startTravelMode:(id)sender {
    (void)sender;

    if (self.busy) {
        return;
    }

    if (self.state == DSSleepStateEnabled || self.state == DSSleepStatePartiallyEnabled) {
        [self appendDebugLog:@"display sleep requested while sleep prevention is already on"];
        [self requestDisplaySleepForTravelMode];
        return;
    }

    self.busy = YES;
    [self updateMenu];

    __weak typeof(self) weakSelf = self;
    [self setSleepPreventionEnabled:YES completion:^(NSError *error) {
        DSAppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        strongSelf.busy = NO;

        if (error != nil) {
            [strongSelf updateMenu];
            [strongSelf showError:error];
            return;
        }

        strongSelf.state = DSSleepStateEnabled;
        [strongSelf updateKeepAwakeActivity];
        [strongSelf updateAutomaticDisplaySleepTimer];
        [strongSelf updateMenu];
        [strongSelf refreshState:nil];
        [strongSelf appendDebugLog:@"display sleep request enabled sleep prevention"];
        [strongSelf requestDisplaySleepForTravelMode];
    }];
}

- (void)openDiagnosticsLog:(id)sender {
    (void)sender;
    NSURL *logURL = [DSAppDelegate diagnosticsLogURL];
    [NSFileManager.defaultManager createDirectoryAtURL:logURL.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];

    if (![NSFileManager.defaultManager fileExistsAtPath:logURL.path]) {
        [@"" writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    [NSWorkspace.sharedWorkspace openURL:logURL];
}

- (void)updateMenu {
    switch (self.state) {
        case DSSleepStateEnabled:
            self.stateItem.title = @"상태: 켜짐: 잠들지 않기";
            self.toggleItem.title = @"꺼짐: 잠들어도 돼";
            self.toggleItem.state = NSControlStateValueOff;
            break;
        case DSSleepStatePartiallyEnabled:
            self.stateItem.title = @"상태: 일부만 켜짐";
            self.toggleItem.title = @"켜짐: 잠들지 않기";
            self.toggleItem.state = NSControlStateValueOff;
            break;
        case DSSleepStateDisabled:
            self.stateItem.title = @"상태: 꺼짐: 잠들어도 돼";
            self.toggleItem.title = @"켜짐: 잠들지 않기";
            self.toggleItem.state = NSControlStateValueOff;
            break;
        case DSSleepStateUnknown:
            self.stateItem.title = @"상태: 확인 중";
            self.toggleItem.title = @"켜짐: 잠들지 않기";
            self.toggleItem.state = NSControlStateValueOff;
            break;
    }

    if (self.busy) {
        self.stateItem.title = @"상태: 변경 중...";
    }

    BOOL displaySleepControlsEnabled = !self.busy && [self shouldKeepAwake];
    self.toggleItem.enabled = !self.busy;
    self.automaticDisplaySleepItem.enabled = displaySleepControlsEnabled;
    self.quitItem.enabled = YES;

    [self updateAutomaticDisplaySleepMenu];
    [self updateStatusIcon];
}

- (NSMenu *)automaticDisplaySleepMenu {
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"화면 꺼짐"];

    NSMenuItem *nowItem = [[NSMenuItem alloc] initWithTitle:@"즉시 꺼짐"
                                                     action:@selector(turnDisplayOffImmediately:)
                                              keyEquivalent:@""];
    nowItem.target = self;
    [submenu addItem:nowItem];

    for (NSNumber *minutesNumber in [DSAppDelegate automaticDisplaySleepMinuteOptions]) {
        NSInteger minutes = minutesNumber.integerValue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[DSAppDelegate automaticDisplaySleepTitleForMinutes:minutes]
                                                      action:@selector(selectAutomaticDisplaySleepInterval:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = minutesNumber;
        [submenu addItem:item];
    }

    return submenu;
}

- (void)selectAutomaticDisplaySleepInterval:(NSMenuItem *)sender {
    if (![self shouldKeepAwake]) {
        return;
    }

    NSInteger minutes = [sender.representedObject integerValue];
    if (![DSAppDelegate isValidAutomaticDisplaySleepMinutes:minutes]) {
        return;
    }

    self.automaticDisplaySleepMinutes = minutes;
    [NSUserDefaults.standardUserDefaults setInteger:minutes forKey:DSAutomaticDisplaySleepMinutesKey];
    [self appendDebugLog:@"automatic display sleep interval changed; minutes=%ld", (long)minutes];
    [self updateMenu];
    [self updateAutomaticDisplaySleepTimer];
    [self evaluateAutomaticDisplaySleep:nil];
}

- (void)updateAutomaticDisplaySleepMenu {
    self.automaticDisplaySleepItem.title = @"화면 꺼짐: 화면은 끄되 잠들지 않기";
    BOOL enabled = self.automaticDisplaySleepItem.enabled;

    for (NSMenuItem *item in self.automaticDisplaySleepItem.submenu.itemArray) {
        item.enabled = enabled;

        if (![item.representedObject isKindOfClass:NSNumber.class]) {
            item.state = NSControlStateValueOff;
            continue;
        }

        NSInteger minutes = [item.representedObject integerValue];
        item.state = minutes == self.automaticDisplaySleepMinutes ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)turnDisplayOffImmediately:(id)sender {
    (void)sender;
    if (![self shouldKeepAwake]) {
        return;
    }

    [self startTravelMode:nil];
}

- (void)startLidMonitor {
    self.didRequestDisplaySleepForClosedLid = NO;
    [self monitorLidState:nil];
    self.lidMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            target:self
                                                          selector:@selector(monitorLidState:)
                                                          userInfo:nil
                                                           repeats:YES];
    self.lidMonitorTimer.tolerance = 1.0;
    [self appendDebugLog:@"lid monitor started with run loop timer"];
}

- (void)monitorLidState:(NSTimer *)timer {
    (void)timer;
    [self handleLidClosed:[DSAppDelegate isLidClosed]];
}

- (void)handleLidClosed:(BOOL)lidClosed {
    BOOL shouldKeepAwake = self.state == DSSleepStateEnabled || self.state == DSSleepStatePartiallyEnabled;
    if (!self.hasObservedLidState || self.lastObservedLidClosed != lidClosed) {
        self.hasObservedLidState = YES;
        self.lastObservedLidClosed = lidClosed;
        [self appendDebugLog:@"lid state changed; lidClosed=%@ keepAwake=%@", lidClosed ? @"yes" : @"no", shouldKeepAwake ? @"yes" : @"no"];
    }

    if (!lidClosed) {
        self.didRequestDisplaySleepForClosedLid = NO;
        self.lastDisplaySleepRequestAt = nil;
        [self restoreBuiltInDisplayBrightnessIfNeeded];
        return;
    }

    if (!shouldKeepAwake) {
        [self appendDebugLog:@"lid closed but sleep prevention is off"];
        return;
    }

    if (!self.didRequestDisplaySleepForClosedLid) {
        self.didRequestDisplaySleepForClosedLid = YES;
        [self appendDebugLog:@"lid closed detected; requesting display sleep"];
        [self dimBuiltInDisplayForClosedLidIfNeeded];
        [self requestDisplaySleepIfNeeded:YES];
        return;
    }

    [self dimBuiltInDisplayForClosedLidIfNeeded];
    [self requestDisplaySleepIfNeeded:NO];
}

- (void)requestDisplaySleepIfNeeded:(BOOL)force {
    if (self.displaySleepRequestInFlight) {
        return;
    }

    NSDate *now = NSDate.date;
    if (!force && self.lastDisplaySleepRequestAt != nil &&
        [now timeIntervalSinceDate:self.lastDisplaySleepRequestAt] < DSDisplaySleepRetryInterval) {
        return;
    }

    self.lastDisplaySleepRequestAt = now;
    [self requestDisplaySleep];
}

- (void)requestDisplaySleepForTravelMode {
    [self appendDebugLog:@"display sleep requested from menu"];
    [self requestDisplaySleepIfNeeded:YES];
}

- (BOOL)shouldKeepAwake {
    return self.state == DSSleepStateEnabled || self.state == DSSleepStatePartiallyEnabled;
}

- (void)updateKeepAwakeActivity {
    BOOL shouldKeepAwake = [self shouldKeepAwake];

    if (shouldKeepAwake && self.keepAwakeActivity == nil) {
        self.keepAwakeActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityIdleSystemSleepDisabled
                                                                              reason:@"Don't Sleep is keeping the Mac awake"];
        [self appendDebugLog:@"keep awake activity started"];
        return;
    }

    if (!shouldKeepAwake && self.keepAwakeActivity != nil) {
        [NSProcessInfo.processInfo endActivity:self.keepAwakeActivity];
        self.keepAwakeActivity = nil;
        [self appendDebugLog:@"keep awake activity ended"];
    }
}

- (void)updateAutomaticDisplaySleepTimer {
    BOOL shouldRun = [self shouldKeepAwake] && self.automaticDisplaySleepMinutes > 0;

    if (!shouldRun) {
        [self.automaticDisplaySleepTimer invalidate];
        self.automaticDisplaySleepTimer = nil;
        self.lastAutomaticDisplaySleepRequestAt = nil;
        return;
    }

    if (self.automaticDisplaySleepTimer != nil) {
        return;
    }

    self.automaticDisplaySleepTimer = [NSTimer scheduledTimerWithTimeInterval:DSAutomaticDisplaySleepIdleCheckInterval
                                                                       target:self
                                                                     selector:@selector(evaluateAutomaticDisplaySleep:)
                                                                     userInfo:nil
                                                                      repeats:YES];
    self.automaticDisplaySleepTimer.tolerance = 10.0;
    [self appendDebugLog:@"automatic display sleep timer started; minutes=%ld", (long)self.automaticDisplaySleepMinutes];
}

- (void)evaluateAutomaticDisplaySleep:(NSTimer *)timer {
    (void)timer;

    if (![self shouldKeepAwake] || self.automaticDisplaySleepMinutes <= 0) {
        return;
    }

    CFTimeInterval idleSeconds = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    NSTimeInterval threshold = (NSTimeInterval)self.automaticDisplaySleepMinutes * 60.0;

    if (idleSeconds < threshold) {
        self.lastAutomaticDisplaySleepRequestAt = nil;
        return;
    }

    NSDate *now = NSDate.date;
    if (self.lastAutomaticDisplaySleepRequestAt != nil &&
        [now timeIntervalSinceDate:self.lastAutomaticDisplaySleepRequestAt] < DSAutomaticDisplaySleepMinimumRequestInterval) {
        return;
    }

    self.lastAutomaticDisplaySleepRequestAt = now;
    [self appendDebugLog:@"automatic display sleep requested; idleSeconds=%.0f threshold=%.0f", idleSeconds, threshold];
    [self requestDisplaySleepIfNeeded:YES];
}

- (void)setSleepPreventionEnabled:(BOOL)enabled completion:(void (^)(NSError *error))completion {
    NSString *helperCommand = enabled ? @"enable" : @"disable";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *method = @"osascript";
        NSError *installError = nil;

        if ((![DSAppDelegate isPrivilegedHelperUsable] || ![DSAppDelegate isInstalledPrivilegedHelperCurrent]) &&
            ![DSAppDelegate installBundledPrivilegedHelperWithError:&installError]) {
            error = installError;
            method = @"helper-install";
        } else {
            [DSCommandRunner outputForExecutable:DSPrivilegedHelperPath
                                       arguments:@[helperCommand]
                                           error:&error];
            if (error == nil) {
                method = @"helper";
            } else {
                NSError *reinstallError = nil;
                if ([DSAppDelegate installBundledPrivilegedHelperWithError:&reinstallError]) {
                    error = nil;
                    [DSCommandRunner outputForExecutable:DSPrivilegedHelperPath
                                               arguments:@[helperCommand]
                                                   error:&error];
                    method = error == nil ? @"helper-reinstalled" : @"helper";
                } else if (reinstallError != nil) {
                    error = reinstallError;
                    method = @"helper-reinstall";
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendDebugLog:@"sleep prevention command finished; enabled=%@ method=%@ installError=%@ error=%@",
             enabled ? @"yes" : @"no",
             method,
             installError.localizedDescription ?: @"none",
             error.localizedDescription ?: @"none"];

            if (completion != nil) {
                completion(error);
            }
        });
    });
}

- (void)requestDisplaySleep {
    self.displaySleepRequestInFlight = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        BOOL idleRequested = [DSAppDelegate requestDisplayIdleWithIOKit];
        NSString *method = @"pmset";

        if ([DSAppDelegate isPrivilegedHelperUsable] && [DSAppDelegate isInstalledPrivilegedHelperCurrent]) {
            [DSCommandRunner outputForExecutable:DSPrivilegedHelperPath
                                       arguments:@[@"display-sleep"]
                                           error:&error];
            method = error == nil ? @"helper" : @"helper-failed";
        }

        if (error != nil || [method isEqualToString:@"pmset"]) {
            NSError *pmsetError = nil;
            [DSCommandRunner outputForExecutable:@"/usr/bin/pmset"
                                       arguments:@[@"displaysleepnow"]
                                           error:&pmsetError];
            if (pmsetError == nil) {
                error = nil;
                method = @"pmset";
            } else if (error == nil) {
                error = pmsetError;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            DSAppDelegate *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }

            strongSelf.displaySleepRequestInFlight = NO;
            if (error != nil) {
                [strongSelf appendDebugLog:@"display sleep request finished; iokit=%@ method=%@ error=%@", idleRequested ? @"yes" : @"no", method, error.localizedDescription ?: @"unknown"];
            } else {
                [strongSelf appendDebugLog:@"display sleep request finished; iokit=%@ method=%@ ok", idleRequested ? @"yes" : @"no", method];
            }
        });
    });
}

- (void)dimBuiltInDisplayForClosedLidIfNeeded {
    if (self.didDimBuiltInDisplayForClosedLid) {
        return;
    }

    float brightness = 0.0;
    if (![DSAppDelegate getBuiltInDisplayBrightness:&brightness]) {
        [self appendDebugLog:@"could not read built-in display brightness"];
        return;
    }

    self.savedBuiltInDisplayBrightness = brightness;
    self.hasSavedBuiltInDisplayBrightness = YES;

    if (![DSAppDelegate setBuiltInDisplayBrightness:0.0]) {
        [self appendDebugLog:@"could not dim built-in display"];
        return;
    }

    self.didDimBuiltInDisplayForClosedLid = YES;
    [self appendDebugLog:@"built-in display dimmed; savedBrightness=%.3f", brightness];
}

- (void)restoreBuiltInDisplayBrightnessIfNeeded {
    if (!self.didDimBuiltInDisplayForClosedLid || !self.hasSavedBuiltInDisplayBrightness) {
        return;
    }

    float brightness = MAX(0.05, self.savedBuiltInDisplayBrightness);
    if ([DSAppDelegate setBuiltInDisplayBrightness:brightness]) {
        [self appendDebugLog:@"built-in display brightness restored; brightness=%.3f", brightness];
    } else {
        [self appendDebugLog:@"could not restore built-in display brightness"];
    }

    self.didDimBuiltInDisplayForClosedLid = NO;
    self.hasSavedBuiltInDisplayBrightness = NO;
}

- (void)appendDebugLog:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, message ?: @""];
    NSURL *logURL = [DSAppDelegate diagnosticsLogURL];

    [NSFileManager.defaultManager createDirectoryAtURL:logURL.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];

    if (![NSFileManager.defaultManager fileExistsAtPath:logURL.path]) {
        [line writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

- (void)updateStatusIcon {
    NSStatusBarButton *button = self.statusItem.button;
    if (button == nil) {
        return;
    }

    NSImage *image = [DSAppDelegate statusBarIconForState:self.state];
    button.title = @"";
    button.imagePosition = NSImageOnly;
    button.image = image;
}

- (void)showError:(NSError *)error {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"설정을 변경하지 못했습니다";
    alert.informativeText = error.localizedDescription ?: @"알 수 없는 오류입니다.";
    alert.alertStyle = NSAlertStyleWarning;
    if (self.appIcon != nil) {
        alert.icon = self.appIcon;
    }
    [alert runModal];
}

+ (NSImage *)bundledAppIcon {
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
    if (iconPath.length == 0) {
        return nil;
    }

    return [[NSImage alloc] initWithContentsOfFile:iconPath];
}

+ (NSImage *)statusBarIconForState:(DSSleepState)state {
    BOOL isAwake = state == DSSleepStateEnabled || state == DSSleepStatePartiallyEnabled;
    NSString *resourceName = isAwake ? @"MenuBarIconOn" : @"MenuBarIcon";
    NSString *iconPath = [NSBundle.mainBundle pathForResource:resourceName ofType:@"svg"];
    NSImage *image = iconPath.length > 0 ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (image == nil) {
        image = [NSImage imageWithSystemSymbolName:@"laptopcomputer" accessibilityDescription:@"Don't Sleep"];
    }

    image.size = NSMakeSize(DSMenuBarIconWidth, DSMenuBarIconHeight);
    image.template = YES;
    image.accessibilityDescription = @"Don't Sleep";
    return image;
}

+ (BOOL)isPrivilegedHelperUsable {
    struct stat helperStat;
    if (stat(DSPrivilegedHelperPath.fileSystemRepresentation, &helperStat) != 0) {
        return NO;
    }

    BOOL hasExecuteBit = (helperStat.st_mode & S_IXUSR) == S_IXUSR;
    BOOL hasSetuidBit = (helperStat.st_mode & S_ISUID) == S_ISUID;

    return helperStat.st_uid == 0 &&
           helperStat.st_gid == 0 &&
           hasExecuteBit &&
           hasSetuidBit;
}

+ (BOOL)isInstalledPrivilegedHelperCurrent {
    NSString *bundledHelperPath = [self bundledPrivilegedHelperPath];
    if (bundledHelperPath.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:DSPrivilegedHelperPath] ||
        ![NSFileManager.defaultManager fileExistsAtPath:bundledHelperPath]) {
        return NO;
    }

    return [NSFileManager.defaultManager contentsEqualAtPath:DSPrivilegedHelperPath
                                                     andPath:bundledHelperPath];
}

+ (BOOL)installBundledPrivilegedHelperWithError:(NSError **)error {
    NSString *bundledHelperPath = [self bundledPrivilegedHelperPath];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:bundledHelperPath]) {
        if (error != NULL) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"앱 번들 안에서 관리자 헬퍼를 찾지 못했습니다. 앱을 다시 설치해주세요."
            };
            *error = [NSError errorWithDomain:@"DontSleep.Helper" code:1 userInfo:userInfo];
        }
        return NO;
    }

    NSString *destinationDirectory = DSPrivilegedHelperPath.stringByDeletingLastPathComponent;
    NSString *command = [NSString stringWithFormat:@"/bin/mkdir -p %@ && /usr/bin/install -o root -g wheel -m 4755 %@ %@",
                         [self shellQuotedString:destinationDirectory],
                         [self shellQuotedString:bundledHelperPath],
                         [self shellQuotedString:DSPrivilegedHelperPath]];
    NSString *script = [NSString stringWithFormat:@"do shell script %@ with administrator privileges",
                        [self appleScriptQuotedString:command]];

    NSError *installError = nil;
    [DSCommandRunner outputForExecutable:@"/usr/bin/osascript"
                               arguments:@[@"-e", script]
                                   error:&installError];

    if (installError != nil) {
        if (error != NULL) {
            *error = installError;
        }
        return NO;
    }

    if (![self isPrivilegedHelperUsable] || ![self isInstalledPrivilegedHelperCurrent]) {
        if (error != NULL) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"관리자 헬퍼 설치는 끝났지만 실행 권한을 확인하지 못했습니다. 설치 명령을 다시 실행해주세요."
            };
            *error = [NSError errorWithDomain:@"DontSleep.Helper" code:2 userInfo:userInfo];
        }
        return NO;
    }

    return YES;
}

+ (NSString *)bundledPrivilegedHelperPath {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath ?: @"";
    return [[bundlePath stringByAppendingPathComponent:@"Contents/Library/PrivilegedHelperTools"] stringByAppendingPathComponent:DSPrivilegedHelperName];
}

+ (NSString *)shellQuotedString:(NSString *)string {
    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

+ (NSString *)appleScriptQuotedString:(NSString *)string {
    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

+ (DSSleepState)stateFromOutput:(NSString *)output {
    NSArray<NSString *> *values = [self sleepDisabledValuesFromOutput:output];

    if (values.count == 0) {
        return DSSleepStateDisabled;
    }

    BOOL hasEnabledValue = [values containsObject:@"1"];
    BOOL hasDisabledValue = [values containsObject:@"0"];

    if (hasEnabledValue && !hasDisabledValue) {
        return DSSleepStateEnabled;
    }

    if (hasEnabledValue && hasDisabledValue) {
        return DSSleepStatePartiallyEnabled;
    }

    return DSSleepStateDisabled;
}

+ (DSSleepState)currentSleepState {
    NSError *customError = nil;
    NSString *customOutput = [DSCommandRunner outputForExecutable:@"/usr/bin/pmset"
                                                        arguments:@[@"-g", @"custom"]
                                                            error:&customError] ?: @"";

    NSError *currentError = nil;
    NSString *currentOutput = [DSCommandRunner outputForExecutable:@"/usr/bin/pmset"
                                                         arguments:@[@"-g"]
                                                             error:&currentError] ?: @"";

    if (customOutput.length == 0 && currentOutput.length == 0 && customError != nil && currentError != nil) {
        return DSSleepStateUnknown;
    }

    NSString *combinedOutput = [customOutput stringByAppendingFormat:@"\n%@", currentOutput];
    return [self stateFromOutput:combinedOutput];
}

+ (NSArray<NSNumber *> *)automaticDisplaySleepMinuteOptions {
    return @[@5, @10, @15, @30, @60, @120, @180, @0];
}

+ (NSInteger)savedAutomaticDisplaySleepMinutes {
    NSInteger minutes = [NSUserDefaults.standardUserDefaults integerForKey:DSAutomaticDisplaySleepMinutesKey];
    return [self isValidAutomaticDisplaySleepMinutes:minutes] ? minutes : 0;
}

+ (BOOL)isValidAutomaticDisplaySleepMinutes:(NSInteger)minutes {
    return [[self automaticDisplaySleepMinuteOptions] containsObject:@(minutes)];
}

+ (NSString *)automaticDisplaySleepTitleForMinutes:(NSInteger)minutes {
    switch (minutes) {
        case 0:
            return @"끄지 않음";
        case 60:
            return @"1시간";
        case 120:
            return @"2시간";
        case 180:
            return @"3시간";
        default:
            return [NSString stringWithFormat:@"%ld분", (long)minutes];
    }
}

+ (NSArray<NSString *> *)sleepDisabledValuesFromOutput:(NSString *)output {
    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableArray<NSString *> *values = [NSMutableArray array];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:whitespace];

        if (![trimmed hasPrefix:@"disablesleep"] && ![trimmed hasPrefix:@"SleepDisabled"]) {
            continue;
        }

        NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];

        for (NSString *part in parts) {
            if (part.length > 0) {
                [tokens addObject:part];
            }
        }

        if (tokens.count >= 2 && ([tokens.lastObject isEqualToString:@"0"] || [tokens.lastObject isEqualToString:@"1"])) {
            [values addObject:tokens.lastObject];
        }
    }

    return values;
}

+ (BOOL)isLidClosed {
    io_registry_entry_t powerDomain = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain");
    if (powerDomain == IO_OBJECT_NULL) {
        return NO;
    }

    CFTypeRef value = IORegistryEntryCreateCFProperty(powerDomain, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(powerDomain);

    if (value == NULL) {
        return NO;
    }

    BOOL lidClosed = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        lidClosed = CFBooleanGetValue(value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numberValue = 0;
        if (CFNumberGetValue(value, kCFNumberIntType, &numberValue)) {
            lidClosed = numberValue != 0;
        }
    }

    CFRelease(value);
    return lidClosed;
}

+ (BOOL)requestDisplayIdleWithIOKit {
    io_service_t displayWrangler = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayWrangler"));
    if (displayWrangler == IO_OBJECT_NULL) {
        return NO;
    }

    kern_return_t result = IORegistryEntrySetCFProperty(displayWrangler, CFSTR("IORequestIdle"), kCFBooleanTrue);
    IOObjectRelease(displayWrangler);
    return result == KERN_SUCCESS;
}

+ (NSURL *)diagnosticsLogURL {
    NSURL *libraryURL = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    return [[libraryURL URLByAppendingPathComponent:@"Logs" isDirectory:YES] URLByAppendingPathComponent:@"DontSleep.log"];
}

+ (BOOL)getBuiltInDisplayBrightness:(float *)brightness {
    io_service_t service = [self builtInDisplayService];
    if (service == IO_OBJECT_NULL) {
        return NO;
    }

    return IODisplayGetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), brightness) == KERN_SUCCESS;
}

+ (BOOL)setBuiltInDisplayBrightness:(float)brightness {
    io_service_t service = [self builtInDisplayService];
    if (service == IO_OBJECT_NULL) {
        return NO;
    }

    float clampedBrightness = MAX(0.0, MIN(1.0, brightness));
    return IODisplaySetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), clampedBrightness) == KERN_SUCCESS;
}

+ (io_service_t)builtInDisplayService {
    uint32_t displayCount = 0;
    if (CGGetOnlineDisplayList(0, NULL, &displayCount) != kCGErrorSuccess || displayCount == 0) {
        return IO_OBJECT_NULL;
    }

    CGDirectDisplayID *displays = calloc(displayCount, sizeof(CGDirectDisplayID));
    if (displays == NULL) {
        return IO_OBJECT_NULL;
    }

    io_service_t service = IO_OBJECT_NULL;
    if (CGGetOnlineDisplayList(displayCount, displays, &displayCount) == kCGErrorSuccess) {
        for (uint32_t index = 0; index < displayCount; index += 1) {
            if (CGDisplayIsBuiltin(displays[index])) {
                service = CGDisplayIOServicePort(displays[index]);
                break;
            }
        }
    }

    free(displays);
    return service;
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        DSAppDelegate *delegate = [[DSAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }

    return 0;
}
