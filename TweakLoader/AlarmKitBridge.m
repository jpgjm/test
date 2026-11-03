//
//  AlarmKitBridge.m
//  LiveContainer (TweakLoader)
//
//  ゲストアプリを改変せずに、AlarmKit のボタンからゲスト自身の App Intent を動かす。
//
//  ── 問題 ────────────────────────────────────────────────────────
//
//  AlarmKit は stopIntent / secondaryIntent を「アラームを登録したアプリ」
//  (= LiveContainer) のメタデータから解決する。ゲストが宣言した Intent は
//  そこに無いので、ボタンを押しても何も起きない。
//
//  ── この版でやること (diag2) ────────────────────────────────────
//
//  1. 記録: AlarmKit がゲストのプロセス内で LNAction を保存形式にする瞬間
//     (+[NSKeyedArchiver archivedDataWithRootObject:requiringSecureCoding:error:])
//     をフックし、中身と保存形式のデータをファイルに残す。
//     LCGuestIntent のスタブから作られた本物の LNAction は「型紙」として保存する。
//
//  2. 包み替え: ゲスト自身の Intent だったら、元の LNAction を丸ごと保存形式にして
//     LCGuestIntent (action = "lc.bridge") の LNAction に包んで渡す。
//     LCGuestIntent は LiveContainer のメタデータにあるので解決される。
//
//  3. 実行: LCGuestIntent がゲストを LiveProcess で画面なしで起こすと、
//     このファイルが起動時に「保留中の要求」を見つけ、元の LNAction を
//     LNAppContext でゲストのプロセス内で実行する。終わったら自分で終了する。
//
//  diag2.1: 包み替えは型紙を -[LNAction actionWithParameters:] で複製して
//     引数だけ差し替える。metadata と systemProtocols が型紙と同じになる。
//  diag2.2: LiveProcess で実行するとき intentNotFound になる問題への対策
//     (ゲストのメタデータの付け直しと、AppManager への静的メタデータの強制)。
//  diag2.3: 付け直しの作り方を 3 通りに (diag2.2 では存在確認で弾かれて試されなかった)。
//  diag2.4: 型紙を不要にした。包み替え先の LCGuestIntent は LiveContainer 自身の
//     Metadata.appintents から組み立てる (型紙はあれば予備)。
//
//  記録先 (ゲストのコンテナ): Documents/LCBridge/bridge.log
//  型紙 (LiveContainer の Documents): Documents/LCBridge/template-lcguestintent.archive
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#import "../LiveContainer/utils.h"

static NSString *const LCBGuestIntentID = @"com.kdt.livecontainer.guestIntent";
static NSString *const LCBBridgeAction = @"lc.bridge";
/// 型紙が無いときに使う、LiveContainer 側の型名 (一致は必須ではないことを実測済み)
static NSString *const LCBFallbackMangledName = @"13LiveContainer13LCGuestIntentV";

#pragma mark - 記録

static NSURL *LCBGuestDir(void) {
    NSURL *dir = [[NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:@"Documents/LCBridge" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

/// LiveContainer 自身の Documents/LCBridge。LiveProcess からは書けないことがあるので nil を返しうる。
static NSURL *LCBHostDir(void) {
    const char *home = getenv("LC_HOME_PATH");
    if (!home) return nil;
    NSURL *dir = [[NSURL fileURLWithPath:@(home)] URLByAppendingPathComponent:@"Documents/LCBridge" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return dir;
}

static void LCBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LCBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LCBridge] %@", message);

    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    NSString *line = [NSString stringWithFormat:@"[%@] pid=%d%@ %@\n",
                      [formatter stringFromDate:NSDate.date], getpid(),
                      getenv("LP_HOME_PATH") ? @" (LiveProcess)" : @"", message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    @synchronized (NSFileManager.class) {
        NSURL *url = [LCBGuestDir() URLByAppendingPathComponent:@"bridge.log"];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } else {
            [data writeToURL:url atomically:YES];
        }
    }
}

/// LNAction の metadata / systemProtocols を短く表す (diag2.1)。
/// AlarmKit が作る本物には両方入っている。包み替え後もそろっているかを見る。
static NSString *LCBSummarizeShape(id action) {
    id metadata = nil;
    NSArray *protocols = nil;
    @try { metadata = [action valueForKey:@"metadata"]; } @catch (NSException *e) {}
    @try { protocols = [action valueForKey:@"systemProtocols"]; } @catch (NSException *e) {}
    NSString *metaText = @"なし";
    if (metadata) {
        id metaType = nil;
        @try { metaType = [metadata valueForKey:@"mangledTypeName"]; } @catch (NSException *e) {}
        metaText = [NSString stringWithFormat:@"%@ (%@)", NSStringFromClass([metadata class]), metaType ?: @"?"];
    }
    NSMutableArray *protocolNames = [NSMutableArray array];
    for (id protocol in protocols) {
        id name = nil;
        @try { name = [protocol valueForKey:@"identifier"]; } @catch (NSException *e) {}
        [protocolNames addObject:name ?: NSStringFromClass([protocol class])];
    }
    return [NSString stringWithFormat:@"metadata=%@ systemProtocols=[%@]",
            metaText, [protocolNames componentsJoinedByString:@","]];
}

/// LNAction の中身を 1 行ずつ書き出す。
static void LCBDescribeAction(id action, NSString *label) {
    LCBLog(@"  %@: identifier=%@ mangledTypeName=%@ openAppWhenRun=%@",
           label, [action valueForKey:@"identifier"], [action valueForKey:@"mangledTypeName"],
           [action valueForKey:@"openAppWhenRun"]);
    LCBLog(@"    %@", LCBSummarizeShape(action));
    NSArray *parameters = [action valueForKey:@"parameters"];
    for (id property in parameters) {
        id value = nil;
        @try { value = [property valueForKey:@"value"]; } @catch (NSException *e) {}
        LCBLog(@"    param id=%@ class=%@ value=%@", [property valueForKey:@"identifier"],
               NSStringFromClass([property class]), value);
    }
}

#pragma mark - 包み替え

/// 文字列の LNValue を作る。valueType が渡されれば (型紙のもの) それを使う。
static id LCBMakeValue(NSString *string, id valueType) {
    Class valueClass = NSClassFromString(@"LNValue");
    id type = valueType;
    if (!type) {
        Class typeClass = NSClassFromString(@"LNPrimitiveValueType");
        type = ((id (*)(id, SEL))objc_msgSend)(typeClass, NSSelectorFromString(@"stringValueType"));
    }
    id value = [valueClass alloc];
    return ((id (*)(id, SEL, id, id))objc_msgSend)(value, NSSelectorFromString(@"initWithValue:valueType:"), string, type);
}

static id LCBMakeProperty(NSString *identifier, NSString *string, id valueType) {
    id property = [NSClassFromString(@"LNProperty") alloc];
    return ((id (*)(id, SEL, id, id))objc_msgSend)(property, NSSelectorFromString(@"initWithIdentifier:value:"),
                                                   identifier, LCBMakeValue(string, valueType));
}

static id LCBUnarchive(NSData *data) {
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    if (!unarchiver) {
        LCBLog(@"  復元できません: %@", error);
        return nil;
    }
    unarchiver.requiresSecureCoding = NO;
    id object = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    return object;
}

/// 元の LNAction を LCGuestIntent の LNAction に包む。
///
/// diag2.1: 型紙 (AlarmKit がスタブから作った本物) があれば、型紙を複製して
/// 引数だけ差し替える (`-[LNAction actionWithParameters:]`)。
/// iPadOS 26.6.1 (23G83) の LinkMetadata を逆アセンブルして、このメソッドが
/// identifier / mangledTypeName / openAppWhenRun / explicitAuthenticationPolicy /
/// outputFlags / outputType / systemProtocols / metadata をすべて引き継ぎ、
/// `_initWithIdentifier:...parameters:metadata:` を呼ぶことを確認済み。
/// diag2 の `initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:` では
/// metadata (LNActionMetadata) と systemProtocols (SessionStarting) が空になっていた。
///
/// 型紙が無い・使えないときは diag2 と同じ手作りに戻る (metadata なし)。
static id LCBMakeGuestIntentFromHostMetadata(NSArray *properties);

static id LCBWrap(id original, NSData *archive) {
    NSString *container = NSHomeDirectory().lastPathComponent;
    NSString *bundleFolder = NSBundle.mainBundle.bundlePath.lastPathComponent;
    NSDictionary *payload = @{
        @"v": @1,
        @"bundle": bundleFolder,
        @"container": container,
        @"origin": [original valueForKey:@"identifier"] ?: @"?",
        @"archive": [archive base64EncodedStringWithOptions:0],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *payloadText = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    NSDictionary<NSString *, NSString *> *values = @{ @"handler": @"", @"action": LCBBridgeAction, @"payload": payloadText };

    NSArray<NSString *> *identifiers = @[ @"handler", @"action", @"payload" ];
    NSArray *valueTypes = nil;
    NSString *mangledName = LCBFallbackMangledName;

    // diag2.4: まず LiveContainer 自身のメタデータから組み立てる (型紙は不要)
    {
        NSMutableArray *hostProperties = [NSMutableArray array];
        for (NSString *identifier in identifiers) {
            [hostProperties addObject:LCBMakeProperty(identifier, values[identifier], nil)];
        }
        id hostAction = LCBMakeGuestIntentFromHostMetadata(hostProperties);
        if (hostAction) {
            LCBLog(@"  包み替え: LiveContainer のメタデータから組み立て payload=%lu 文字", (unsigned long)payloadText.length);
            return hostAction;
        }
        LCBLog(@"  LiveContainer のメタデータから組み立てられません。型紙を探します");
    }

    NSURL *hostDir = LCBHostDir();
    NSURL *templateURL = hostDir ? [hostDir URLByAppendingPathComponent:@"template-lcguestintent.archive"] : nil;
    NSData *templateData = templateURL ? [NSData dataWithContentsOfURL:templateURL] : nil;
    if (!templateData) LCBLog(@"  型紙がありません (%@)", templateURL.path ?: @"LC_HOME_PATH なし");
    id template = templateData ? LCBUnarchive(templateData) : nil;
    if (template && ![template isKindOfClass:NSClassFromString(@"LNAction")]) {
        LCBLog(@"  型紙が LNAction ではありません (%@)", NSStringFromClass([template class]));
        template = nil;
    }
    if (template) {
        NSArray *templateParameters = [template valueForKey:@"parameters"];
        if (templateParameters.count == 3) {
            identifiers = [templateParameters valueForKey:@"identifier"];
            mangledName = [template valueForKey:@"mangledTypeName"] ?: mangledName;
            NSMutableArray *types = [NSMutableArray array];
            for (id property in templateParameters) {
                id type = nil;
                @try { type = [[property valueForKey:@"value"] valueForKey:@"valueType"]; } @catch (NSException *e) {}
                [types addObject:type ?: NSNull.null];
            }
            valueTypes = types;
            LCBLog(@"  型紙: %@", LCBSummarizeShape(template));
        } else {
            LCBLog(@"  型紙の引数が %lu 個なので使いません", (unsigned long)templateParameters.count);
            template = nil;
        }
    }

    // 識別子が handler / action / payload ならその名前で、違えば宣言順で値を割り当てる。
    NSArray<NSString *> *order = @[ @"handler", @"action", @"payload" ];
    NSMutableArray *properties = [NSMutableArray array];
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        NSString *identifier = identifiers[i];
        NSString *value = values[identifier] ?: values[order[i]];
        id type = valueTypes[i];
        [properties addObject:LCBMakeProperty(identifier, value, type == NSNull.null ? nil : type)];
    }

    id action = nil;
    NSString *source = nil;
    SEL withParameters = NSSelectorFromString(@"actionWithParameters:");
    if (template && [template respondsToSelector:withParameters]) {
        @try {
            action = ((id (*)(id, SEL, id))objc_msgSend)(template, withParameters, properties);
            source = @"型紙を複製 (actionWithParameters:)";
        } @catch (NSException *e) {
            LCBLog(@"  actionWithParameters: が例外: %@", e);
        }
    } else if (template) {
        LCBLog(@"  LNAction が actionWithParameters: に応答しません (iOS の変更?)");
    }

    if (!action) {
        action = [NSClassFromString(@"LNAction") alloc];
        action = ((id (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
            action, NSSelectorFromString(@"initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:"),
            LCBGuestIntentID, mangledName, NO, properties);
        source = template ? @"手作り (型紙の複製に失敗、metadata なし)" : @"手作り (型紙なし、metadata なし)";
    }

    LCBLog(@"  包み替え: 引数の識別子=%@ 型名=%@ (%@) payload=%lu 文字",
           [identifiers componentsJoinedByString:@","], [action valueForKey:@"mangledTypeName"], source,
           (unsigned long)payloadText.length);
    return action;
}

#pragma mark - フック

static NSData *(*LCBOriginalArchive)(id, SEL, id, BOOL, NSError **);

static NSData *LCBHookArchive(id self, SEL _cmd, id root, BOOL secure, NSError **error) {
    Class actionClass = NSClassFromString(@"LNAction");
    if (!actionClass || ![root isKindOfClass:actionClass]) {
        return LCBOriginalArchive(self, _cmd, root, secure, error);
    }

    // 呼び出し元が AlarmKit のときだけ扱う。
    Dl_info info = {0};
    void *returnAddress = __builtin_return_address(0);
    NSString *caller = (dladdr(returnAddress, &info) && info.dli_fname) ? @(info.dli_fname).lastPathComponent : @"?";
    if (![caller isEqualToString:@"AlarmKit"]) {
        return LCBOriginalArchive(self, _cmd, root, secure, error);
    }

    NSData *original = LCBOriginalArchive(self, _cmd, root, secure, error);
    NSString *identifier = [root valueForKey:@"identifier"];
    LCBLog(@"AlarmKit が LNAction を保存形式にします (%lu バイト)", (unsigned long)original.length);
    LCBDescribeAction(root, @"元");

    NSString *stamp = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970 * 1000];
    [original writeToURL:[LCBGuestDir() URLByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@-%@.archive", stamp, identifier]] atomically:YES];

    if ([identifier isEqualToString:LCBGuestIntentID]) {
        // スタブから作られた本物。型紙として保存し、そのまま渡す。
        NSURL *hostDir = LCBHostDir();
        if (hostDir && [original writeToURL:[hostDir URLByAppendingPathComponent:@"template-lcguestintent.archive"] atomically:YES]) {
            LCBLog(@"  LCGuestIntent のスタブ。型紙として保存しました");
        }
        return original;
    }

    id wrapped = LCBWrap(root, original);
    if (!wrapped) {
        LCBLog(@"  包み替えに失敗。元のまま渡します");
        return original;
    }
    LCBDescribeAction(wrapped, @"包み替え後");
    return LCBOriginalArchive(self, _cmd, wrapped, secure, error);
}

#pragma mark - 実行 (LiveProcess で起こされたとき)

static NSURL *LCBPendingURL(void) {
    return [[NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:@"Library/LCBridge/pending.plist"];
}

static void LCBExitIfHeadless(NSString *reason) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.connectedScenes.count > 0) {
            LCBLog(@"画面が接続されているので終了しません");
            return;
        }
        LCBLog(@"画面なしで起こされたので終了します (%@)", reason);
        exit(0);
    });
}

#pragma mark - diag2.2: ゲストのプロセス内で Intent を見つけさせる
//
// diag2.1 の実測 (2026-11-03): LNAppContext の performAction が
// AppIntents.PerformIntentError.intentNotFound で返った (9 回とも)。
//
// iPadOS 26.6.1 (23G83) の AppIntents を逆アセンブルして分かったこと:
//   - LNAction に metadata が無いと「LNAction did not include metadata」と記録し、
//     AppManager の登録表から identifier → mangledTypeName の順で探す。無ければ intentNotFound。
//   - AppManager の表は、+[LNEntitlementsValidator currentProcessHasApplicationServiceMachLookup]
//     かつ +[LNFeatureFlags isAppMetadataViaXPCEnabled] なら XPC で、
//     そうでなければバンドルの Metadata.appintents から作る。
//   - プロセスの bundle ID は +[LSBundleRecord bundleRecordForCurrentProcess] で取り、
//     拡張なら親アプリに読み替える。LiveProcess.appex → LiveContainer になる。
//   → 子プロセスの AppManager は LiveContainer のメタデータを引いていて、
//     ゲストの型が載っていない、と推定 (未確認)。
//
// 対策 (両方入れて、どちらが効いたかはログで切り分ける):
//   A. 実行前に、ゲスト自身の Metadata.appintents から LNActionMetadata を読み、
//      LNAction に付け直す。
//   B. 保留中の要求があって起こされたときだけ、上の 2 つの判定を NO にし、
//      AppManager にゲストのバンドルから表を作らせる。

static BOOL (*LCBOriginalXPCEnabled)(id, SEL);
static BOOL (*LCBOriginalMachLookup)(id, SEL);
static BOOL LCBForcedXPCEnabled(id self, SEL _cmd) { return NO; }
static BOOL LCBForcedMachLookup(id self, SEL _cmd) { return NO; }

/// B. AppManager に XPC ではなく静的なメタデータを使わせる。
static void LCBForceStaticAppMetadata(void) {
    // LinkServices はまだ読まれていないことがあるので明示的に読む (dyld 共有キャッシュ内)
    void *handle = dlopen("/System/Library/PrivateFrameworks/LinkServices.framework/LinkServices", RTLD_NOW);
    if (!handle) LCBLog(@"  LinkServices を読めません: %s", dlerror());

    struct { NSString *cls; NSString *sel; IMP replacement; BOOL (**original)(id, SEL); } targets[] = {
        { @"LNFeatureFlags", @"isAppMetadataViaXPCEnabled", (IMP)LCBForcedXPCEnabled, &LCBOriginalXPCEnabled },
        { @"LNEntitlementsValidator", @"currentProcessHasApplicationServiceMachLookup", (IMP)LCBForcedMachLookup, &LCBOriginalMachLookup },
    };
    for (size_t i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
        Class cls = NSClassFromString(targets[i].cls);
        SEL sel = NSSelectorFromString(targets[i].sel);
        Method method = cls ? class_getClassMethod(cls, sel) : NULL;
        if (!method) {
            LCBLog(@"  +[%@ %@] がありません (フックしません)", targets[i].cls, targets[i].sel);
            continue;
        }
        BOOL (*original)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(method);
        BOOL before = NO;
        @try { before = original(cls, sel); } @catch (NSException *e) {}
        *targets[i].original = original;
        method_setImplementation(method, targets[i].replacement);
        LCBLog(@"  +[%@ %@]: 元の値=%@ → NO に固定", targets[i].cls, targets[i].sel, before ? @"YES" : @"NO");
    }
}

/// このプロセスが自分を何だと思っているかを記録する。
static void LCBDescribeProcessIdentity(void) {
    NSBundle *main = NSBundle.mainBundle;
    LCBLog(@"  mainBundle: id=%@ path=%@", main.bundleIdentifier, main.bundlePath);
    NSURL *metadataURL = [main.bundleURL URLByAppendingPathComponent:@"Metadata.appintents" isDirectory:YES];
    BOOL hasMetadata = [NSFileManager.defaultManager fileExistsAtPath:metadataURL.path];
    LCBLog(@"  mainBundle の Metadata.appintents: %@", hasMetadata ? @"あり" : @"なし");

    Class recordClass = NSClassFromString(@"LSBundleRecord");
    SEL currentSel = NSSelectorFromString(@"bundleRecordForCurrentProcess");
    if ([recordClass respondsToSelector:currentSel]) {
        id record = nil;
        @try { record = ((id (*)(id, SEL))objc_msgSend)(recordClass, currentSel); } @catch (NSException *e) {}
        id identifier = nil, containing = nil;
        @try { identifier = [record valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}
        if ([record respondsToSelector:NSSelectorFromString(@"containingBundleRecord")]) {
            @try { containing = [[record valueForKey:@"containingBundleRecord"] valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}
        }
        LCBLog(@"  LSBundleRecord (現在のプロセス): class=%@ id=%@ 親=%@",
               record ? NSStringFromClass([record class]) : @"nil", identifier, containing ?: @"(なし)");
    }

    Class validator = NSClassFromString(@"LNEntitlementsValidator");
    SEL bundleSel = NSSelectorFromString(@"bundleIdentifierForCurrentProcess");
    if ([validator respondsToSelector:bundleSel]) {
        id identifier = nil;
        @try { identifier = ((id (*)(id, SEL))objc_msgSend)(validator, bundleSel); } @catch (NSException *e) {}
        LCBLog(@"  +[LNEntitlementsValidator bundleIdentifierForCurrentProcess]=%@", identifier);
    }
}

/// バンドルの Metadata.appintents から、identifier の LNActionMetadata を読む。
/// ゲスト (A の付け直し) と LiveContainer 自身 (diag2.4 の包み替え) の両方で使う。
static id LCBLoadActionMetadata(NSURL *bundleURL, NSString *bundleID, NSString *identifier) {
    NSBundle *main = NSBundle.mainBundle;
    if (!bundleURL || !bundleID) {
        LCBLog(@"  メタデータ: バンドルの URL / ID がありません");
        return nil;
    }

    // -[LNEffectiveBundleIdentifier bundleMetadataForURLs:] と同じ手順:
    //   [[NSBundle alloc] _initUniqueWithURL:] → [[LNBundleMetadata alloc] initWithBundle:usingEffectiveBundleIdentifier:error:]
    // type=0 は型紙 (LiveContainer = アプリ) の LNEffectiveBundleIdentifier と同じ値。
    Class effectiveClass = NSClassFromString(@"LNEffectiveBundleIdentifier");
    Class metadataClass = NSClassFromString(@"LNBundleMetadata");
    SEL effectiveInit = NSSelectorFromString(@"initWithType:bundleIdentifier:url:");
    SEL metadataInit = NSSelectorFromString(@"initWithBundle:usingEffectiveBundleIdentifier:error:");
    if (!effectiveClass || !metadataClass ||
        ![effectiveClass instancesRespondToSelector:effectiveInit] ||
        ![metadataClass instancesRespondToSelector:metadataInit]) {
        LCBLog(@"  メタデータ: LNEffectiveBundleIdentifier / LNBundleMetadata の API がありません");
        return nil;
    }
    id effective = ((id (*)(id, SEL, long long, id, id))objc_msgSend)(
        [effectiveClass alloc], effectiveInit, 0LL, bundleID, bundleURL);

    NSBundle *bundle = nil;
    SEL uniqueInit = NSSelectorFromString(@"_initUniqueWithURL:");
    if ([NSBundle instancesRespondToSelector:uniqueInit]) {
        bundle = ((id (*)(id, SEL, id))objc_msgSend)([NSBundle alloc], uniqueInit, bundleURL);
    }
    if (!bundle) bundle = [NSBundle bundleWithURL:bundleURL] ?: main;

    NSError *error = nil;
    id metadata = nil;
    @try {
        metadata = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(
            [metadataClass alloc], metadataInit, bundle, effective, &error);
    } @catch (NSException *e) {
        LCBLog(@"  メタデータ: 読み込みで例外 %@", e);
    }
    if (!metadata) {
        LCBLog(@"  メタデータ: 読めません error=%@", error);
        return nil;
    }

    id actions = nil;
    @try { actions = [metadata valueForKey:@"actions"]; } @catch (NSException *e) {}
    NSArray *keys = [actions isKindOfClass:NSDictionary.class] ? [actions allKeys] : @[];
    LCBLog(@"  メタデータ: actions %lu 件 [%@]", (unsigned long)keys.count, [keys componentsJoinedByString:@","]);
    id actionMetadata = [actions isKindOfClass:NSDictionary.class] ? actions[identifier] : nil;
    if (!actionMetadata) {
        LCBLog(@"  メタデータ: %@ が actions にありません", identifier);
        return nil;
    }
    id metaType = nil;
    @try { metaType = [actionMetadata valueForKey:@"mangledTypeName"]; } @catch (NSException *e) {}
    LCBLog(@"  メタデータ: %@ を見つけました (%@, mangledTypeName=%@)",
           identifier, NSStringFromClass([actionMetadata class]), metaType);
    return actionMetadata;
}

/// A. ゲスト自身の Metadata.appintents から読む。
static id LCBLoadGuestActionMetadata(NSString *identifier) {
    NSBundle *main = NSBundle.mainBundle;
    return LCBLoadActionMetadata(main.bundleURL, main.bundleIdentifier, identifier);
}

#pragma mark - diag2.4: 型紙なしで LCGuestIntent を組み立てる
//
// これまでは AlarmClock (LCGuestIntent のスタブを持つアプリ) でアラームを保存して
// 「型紙」を作り、包み替えはその複製で作っていた。diag2.4 では LiveContainer 自身の
// Metadata.appintents から LCGuestIntent の LNActionMetadata を読み、それから組み立てる。
// 型紙は不要になる (あれば予備として使う)。

/// LiveContainer.app の場所。ゲストの中では mainBundle がゲストに差し替わっているので、
/// プロセスの実行ファイル (dyld のイメージ 0) から辿る。LiveProcess では
/// LiveContainer.app/PlugIns/LiveProcess.appex/LiveProcess なので 2 つ上がる。
static NSURL *LCBHostAppBundleURL(void) {
    const char *image = _dyld_get_image_name(0);
    if (!image) return nil;
    NSURL *url = [[NSURL fileURLWithPath:@(image)] URLByDeletingLastPathComponent];
    if ([url.pathExtension isEqualToString:@"appex"]) {
        url = [[url URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    }
    return [url.pathExtension isEqualToString:@"app"] ? url : nil;
}

/// LiveContainer の LCGuestIntent の LNActionMetadata (プロセス内で 1 回だけ読む)。
static id LCBHostGuestIntentMetadata(NSString **bundleIDOut) {
    static id cached;
    static NSString *cachedBundleID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *hostURL = LCBHostAppBundleURL();
        NSDictionary *info = hostURL ? [NSDictionary dictionaryWithContentsOfURL:[hostURL URLByAppendingPathComponent:@"Info.plist"]] : nil;
        NSString *bundleID = info[@"CFBundleIdentifier"];
        LCBLog(@"  LiveContainer 本体: %@ (id=%@)", hostURL.path ?: @"見つかりません", bundleID);
        if (hostURL && bundleID) {
            cached = LCBLoadActionMetadata(hostURL, bundleID, LCBGuestIntentID);
            cachedBundleID = bundleID;
        }
    });
    if (bundleIDOut) *bundleIDOut = cachedBundleID;
    return cached;
}

/// LNAction の init 系メソッドを列挙して記録する (diag2.3 の診断)。
static void LCBDescribeActionInitializers(Class actionClass) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(actionClass, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name containsString:@"nit"] || [name hasPrefix:@"actionWith"] || [name containsString:@"etadata"]) {
            [names addObject:name];
        }
    }
    free(methods);
    LCBLog(@"  LNAction (%@) のメソッド %u 個のうち関係するもの: %@",
           NSStringFromClass(actionClass), count, [names componentsJoinedByString:@" | "]);
}

/// 元の LNAction に metadata を付けた複製を作る。
///
/// diag2.2 の実測: `instancesRespondToSelector:` が `_initWithIdentifier:…metadata:` に NO を返し、
/// 付け直しが一度も試されなかった (23G83 の LinkMetadata にはこのメソッドがある)。
/// diag2.3 では次の順に試し、どれで作れたかを記録する。
///   1. `_initWithIdentifier:…:metadata:` を class_getInstanceMethod の IMP で直接呼ぶ
///   2. 複製 (`copy`) に KVC で `metadata` を入れる (ivar `_metadata`)
///   3. `initWithMetadata:mangledTypeName:parameters:` (systemProtocols は metadata 由来になる)
static id LCBActionWithMetadata(id action, id metadata) {
    Class actionClass = NSClassFromString(@"LNAction");
    Class runtimeClass = [action class];
    if (runtimeClass != actionClass) {
        LCBLog(@"  復元した LNAction の実クラスは %@", NSStringFromClass(runtimeClass));
    }

    // 1. 9 引数の内部 init を IMP で直接呼ぶ
    SEL fullInit = NSSelectorFromString(@"_initWithIdentifier:mangledTypeName:openAppWhenRun:explicitAuthenticationPolicy:outputFlags:outputType:systemProtocols:parameters:metadata:");
    Method fullMethod = class_getInstanceMethod(actionClass, fullInit);
    LCBLog(@"  付け直し 1: class_getInstanceMethod=%@ instancesRespondToSelector=%@",
           fullMethod ? @"あり" : @"なし", [actionClass instancesRespondToSelector:fullInit] ? @"YES" : @"NO");
    if (fullMethod) {
        @try {
            typedef id (*InitFunction)(id, SEL, id, id, BOOL, id, id, id, id, id, id);
            InitFunction function = (InitFunction)method_getImplementation(fullMethod);
            id result = function([actionClass alloc], fullInit,
                                 [action valueForKey:@"identifier"],
                                 [action valueForKey:@"mangledTypeName"],
                                 [[action valueForKey:@"openAppWhenRun"] boolValue],
                                 [action valueForKey:@"explicitAuthenticationPolicy"],
                                 [action valueForKey:@"outputFlags"],
                                 [action valueForKey:@"outputType"],
                                 [action valueForKey:@"systemProtocols"],
                                 [action valueForKey:@"parameters"],
                                 metadata);
            if (result && [result valueForKey:@"metadata"]) {
                LCBLog(@"  付け直し 1 で作れました");
                return result;
            }
            LCBLog(@"  付け直し 1: 結果に metadata がありません");
        } @catch (NSException *e) {
            LCBLog(@"  付け直し 1 で例外: %@", e);
        }
    } else {
        LCBDescribeActionInitializers(actionClass);
    }

    // 2. 複製に KVC で入れる
    @try {
        id copy = [action copy];
        [copy setValue:metadata forKey:@"metadata"];
        if ([copy valueForKey:@"metadata"]) {
            LCBLog(@"  付け直し 2 (KVC) で作れました");
            return copy;
        }
        LCBLog(@"  付け直し 2: KVC 後も metadata がありません");
    } @catch (NSException *e) {
        LCBLog(@"  付け直し 2 で例外: %@", e);
    }

    // 3. metadata から作る init
    SEL metaInit = NSSelectorFromString(@"initWithMetadata:mangledTypeName:parameters:");
    Method metaMethod = class_getInstanceMethod(actionClass, metaInit);
    if (metaMethod) {
        @try {
            typedef id (*MetaInitFunction)(id, SEL, id, id, id);
            id result = ((MetaInitFunction)method_getImplementation(metaMethod))(
                [actionClass alloc], metaInit, metadata,
                [action valueForKey:@"mangledTypeName"], [action valueForKey:@"parameters"]);
            if (result) {
                LCBLog(@"  付け直し 3 (initWithMetadata:mangledTypeName:parameters:) で作れました");
                return result;
            }
        } @catch (NSException *e) {
            LCBLog(@"  付け直し 3 で例外: %@", e);
        }
    } else {
        LCBLog(@"  付け直し 3: initWithMetadata:mangledTypeName:parameters: がありません");
    }
    return nil;
}

/// LiveContainer のメタデータから LCGuestIntent の LNAction を組み立てる (diag2.4)。
/// properties は handler / action / payload の LNProperty。
static id LCBMakeGuestIntentFromHostMetadata(NSArray *properties) {
    NSString *bundleID = nil;
    id metadata = LCBHostGuestIntentMetadata(&bundleID);
    if (!metadata) return nil;
    Class actionClass = NSClassFromString(@"LNAction");

    // 1. initWithMetadata:bundleIdentifier:parameters: (metadata から型名・systemProtocols を決める)
    SEL init1 = NSSelectorFromString(@"initWithMetadata:bundleIdentifier:parameters:");
    Method m1 = class_getInstanceMethod(actionClass, init1);
    if (m1) {
        @try {
            id action = ((id (*)(id, SEL, id, id, id))method_getImplementation(m1))(
                [actionClass alloc], init1, metadata, bundleID, properties);
            NSArray *protocols = [action valueForKey:@"systemProtocols"];
            if (action && [action valueForKey:@"metadata"] && protocols.count > 0) {
                LCBLog(@"  組み立て: initWithMetadata:bundleIdentifier:parameters:");
                return action;
            }
            LCBLog(@"  組み立て 1: %@ (足りないので次へ)", action ? LCBSummarizeShape(action) : @"nil");
        } @catch (NSException *e) {
            LCBLog(@"  組み立て 1 で例外: %@", e);
        }
    } else {
        LCBLog(@"  組み立て 1: initWithMetadata:bundleIdentifier:parameters: がありません");
    }

    // 2. 9 引数の内部 init に、metadata の型名・systemProtocols を渡す
    SEL init2 = NSSelectorFromString(@"_initWithIdentifier:mangledTypeName:openAppWhenRun:explicitAuthenticationPolicy:outputFlags:outputType:systemProtocols:parameters:metadata:");
    Method m2 = class_getInstanceMethod(actionClass, init2);
    if (m2) {
        @try {
            id mangled = [metadata valueForKey:@"mangledTypeName"] ?: LCBFallbackMangledName;
            id protocols = nil;
            @try { protocols = [metadata valueForKey:@"systemProtocols"]; } @catch (NSException *e) {}
            typedef id (*InitFunction)(id, SEL, id, id, BOOL, id, id, id, id, id, id);
            id action = ((InitFunction)method_getImplementation(m2))(
                [actionClass alloc], init2, LCBGuestIntentID, mangled, NO, nil, nil, nil,
                protocols ?: @[], properties, metadata);
            if (action) {
                LCBLog(@"  組み立て: _initWithIdentifier:…:metadata: (systemProtocols=%@)",
                       [protocols isKindOfClass:NSArray.class] ? (id)@([protocols count]) : (id)@"不明");
                return action;
            }
        } @catch (NSException *e) {
            LCBLog(@"  組み立て 2 で例外: %@", e);
        }
    } else {
        LCBLog(@"  組み立て 2: _initWithIdentifier:…:metadata: がありません");
    }
    return nil;
}

/// LNAppContext で 1 回実行する。completion は main キューで呼ぶ。
static void LCBPerform(id action, NSString *label, void (^completion)(id result, NSError *error)) {
    Class contextClass = NSClassFromString(@"LNAppContext");
    Class optionsClass = NSClassFromString(@"LNActionExecutorOptions");
    if (!contextClass || !optionsClass) {
        LCBLog(@"LNAppContext / LNActionExecutorOptions がありません");
        completion(nil, nil);
        return;
    }

    // 本家 SideStoreSupport/PrivateIntentRunner.m と同じ設定。
    id options = [optionsClass new];
    @try {
        [options setValue:@"LCBridge" forKey:@"clientLabel"];
        [options setValue:@2 forKey:@"kind"];
        [options setValue:@NO forKey:@"donateToTranscript"];
    } @catch (NSException *e) {
        LCBLog(@"オプションの設定に失敗: %@", e);
    }

    id context = [contextClass new];
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
    audit_token_t token = {0};
    NSDate *startedAt = NSDate.date;
    LCBLog(@"実行 [%@]", label);

    // auditToken は 32 バイトの struct。arm64 では参照渡しになるのでポインタで渡す (本家と同じ)。
    typedef void (*PerformFunction)(id, SEL, id, id, id, id, audit_token_t *, void (^)(id, NSError *));
    ((PerformFunction)objc_msgSend)(
        context, NSSelectorFromString(@"performAction:options:reportingProgress:delegate:auditToken:completionHandler:"),
        action, options, progress, nil, &token, ^(id result, NSError *error) {
            LCBLog(@"実行完了 [%@] (%.0f ms) result=%@ error=%@",
                   label, -startedAt.timeIntervalSinceNow * 1000, result, error);
            if (error.userInfo[NSUnderlyingErrorKey]) {
                LCBLog(@"  下位のエラー: %@", error.userInfo[NSUnderlyingErrorKey]);
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
        });
}

static void LCBRunPending(void) {
    NSURL *url = LCBPendingURL();
    NSDictionary *pending = [NSDictionary dictionaryWithContentsOfURL:url];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    if (!pending) return;

    NSDate *date = pending[@"date"];
    if (![date isKindOfClass:NSDate.class] || -date.timeIntervalSinceNow > 120) {
        LCBLog(@"保留中の要求が古いので実行しません (%@)", date);
        return;
    }

    NSData *archive = [[NSData alloc] initWithBase64EncodedString:pending[@"archive"] ?: @"" options:0];
    id action = archive ? LCBUnarchive(archive) : nil;
    if (!action) {
        LCBLog(@"保留中の要求を復元できません");
        LCBExitIfHeadless(@"復元失敗");
        return;
    }
    LCBLog(@"保留中の要求を実行します");
    LCBDescribeAction(action, @"実行");
    LCBDescribeProcessIdentity();

    // A. ゲスト自身のメタデータを付け直す (元の LNAction に無いときだけ)
    id withMetadata = nil;
    id existingMetadata = nil;
    @try { existingMetadata = [action valueForKey:@"metadata"]; } @catch (NSException *e) {}
    if (!existingMetadata) {
        id actionMetadata = LCBLoadGuestActionMetadata([action valueForKey:@"identifier"]);
        if (actionMetadata) {
            withMetadata = LCBActionWithMetadata(action, actionMetadata);
            if (withMetadata) LCBDescribeAction(withMetadata, @"metadata 付き");
        }
    }

    // 完了が来ない場合の保険
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LCBExitIfHeadless(@"25 秒で完了しない");
    });

    // 1 回目: metadata 付き (作れたとき)。失敗したら 2 回目: 元のまま。
    // どちらにも B (静的メタデータの強制) は効いているので、
    // 「1 回目だけ成功」なら A が、「2 回目も成功」なら B が効いたことになる。
    if (withMetadata) {
        LCBPerform(withMetadata, @"A: metadata 付き", ^(id result, NSError *error) {
            if (!error) {
                LCBExitIfHeadless(@"実行完了");
                return;
            }
            LCBPerform(action, @"元のまま", ^(id result2, NSError *error2) {
                LCBExitIfHeadless(@"実行完了");
            });
        });
    } else {
        LCBPerform(action, @"元のまま", ^(id result, NSError *error) {
            LCBExitIfHeadless(@"実行完了");
        });
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void LCBridgeInit(void) {
    if (!NSUserDefaults.lcGuestAppId) return;

    Method method = class_getClassMethod(NSKeyedArchiver.class, @selector(archivedDataWithRootObject:requiringSecureCoding:error:));
    if (method) {
        LCBOriginalArchive = (NSData *(*)(id, SEL, id, BOOL, NSError **))method_setImplementation(method, (IMP)LCBHookArchive);
    }

    if (getenv("LP_HOME_PATH") && [NSFileManager.defaultManager fileExistsAtPath:LCBPendingURL().path]) {
        LCBLog(@"保留中の要求があります。起動完了を待って実行します");
        // B. AppManager が初期化される前に (ゲストの main より前) 判定を差し替える
        LCBForceStaticAppMetadata();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            LCBRunPending();
        }];
    }
}
