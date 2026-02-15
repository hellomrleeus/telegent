#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <signal.h>
#import <unistd.h>

static NSString *const kTelegentLanguageKey = @"telegentLanguage";
static NSString *const kTelegentLangZH = @"zh-Hans";
static NSString *const kTelegentLangEN = @"en";

@interface BridgeController : NSObject
@property(nonatomic, strong) NSTask *task;
@property(nonatomic, copy) NSString *repoRoot;
@property(nonatomic, copy) NSString *corePath;
@property(nonatomic, copy) NSString *logPath;
@property(nonatomic, copy) NSString *dataRoot;
- (instancetype)initWithRepoRoot:(NSString *)repoRoot;
- (BOOL)isRunning;
- (NSError *)start;
- (void)stop;
- (NSError *)restart;
- (void)openLog;
- (NSDictionary<NSString *, NSString *> *)resolvedEnvironment;
- (NSDictionary<NSString *, NSString *> *)defaultEnv;
- (NSDictionary<NSString *, NSString *> *)loadStoredConfig;
- (void)saveStoredConfig:(NSDictionary<NSString *, NSString *> *)config;
- (void)cleanupResidualCoreProcesses;
@end

@implementation BridgeController

- (NSString *)readLogTail:(NSUInteger)maxBytes {
    NSData *data = [NSData dataWithContentsOfFile:self.logPath];
    if (!data || data.length == 0) return @"";
    NSUInteger len = data.length;
    NSUInteger start = (len > maxBytes) ? (len - maxBytes) : 0;
    NSData *slice = [data subdataWithRange:NSMakeRange(start, len - start)];
    NSString *txt = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    return txt ?: @"";
}

- (instancetype)initWithRepoRoot:(NSString *)repoRoot {
    self = [super init];
    if (!self) return nil;
    _repoRoot = [repoRoot copy];
    _corePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/MacOS/telegent-core"];
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    _dataRoot = [appSupport stringByAppendingPathComponent:@"telegent"];
    _logPath = [_dataRoot stringByAppendingPathComponent:@"logs/app-bridge.log"];
    return self;
}

- (BOOL)isRunning {
    return self.task != nil && self.task.running;
}

- (NSDictionary<NSString *, NSString *> *)defaultEnv {
    NSString *tmpDir = [self.dataRoot stringByAppendingPathComponent:@"tmp"];
    NSString *imageDir = [self.dataRoot stringByAppendingPathComponent:@"images"];
    NSString *whisperScript = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:@"transcribe_faster_whisper.py"];
    return @{
        @"TELEGRAM_BOT_TOKEN": @"",
        @"TELEGRAM_ALLOWED_USER_ID": @"",
        @"AGENT_PROVIDER": @"codex",
        @"AGENT_BIN": @"/Applications/Codex.app/Contents/Resources/codex",
        @"AGENT_ARGS": @"",
        @"AGENT_MODEL": @"",
        @"AGENT_SUPPORTS_IMAGE": @"true",
        @"CODEX_WORKDIR": self.repoRoot,
        @"CODEX_BIN": @"/Applications/Codex.app/Contents/Resources/codex",
        @"WHISPER_PYTHON_BIN": @"python3",
        @"WHISPER_SCRIPT": whisperScript,
        @"FASTER_WHISPER_MODEL": @"small",
        @"FASTER_WHISPER_LANGUAGE": @"zh",
        @"FASTER_WHISPER_COMPUTE_TYPE": @"int8",
        @"CODEX_TIMEOUT_SEC": @"180",
        @"MAX_REPLY_CHARS": @"3500",
        @"CODEX_SANDBOX": @"workspace-write",
        @"TMPDIR": tmpDir,
        @"IMAGE_DIR": imageDir,
        @"CHAT_LOG_FILE": [self.dataRoot stringByAppendingPathComponent:@"chat-history.jsonl"],
        @"SESSION_STORE_FILE": [self.dataRoot stringByAppendingPathComponent:@"codex-sessions.json"],
        @"MEMORY_FILE": [self.dataRoot stringByAppendingPathComponent:@"MEMORY.md"]
    };
}

- (NSDictionary<NSString *, NSString *> *)loadStoredConfig {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"telegentConfig"];
    if (![stored isKindOfClass:[NSDictionary class]]) {
        // Compatibility migration from old key.
        stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BridgeConfig"];
    }
    if (![stored isKindOfClass:[NSDictionary class]]) return out;
    for (NSString *key in stored) {
        id val = stored[key];
        if ([val isKindOfClass:[NSString class]] && ((NSString *)val).length > 0) {
            out[key] = (NSString *)val;
        } else if (val != nil) {
            out[key] = [val description];
        }
    }
    return out;
}

- (void)saveStoredConfig:(NSDictionary<NSString *, NSString *> *)config {
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *key in config) {
        NSString *val = [config[key] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (val.length > 0) {
            clean[key] = val;
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:clean forKey:@"telegentConfig"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDictionary<NSString *, NSString *> *)resolvedEnvironment {
    NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionaryWithDictionary:[self defaultEnv]];
    NSMutableDictionary<NSString *, NSString *> *stored = [[self loadStoredConfig] mutableCopy];
    if (!stored) stored = [NSMutableDictionary dictionary];
    NSString *whisperScript = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:@"transcribe_faster_whisper.py"];

    // Pin runtime artifacts to app-owned data directory unless user explicitly overrides later.
    NSDictionary<NSString *, NSString *> *pinned = @{
        @"WHISPER_SCRIPT": whisperScript,
        @"TMPDIR": [self.dataRoot stringByAppendingPathComponent:@"tmp"],
        @"IMAGE_DIR": [self.dataRoot stringByAppendingPathComponent:@"images"],
        @"CHAT_LOG_FILE": [self.dataRoot stringByAppendingPathComponent:@"chat-history.jsonl"],
        @"SESSION_STORE_FILE": [self.dataRoot stringByAppendingPathComponent:@"codex-sessions.json"],
        @"MEMORY_FILE": [self.dataRoot stringByAppendingPathComponent:@"MEMORY.md"]
    };
    for (NSString *k in pinned) {
        stored[k] = pinned[k];
    }
    [self saveStoredConfig:stored];
    [env addEntriesFromDictionary:stored];
    return env;
}

- (NSError *)start {
    if ([self isRunning]) return nil;
    [self cleanupResidualCoreProcesses];

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:self.corePath]) {
        return [NSError errorWithDomain:@"telegent" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Missing core binary: %@", self.corePath]}];
    }

    NSString *logDir = [self.logPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpDir = [self resolvedEnvironment][@"TMPDIR"];
    if (tmpDir.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:[tmpDir stringByAppendingPathComponent:@"inbox"] withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *imageDir = [self resolvedEnvironment][@"IMAGE_DIR"];
    if (imageDir.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:imageDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.logPath]) {
        [[NSData data] writeToFile:self.logPath atomically:YES];
    }

    NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    [env addEntriesFromDictionary:[self resolvedEnvironment]];
    env[@"BRIDGE_PARENT_PID"] = [NSString stringWithFormat:@"%d", getpid()];

    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    [logHandle seekToEndOfFile];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.corePath];
    task.currentDirectoryURL = [NSURL fileURLWithPath:self.repoRoot];
    task.environment = env;
    task.standardOutput = logHandle;
    task.standardError = logHandle;

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        (void)finishedTask;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.task = nil;
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return error;
    }
    self.task = task;

    // If core exits immediately, surface a clear startup error in UI.
    [NSThread sleepForTimeInterval:0.4];
    if (!task.running) {
        self.task = nil;
        NSString *tail = [self readLogTail:8192];
        if ([tail containsString:@"another bridge instance is already running"]) {
            NSString *msg = @"启动被拦截：检测到已有 Bridge 实例正在运行。\n\n请先退出旧实例（包括其它 App 包或终端里的 go run），再重试。";
            return [NSError errorWithDomain:@"telegent" code:2 userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        NSString *fallback = [tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (fallback.length == 0) {
            fallback = [NSString stringWithFormat:@"bridge core exited immediately (code=%d)", task.terminationStatus];
        }
        return [NSError errorWithDomain:@"telegent" code:3 userInfo:@{NSLocalizedDescriptionKey: fallback}];
    }

    return nil;
}

- (void)cleanupResidualCoreProcesses {
    NSTask *pgrep = [[NSTask alloc] init];
    pgrep.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pgrep"];
    pgrep.arguments = @[@"-f", self.corePath];
    NSPipe *outPipe = [NSPipe pipe];
    pgrep.standardOutput = outPipe;
    pgrep.standardError = [NSPipe pipe];

    NSError *err = nil;
    if (![pgrep launchAndReturnError:&err]) {
        return;
    }
    [pgrep waitUntilExit];
    if (pgrep.terminationStatus != 0) {
        return;
    }

    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (raw.length == 0) return;

    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trim.length == 0) continue;
        pid_t pid = (pid_t)[trim intValue];
        if (pid <= 1) continue;
        if (pid == getpid()) continue;
        if (self.task && self.task.running && pid == (pid_t)self.task.processIdentifier) continue;
        [pids addObject:@(pid)];
    }

    for (NSNumber *pidNum in pids) {
        kill((pid_t)pidNum.intValue, SIGTERM);
    }
    [NSThread sleepForTimeInterval:0.2];
    for (NSNumber *pidNum in pids) {
        pid_t pid = (pid_t)pidNum.intValue;
        if (kill(pid, 0) == 0) {
            kill(pid, SIGKILL);
        }
    }
}

- (void)stop {
    NSTask *task = self.task;
    if (task && task.running) {
        [task terminate];
        for (int i = 0; i < 20; i++) {
            if (!task.running) break;
            [NSThread sleepForTimeInterval:0.05];
        }
        if (task.running) {
            kill((pid_t)task.processIdentifier, SIGKILL);
        }
    }
    self.task = nil;
}

- (NSError *)restart {
    [self stop];
    return [self start];
}

- (void)openLog {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.logPath]];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusLine;
@property(nonatomic, strong) NSMenuItem *versionLine;
@property(nonatomic, strong) NSMenuItem *startItem;
@property(nonatomic, strong) NSMenuItem *stopItem;
@property(nonatomic, strong) NSMenuItem *restartItem;
@property(nonatomic, strong) BridgeController *bridge;

@property(nonatomic, strong) NSWindow *controlWindow;
@property(nonatomic, strong) NSTabView *tabView;

@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *configFields;
@property(nonatomic, strong) NSTextField *configHint;
@property(nonatomic, strong) NSSwitch *screenSwitch;
@property(nonatomic, strong) NSSwitch *axSwitch;
@property(nonatomic, strong) NSSwitch *micSwitch;
@property(nonatomic, strong) NSSwitch *camSwitch;
@property(nonatomic, strong) NSTextField *permHint;

@property(nonatomic, strong) NSTextView *memoryTextView;
@property(nonatomic, strong) NSTextView *agentsTextView;
@property(nonatomic, strong) NSTextField *memoryAppendField;
@property(nonatomic, strong) NSTextView *runtimeLogTextView;
@property(nonatomic, strong) NSTextView *chatHistoryTextView;
@property(nonatomic, strong) NSScrollView *chatHistoryScrollView;
@property(nonatomic, strong) NSStackView *chatHistoryStackView;
@property(nonatomic, strong) NSImage *chatUserAvatar;
@property(nonatomic, strong) NSImage *chatBotAvatar;
@property(nonatomic, strong) NSTextView *codexCheckTextView;
@property(nonatomic, strong) NSTableView *dependencyTableView;
@property(nonatomic, strong) NSTextView *dependencyFailureTextView;
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *dependencyRows;
@property(nonatomic, copy) NSString *statusVersionText;
@property(nonatomic, strong) NSImage *statusIconRunning;
@property(nonatomic, strong) NSImage *statusIconStopped;
@property(nonatomic, strong) NSImage *statusIconError;
@property(nonatomic, assign) BOOL startupFailed;
@property(nonatomic, copy) NSString *languageCode;
@end

@implementation AppDelegate

- (NSString *)detectRepoRoot {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *cursor = [bundlePath stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSInteger i = 0; i < 6; i++) {
        NSString *goMod = [cursor stringByAppendingPathComponent:@"go.mod"];
        NSString *agents = [cursor stringByAppendingPathComponent:@"AGENTS.md"];
        NSString *agent = [cursor stringByAppendingPathComponent:@"AGENT.md"];
        if ([fm fileExistsAtPath:goMod] || [fm fileExistsAtPath:agents] || [fm fileExistsAtPath:agent]) {
            return cursor;
        }
        NSString *next = [cursor stringByDeletingLastPathComponent];
        if (next.length == 0 || [next isEqualToString:cursor]) break;
        cursor = next;
    }
    return [bundlePath stringByDeletingLastPathComponent];
}

- (NSString *)normalizedLanguageCode:(NSString *)raw {
    NSString *trim = [[raw ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([trim hasPrefix:@"en"]) return kTelegentLangEN;
    if ([trim hasPrefix:@"zh"]) return kTelegentLangZH;
    return @"";
}

- (void)loadLanguagePreference {
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:kTelegentLanguageKey];
    NSString *normalized = [self normalizedLanguageCode:stored];
    if (normalized.length > 0) {
        self.languageCode = normalized;
        return;
    }
    NSString *systemLang = [[[NSLocale preferredLanguages] firstObject] lowercaseString];
    self.languageCode = [systemLang hasPrefix:@"zh"] ? kTelegentLangZH : kTelegentLangEN;
}

- (BOOL)isEnglish {
    return [self.languageCode isEqualToString:kTelegentLangEN];
}

- (NSString *)L:(NSString *)zh en:(NSString *)en {
    return [self isEnglish] ? (en ?: zh ?: @"") : (zh ?: en ?: @"");
}

- (void)setAppLanguage:(NSString *)languageCode refreshUI:(BOOL)refreshUI {
    NSString *normalized = [self normalizedLanguageCode:languageCode];
    if (normalized.length == 0) return;
    self.languageCode = normalized;
    [[NSUserDefaults standardUserDefaults] setObject:normalized forKey:kTelegentLanguageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (!refreshUI) return;

    [self setupMainMenu];
    [self setupStatusItem];
    BOOL wasVisible = self.controlWindow.isVisible;
    [self buildControlWindow];
    if (wasVisible) {
        [self.controlWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    [self refresh];
}

- (void)switchLanguageChinese {
    [self setAppLanguage:kTelegentLangZH refreshUI:YES];
}

- (void)switchLanguageEnglish {
    [self setAppLanguage:kTelegentLangEN refreshUI:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self loadLanguagePreference];
    NSString *repoRoot = [self detectRepoRoot];
    self.bridge = [[BridgeController alloc] initWithRepoRoot:repoRoot];
    [self setupMainMenu];

    [self setupStatusItem];
    [self buildControlWindow];

    NSError *error = [self.bridge start];
    self.startupFailed = (error != nil);
    if (error) [self showError:error.localizedDescription];
    [self refresh];

    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshTimer) userInfo:nil repeats:YES];
}

- (void)setupMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"telegent"];
    NSString *appName = NSProcessInfo.processInfo.processName ?: @"telegent";
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ %@", [self L:@"退出" en:@"Quit"], appName]
                                                       action:@selector(terminate:)
                                                keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    appItem.submenu = appMenu;

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:[self L:@"编辑" en:@"Edit"] action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:[self L:@"编辑" en:@"Edit"]];
    [editMenu addItemWithTitle:[self L:@"撤销" en:@"Undo"] action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:[self L:@"重做" en:@"Redo"] action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:[self L:@"剪切" en:@"Cut"] action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:[self L:@"复制" en:@"Copy"] action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:[self L:@"粘贴" en:@"Paste"] action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:[self L:@"全选" en:@"Select All"] action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    [NSApp setMainMenu:mainMenu];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.bridge stop];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag) {
        [self.controlWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return YES;
}

- (void)setupStatusItem {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    }
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusIconRunning = [self loadStatusIconNamed:@"status-icon-running" template:YES symbolFallback:@"checkmark.circle.fill"];
    self.statusIconStopped = [self loadStatusIconNamed:@"status-icon-stopped" template:YES symbolFallback:@"pause.circle.fill"];
    self.statusIconError = [self loadStatusIconNamed:@"status-icon-error" template:NO symbolFallback:@"xmark.circle.fill"];
    NSString *shortVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    if (shortVersion.length > 0 && buildVersion.length > 0) {
        self.statusVersionText = [NSString stringWithFormat:@"%@ (%@)", shortVersion, buildVersion];
    } else {
        self.statusVersionText = shortVersion;
    }
    NSString *tip = self.statusVersionText;
    self.statusItem.button.toolTip = tip;
    [self updateStatusItemIcon:NO];

    NSMenu *menu = [[NSMenu alloc] init];
    self.statusLine = [[NSMenuItem alloc] initWithTitle:[self L:@"状态: 已停止" en:@"Status: stopped"] action:nil keyEquivalent:@""];
    [menu addItem:self.statusLine];
    self.versionLine = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@: %@", [self L:@"版本" en:@"Version"], (self.statusVersionText.length > 0 ? self.statusVersionText : @"-")] action:nil keyEquivalent:@""];
    [menu addItem:self.versionLine];
    [menu addItem:[NSMenuItem separatorItem]];

    self.startItem = [[NSMenuItem alloc] initWithTitle:[self L:@"启动" en:@"Start"] action:@selector(startBridge) keyEquivalent:@"s"];
    self.startItem.target = self;
    [menu addItem:self.startItem];

    self.stopItem = [[NSMenuItem alloc] initWithTitle:[self L:@"停止" en:@"Stop"] action:@selector(stopBridge) keyEquivalent:@"t"];
    self.stopItem.target = self;
    [menu addItem:self.stopItem];

    self.restartItem = [[NSMenuItem alloc] initWithTitle:[self L:@"重启" en:@"Restart"] action:@selector(restartBridge) keyEquivalent:@"r"];
    self.restartItem.target = self;
    [menu addItem:self.restartItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *control = [[NSMenuItem alloc] initWithTitle:[self L:@"打开控制中心" en:@"Open Control Center"] action:@selector(openControlCenter) keyEquivalent:@"c"];
    control.target = self;
    [menu addItem:control];

    NSMenuItem *openLog = [[NSMenuItem alloc] initWithTitle:[self L:@"打开运行日志" en:@"Open Runtime Log"] action:@selector(openRuntimeLog) keyEquivalent:@"l"];
    openLog.target = self;
    [menu addItem:openLog];

    NSMenuItem *openProject = [[NSMenuItem alloc] initWithTitle:[self L:@"打开工作目录" en:@"Open Workspace Folder"] action:@selector(openProjectFolder) keyEquivalent:@"o"];
    openProject.target = self;
    [menu addItem:openProject];

    NSMenuItem *langItem = [[NSMenuItem alloc] initWithTitle:[self L:@"语言" en:@"Language"] action:nil keyEquivalent:@""];
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:[self L:@"语言" en:@"Language"]];
    NSMenuItem *zhItem = [[NSMenuItem alloc] initWithTitle:@"中文" action:@selector(switchLanguageChinese) keyEquivalent:@""];
    zhItem.target = self;
    zhItem.state = [self isEnglish] ? NSControlStateValueOff : NSControlStateValueOn;
    [langMenu addItem:zhItem];
    NSMenuItem *enItem = [[NSMenuItem alloc] initWithTitle:@"English" action:@selector(switchLanguageEnglish) keyEquivalent:@""];
    enItem.target = self;
    enItem.state = [self isEnglish] ? NSControlStateValueOn : NSControlStateValueOff;
    [langMenu addItem:enItem];
    langItem.submenu = langMenu;
    [menu addItem:langItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:[self L:@"退出" en:@"Quit"] action:@selector(quitApp) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (NSImage *)loadStatusIconNamed:(NSString *)name template:(BOOL)isTemplate symbolFallback:(NSString *)symbolName {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"png"];
    NSImage *img = path.length > 0 ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!img) {
        if (@available(macOS 11.0, *)) {
            img = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:@"Bridge"];
        }
    }
    if (img) {
        img.template = isTemplate;
        img.size = NSMakeSize(18, 18);
    }
    return img;
}

- (void)updateStatusItemIcon:(BOOL)running {
    NSStatusBarButton *button = self.statusItem.button;
    if (!button) return;
    NSImage *img = nil;
    if (self.startupFailed) {
        img = self.statusIconError;
    } else {
        img = running ? self.statusIconRunning : self.statusIconStopped;
    }
    if (img) {
        button.image = img;
        if ([button respondsToSelector:@selector(setContentTintColor:)]) {
            button.contentTintColor = self.startupFailed ? [NSColor systemRedColor] : nil;
        }
        button.title = @"";
        return;
    }
    NSString *prefix = self.startupFailed ? @"Bridge✖" : (running ? @"Bridge●" : @"Bridge○");
    button.title = prefix;
}

- (void)buildControlWindow {
    NSRect frame = NSMakeRect(200, 200, 980, 700);
    self.controlWindow = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
    self.controlWindow.title = [self L:@"telegent 控制中心" en:@"telegent Control Center"];
    self.controlWindow.delegate = self;

    NSView *content = self.controlWindow.contentView;
    self.tabView = [[NSTabView alloc] initWithFrame:content.bounds];
    self.tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.tabView.delegate = self;
    [content addSubview:self.tabView];

    [self buildConfigTab];
    [self buildPermissionTab];
    [self buildLogsTab];
    [self buildChatHistoryTab];
    [self buildCodexCheckTab];
    [self buildMemoryAgentsTab];
}

- (NSView *)makeTabContainer {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 960, 640)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return v;
}

- (void)buildConfigTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"config"];
    item.label = [self L:@"配置" en:@"Config"];

    NSView *root = [self makeTabContainer];
    self.configFields = [NSMutableDictionary dictionary];

    NSArray<NSDictionary<NSString *, NSString *> *> *defs = @[
        @{@"group": @"Telegram", @"key": @"TELEGRAM_BOT_TOKEN", @"label": @"机器人 Token"},
        @{@"group": @"Telegram", @"key": @"TELEGRAM_ALLOWED_USER_ID", @"label": @"你的 Telegram 用户 ID"},

        @{@"group": @"Agent 执行", @"key": @"AGENT_PROVIDER", @"label": @"Agent 提供方"},
        @{@"group": @"Agent 执行", @"key": @"AGENT_BIN", @"label": @"Agent 可执行路径"},
        @{@"group": @"Agent 执行", @"key": @"AGENT_ARGS", @"label": @"Agent 固定参数"},
        @{@"group": @"Agent 执行", @"key": @"AGENT_MODEL", @"label": @"Agent 模型(可选)"},
        @{@"group": @"Agent 执行", @"key": @"AGENT_SUPPORTS_IMAGE", @"label": @"Agent 支持图片输入"},
        @{@"group": @"Agent 执行", @"key": @"CODEX_WORKDIR", @"label": @"工作目录"},
        @{@"group": @"Agent 执行", @"key": @"CODEX_TIMEOUT_SEC", @"label": @"执行超时(秒)"},
        @{@"group": @"Agent 执行", @"key": @"MAX_REPLY_CHARS", @"label": @"最大回复字符数"},
        @{@"group": @"Agent 执行", @"key": @"CODEX_SANDBOX", @"label": @"Codex 沙箱模式"},
        @{@"group": @"Agent 执行", @"key": @"CODEX_MODEL", @"label": @"Codex 模型(可选)"},

        @{@"group": @"语音转写", @"key": @"WHISPER_PYTHON_BIN", @"label": @"Whisper Python 路径"},
        @{@"group": @"语音转写", @"key": @"FASTER_WHISPER_MODEL", @"label": @"Whisper 模型"},
        @{@"group": @"语音转写", @"key": @"FASTER_WHISPER_LANGUAGE", @"label": @"Whisper 语言"},
        @{@"group": @"语音转写", @"key": @"FASTER_WHISPER_COMPUTE_TYPE", @"label": @"Whisper 算力模式"},

        @{@"group": @"存储与日志", @"key": @"TMPDIR", @"label": @"临时目录"},
        @{@"group": @"存储与日志", @"key": @"IMAGE_DIR", @"label": @"图片目录"},
        @{@"group": @"存储与日志", @"key": @"CHAT_LOG_FILE", @"label": @"聊天日志文件"},
        @{@"group": @"存储与日志", @"key": @"SESSION_STORE_FILE", @"label": @"会话存储文件"},
        @{@"group": @"存储与日志", @"key": @"MEMORY_FILE", @"label": @"记忆文件"}
    ];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 96, 920, 514)];
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat formHeight = 20.0;
    NSString *lastGroup = nil;
    for (NSDictionary<NSString *, NSString *> *def in defs) {
        NSString *group = def[@"group"] ?: @"";
        if (lastGroup == nil || ![lastGroup isEqualToString:group]) {
            formHeight += 34.0;
            lastGroup = group;
        }
        formHeight += 46.0;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, formHeight)];
    form.autoresizingMask = NSViewWidthSizable;
    CGFloat y = form.bounds.size.height - 12.0;
    lastGroup = nil;
    for (NSDictionary<NSString *, NSString *> *def in defs) {
        NSString *key = def[@"key"];
        NSString *zh = def[@"label"];
        NSString *group = def[@"group"] ?: @"";

        if (lastGroup == nil || ![lastGroup isEqualToString:group]) {
            NSTextField *groupLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y - 22, 860, 20)];
            groupLabel.stringValue = group;
            groupLabel.bezeled = NO;
            groupLabel.drawsBackground = NO;
            groupLabel.editable = NO;
            groupLabel.selectable = NO;
            groupLabel.font = [NSFont boldSystemFontOfSize:13];
            groupLabel.textColor = [NSColor labelColor];
            [form addSubview:groupLabel];

            NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(10, y - 28, 870, 1)];
            line.boxType = NSBoxSeparator;
            [form addSubview:line];

            y -= 38.0;
            lastGroup = group;
        }

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(10, y - 24, 280, 20)];
        label.stringValue = zh;
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;

        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(300, y - 30, 580, 28)];
        field.placeholderString = @"(empty)";
        field.selectable = YES;
        field.editable = YES;
        field.autoresizingMask = NSViewWidthSizable;
        if ([key isEqualToString:@"TMPDIR"] ||
            [key isEqualToString:@"IMAGE_DIR"] ||
            [key isEqualToString:@"CHAT_LOG_FILE"] ||
            [key isEqualToString:@"SESSION_STORE_FILE"] ||
            [key isEqualToString:@"MEMORY_FILE"]) {
            field.editable = NO;
            field.selectable = YES;
            field.textColor = [NSColor secondaryLabelColor];
        }

        [form addSubview:label];
        [form addSubview:field];
        self.configFields[key] = field;
        y -= 46;
    }
    scroll.documentView = form;
    [root addSubview:scroll];

    NSBox *bottomBar = [[NSBox alloc] initWithFrame:NSMakeRect(20, 20, 920, 56)];
    bottomBar.boxType = NSBoxCustom;
    bottomBar.borderType = NSNoBorder;
    bottomBar.fillColor = [NSColor colorWithWhite:1.0 alpha:0.03];
    bottomBar.cornerRadius = 8.0;
    bottomBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [root addSubview:bottomBar];

    NSButton *reload = [[NSButton alloc] initWithFrame:NSMakeRect(12, 12, 120, 32)];
    reload.title = [self L:@"重新加载" en:@"Reload"];
    reload.bezelStyle = NSBezelStyleRounded;
    reload.target = self;
    reload.action = @selector(reloadConfig);
    reload.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [bottomBar addSubview:reload];

    NSButton *save = [[NSButton alloc] initWithFrame:NSMakeRect(142, 12, 120, 32)];
    save.title = [self L:@"保存配置" en:@"Save Config"];
    save.bezelStyle = NSBezelStyleRounded;
    save.target = self;
    save.action = @selector(saveConfig);
    save.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [bottomBar addSubview:save];

    NSButton *saveRestart = [[NSButton alloc] initWithFrame:NSMakeRect(272, 12, 200, 32)];
    saveRestart.title = [self L:@"保存并重启 Bridge" en:@"Save + Restart Bridge"];
    saveRestart.bezelStyle = NSBezelStyleRounded;
    saveRestart.target = self;
    saveRestart.action = @selector(saveAndRestart);
    saveRestart.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [bottomBar addSubview:saveRestart];

    self.configHint = [[NSTextField alloc] initWithFrame:NSMakeRect(492, 16, 410, 24)];
    self.configHint.bezeled = NO;
    self.configHint.drawsBackground = NO;
    self.configHint.editable = NO;
    self.configHint.selectable = NO;
    self.configHint.textColor = [NSColor secondaryLabelColor];
    self.configHint.stringValue = [self L:@"配置存储: App 内部" en:@"Config storage: App internal"];
    self.configHint.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [bottomBar addSubview:self.configHint];

    item.view = root;
    [self.tabView addTabViewItem:item];
    [self reloadConfig];
}

- (void)buildPermissionTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"perm"];
    item.label = [self L:@"授权" en:@"Permissions"];

    NSView *root = [self makeTabContainer];

    NSButton *openScreen = [[NSButton alloc] initWithFrame:NSMakeRect(20, 590, 220, 30)];
    openScreen.title = [self L:@"打开屏幕录制设置" en:@"Open Screen Recording Settings"];
    openScreen.bezelStyle = NSBezelStyleRounded;
    openScreen.target = self;
    openScreen.action = @selector(openScreenRecordingSettings);
    openScreen.autoresizingMask = NSViewMinYMargin;
    [root addSubview:openScreen];

    NSButton *requestScreen = [[NSButton alloc] initWithFrame:NSMakeRect(250, 590, 220, 30)];
    requestScreen.title = [self L:@"请求屏幕录制授权" en:@"Request Screen Recording Access"];
    requestScreen.bezelStyle = NSBezelStyleRounded;
    requestScreen.target = self;
    requestScreen.action = @selector(requestScreenRecordingAccess);
    requestScreen.autoresizingMask = NSViewMinYMargin;
    [root addSubview:requestScreen];

    NSButton *openAccessibility = [[NSButton alloc] initWithFrame:NSMakeRect(480, 590, 220, 30)];
    openAccessibility.title = [self L:@"打开辅助功能设置" en:@"Open Accessibility Settings"];
    openAccessibility.bezelStyle = NSBezelStyleRounded;
    openAccessibility.target = self;
    openAccessibility.action = @selector(openAccessibilitySettings);
    openAccessibility.autoresizingMask = NSViewMinYMargin;
    [root addSubview:openAccessibility];

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 540, 300, 28)];
    title.stringValue = [self L:@"权限开关（当前 Mac 状态）" en:@"Permission switches (current Mac status)"];
    title.bezeled = NO;
    title.drawsBackground = NO;
    title.editable = NO;
    title.selectable = NO;
    title.font = [NSFont boldSystemFontOfSize:16];
    title.autoresizingMask = NSViewMinYMargin;
    [root addSubview:title];

    NSArray<NSDictionary<NSString *, id> *> *rows = @[
        @{@"name": [self L:@"屏幕录制" en:@"Screen Recording"], @"tag": @1, @"action": @"openScreenRecordingSettings"},
        @{@"name": [self L:@"辅助功能" en:@"Accessibility"], @"tag": @2, @"action": @"openAccessibilitySettings"},
        @{@"name": [self L:@"麦克风" en:@"Microphone"], @"tag": @3, @"action": @"openMicrophoneSettings"},
        @{@"name": [self L:@"摄像头" en:@"Camera"], @"tag": @4, @"action": @"openCameraSettings"}
    ];

    CGFloat y = 490;
    for (NSDictionary<NSString *, id> *row in rows) {
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(40, y + 6, 140, 24)];
        label.stringValue = row[@"name"];
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;
        [root addSubview:label];

        NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(190, y + 2, 60, 32)];
        sw.tag = [row[@"tag"] integerValue];
        sw.target = self;
        sw.action = @selector(permissionSwitchChanged:);
        [root addSubview:sw];

        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(280, y + 2, 200, 30)];
        btn.title = [self L:@"去设置" en:@"Open Settings"];
        btn.bezelStyle = NSBezelStyleRounded;
        btn.target = self;
        btn.action = NSSelectorFromString(row[@"action"]);
        [root addSubview:btn];

        if ([row[@"tag"] integerValue] == 1) self.screenSwitch = sw;
        if ([row[@"tag"] integerValue] == 2) self.axSwitch = sw;
        if ([row[@"tag"] integerValue] == 3) self.micSwitch = sw;
        if ([row[@"tag"] integerValue] == 4) self.camSwitch = sw;

        y -= 58;
    }

    self.permHint = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 80, 880, 140)];
    self.permHint.bezeled = NO;
    self.permHint.drawsBackground = NO;
    self.permHint.editable = NO;
    self.permHint.selectable = NO;
    self.permHint.lineBreakMode = NSLineBreakByWordWrapping;
    self.permHint.usesSingleLineMode = NO;
    self.permHint.stringValue = [self L:@"说明:\n1. 打开授权页会自动检测当前权限状态。\n2. 点击开关会尝试触发授权请求；如果系统不允许直接弹框，会跳转到系统设置。\n3. 某些权限(如完全磁盘访问、自动化控制)无法通过公开 API 准确读取。"
                                  en:@"Notes:\n1. Permission tab auto-detects current status.\n2. Toggling switch attempts permission request; if popup is unavailable, it opens System Settings.\n3. Some permissions (e.g. Full Disk Access, Automation) cannot be accurately read via public APIs."];
    self.permHint.autoresizingMask = NSViewWidthSizable;
    [root addSubview:self.permHint];

    item.view = root;
    [self.tabView addTabViewItem:item];
    [self refreshPermissions];
}

- (NSString *)readTailFromFile:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) return @"";
    NSUInteger len = data.length;
    NSUInteger start = (len > maxBytes) ? (len - maxBytes) : 0;
    NSData *slice = [data subdataWithRange:NSMakeRange(start, len - start)];
    NSString *txt = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    return txt ?: @"";
}

- (void)clearFileAtPath:(NSString *)path {
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToFile:path atomically:YES];
}

- (void)buildLogsTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"logs"];
    item.label = [self L:@"日志" en:@"Logs"];

    NSView *root = [self makeTabContainer];

    NSButton *refresh = [[NSButton alloc] initWithFrame:NSMakeRect(20, 595, 120, 30)];
    refresh.title = [self L:@"刷新日志" en:@"Reload Logs"];
    refresh.bezelStyle = NSBezelStyleRounded;
    refresh.target = self;
    refresh.action = @selector(reloadRuntimeLog);
    refresh.autoresizingMask = NSViewMinYMargin;
    [root addSubview:refresh];

    NSButton *clear = [[NSButton alloc] initWithFrame:NSMakeRect(150, 595, 120, 30)];
    clear.title = [self L:@"清空日志" en:@"Clear Logs"];
    clear.bezelStyle = NSBezelStyleRounded;
    clear.target = self;
    clear.action = @selector(clearRuntimeLog);
    clear.autoresizingMask = NSViewMinYMargin;
    [root addSubview:clear];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 920, 560)];
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.runtimeLogTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 900, 540)];
    self.runtimeLogTextView.editable = NO;
    self.runtimeLogTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    scroll.documentView = self.runtimeLogTextView;
    [root addSubview:scroll];

    item.view = root;
    [self.tabView addTabViewItem:item];
    [self reloadRuntimeLog];
}

- (void)buildChatHistoryTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"chat"];
    item.label = [self L:@"对话" en:@"Chat"];

    NSView *root = [self makeTabContainer];

    NSButton *refresh = [[NSButton alloc] initWithFrame:NSMakeRect(20, 595, 140, 30)];
    refresh.title = [self L:@"刷新对话记录" en:@"Reload Chat"];
    refresh.bezelStyle = NSBezelStyleRounded;
    refresh.target = self;
    refresh.action = @selector(reloadChatHistory);
    refresh.autoresizingMask = NSViewMinYMargin;
    [root addSubview:refresh];

    NSButton *clear = [[NSButton alloc] initWithFrame:NSMakeRect(170, 595, 140, 30)];
    clear.title = [self L:@"清空对话记录" en:@"Clear Chat"];
    clear.bezelStyle = NSBezelStyleRounded;
    clear.target = self;
    clear.action = @selector(clearChatHistory);
    clear.autoresizingMask = NSViewMinYMargin;
    [root addSubview:clear];

    self.chatHistoryScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 920, 560)];
    self.chatHistoryScrollView.hasVerticalScroller = YES;
    self.chatHistoryScrollView.hasHorizontalScroller = NO;
    self.chatHistoryScrollView.borderType = NSNoBorder;
    self.chatHistoryScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 540)];
    doc.autoresizingMask = NSViewWidthSizable;
    self.chatHistoryStackView = [[NSStackView alloc] initWithFrame:doc.bounds];
    self.chatHistoryStackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.chatHistoryStackView.alignment = NSLayoutAttributeLeading;
    self.chatHistoryStackView.spacing = 4;
    self.chatHistoryStackView.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    self.chatHistoryStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:self.chatHistoryStackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.chatHistoryStackView.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [self.chatHistoryStackView.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [self.chatHistoryStackView.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [self.chatHistoryStackView.bottomAnchor constraintLessThanOrEqualToAnchor:doc.bottomAnchor],
        [self.chatHistoryStackView.widthAnchor constraintEqualToAnchor:doc.widthAnchor]
    ]];

    self.chatHistoryScrollView.documentView = doc;
    [root addSubview:self.chatHistoryScrollView];

    item.view = root;
    [self.tabView addTabViewItem:item];
    [self reloadChatHistory];
}

- (NSString *)runCommandCapture:(NSString *)bin args:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:bin];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        return [NSString stringWithFormat:@"failed to run %@: %@", bin, err.localizedDescription ?: @"unknown"];
    }
    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSDictionary<NSString *, id> *)runCommandDetailed:(NSString *)bin args:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:bin];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSString *errText = launchError.localizedDescription ?: @"unknown launch error";
        return @{@"ok": @NO, @"output": @"", @"error": errText, @"status": @(-1)};
    }

    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    txt = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL ok = (task.terminationStatus == 0);
    return @{@"ok": @(ok), @"output": txt ?: @"", @"error": ok ? @"" : (txt ?: @""), @"status": @(task.terminationStatus)};
}

- (NSString *)firstLineOfText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"";
    NSRange r = [trimmed rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
    if (r.location == NSNotFound) return trimmed;
    return [trimmed substringToIndex:r.location];
}

- (NSString *)resolveExecutablePath:(NSString *)configuredName env:(NSDictionary<NSString *, NSString *> *)env {
    NSString *name = [[configuredName ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if (name.length == 0) return @"";

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"./"] || [name hasPrefix:@"../"]) {
        return [name stringByStandardizingPath];
    }

    NSString *pathVar = env[@"PATH"];
    if (pathVar.length == 0) {
        pathVar = [[[NSProcessInfo processInfo] environment][@"PATH"] copy];
    }
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    for (NSString *dir in [pathVar componentsSeparatedByString:@":"]) {
        if (dir.length == 0) continue;
        [dirs addObject:dir];
    }
    NSArray<NSString *> *fallbackDirs = @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/opt/local/bin", @"/usr/bin", @"/bin"];
    for (NSString *dir in fallbackDirs) {
        if (![dirs containsObject:dir]) {
            [dirs addObject:dir];
        }
    }
    for (NSString *dir in dirs) {
        NSString *candidate = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return @"";
}

- (void)buildCodexCheckTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"codex-check"];
    item.label = [self L:@"依赖检查" en:@"Dependency Check"];

    NSView *root = [self makeTabContainer];

    NSButton *run = [[NSButton alloc] initWithFrame:NSMakeRect(20, 595, 180, 30)];
    run.title = [self L:@"执行依赖检查" en:@"Run Dependency Check"];
    run.bezelStyle = NSBezelStyleRounded;
    run.target = self;
    run.action = @selector(runCodexCheck);
    run.autoresizingMask = NSViewMinYMargin;
    [root addSubview:run];

    NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 220, 920, 360)];
    tableScroll.hasVerticalScroller = YES;
    tableScroll.borderType = NSBezelBorder;
    tableScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 920, 360)];
    table.delegate = self;
    table.dataSource = self;
    table.usesAlternatingRowBackgroundColors = YES;
    table.rowHeight = 28;

    NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    c1.title = [self L:@"依赖项" en:@"Item"];
    c1.width = 190;
    [table addTableColumn:c1];

    NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"status"];
    c2.title = [self L:@"状态" en:@"Status"];
    c2.width = 100;
    [table addTableColumn:c2];

    NSTableColumn *c3 = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    c3.title = [self L:@"路径" en:@"Path"];
    c3.width = 300;
    [table addTableColumn:c3];

    NSTableColumn *c4 = [[NSTableColumn alloc] initWithIdentifier:@"detail"];
    c4.title = [self L:@"说明" en:@"Detail"];
    c4.width = 310;
    [table addTableColumn:c4];

    self.dependencyTableView = table;
    tableScroll.documentView = table;
    [root addSubview:tableScroll];

    NSTextField *failureLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 190, 160, 24)];
    failureLabel.stringValue = [self L:@"失败原因" en:@"Failure Reasons"];
    failureLabel.bezeled = NO;
    failureLabel.drawsBackground = NO;
    failureLabel.editable = NO;
    failureLabel.selectable = NO;
    failureLabel.font = [NSFont boldSystemFontOfSize:14];
    failureLabel.autoresizingMask = NSViewMinYMargin;
    [root addSubview:failureLabel];

    NSScrollView *failureScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 920, 160)];
    failureScroll.hasVerticalScroller = YES;
    failureScroll.borderType = NSBezelBorder;
    failureScroll.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.dependencyFailureTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 900, 140)];
    self.dependencyFailureTextView.editable = NO;
    self.dependencyFailureTextView.font = [NSFont systemFontOfSize:12];
    failureScroll.documentView = self.dependencyFailureTextView;
    [root addSubview:failureScroll];

    item.view = root;
    [self.tabView addTabViewItem:item];
    [self runCodexCheck];
}

- (NSScrollView *)makeEditorBlockWithTitle:(NSString *)title textViewOut:(NSTextView * __strong *)out frame:(NSRect)frame {
    NSView *container = [[NSView alloc] initWithFrame:frame];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, frame.size.height - 24, frame.size.width, 20)];
    label.stringValue = title;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [container addSubview:label];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - 30)];
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - 30)];
    tv.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tv.minSize = NSMakeSize(0, 0);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    scroll.documentView = tv;
    [container addSubview:scroll];

    *out = tv;

    NSScrollView *holder = [[NSScrollView alloc] initWithFrame:frame];
    holder.documentView = container;
    holder.drawsBackground = NO;
    holder.hasVerticalScroller = NO;
    holder.hasHorizontalScroller = NO;
    holder.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return holder;
}

- (void)buildMemoryAgentsTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"memory"];
    item.label = [self L:@"记忆&Agent" en:@"Memory & Agent"];

    NSView *root = [self makeTabContainer];

    NSButton *reload = [[NSButton alloc] initWithFrame:NSMakeRect(20, 595, 120, 30)];
    reload.title = [self L:@"重新加载" en:@"Reload"];
    reload.bezelStyle = NSBezelStyleRounded;
    reload.target = self;
    reload.action = @selector(reloadMemoryAgents);
    reload.autoresizingMask = NSViewMinYMargin;
    [root addSubview:reload];

    NSButton *saveMem = [[NSButton alloc] initWithFrame:NSMakeRect(150, 595, 140, 30)];
    saveMem.title = [self L:@"保存 MEMORY.md" en:@"Save MEMORY.md"];
    saveMem.bezelStyle = NSBezelStyleRounded;
    saveMem.target = self;
    saveMem.action = @selector(saveMemoryFile);
    saveMem.autoresizingMask = NSViewMinYMargin;
    [root addSubview:saveMem];

    NSButton *saveAgents = [[NSButton alloc] initWithFrame:NSMakeRect(300, 595, 160, 30)];
    saveAgents.title = [self L:@"保存 AGENTS.md" en:@"Save AGENTS.md"];
    saveAgents.bezelStyle = NSBezelStyleRounded;
    saveAgents.target = self;
    saveAgents.action = @selector(saveAgentsFile);
    saveAgents.autoresizingMask = NSViewMinYMargin;
    [root addSubview:saveAgents];

    self.memoryAppendField = [[NSTextField alloc] initWithFrame:NSMakeRect(470, 595, 320, 28)];
    self.memoryAppendField.placeholderString = [self L:@"快速追加记忆项" en:@"Quick append memory item"];
    self.memoryAppendField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [root addSubview:self.memoryAppendField];

    NSButton *append = [[NSButton alloc] initWithFrame:NSMakeRect(800, 595, 140, 30)];
    append.title = [self L:@"追加记忆" en:@"Append Memory"];
    append.bezelStyle = NSBezelStyleRounded;
    append.target = self;
    append.action = @selector(appendMemoryItemFromUI);
    append.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:append];

    NSScrollView *memoryBlock = [self makeEditorBlockWithTitle:@"MEMORY.md" textViewOut:&_memoryTextView frame:NSMakeRect(0, 0, 450, 560)];
    NSScrollView *agentsBlock = [self makeEditorBlockWithTitle:@"AGENTS.md" textViewOut:&_agentsTextView frame:NSMakeRect(0, 0, 450, 560)];

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(20, 20, 920, 560)];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [split addSubview:memoryBlock];
    [split addSubview:agentsBlock];
    [split adjustSubviews];
    [root addSubview:split];

    item.view = root;
    [self.tabView addTabViewItem:item];
    [self reloadMemoryAgents];
}

- (NSString *)readTextFile:(NSString *)path {
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return txt ?: @"";
}

- (BOOL)writeTextFile:(NSString *)path content:(NSString *)content {
    NSError *err = nil;
    BOOL ok = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (!ok && err) {
        [self showError:err.localizedDescription];
    }
    return ok;
}

- (void)reloadConfig {
    NSDictionary<NSString *, NSString *> *resolved = [self.bridge resolvedEnvironment];
    for (NSString *key in self.configFields) {
        self.configFields[key].stringValue = resolved[key] ?: @"";
    }
    self.configHint.stringValue = [self L:@"配置存储: App 内部 (NSUserDefaults)" en:@"Config storage: App internal (NSUserDefaults)"];
}

- (void)saveConfig {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    NSArray<NSString *> *ordered = @[@"TELEGRAM_BOT_TOKEN", @"TELEGRAM_ALLOWED_USER_ID", @"AGENT_PROVIDER", @"AGENT_BIN", @"AGENT_ARGS", @"AGENT_MODEL", @"AGENT_SUPPORTS_IMAGE", @"WHISPER_PYTHON_BIN", @"FASTER_WHISPER_MODEL", @"FASTER_WHISPER_LANGUAGE", @"FASTER_WHISPER_COMPUTE_TYPE", @"CODEX_WORKDIR", @"CODEX_TIMEOUT_SEC", @"MAX_REPLY_CHARS", @"CODEX_SANDBOX", @"CODEX_MODEL", @"TMPDIR", @"IMAGE_DIR", @"CHAT_LOG_FILE", @"SESSION_STORE_FILE", @"MEMORY_FILE"];
    for (NSString *key in ordered) {
        NSString *val = [self.configFields[key].stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (val.length > 0) {
            out[key] = val;
        }
    }
    [self.bridge saveStoredConfig:out];
    self.configHint.stringValue = [self L:@"已保存到 App 内部配置" en:@"Saved to app internal config"];
}

- (void)saveAndRestart {
    [self saveConfig];
    NSError *err = [self.bridge restart];
    if (err) {
        self.configHint.stringValue = [self L:@"保存成功，但重启失败" en:@"Saved, but restart failed"];
        [self showError:err.localizedDescription];
        [self refresh];
        return;
    }
    [self reloadConfig];
    [self runCodexCheck];
    self.configHint.stringValue = [self L:@"已保存并重启成功" en:@"Saved and restarted successfully"];
    [self refresh];
}

- (void)reloadRuntimeLog {
    self.runtimeLogTextView.string = [self readTailFromFile:self.bridge.logPath maxBytes:300000];
}

- (void)clearRuntimeLog {
    [self clearFileAtPath:self.bridge.logPath];
    self.runtimeLogTextView.string = @"";
}

- (void)reloadChatHistory {
    NSString *path = [self.bridge resolvedEnvironment][@"CHAT_LOG_FILE"];
    NSString *raw = [self readTailFromFile:path maxBytes:300000];
    [self ensureChatAvatarsLoaded];
    [self renderChatHistoryFromJSONL:raw];
}

- (void)clearChatHistory {
    NSString *path = [self.bridge resolvedEnvironment][@"CHAT_LOG_FILE"];
    [self clearFileAtPath:path];
    [self clearTempImages];
    [self clearChatHistoryRows];
}

- (NSString *)chatTimeFromRFC3339:(NSString *)ts {
    NSString *raw = [ts stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return @"--:--";
    static NSDateFormatter *inFmt = nil;
    static NSDateFormatter *outFmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inFmt = [[NSDateFormatter alloc] init];
        inFmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        inFmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssXXXXX";
        outFmt = [[NSDateFormatter alloc] init];
        outFmt.dateFormat = @"HH:mm";
    });
    NSDate *d = [inFmt dateFromString:raw];
    if (!d) return raw;
    return [outFmt stringFromDate:d] ?: raw;
}

- (void)clearChatHistoryRows {
    NSArray<NSView *> *rows = [self.chatHistoryStackView.arrangedSubviews copy];
    for (NSView *v in rows) {
        [self.chatHistoryStackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)clearTempImages {
    NSString *inboxDir = [self.bridge resolvedEnvironment][@"IMAGE_DIR"];
    if (inboxDir.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *exts = @[@"jpg", @"jpeg", @"png", @"webp", @"gif", @"heic", @"bmp", @"tif", @"tiff"];
    NSSet<NSString *> *allowed = [NSSet setWithArray:exts];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:inboxDir error:nil];
    for (NSString *name in items) {
        NSString *path = [inboxDir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
            NSString *ext = [[name pathExtension] lowercaseString];
            if ([allowed containsObject:ext]) {
                [fm removeItemAtPath:path error:nil];
            }
        }
    }
}

- (NSImage *)defaultAvatarWithColor:(NSColor *)color {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(28, 28)];
    [img lockFocus];
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 28, 28)];
    [color setFill];
    [circle fill];
    [img unlockFocus];
    return img;
}

- (NSImage *)fetchTelegramAvatarWithToken:(NSString *)token userID:(NSString *)userID {
    if (token.length == 0 || userID.length == 0) return nil;
    NSString *urlStr = [NSString stringWithFormat:@"https://api.telegram.org/bot%@/getUserProfilePhotos?user_id=%@&limit=1", token, userID];
    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlStr]];
    if (!data) return nil;
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *photos = obj[@"result"][@"photos"];
    if (![photos isKindOfClass:[NSArray class]] || photos.count == 0) return nil;
    NSArray *sizes = photos.firstObject;
    if (![sizes isKindOfClass:[NSArray class]] || sizes.count == 0) return nil;
    NSString *fileID = [[sizes lastObject][@"file_id"] description];
    if (fileID.length == 0) return nil;

    NSString *getFileURL = [NSString stringWithFormat:@"https://api.telegram.org/bot%@/getFile?file_id=%@", token, fileID];
    NSData *fData = [NSData dataWithContentsOfURL:[NSURL URLWithString:getFileURL]];
    if (!fData) return nil;
    NSDictionary *fObj = [NSJSONSerialization JSONObjectWithData:fData options:0 error:nil];
    NSString *filePath = [fObj[@"result"][@"file_path"] description];
    if (filePath.length == 0) return nil;

    NSString *downURL = [NSString stringWithFormat:@"https://api.telegram.org/file/bot%@/%@", token, filePath];
    NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:downURL]];
    if (!imgData) return nil;
    NSImage *img = [[NSImage alloc] initWithData:imgData];
    return img;
}

- (NSString *)fetchBotUserIDWithToken:(NSString *)token {
    if (token.length == 0) return @"";
    NSString *urlStr = [NSString stringWithFormat:@"https://api.telegram.org/bot%@/getMe", token];
    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlStr]];
    if (!data) return @"";
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSNumber *uid = obj[@"result"][@"id"];
    return uid ? uid.stringValue : @"";
}

- (void)ensureChatAvatarsLoaded {
    if (self.chatUserAvatar && self.chatBotAvatar) return;
    NSDictionary<NSString *, NSString *> *env = [self.bridge resolvedEnvironment];
    NSString *token = [env[@"TELEGRAM_BOT_TOKEN"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *userID = [env[@"TELEGRAM_ALLOWED_USER_ID"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *botID = [self fetchBotUserIDWithToken:token];

    NSImage *u = [self fetchTelegramAvatarWithToken:token userID:userID];
    NSImage *b = [self fetchTelegramAvatarWithToken:token userID:botID];
    self.chatUserAvatar = u ?: [self defaultAvatarWithColor:[NSColor systemBlueColor]];
    self.chatBotAvatar = b ?: [self defaultAvatarWithColor:[NSColor systemGreenColor]];
}

- (NSView *)chatRowWithTime:(NSString *)timeText message:(NSString *)message mediaPath:(NSString *)mediaPath isUser:(BOOL)isUser contentWidth:(CGFloat)contentWidth {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 860, 66)];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat edgeInset = MAX(8.0, MIN(14.0, contentWidth * 0.012));
    CGFloat oppositeInset = MAX(56.0, MIN(180.0, contentWidth * 0.18));
    CGFloat bubbleMaxWidth = MAX(160.0, contentWidth - oppositeInset - 44.0);
    NSImage *mediaImage = nil;
    NSString *mediaPathTrim = [mediaPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (mediaPathTrim.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:mediaPathTrim]) {
        mediaImage = [[NSImage alloc] initWithContentsOfFile:mediaPathTrim];
    }

    NSDictionary *measureAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:13]};
    CGFloat textMaxWidth = MAX(40.0, bubbleMaxWidth - 16.0);
    CGRect measureRect = [(message ?: @"") boundingRectWithSize:CGSizeMake(textMaxWidth, CGFLOAT_MAX)
                                                        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                     attributes:measureAttrs];
    CGFloat textWidth = (message.length > 0) ? MAX(36.0, ceil(measureRect.size.width)) : 0.0;
    CGFloat textHeight = (message.length > 0) ? MAX(18.0, ceil(measureRect.size.height)) : 0.0;
    CGFloat imageHeight = 0.0;
    CGFloat imageWidth = 0.0;
    if (mediaImage) {
        NSSize src = mediaImage.size;
        if (src.width > 1 && src.height > 1) {
            imageWidth = MIN(bubbleMaxWidth - 18.0, 320.0);
            imageHeight = imageWidth * (src.height / src.width);
            if (imageHeight > 220.0) {
                imageHeight = 220.0;
                imageWidth = imageHeight * (src.width / src.height);
            }
        }
    }
    CGFloat bubbleHeight = 16.0;
    if (imageHeight > 0) {
        bubbleHeight += imageHeight;
    }
    if (textHeight > 0) {
        if (imageHeight > 0) bubbleHeight += 6.0;
        bubbleHeight += textHeight;
    } else if (imageHeight <= 0) {
        bubbleHeight += 18.0;
    }
    CGFloat bubbleWidthValue = MAX(96.0, textWidth + 16.0);
    if (imageWidth > 0) {
        bubbleWidthValue = MAX(bubbleWidthValue, imageWidth + 16.0);
    }
    if (bubbleWidthValue > bubbleMaxWidth) {
        bubbleWidthValue = bubbleMaxWidth;
    }
    CGFloat rowHeight = MAX(44.0, bubbleHeight + 24.0);
    [row.heightAnchor constraintEqualToConstant:rowHeight].active = YES;

    NSImageView *avatar = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 28, 28)];
    avatar.image = isUser ? self.chatUserAvatar : self.chatBotAvatar;
    avatar.wantsLayer = YES;
    avatar.layer.cornerRadius = 14;
    avatar.layer.masksToBounds = YES;
    avatar.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *timeLabel = [NSTextField labelWithString:timeText ?: @"--:--"];
    timeLabel.font = [NSFont systemFontOfSize:11];
    timeLabel.textColor = [NSColor secondaryLabelColor];
    timeLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *bubble = [[NSView alloc] initWithFrame:NSZeroRect];
    bubble.wantsLayer = YES;
    bubble.layer.cornerRadius = 10;
    bubble.layer.masksToBounds = YES;
    bubble.layer.backgroundColor = (isUser ? [NSColor colorWithRed:0.13 green:0.36 blue:0.82 alpha:1.0] : [NSColor colorWithWhite:0.18 alpha:1.0]).CGColor;
    bubble.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:bubble.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor]
    ]];

    NSView *lastView = nil;
    if (mediaImage && imageHeight > 0) {
        NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        imageView.image = mediaImage;
        imageView.imageScaling = NSImageScaleAxesIndependently;
        imageView.wantsLayer = YES;
        imageView.layer.cornerRadius = 8.0;
        imageView.layer.masksToBounds = YES;
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:imageView];
        [NSLayoutConstraint activateConstraints:@[
            [imageView.topAnchor constraintEqualToAnchor:content.topAnchor constant:8],
            [imageView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
            [imageView.widthAnchor constraintEqualToConstant:imageWidth],
            [imageView.heightAnchor constraintEqualToConstant:imageHeight]
        ]];
        lastView = imageView;
    }

    if (message.length > 0) {
        NSTextField *bubbleText = [[NSTextField alloc] initWithFrame:NSZeroRect];
        bubbleText.bezeled = NO;
        bubbleText.drawsBackground = NO;
        bubbleText.editable = NO;
        bubbleText.selectable = YES;
        bubbleText.usesSingleLineMode = NO;
        bubbleText.lineBreakMode = NSLineBreakByWordWrapping;
        bubbleText.maximumNumberOfLines = 0;
        bubbleText.stringValue = message ?: @"";
        bubbleText.font = [NSFont systemFontOfSize:13];
        bubbleText.textColor = [NSColor whiteColor];
        bubbleText.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:bubbleText];
        NSLayoutYAxisAnchor *textTop = lastView ? lastView.bottomAnchor : content.topAnchor;
        CGFloat textTopPadding = lastView ? 6.0 : 8.0;
        [NSLayoutConstraint activateConstraints:@[
            [bubbleText.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
            [bubbleText.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
            [bubbleText.topAnchor constraintEqualToAnchor:textTop constant:textTopPadding],
            [bubbleText.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-8]
        ]];
    } else if (lastView) {
        [lastView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-8].active = YES;
    }

    [row addSubview:avatar];
    [row addSubview:timeLabel];
    [row addSubview:bubble];

    NSLayoutConstraint *bubbleWidth = [bubble.widthAnchor constraintEqualToConstant:bubbleWidthValue];
    NSLayoutConstraint *bubbleHeightC = [bubble.heightAnchor constraintEqualToConstant:bubbleHeight];
    if (isUser) {
        [NSLayoutConstraint activateConstraints:@[
            [avatar.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-edgeInset],
            [avatar.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
            [avatar.widthAnchor constraintEqualToConstant:28],
            [avatar.heightAnchor constraintEqualToConstant:28],

            [timeLabel.trailingAnchor constraintEqualToAnchor:avatar.leadingAnchor constant:-8],
            [timeLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:0],

            [bubble.trailingAnchor constraintEqualToAnchor:avatar.leadingAnchor constant:-8],
            [bubble.topAnchor constraintEqualToAnchor:timeLabel.bottomAnchor constant:2],
            bubbleWidth,
            bubbleHeightC,
            [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor constant:oppositeInset]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [avatar.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:edgeInset],
            [avatar.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
            [avatar.widthAnchor constraintEqualToConstant:28],
            [avatar.heightAnchor constraintEqualToConstant:28],

            [timeLabel.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:8],
            [timeLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:0],

            [bubble.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:8],
            [bubble.topAnchor constraintEqualToAnchor:timeLabel.bottomAnchor constant:2],
            bubbleWidth,
            bubbleHeightC,
            [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-oppositeInset]
        ]];
    }
    return row;
}

- (void)renderChatHistoryFromJSONL:(NSString *)raw {
    [self clearChatHistoryRows];
    NSString *trim = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        NSTextField *empty = [NSTextField labelWithString:[self L:@"暂无对话记录" en:@"No chat history yet"]];
        empty.textColor = [NSColor secondaryLabelColor];
        [self.chatHistoryStackView addArrangedSubview:empty];
        return;
    }
    NSArray<NSString *> *lines = [trim componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSView *doc = self.chatHistoryScrollView.documentView;
    if (doc) {
        NSRect frame = doc.frame;
        CGFloat targetWidth = self.chatHistoryScrollView.contentSize.width;
        if (targetWidth < 320.0) targetWidth = 320.0;
        if (fabs(frame.size.width - targetWidth) > 0.5) {
            frame.size.width = targetWidth;
            [doc setFrame:frame];
        }
    }

    CGFloat contentWidth = self.chatHistoryScrollView.contentSize.width - 24.0;
    if (contentWidth < 320.0) contentWidth = 320.0;
    for (NSString *line in lines) {
        NSString *one = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (one.length == 0) continue;
        NSData *data = [one dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) continue;
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSString *timeText = [self chatTimeFromRFC3339:[obj[@"timestamp"] description]];
        NSString *userText = @"";
        id userVal = obj[@"user_text"];
        if ([userVal isKindOfClass:[NSString class]]) {
            userText = [(NSString *)userVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        NSString *botText = @"";
        id botVal = obj[@"bot_text"];
        if ([botVal isKindOfClass:[NSString class]]) {
            botText = [(NSString *)botVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        NSString *tag = @"";
        id tagValForFilter = obj[@"tag"];
        if ([tagValForFilter isKindOfClass:[NSString class]]) {
            tag = [(NSString *)tagValForFilter lowercaseString];
        }
        if ([tag containsString:@"screenshot"] && [botText hasPrefix:@"screenshot sent:"]) {
            botText = @"";
        }
        NSString *mediaPath = @"";
        id pathVal = obj[@"media_path"];
        if ([pathVal isKindOfClass:[NSString class]]) {
            mediaPath = [(NSString *)pathVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        NSString *botMediaPath = @"";
        id botPathVal = obj[@"bot_media_path"];
        if ([botPathVal isKindOfClass:[NSString class]]) {
            botMediaPath = [(NSString *)botPathVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (userText.length == 0) {
            if (botMediaPath.length > 0) {
                // Screenshot-style bot image message: do not auto-generate a user placeholder row.
                userText = @"";
            } else {
            NSString *mediaType = @"";
            id mediaVal = obj[@"media_type"];
            if ([mediaVal isKindOfClass:[NSString class]]) {
                mediaType = [(NSString *)mediaVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
            if (mediaType.length == 0) {
                if ([tag containsString:@"image"]) mediaType = @"图片";
                else if ([tag containsString:@"media"]) mediaType = @"多媒体";
                else if ([tag containsString:@"screenshot"]) mediaType = @"截图";
            }
            if (mediaType.length > 0) {
                userText = [NSString stringWithFormat:@"[%@]", mediaType];
            }
            }
        }
        if (mediaPath.length > 0 && [userText isEqualToString:@"[图片]"]) {
            userText = @"";
        } else if (mediaPath.length > 0 && [userText hasPrefix:@"[图片] "]) {
            userText = [[userText substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (userText.length > 0) {
            NSView *row = [self chatRowWithTime:timeText message:userText mediaPath:mediaPath isUser:YES contentWidth:contentWidth];
            [self.chatHistoryStackView addArrangedSubview:row];
            if (self.chatHistoryScrollView.documentView) {
                [row.widthAnchor constraintEqualToAnchor:self.chatHistoryScrollView.documentView.widthAnchor constant:-24].active = YES;
            } else {
                [row.widthAnchor constraintEqualToAnchor:self.chatHistoryStackView.widthAnchor constant:-24].active = YES;
            }
        } else if (mediaPath.length > 0) {
            NSView *row = [self chatRowWithTime:timeText message:@"" mediaPath:mediaPath isUser:YES contentWidth:contentWidth];
            [self.chatHistoryStackView addArrangedSubview:row];
            if (self.chatHistoryScrollView.documentView) {
                [row.widthAnchor constraintEqualToAnchor:self.chatHistoryScrollView.documentView.widthAnchor constant:-24].active = YES;
            } else {
                [row.widthAnchor constraintEqualToAnchor:self.chatHistoryStackView.widthAnchor constant:-24].active = YES;
            }
        }
        if (botText.length > 0 || botMediaPath.length > 0) {
            NSView *row = [self chatRowWithTime:timeText message:botText mediaPath:botMediaPath isUser:NO contentWidth:contentWidth];
            [self.chatHistoryStackView addArrangedSubview:row];
            if (self.chatHistoryScrollView.documentView) {
                [row.widthAnchor constraintEqualToAnchor:self.chatHistoryScrollView.documentView.widthAnchor constant:-24].active = YES;
            } else {
                [row.widthAnchor constraintEqualToAnchor:self.chatHistoryStackView.widthAnchor constant:-24].active = YES;
            }
        }
    }
    [self.chatHistoryStackView layoutSubtreeIfNeeded];
    if (doc) {
        NSSize fit = [self.chatHistoryStackView fittingSize];
        CGFloat minH = self.chatHistoryScrollView.contentSize.height + 1.0;
        CGFloat targetH = MAX(minH, fit.height + 24.0);
        NSRect f = doc.frame;
        if (fabs(f.size.height - targetH) > 0.5) {
            f.size.height = targetH;
            [doc setFrame:f];
        }
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object != self.controlWindow) return;
    if ([self.tabView.selectedTabViewItem.identifier isKindOfClass:[NSString class]] &&
        [self.tabView.selectedTabViewItem.identifier isEqualToString:@"chat"]) {
        [self reloadChatHistory];
    }
}

- (void)runCodexCheck {
    NSDictionary<NSString *, NSString *> *env = [self.bridge resolvedEnvironment];
    NSMutableArray<NSString *> *failureReasons = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];

    NSString *provider = [[env[@"AGENT_PROVIDER"] ?: @"codex" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (provider.length == 0) provider = @"codex";
    [rows addObject:@{
        @"item": @"当前 Agent 提供方",
        @"status": @"● 信息",
        @"path": @"-",
        @"detail": provider
    }];

    NSString *configuredAgent = [env[@"AGENT_BIN"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (configuredAgent.length == 0) configuredAgent = [env[@"CODEX_BIN"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (configuredAgent.length == 0) configuredAgent = @"/Applications/Codex.app/Contents/Resources/codex";
    NSString *resolvedAgent = [self resolveExecutablePath:configuredAgent env:env];
    BOOL agentPathOK = (resolvedAgent.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:resolvedAgent]);
    if (!agentPathOK) {
        [failureReasons addObject:[NSString stringWithFormat:@"AGENT_BIN 不可执行: %@。请在配置中设置有效路径。", configuredAgent]];
    }
    [rows addObject:@{
        @"item": @"Agent 可执行",
        @"status": agentPathOK ? @"● 通过" : @"● 失败",
        @"path": agentPathOK ? resolvedAgent : configuredAgent,
        @"detail": agentPathOK ? @"已找到可执行文件" : @"未找到或无执行权限"
    }];

    BOOL supportsImage = YES;
    NSString *supportsImageRaw = [[env[@"AGENT_SUPPORTS_IMAGE"] ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (supportsImageRaw.length > 0) {
        supportsImage = ([supportsImageRaw isEqualToString:@"1"] ||
                         [supportsImageRaw isEqualToString:@"true"] ||
                         [supportsImageRaw isEqualToString:@"yes"] ||
                         [supportsImageRaw isEqualToString:@"on"]);
    } else {
        supportsImage = [provider isEqualToString:@"codex"];
    }
    [rows addObject:@{
        @"item": @"图片输入能力",
        @"status": @"● 信息",
        @"path": @"-",
        @"detail": supportsImage ? @"支持（可直接传图）" : @"不支持（将自动回退为文本描述）"
    }];

    NSString *agentVersionLine = @"";
    BOOL agentVersionOK = NO;
    if (agentPathOK) {
        NSDictionary<NSString *, id> *ret = [self runCommandDetailed:resolvedAgent args:@[@"--version"]];
        agentVersionOK = [ret[@"ok"] boolValue];
        agentVersionLine = [self firstLineOfText:ret[@"output"]];
        if (agentVersionLine.length == 0) {
            NSString *errLine = [self firstLineOfText:ret[@"error"]];
            agentVersionLine = (errLine.length > 0) ? errLine : @"(empty)";
        }
        if (!agentVersionOK && [provider isEqualToString:@"codex"]) {
            NSString *reason = [self firstLineOfText:ret[@"error"]];
            if (reason.length == 0) reason = @"unknown error";
            [failureReasons addObject:[NSString stringWithFormat:@"Agent 版本检查失败: %@", reason]];
        }
    }
    [rows addObject:@{
        @"item": @"Agent 版本命令",
        @"status": agentVersionOK ? @"● 通过" : @"● 信息",
        @"path": agentPathOK ? resolvedAgent : @"-",
        @"detail": agentPathOK ? agentVersionLine : @"依赖缺失，跳过"
    }];

    if ([provider isEqualToString:@"codex"]) {
        NSString *defaultCodex = @"/Applications/Codex.app/Contents/Resources/codex";
        BOOL defaultCodexOK = [[NSFileManager defaultManager] isExecutableFileAtPath:defaultCodex];
        if (!defaultCodexOK) {
            [failureReasons addObject:[NSString stringWithFormat:@"系统默认 Codex 不存在或不可执行: %@", defaultCodex]];
        }
        [rows addObject:@{
            @"item": @"系统默认 Codex",
            @"status": defaultCodexOK ? @"● 通过" : @"● 失败",
            @"path": defaultCodex,
            @"detail": defaultCodexOK ? @"可执行" : @"未安装或权限不足"
        }];

        BOOL codexVersionMatch = NO;
        NSString *matchDetail = @"依赖缺失，跳过";
        if (agentVersionOK && defaultCodexOK) {
            NSDictionary<NSString *, id> *ret = [self runCommandDetailed:defaultCodex args:@[@"--version"]];
            BOOL machineVersionOK = [ret[@"ok"] boolValue];
            NSString *machineLine = [self firstLineOfText:ret[@"output"]];
            codexVersionMatch = machineVersionOK && [machineLine isEqualToString:agentVersionLine];
            if (machineLine.length == 0) machineLine = @"(empty)";
            matchDetail = codexVersionMatch ? [NSString stringWithFormat:@"一致: %@", agentVersionLine] : [NSString stringWithFormat:@"配置=%@, 系统=%@", agentVersionLine, machineLine];
            if (!codexVersionMatch) {
                if (!machineVersionOK) {
                    NSString *reason = [self firstLineOfText:ret[@"error"]];
                    if (reason.length == 0) reason = @"unknown error";
                    [failureReasons addObject:[NSString stringWithFormat:@"系统默认 Codex 版本检查失败: %@", reason]];
                } else {
                    [failureReasons addObject:@"Codex 版本不一致：建议将 AGENT_BIN 指向系统默认 Codex，或确认版本预期。"];
                }
            }
        }
        [rows addObject:@{
            @"item": @"Codex 版本一致",
            @"status": codexVersionMatch ? @"● 通过" : @"● 失败",
            @"path": @"-",
            @"detail": matchDetail
        }];
    } else {
        NSString *agentArgs = [env[@"AGENT_ARGS"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [rows addObject:@{
            @"item": @"通用 Agent 参数",
            @"status": @"● 信息",
            @"path": @"AGENT_ARGS",
            @"detail": (agentArgs.length > 0) ? agentArgs : @"(empty)"
        }];
        if (agentArgs.length == 0) {
            [failureReasons addObject:@"当前 provider 为 generic，建议配置 AGENT_ARGS（可包含 {{prompt}} / {{session_id}} / {{image_paths}}）。"];
        }
    }

    NSString *pythonConfigured = [env[@"WHISPER_PYTHON_BIN"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (pythonConfigured.length == 0) pythonConfigured = @"python3";
    NSString *resolvedPython = [self resolveExecutablePath:pythonConfigured env:env];
    BOOL pythonOK = (resolvedPython.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:resolvedPython]);
    if (!pythonOK) {
        [failureReasons addObject:[NSString stringWithFormat:@"WHISPER_PYTHON_BIN 不可执行: %@。请安装 Python3 或填写绝对路径。", pythonConfigured]];
    }
    [rows addObject:@{
        @"item": @"Python 可执行",
        @"status": pythonOK ? @"● 通过" : @"● 失败",
        @"path": pythonOK ? resolvedPython : pythonConfigured,
        @"detail": pythonOK ? @"用于语音转写（全部 provider 通用）" : @"未找到 python"
    }];

    NSString *scriptConfigured = [env[@"WHISPER_SCRIPT"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (scriptConfigured.length == 0) {
        scriptConfigured = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:@"transcribe_faster_whisper.py"];
    }
    NSString *scriptPath = scriptConfigured;
    if (![scriptPath hasPrefix:@"/"]) {
        scriptPath = [self.bridge.repoRoot stringByAppendingPathComponent:scriptPath];
    }
    BOOL scriptOK = [[NSFileManager defaultManager] fileExistsAtPath:scriptPath];
    if (!scriptOK) {
        [failureReasons addObject:[NSString stringWithFormat:@"WHISPER_SCRIPT 不存在: %@。请重新打包 App 或设置脚本路径。", scriptConfigured]];
    }
    [rows addObject:@{
        @"item": @"Whisper 脚本",
        @"status": scriptOK ? @"● 通过" : @"● 失败",
        @"path": scriptPath,
        @"detail": scriptOK ? @"transcribe_faster_whisper.py" : @"脚本缺失"
    }];

    BOOL whisperImportOK = NO;
    NSString *whisperImportDetail = @"依赖缺失，跳过";
    if (pythonOK) {
        NSDictionary<NSString *, id> *ret = [self runCommandDetailed:resolvedPython args:@[@"-c", @"import faster_whisper; print('ok')"]];
        whisperImportOK = [ret[@"ok"] boolValue];
        whisperImportDetail = whisperImportOK ? @"import faster_whisper 成功" : ([self firstLineOfText:ret[@"error"]] ?: @"import faster_whisper 失败");
        if (!whisperImportOK) {
            [failureReasons addObject:@"Python 缺少 faster-whisper。请执行: python3 -m pip install faster-whisper"];
        }
    }
    [rows addObject:@{
        @"item": @"faster-whisper 模块",
        @"status": whisperImportOK ? @"● 通过" : @"● 失败",
        @"path": pythonOK ? resolvedPython : @"-",
        @"detail": whisperImportDetail
    }];

    self.dependencyRows = rows;
    [self.dependencyTableView reloadData];

    NSMutableString *txt = [NSMutableString string];
    if (failureReasons.count == 0) {
        [txt appendString:@"无。所有依赖检查通过。\n"];
    } else {
        NSInteger idx = 1;
        for (NSString *reason in failureReasons) {
            [txt appendFormat:@"%ld. %@\n", (long)idx, reason];
            idx += 1;
        }
    }
    self.dependencyFailureTextView.string = txt;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.dependencyTableView) {
        return self.dependencyRows.count;
    }
    return 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView != self.dependencyTableView || row < 0 || row >= (NSInteger)self.dependencyRows.count) {
        return nil;
    }
    NSDictionary<NSString *, NSString *> *item = self.dependencyRows[(NSUInteger)row];
    NSString *columnID = tableColumn.identifier;

    NSTextField *cell = [tableView makeViewWithIdentifier:columnID owner:self];
    if (!cell) {
        cell = [[NSTextField alloc] initWithFrame:NSZeroRect];
        cell.identifier = columnID;
        cell.bezeled = NO;
        cell.drawsBackground = NO;
        cell.editable = NO;
        cell.selectable = YES;
        cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
        cell.font = [NSFont systemFontOfSize:12];
    }

    NSString *value = item[columnID] ?: @"";
    cell.stringValue = value;
    if ([columnID isEqualToString:@"status"]) {
        if ([value containsString:@"通过"]) {
            cell.textColor = [NSColor systemGreenColor];
        } else if ([value containsString:@"信息"]) {
            cell.textColor = [NSColor secondaryLabelColor];
        } else {
            cell.textColor = [NSColor systemRedColor];
        }
    } else {
        cell.textColor = [NSColor textColor];
    }
    return cell;
}

- (void)refreshPermissions {
    BOOL screen = [self isScreenRecordingGranted];
    NSDictionary *axOpts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @NO};
    BOOL ax = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)axOpts);
    AVAuthorizationStatus mic = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    AVAuthorizationStatus cam = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

    self.screenSwitch.state = screen ? NSControlStateValueOn : NSControlStateValueOff;
    self.axSwitch.state = ax ? NSControlStateValueOn : NSControlStateValueOff;
    self.micSwitch.state = (mic == AVAuthorizationStatusAuthorized) ? NSControlStateValueOn : NSControlStateValueOff;
    self.camSwitch.state = (cam == AVAuthorizationStatusAuthorized) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)isScreenRecordingGranted {
    // Pure status check: do not trigger any permission prompt.
    return CGPreflightScreenCaptureAccess();
}

- (BOOL)canCaptureScreenByCommand {
    NSString *tmpDir = [self.bridge resolvedEnvironment][@"TMPDIR"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [tmpDir stringByAppendingPathComponent:@"perm-check.png"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    NSString *bin = @"/usr/sbin/screencapture";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
        bin = @"/usr/bin/screencapture";
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:bin];
    task.arguments = @[@"-x", path];
    NSPipe *pipe = [NSPipe pipe];
    task.standardError = pipe;
    task.standardOutput = pipe;

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        return NO;
    }
    [task waitUntilExit];

    BOOL ok = (task.terminationStatus == 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return ok;
}

- (void)openScreenRecordingSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

- (void)requestScreenRecordingAccess {
    CGRequestScreenCaptureAccess();
    [self refreshPermissions];
}

- (void)openAccessibilitySettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)openMicrophoneSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
}

- (void)openCameraSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"]];
}

- (void)permissionSwitchChanged:(NSSwitch *)sender {
    NSInteger tag = sender.tag;
    if (tag == 1) {
        if (sender.state == NSControlStateValueOn) {
            CGRequestScreenCaptureAccess();
        }
        [self openScreenRecordingSettings];
    } else if (tag == 2) {
        NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        [self openAccessibilitySettings];
    } else if (tag == 3) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(__unused BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshPermissions]; });
        }];
        [self openMicrophoneSettings];
    } else if (tag == 4) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(__unused BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshPermissions]; });
        }];
        [self openCameraSettings];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshPermissions];
    });
}

- (void)reloadMemoryAgents {
    NSString *memoryPath = [self.bridge.dataRoot stringByAppendingPathComponent:@"MEMORY.md"];
    NSString *agentsPath = [self.bridge.dataRoot stringByAppendingPathComponent:@"AGENTS.md"];
    NSString *legacyDefault = @"# AGENTS\n\n## Role\n- Personal assistant on this Mac.\n";
    NSString *repoAgentSingular = [self.bridge.repoRoot stringByAppendingPathComponent:@"AGENT.md"];
    NSString *repoAgentsPlural = [self.bridge.repoRoot stringByAppendingPathComponent:@"AGENTS.md"];
    NSString *seed = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:repoAgentSingular]) {
        seed = [self readTextFile:repoAgentSingular];
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:repoAgentsPlural]) {
        seed = [self readTextFile:repoAgentsPlural];
    }
    if (seed.length == 0) {
        seed = legacyDefault;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:memoryPath]) {
        [self writeTextFile:memoryPath content:@"# MEMORY\n\n## Profile\n- name:\n\n## User Memory Items\n"];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:agentsPath]) {
        [self writeTextFile:agentsPath content:seed];
    } else {
        NSString *current = [self readTextFile:agentsPath];
        NSString *currentTrim = [current stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *legacyTrim = [legacyDefault stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([currentTrim isEqualToString:legacyTrim] && seed.length > 0 && ![seed isEqualToString:legacyDefault]) {
            [self writeTextFile:agentsPath content:seed];
        }
    }
    self.memoryTextView.string = [self readTextFile:memoryPath];
    self.agentsTextView.string = [self readTextFile:agentsPath];
}

- (void)saveMemoryFile {
    [self writeTextFile:[self.bridge.dataRoot stringByAppendingPathComponent:@"MEMORY.md"] content:self.memoryTextView.string ?: @""];
}

- (void)saveAgentsFile {
    [self writeTextFile:[self.bridge.dataRoot stringByAppendingPathComponent:@"AGENTS.md"] content:self.agentsTextView.string ?: @""];
}

- (void)appendMemoryItemFromUI {
    NSString *item = [self.memoryAppendField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (item.length == 0) return;

    NSString *memPath = [self.bridge.dataRoot stringByAppendingPathComponent:@"MEMORY.md"];
    NSMutableString *text = [[self readTextFile:memPath] mutableCopy];
    if (text.length == 0) {
        [text appendString:@"# MEMORY\n\n## User Memory Items\n"];
    }
    if ([text rangeOfString:@"## User Memory Items"].location == NSNotFound) {
        [text appendString:@"\n## User Memory Items\n"];
    }
    [text appendFormat:@"- %@\n", item];
    if ([self writeTextFile:memPath content:text]) {
        self.memoryTextView.string = text;
        self.memoryAppendField.stringValue = @"";
    }
}

- (void)refreshTimer {
    [self refresh];
    if ([self isPermissionTabSelected]) {
        [self refreshPermissions];
    }
}

- (void)refresh {
    BOOL running = [self.bridge isRunning];
    if (running) self.startupFailed = NO;
    [self updateStatusItemIcon:running];
    NSString *statusText = running ? [self L:@"状态: 运行中" en:@"Status: running"] : [self L:@"状态: 已停止" en:@"Status: stopped"];
    NSColor *statusColor = self.startupFailed ? [NSColor systemRedColor] : (running ? [NSColor systemGreenColor] : [NSColor secondaryLabelColor]);
    NSDictionary<NSAttributedStringKey, id> *attrs = @{
        NSForegroundColorAttributeName: statusColor,
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12]
    };
    self.statusLine.attributedTitle = [[NSAttributedString alloc] initWithString:statusText attributes:attrs];
    self.startItem.enabled = !running;
    self.stopItem.enabled = running;
    self.restartItem.enabled = running;
}

- (BOOL)isPermissionTabSelected {
    id ident = self.tabView.selectedTabViewItem.identifier;
    return [ident isKindOfClass:[NSString class]] && [(NSString *)ident isEqualToString:@"perm"];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(nullable NSTabViewItem *)tabViewItem {
    (void)tabView;
    if ([tabViewItem.identifier isKindOfClass:[NSString class]] &&
        [(NSString *)tabViewItem.identifier isEqualToString:@"perm"]) {
        [self refreshPermissions];
    }
}

- (void)showError:(NSString *)text {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"telegent";
    alert.informativeText = text ?: [self L:@"未知错误" en:@"Unknown error"];
    [alert runModal];
}

- (void)startBridge {
    NSError *e = [self.bridge start];
    self.startupFailed = (e != nil);
    if (e) [self showError:e.localizedDescription];
    [self refresh];
}
- (void)stopBridge {
    [self.bridge stop];
    self.startupFailed = NO;
    [self refresh];
}
- (void)restartBridge {
    NSError *e = [self.bridge restart];
    self.startupFailed = (e != nil);
    if (e) [self showError:e.localizedDescription];
    [self refresh];
}
- (void)openControlCenter { [self.controlWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)openRuntimeLog { [self.bridge openLog]; }
- (void)openProjectFolder {
    NSString *workspace = [self.bridge resolvedEnvironment][@"CODEX_WORKDIR"];
    if (workspace.length == 0) workspace = self.bridge.repoRoot;
    if (![workspace hasPrefix:@"/"]) {
        workspace = [self.bridge.repoRoot stringByAppendingPathComponent:workspace];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:workspace]];
}
- (void)quitApp { [NSApp terminate:nil]; }

@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        static AppDelegate *strongDelegate = nil;
        strongDelegate = [[AppDelegate alloc] init];
        app.delegate = strongDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
