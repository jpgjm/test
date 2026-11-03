//
//  LCGuestIntent.swift
//  LiveContainer
//
//  ゲストアプリのための汎用 App Intent と、その検証用プローブ。
//
//  ── 何のためのファイルか ────────────────────────────────────────
//
//  ゲストが宣言した App Intents はシステムに登録されない。AlarmKit は
//  アラームを登録したアプリ (= LiveContainer) のメタデータからしか
//  stopIntent / secondaryIntent を解決しないため、ゲストのコードを
//  ボタンから動かす手段がない。
//
//  そこで LiveContainer が `LiveActivityIntent` を 1 つだけ静的に宣言し、
//  `persistentIdentifier` を固定する。ゲストは構造の一致するスタブを
//  渡すだけでよい (一致が必要なのは persistentIdentifier だけ)。
//
//  ── この版で検証すること ────────────────────────────────────────
//
//  これまで「背面のアプリからは LiveProcess.appex (NSExtension) を
//  起動できない」と結論していたが、根拠は「completion が nil UUID で
//  返り、理由の通知もない」ことだけだった。
//
//  iPadOS 26.6.1 の ExtensionFoundation を逆アセンブルした結果、
//  `-[EXConcreteExtension _beginExtensionRequest:completion:]` は失敗時に
//  **completion(nil, error)** と 2 引数で呼んでいる。LiveContainer の
//  `FoundationPrivate.h` を含め、これまでのコードは completion を
//  1 引数で宣言していたため、エラーを受け取れていなかった。
//
//  この版は completion を (NSUUID?, NSError?) で受け、エラーを
//  NSUnderlyingError までたどって記録する。呼び出し元・ロック状態・
//  RunningBoard の状態も同時に残し、失敗の原因を切り分ける。
//
//  ── 流れ ────────────────────────────────────────────────────────
//
//    1. 環境を記録 (呼び出し元 / applicationState / ロック状態 / RBS 状態)
//    2. payload の documents からゲストを特定し、LiveProcess.appex で
//       画面を出さずに起動を試みる (成功したらゲスト側が自分で処理する)
//    3. 起動に失敗したら、従来どおり Tweaks で読み込まれた dylib の
//       シンボル (handler) をこのプロセスで呼ぶ。機能は失われない
//
//  同じ処理を通常の AppIntent (`LCGuestProbeIntent`) からも呼べるので、
//  ショートカットから実行して「Intent の種類」による差を比べられる。
//
//  記録先: ファイル > LiveContainer > lc-guest-intent.log
//  (AlarmHandler.dylib の記録と同じファイルに時系列で並ぶ)
//

import AppIntents
import Foundation
import UIKit

// MARK: - AlarmKit などから呼ばれる汎用 Intent

@available(iOS 17.0, *)
struct LCGuestIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "LiveContainer Guest Action"

    static var description = IntentDescription(
        "Runs an action on behalf of a guest app. Guests pass a stub with the same persistent identifier."
    )

    /// ショートカットには出さない。システム API から渡されるためのもの。
    static var isDiscoverable: Bool = false

    /// 前面に出さない。
    static var openAppWhenRun: Bool = false

    /// ゲスト側スタブとの唯一の接点。変更しないこと。
    static var persistentIdentifier: String { "com.kdt.livecontainer.guestIntent" }

    // ゲスト側スタブ (AlarmClock の LCGuestIntentStub.swift) と
    // 名前・型・宣言順を完全に一致させること。

    /// Tweaks で読み込まれた dylib の C シンボル名。
    @Parameter(title: "Handler Symbol")
    var handler: String

    /// ゲストに渡す任意の文字列。LiveContainer は解釈しない。
    @Parameter(title: "Action")
    var action: String

    /// ゲストに渡す任意の文字列。`documents` キーだけはゲストの特定に使う。
    @Parameter(title: "Payload")
    var payload: String

    init() {
        self.handler = ""
        self.action = ""
        self.payload = ""
    }

    init(handler: String, action: String = "", payload: String = "") {
        self.handler = handler
        self.action = action
        self.payload = payload
    }

    func perform() async throws -> some IntentResult {
        let request = LCGuestRequest(handler: handler, action: action, payload: payload)
        request.saveAsLast()
        _ = await LCGuestBridge.run(request, source: "LiveActivityIntent (AlarmKit など)")
        return .result()
    }
}

// MARK: - 比較用の通常 Intent (ショートカットから実行する)

/// `LCGuestIntent` と同じ処理を、通常の AppIntent として実行する。
///
/// LinkServices は `LiveActivityIntent` の実行時だけ専用のアサーション
/// (SessionAssertion) を使う。Intent の種類で LiveProcess の起動可否が
/// 変わるかを比べるために置いている。
///
/// 直前に `LCGuestIntent` が受け取った handler / action / payload を使う。
/// 先に一度アラームの停止ボタンを押しておくこと。
@available(iOS 17.0, *)
struct LCGuestProbeIntent: AppIntent {

    static var title: LocalizedStringResource = "Guest Probe (LiveContainer)"

    static var description = IntentDescription(
        "Diagnostic: replays the last guest action as a regular App Intent and returns the log summary."
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let request = LCGuestRequest.loadLast() else {
            LCGuestTrace.record("[Probe] 直前の要求がありません。先にアラームの停止ボタンを押してください")
            return .result(value: "直前の要求がありません。先にアラームの停止ボタンを押してください。")
        }
        let summary = await LCGuestBridge.run(request, source: "AppIntent (ショートカット)")
        return .result(value: summary)
    }
}

// MARK: - 要求

@available(iOS 17.0, *)
struct LCGuestRequest: Codable {
    var handler: String
    var action: String
    var payload: String

    private static let defaultsKey = "LCGuestIntentLastRequest"

    func saveAsLast() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    static func loadLast() -> LCGuestRequest? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LCGuestRequest.self, from: data)
    }
}

// MARK: - 本体

@available(iOS 17.0, *)
enum LCGuestBridge {

    /// - Returns: 結果の 1 行要約 (ショートカットに返す)
    static func run(_ request: LCGuestRequest, source: String) async -> String {
        LCGuestTrace.record("──── 呼び出し元: \(source)")
        LCGuestTrace.record("  handler=\(request.handler) action=\(request.action)")
        await LCGuestEnvironment.record()

        // 1. LiveProcess での起動を試す
        let spawn = await LCGuestSpawner.spawn(for: request)

        switch spawn {
        case .started(let pid, let exitedAfter):
            let exitText = exitedAfter.map { String(format: "%.1f 秒後に終了", $0) } ?? "待機時間内に終了せず"
            // 【diag2.2】pid=0 は「completion は UUID を返したが新しい子は起動していない」。
            //   先に起動した LiveProcess が動いている間に次の要求を出すと起きる (2026-11-03 実測)。
            //   保留中の要求ファイル (lc.bridge) は上書きされ、次に起動した子が 120 秒以内なら拾う。
            if pid == 0 {
                LCGuestTrace.record("  [結果] 新しい子プロセスは起動されず (pid=0、\(exitText))。先に起動した LiveProcess が動作中の可能性")
                return "起動されず pid=0 \(exitText)"
            }
            LCGuestTrace.record("  [結果] LiveProcess 起動成功 pid=\(pid) (\(exitText))。処理はゲスト側に任せる")
            return "起動成功 pid=\(pid) \(exitText)"

        case .failed(let reason):
            LCGuestTrace.record("  [結果] LiveProcess 起動失敗: \(reason)")
            // 2. 従来の経路で処理する (機能を失わないため)
            let inProcess = callInProcessHandler(request)
            return "起動失敗: \(reason) / プロセス内ハンドラ: \(inProcess)"

        case .skipped(let reason):
            LCGuestTrace.record("  [結果] LiveProcess 起動を省略: \(reason)")
            let inProcess = callInProcessHandler(request)
            return "起動省略: \(reason) / プロセス内ハンドラ: \(inProcess)"
        }
    }

    /// Tweaks で読み込まれた dylib のエントリを `RTLD_DEFAULT` から引いて呼ぶ。
    /// これまでの方式 (v48 以降) と同じ。
    private static func callInProcessHandler(_ request: LCGuestRequest) -> String {
        guard !request.handler.isEmpty else {
            LCGuestTrace.record("  プロセス内ハンドラ: handler が空なので呼びません")
            return "handler なし"
        }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, request.handler) else {
            LCGuestTrace.record("  プロセス内ハンドラ: \(request.handler) が見つかりません (Tweaks の読み込みを確認)")
            return "シンボルなし"
        }
        typealias Entry = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
        let entry = unsafeBitCast(symbol, to: Entry.self)
        let result = request.action.withCString { actionPtr in
            request.payload.withCString { payloadPtr in
                entry(actionPtr, payloadPtr)
            }
        }
        LCGuestTrace.record("  プロセス内ハンドラ: \(request.handler) result=\(result)")
        return "result=\(result)"
    }
}

// MARK: - 環境の記録

@available(iOS 17.0, *)
enum LCGuestEnvironment {

    static func record() async {
        let (state, protectedData) = await MainActor.run { () -> (String, Bool) in
            let app = UIApplication.shared
            let stateText: String
            switch app.applicationState {
            case .active: stateText = "active"
            case .inactive: stateText = "inactive"
            case .background: stateText = "background"
            @unknown default: stateText = "unknown"
            }
            return (stateText, app.isProtectedDataAvailable)
        }
        LCGuestTrace.record("  pid=\(getpid()) applicationState=\(state) "
                            + "ロック=\(protectedData ? "解除中 (保護データ利用可)" : "ロック中 (保護データ利用不可)")")
        LCGuestTrace.record("  RBS状態: \(runningBoardState())")
    }

    /// RunningBoard から見た自分の状態 (アサーション・制限)。
    /// 私的 API なので、応答しない場合は何もしない。
    private static func runningBoardState() -> String {
        guard let handleClass = NSClassFromString("RBSProcessHandle") as AnyObject? else {
            return "(RBSProcessHandle なし)"
        }
        guard let current = LCObjC.get(handleClass, "currentProcess") else {
            return "(currentProcess を取得できません)"
        }
        var parts: [String] = []
        if let state = LCObjC.get(current, "currentState") {
            parts.append(LCObjC.compact(String(describing: state), limit: 900))
        }
        if let limitations = LCObjC.get(current, "activeLimitations") {
            parts.append("limitations=" + LCObjC.compact(String(describing: limitations), limit: 300))
        }
        return parts.isEmpty ? "(取得できません)" : parts.joined(separator: " | ")
    }
}

// MARK: - LiveProcess の起動

/// `NSExtension` の私的 API。
///
/// LiveContainer アプリターゲットは LiveContainerShared をリンクしていない
/// (main.c が dlopen する) ので、ヘッダを使わず @objc プロトコルで呼ぶ。
///
/// 【重要】completion は (NSUUID?, NSError?) の 2 引数。
///   ExtensionFoundation は失敗時に completion(nil, error) と呼ぶ。
///   1 引数で宣言するとエラーが捨てられる (これまでの原因不明の正体)。
@objc private protocol LCNSExtensionShim {
    @objc var preferredLanguages: [String] { get set }
    @objc(beginExtensionRequestWithInputItems:completion:)
    func lcBegin(items: [Any], completion: ((NSUUID?, NSError?) -> Void)?)
    @objc(pidForRequestIdentifier:)
    func lcPid(for identifier: NSUUID) -> Int32
    @objc(setRequestCancellationBlock:)
    func lcSetCancellation(_ block: ((NSUUID?, NSError?) -> Void)?)
    @objc(setRequestInterruptionBlock:)
    func lcSetInterruption(_ block: ((NSUUID?) -> Void)?)
    @objc(_kill:)
    func lcKill(_ signal: Int32)
}

/// `+[NSExtension extensionWithIdentifier:error:]` をエラー付きで呼ぶため。
@objc private protocol LCNSExtensionFactoryShim {
    @objc(extensionWithIdentifier:error:)
    func lcExtension(identifier: String, error: NSErrorPointer) -> AnyObject?
}

@available(iOS 17.0, *)
enum LCGuestSpawnResult {
    /// 起動できた。`exitedAfter` は子プロセスが終了するまでの秒数 (待機時間内に終われば)。
    case started(pid: Int32, exitedAfter: Double?)
    case failed(String)
    case skipped(String)
}

@available(iOS 17.0, *)
enum LCGuestSpawner {

    /// 起動した NSExtension を保持する。解放されるとリクエストごと取り消される。
    private static var held: [AnyObject] = []
    private static let heldLock = NSLock()

    /// security-scoped bookmark (本家 AppSceneViewController.m と同じ値)
    private static let bookmarkOptions = URL.BookmarkCreationOptions(rawValue: 1 << 11)

    /// completion を待つ秒数。
    private static let beginTimeout: Double = 8
    /// 起動成功後、子プロセスの終了 (interruption) を待つ秒数。
    /// LiveActivityIntent の実行時間には上限があるので長くしない。
    private static let exitWaitTimeout: Double = 15

    static func spawn(for request: LCGuestRequest) async -> LCGuestSpawnResult {

        // --- 1. ゲストを特定する --------------------------------------
        //
        // 【diag2】action == "lc.bridge" は TweakLoader (AlarmKitBridge.m) が
        //   ゲスト自身の Intent を包み替えたもの。payload にゲストの場所と
        //   元の LNAction (保存形式) が入っている。元の LNAction はゲストの
        //   コンテナに「保留中の要求」として置き、起こしたゲストに実行させる。
        let target: LCGuestTarget
        if request.action == LCGuestBridgeRequest.action {
            guard let bridge = LCGuestBridgeRequest(payload: request.payload) else {
                return .skipped("lc.bridge の payload を読めません")
            }
            LCGuestTrace.record("  包み替えられた Intent: \(bridge.origin) (保存形式 \(bridge.archiveBase64.count) 文字)")
            guard let bridgeTarget = bridge.writePending() else {
                return .failed("保留中の要求を書き込めません")
            }
            target = bridgeTarget
        } else {
            guard let located = LCGuestLocator.locate(payload: request.payload) else {
                return .skipped("payload からゲストを特定できません")
            }
            target = located
        }
        LCGuestTrace.record("  ゲスト: \(target.bundleFolder) コンテナ: \(target.container)")

        // --- 2. LiveProcess.appex を用意する ---------------------------
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let liveProcessBundle = Bundle(url: pluginsURL.appendingPathComponent("LiveProcess.appex")),
              let liveProcessID = liveProcessBundle.bundleIdentifier else {
            return .skipped("LiveProcess.appex がありません (インストール時に拡張が削除された可能性)")
        }

        guard let extensionClass = NSClassFromString("NSExtension") else {
            return .failed("NSExtension クラスがありません")
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: LCNSExtensionFactoryShim.self)
        var createError: NSError?
        guard let extObject = factory.lcExtension(identifier: liveProcessID, error: &createError) else {
            LCGuestErrorDump.record(createError, label: "extensionWithIdentifier のエラー")
            return .failed("NSExtension を生成できません (\(liveProcessID))")
        }
        heldLock.lock(); held.append(extObject); heldLock.unlock()

        let ext = unsafeBitCast(extObject, to: LCNSExtensionShim.self)
        ext.preferredLanguages = []

        // --- 3. userInfo (本家 AppSceneViewController.m と同じキー) ------
        let bookmarks = makeBookmarks(target)
        var userInfo: [String: Any] = [
            "selected": target.bundleFolder,
            "selectedContainer": target.container,
            "bookmarks": bookmarks,
            "lcHomePath": NSHomeDirectory(),
        ]
        if let scheme = LCGuestLocator.hostURLScheme() {
            userInfo["hostUrlScheme"] = scheme
        }
        let item = NSExtensionItem()
        item.userInfo = userInfo
        LCGuestTrace.record("  起動要求: \(liveProcessID) scheme=\(userInfo["hostUrlScheme"] ?? "(なし)") bookmarks=\(bookmarks.count)")

        // --- 4. 起動する -----------------------------------------------
        let outcome = LCGuestSpawnOutcome()
        ext.lcSetCancellation { _, error in outcome.markCancelled(error) }
        ext.lcSetInterruption { _ in outcome.markInterrupted() }

        let startedAt = Date()
        ext.lcBegin(items: [item]) { uuid, error in
            outcome.markCompleted(uuid: uuid, error: error)
        }

        await waitUntil(timeout: beginTimeout) { outcome.completed || outcome.cancelled }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        guard let uuid = outcome.uuid else {
            // 失敗。エラーをすべて記録する。
            if outcome.completed {
                LCGuestTrace.record("  completion: UUID=nil (\(elapsedMs) ms)")
            } else {
                LCGuestTrace.record("  completion が \(Int(beginTimeout)) 秒以内に返りません")
            }
            LCGuestErrorDump.record(outcome.completionError, label: "completion のエラー")
            // cancellation が遅れて届くことがあるので少しだけ待つ
            await waitUntil(timeout: 2) { outcome.cancelled }
            if outcome.cancelled {
                LCGuestErrorDump.record(outcome.cancellationError, label: "cancellation のエラー")
            }
            ext.lcKill(9)
            release(extObject)
            let code = outcome.completionError.map { "\($0.domain) code=\($0.code)" } ?? "エラーなし"
            return .failed("UUID=nil [\(code)]")
        }

        let pid = ext.lcPid(for: uuid)
        LCGuestTrace.record("  completion: 起動しました pid=\(pid) (\(elapsedMs) ms)")

        // --- 5. 子プロセスの終了を待つ (ゲストは処理後に exit する) -------
        await waitUntil(timeout: exitWaitTimeout) { outcome.interrupted || outcome.cancelled }
        if outcome.cancelled {
            LCGuestErrorDump.record(outcome.cancellationError, label: "起動後の cancellation")
        }
        let exitedAfter: Double? = (outcome.interrupted || outcome.cancelled)
            ? Date().timeIntervalSince(startedAt) : nil
        if exitedAfter == nil {
            LCGuestTrace.record("  子プロセスは \(Int(exitWaitTimeout)) 秒以内に終了しませんでした (保持を解放します)")
        }
        release(extObject)
        return .started(pid: pid, exitedAfter: exitedAfter)
    }

    private static func makeBookmarks(_ target: LCGuestTarget) -> [Data] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let candidates: [(String, URL)] = [
            ("アプリ", target.appURL),
            ("コンテナ", documents.appendingPathComponent("Data/Application/\(target.container)", isDirectory: true)),
            ("Tweaks", documents.appendingPathComponent("Tweaks", isDirectory: true)),
            // AlarmKit のカスタム音源はホストの Library/Sounds から読まれる。
            // ゲストがここを書き換えられるように渡す。
            ("Library/Sounds", home.appendingPathComponent("Library/Sounds", isDirectory: true)),
        ]
        var result: [Data] = []
        for (label, url) in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else {
                LCGuestTrace.record("  bookmark 省略: \(label) (存在しません)")
                continue
            }
            // nil を渡すと LiveProcess 側が配列に nil を入れて落ちるので必ず除く
            guard let data = try? url.bookmarkData(options: bookmarkOptions,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
                LCGuestTrace.record("  bookmark 失敗: \(label)")
                continue
            }
            result.append(data)
        }
        return result
    }

    private static func release(_ object: AnyObject) {
        heldLock.lock()
        held.removeAll { $0 === object }
        heldLock.unlock()
    }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// completion / cancellation / interruption はどれが先に来るか分からないので参照型で受ける。
private final class LCGuestSpawnOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _completed = false
    private var _uuid: NSUUID?
    private var _completionError: NSError?
    private var _cancelled = false
    private var _cancellationError: NSError?
    private var _interrupted = false

    func markCompleted(uuid: NSUUID?, error: NSError?) {
        lock.lock(); _completed = true; _uuid = uuid; _completionError = error; lock.unlock()
    }
    func markCancelled(_ error: NSError?) {
        lock.lock(); _cancelled = true; _cancellationError = error; lock.unlock()
    }
    func markInterrupted() {
        lock.lock(); _interrupted = true; lock.unlock()
    }

    var completed: Bool { lock.lock(); defer { lock.unlock() }; return _completed }
    var uuid: NSUUID? { lock.lock(); defer { lock.unlock() }; return _uuid }
    var completionError: NSError? { lock.lock(); defer { lock.unlock() }; return _completionError }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var cancellationError: NSError? { lock.lock(); defer { lock.unlock() }; return _cancellationError }
    var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return _interrupted }
}

// MARK: - 包み替えられた要求 (diag2)

/// TweakLoader の AlarmKitBridge.m が作る payload。
///
///     { "v": 1, "bundle": "<Documents/Applications のフォルダ名>",
///       "container": "<コンテナ UUID>", "origin": "<元の Intent の識別子>",
///       "archive": "<元の LNAction を NSKeyedArchiver で保存して base64 にしたもの>" }
struct LCGuestBridgeRequest {
    static let action = "lc.bridge"

    let bundleFolder: String
    let container: String
    let origin: String
    let archiveBase64: String

    init?(payload: String) {
        guard let data = payload.data(using: .utf8),
              let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bundle = spec["bundle"] as? String, !bundle.isEmpty,
              let container = spec["container"] as? String, !container.isEmpty,
              let archive = spec["archive"] as? String, !archive.isEmpty else {
            return nil
        }
        self.bundleFolder = bundle
        self.container = container
        self.origin = spec["origin"] as? String ?? "?"
        self.archiveBase64 = archive
    }

    /// ゲストのコンテナの `Library/LCBridge/pending.plist` に要求を置き、起こす先を返す。
    /// 起こされたゲストの中で AlarmKitBridge.m が読んで実行し、消す。
    func writePending() -> LCGuestTarget? {
        let documents = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let appURL = documents.appendingPathComponent("Applications/\(bundleFolder)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            LCGuestTrace.record("  ゲストが見つかりません \(appURL.path)")
            return nil
        }
        let directory = documents
            .appendingPathComponent("Data/Application/\(container)/Library/LCBridge", isDirectory: true)
        let pending: NSDictionary = ["date": Date(), "archive": archiveBase64, "origin": origin]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pending.write(to: directory.appendingPathComponent("pending.plist"))
        } catch {
            LCGuestTrace.record("  保留中の要求を書けません: \(error)")
            return nil
        }
        LCGuestTrace.record("  保留中の要求を置きました: \(directory.path)/pending.plist")
        return LCGuestTarget(bundleFolder: bundleFolder, container: container, appURL: appURL)
    }
}

// MARK: - ゲストの特定

struct LCGuestTarget {
    let bundleFolder: String
    let container: String
    let appURL: URL
}

enum LCGuestLocator {

    /// payload の `documents` (= `<LC>/Documents/Data/Application/<UUID>/Documents`)
    /// からコンテナ UUID を取り出し、それを使っているアプリを探す。
    static func locate(payload: String) -> LCGuestTarget? {
        guard let data = payload.data(using: .utf8),
              let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let documentsPath = spec["documents"] as? String else {
            LCGuestTrace.record("  ゲスト特定: payload に documents がありません")
            return nil
        }

        let components = URL(fileURLWithPath: documentsPath).pathComponents
        guard let index = components.lastIndex(of: "Application"), index + 1 < components.count else {
            LCGuestTrace.record("  ゲスト特定: documents の形式が想定外です \(documentsPath)")
            return nil
        }
        let container = components[index + 1]

        let applications = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents/Applications", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []

        for folder in folders {
            let appURL = applications.appendingPathComponent(folder, isDirectory: true)
            let infoURL = appURL.appendingPathComponent("LCAppInfo.plist")
            guard let infoData = FileManager.default.contents(atPath: infoURL.path),
                  let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil)) as? [String: Any] else {
                continue
            }
            if (info["LCDataUUID"] as? String) == container {
                return LCGuestTarget(bundleFolder: folder, container: container, appURL: appURL)
            }
            if let containers = info["LCContainers"] as? [[String: Any]],
               containers.contains(where: { ($0["folderName"] as? String) == container }) {
                return LCGuestTarget(bundleFolder: folder, container: container, appURL: appURL)
            }
        }
        LCGuestTrace.record("  ゲスト特定: コンテナ \(container) を使うアプリが Documents/Applications にありません (共有アプリは未対応)")
        return nil
    }

    /// 本家は `NSUserDefaults.lcAppUrlScheme` を渡している。
    /// LiveContainerShared のカテゴリなので実行時に引き、無ければ Info.plist の先頭を使う。
    static func hostURLScheme() -> String? {
        if let value = LCObjC.get(UserDefaults.self as AnyObject, "lcAppUrlScheme") as? String, !value.isEmpty {
            return value
        }
        guard let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]],
              let schemes = types.first?["CFBundleURLSchemes"] as? [String] else {
            return nil
        }
        return schemes.first
    }
}

// MARK: - エラーの記録

enum LCGuestErrorDump {

    /// domain / code / 説明 / userInfo を、下位のエラーまでたどって記録する。
    static func record(_ error: NSError?, label: String) {
        guard let error else {
            LCGuestTrace.record("  \(label): なし")
            return
        }
        LCGuestTrace.record("  \(label):")
        dump(error, depth: 1, remaining: 6)
    }

    private static func dump(_ error: NSError, depth: Int, remaining: Int) {
        let indent = String(repeating: "    ", count: depth)
        LCGuestTrace.record("\(indent)\(error.domain) code=\(error.code): \(error.localizedDescription)")
        for (key, value) in error.userInfo.sorted(by: { $0.key < $1.key }) {
            if key == NSUnderlyingErrorKey || key == NSMultipleUnderlyingErrorsKey { continue }
            LCGuestTrace.record("\(indent)  \(key) = \(LCObjC.compact(String(describing: value), limit: 400))")
        }
        guard remaining > 0 else { return }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            LCGuestTrace.record("\(indent)  ↳ 下位のエラー:")
            dump(underlying, depth: depth + 1, remaining: remaining - 1)
        }
        if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            for (i, sub) in multiple.enumerated() {
                LCGuestTrace.record("\(indent)  ↳ 下位のエラー[\(i)]:")
                dump(sub, depth: depth + 1, remaining: remaining - 1)
            }
        }
    }
}

// MARK: - 補助

enum LCObjC {

    /// 引数なしのメソッドを、応答する場合だけ呼ぶ。
    static func get(_ object: AnyObject, _ selectorName: String) -> AnyObject? {
        // クラスオブジェクトも NSObjectProtocol として扱える
        guard let target = object as? NSObjectProtocol else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue()
    }

    /// 改行を詰めて長さを制限する。
    static func compact(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// 画面が出ない実行を観測する唯一の手段。
/// LiveContainer は UIFileSharingEnabled なので「ファイル」アプリから読める。
enum LCGuestTrace {

    static let fileName = "lc-guest-intent.log"
    private static let lock = NSLock()

    static func record(_ message: String) {
        NSLog("[LCGuestIntent] %@", message)

        let documents = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let url = documents.appendingPathComponent(fileName)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
