# AlarmKitBridge 検証版 (diag2 〜 diag2.4)

> **diag2.1 (2026-11-03)**: 包み替えの作り方だけを変えた版。手順・集めるログは diag2 と同じ。
> **diag2.2 (2026-11-03)**: LiveProcess での実行が `intentNotFound` になる問題への対策。
> **diag2.3 (2026-11-03)**: diag2.2 の A (metadata の付け直し) が試されなかった不具合の修正。
> **diag2.4 (2026-11-03)**: 型紙を不要にした。検証は LiveContainer と BridgeProbe v2 の 2 つで完結する。
> 成果物名は `LiveContainer-guestintent-diag2.4.ipa`。**手順は下の「diag2.4 の手順」だけを見ればよい**
> (それより上の手順 3 の「型紙を作る」は不要になった)。

diag1 (LCGuestIntent + LiveProcess 起動) に、**ゲストを改変せずに** AlarmKit のボタンから
ゲスト自身の App Intent を動かす「透過ブリッジ」を足したもの。

## 目的と完了条件

- 目的: スタブを持たない普通のアプリ (BridgeProbe) の stopIntent / secondaryIntent が、
  素の LiveContainer 上で実行されること。
- 完了条件 (どれか 1 つでも「はい」なら前進):
  1. AlarmKit の停止ボタンで BridgeProbe の `ProbeStopIntent.perform()` が走り、`bridge-probe.log` に ★ 行が出る
  2. 走らない場合、どの段で止まったかがログで 1 つに特定できる

## 仕組み

```
[登録時: ゲストのプロセス (LC 本体)]
  AlarmManager.schedule(stopIntent: ProbeStopIntent(...))
    └ AlarmKit が LNAction を NSKeyedArchiver で保存形式にする ← ここをフック (TweakLoader/AlarmKitBridge.m)
         ・元の LNAction を丸ごと保存形式にし、base64 で payload に入れる
         ・LCGuestIntent (action="lc.bridge") の LNAction に差し替えて AlarmKit に返す

[停止ボタン: LiveContainer のメタデータで解決される]
  LCGuestIntent.perform()  (LiveContainer/LCGuestIntent.swift)
    └ payload から pending.plist をゲストのコンテナ Library/LCBridge/ に書く
    └ LiveProcess.appex でゲストを画面なしで起こす (diag1 で実証済み)

[ゲストのプロセス (LiveProcess)]
  AlarmKitBridge.m の constructor が pending.plist を見つける
    └ 起動完了後に元の LNAction を復元し、LNAppContext.performAction でプロセス内実行
    └ 終わったら (画面が無ければ) exit
```

LCGuestIntent のスタブを持つアプリ (AlarmClock v51) は包み替えない。
代わりに、AlarmKit が作った本物の LNAction を **型紙** として
`LiveContainer の Documents/LCBridge/template-lcguestintent.archive` に保存する。
包み替えでは型紙の引数識別子と型名を使う (手作りより確実)。

## 変更点 (diag1 からの差分)

| ファイル | 内容 |
|---|---|
| `TweakLoader/AlarmKitBridge.m` | 新規。フック・型紙保存・包み替え・保留要求の実行 |
| `LiveContainer/LCGuestIntent.swift` | action `lc.bridge` を受けたら payload から保留要求を書き、そのゲストを起こす (`LCGuestBridgeRequest`) |
| `LiveContainer.xcodeproj/project.pbxproj` | TweakLoader の `membershipExceptions` に `AlarmKitBridge.m` を追加 (同期フォルダでも自動では入らない) |
| `.github/workflows/build-guest-intent.yml` | TweakLoader.dylib に AlarmKitBridge が入ったかを検査。成果物名を `-diag2` に |

Info.plist と entitlements は変えていない。**上書きインストールで検証できる。**

## 手順

1. このフォルダを push → Actions **Build IPA (LCGuestIntent diag2.4)** → `LiveContainer-guestintent-diag2.4.ipa`
2. SideStore で上書きインストール (拡張は残す)
3. **型紙を作る**: LC 内の AlarmClock v51 でアラームを 1 件登録し直す (保存するだけでよい。鳴らさなくてよい)
   → `ファイル > LiveContainer > LCBridge > template-lcguestintent.archive` ができる
4. `BridgeProbe-v1.0.0.zip` をビルドした ipa を **LC に** 入れる
   (比較のため、可能なら SideStore で直インストールも 1 回やる。直インストールでは包み替えは起きない)
5. BridgeProbe で次を試す

| # | 操作 | 期待 (成功時) |
|---|---|---|
| 1 | 「.countdown で登録」→ 60 秒待つ → **ロック中に停止** | `★ ProbeStopIntent が実行されました note=停止テスト #n count=n 環境=LiveContainer (LiveProcess)` |
| 2 | 「.countdown で登録」→ 鳴ったら **スヌーズ** | `★ ProbeSnoozeIntent … custom=false` が出るか (= `.countdown` でも secondaryIntent が走るか) |
| 3 | 「.custom で登録」→ 鳴ったら **スヌーズ** | `★ ProbeSnoozeIntent … custom=true` → `★ stop(id:) 成功` で鳴り止む |

`.custom` は Intent が走らないとスヌーズで止まらない。止まらなければ停止ボタンで止める。

## 集めるログ

| ファイル | 場所 (ファイル App) | 中身 |
|---|---|---|
| `bridge-probe.log` | BridgeProbe の Documents (アプリ内「プローブ」タブから共有可) | Intent が走ったか |
| `bridge.log` | BridgeProbe の Documents/LCBridge (アプリ内「LCBridge」タブ) | 包み替え・保留要求の実行・LNAppContext の結果 |
| `lc-guest-intent.log` | LiveContainer の Documents | LCGuestIntent が受けたか・LiveProcess 起動 |
| `*.archive` | BridgeProbe の Documents/LCBridge と LC の Documents/LCBridge | LNAction の実物 (こちらで plist を解析する) |

## ログの読み方 (段ごと)

| 段 | 見る行 | 止まったときの意味 |
|---|---|---|
| A. フック | `bridge.log`: `AlarmKit が LNAction を保存形式にします` | 出ない → 呼び出し元判定 (AlarmKit) が外れた / 別 API で保存している |
| B. 包み替え | `包み替え: … (型紙を複製 (actionWithParameters:))` と、その下の `包み替え後` の `metadata=LNActionMetadata (13LiveContainer13LCGuestIntentV) systemProtocols=[com.apple.link.systemProtocol.SessionStarting]` | `手作り (型紙なし…)` → 手順 3 をやり直す。`手作り (型紙の複製に失敗…)` → 直前の行の理由を送る |
| C. 解決 | `lc-guest-intent.log`: `包み替えられた Intent: …ProbeStopIntent` | 出ない → AlarmKit が包み替えた LNAction を解決できなかった (型名・引数の不一致) |
| D. 起動 | `[結果] LiveProcess 起動成功` | diag1 と同じ切り分け |
| E. 実行 | `bridge.log`: `保留中の要求を実行します` → `実行完了 … error=` | error の domain/code が次の手掛かり |
| F. 結果 | `bridge-probe.log`: ★ 行 | E が成功で F が無い → LNAppContext は成功扱いだが perform に届いていない |

## 既知の制限

- 共有アプリ (App Group 側に置いたアプリ) と、コンテナをブックマークで外に置いたアプリは保留要求の場所を特定できない。
- 保留要求は 120 秒で無効。
- `LNAppContext` は非公開 API。iOS の更新で引数が変わると E で落ちる (ログに出る)。
- +SideStore 版では使えない (diag1 と同じ理由)。

## diag2.1 の変更

diag2 の型紙 (AlarmClock v51 が作った本物) を解析したら、AlarmKit が作る LNAction には
次の 2 つが入っていた。diag2 の手作り (`initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:`) では両方とも空になる。

| 項目 | 本物 (型紙) | diag2 の手作り |
|---|---|---|
| `metadata` | `LNActionMetadata` (`13LiveContainer13LCGuestIntentV` / `LiveContainer.LCGuestIntent`) | なし |
| `systemProtocols` | `com.apple.link.systemProtocol.SessionStarting` (= LiveActivityIntent) | なし |
| `mangledTypeName` | `10AlarmClock13LCGuestIntentV` (ゲストのスタブ) | 型紙と同じ |

diag2.1 では型紙を `-[LNAction actionWithParameters:]` で複製し、引数 3 つだけを差し替える。
iPadOS 26.6.1 (23G83) の LinkMetadata を逆アセンブルし、このメソッドが identifier / mangledTypeName /
openAppWhenRun / explicitAuthenticationPolicy / outputFlags / outputType / systemProtocols / metadata を
すべて引き継いで `_initWithIdentifier:mangledTypeName:openAppWhenRun:explicitAuthenticationPolicy:outputFlags:outputType:systemProtocols:parameters:metadata:` を呼ぶことを確認した。
引数の LNValue は型紙と同じ valueType (`LNPrimitiveValueType`, string) で作る。

型紙が無い・使えないときは diag2 と同じ手作りに戻り、ログにその旨が出る。

`bridge.log` には LNAction ごとに `metadata=… systemProtocols=[…]` の行が増えた。
AlarmKit が BridgeProbe の Intent から作った元の LNAction にも metadata が入っているか
(LiveContainer のメタデータに無い型なので、おそらく空) がここで分かる。

| ファイル | 内容 |
|---|---|
| `TweakLoader/AlarmKitBridge.m` | 包み替えを型紙の複製に変更。metadata / systemProtocols をログに出す |
| `.github/workflows/build-guest-intent.yml` | 名前と成果物を diag2.1 に。TweakLoader.dylib が diag2.1 かを検査 |
| `docs/diag2-to-diag2.1.patch` | diag2 からの差分 |

Info.plist と entitlements は変えていない。**上書きインストールで検証できる。** 型紙も作り直さなくてよい
(diag2 で作った `template-lcguestintent.archive` をそのまま使う)。

## diag2.2 の変更

### diag2.1 の実測 (2026-11-03 14:27)

| 段 | 結果 |
|---|---|
| A〜D (包み替え・解決・起動) | ○ |
| E. 実行 | × `LNAppContext performAction` → `AppIntents.PerformIntentError.intentNotFound` (9 回とも、12〜62 ms) |
| F. 結果 | × `bridge-probe.log` に ★ 行なし |

### 原因 (23G83 の AppIntents を逆アセンブル)

- [検証] LNAction に `metadata` が無いと「LNAction did not include metadata」と記録し、AppManager の登録表から
  identifier → mangledTypeName の順で探す。無ければ intentNotFound
- [検証] AppManager の表は `+[LNEntitlementsValidator currentProcessHasApplicationServiceMachLookup]` かつ
  `+[LNFeatureFlags isAppMetadataViaXPCEnabled]` なら XPC で、そうでなければバンドルの `Metadata.appintents` から作る
- [検証] プロセスの bundle ID は `+[LSBundleRecord bundleRecordForCurrentProcess]` で取り、拡張なら親アプリに読み替える
  (LiveProcess.appex → LiveContainer)
- [推論] 子プロセスの AppManager は LiveContainer のメタデータを引いていて、ゲストの型が載っていない
- 元の LNAction に metadata が無いのは、登録時に AlarmKit が LiveContainer のプロセスで LNAction を作るため
  (BridgeProbe の型は LiveContainer のメタデータに無い)

### 対策 (TweakLoader/AlarmKitBridge.m)

| | 内容 | いつ |
|---|---|---|
| A | ゲスト自身の `Metadata.appintents` を `LNBundleMetadata initWithBundle:usingEffectiveBundleIdentifier:error:` で読み、`actions[identifier]` を LNAction に付け直す (`_initWithIdentifier:…:metadata:`) | 実行直前 |
| B | `isAppMetadataViaXPCEnabled` と `currentProcessHasApplicationServiceMachLookup` を NO に固定し、AppManager にバンドルの静的メタデータを使わせる | 保留中の要求があって LiveProcess で起こされたときだけ。ゲストの main より前 |

実行は「A: metadata 付き」→ 失敗したら「元のまま」の順に 1 回ずつ。B はどちらにも効いている。

| 結果 | 意味 |
|---|---|
| A が成功 | metadata の付け直しで足りる (B が要るかは次の版で B を外して確かめる) |
| A が失敗・元のまま が成功 | B が効いた。A の付け直し方に問題がある |
| 両方失敗 | 下の診断行から、AppManager がどのバンドルを見ているかを確かめる |

### bridge.log に増えた行

```
+[LNFeatureFlags isAppMetadataViaXPCEnabled]: 元の値=… → NO に固定
+[LNEntitlementsValidator currentProcessHasApplicationServiceMachLookup]: 元の値=… → NO に固定
mainBundle: id=… path=…
mainBundle の Metadata.appintents: あり / なし
LSBundleRecord (現在のプロセス): class=… id=… 親=…
+[LNEntitlementsValidator bundleIdentifierForCurrentProcess]=…
メタデータ: actions N 件 [...]
メタデータ: ProbeSnoozeIntent を見つけました (LNActionMetadata, mangledTypeName=…)
実行 [A: metadata 付き] / 実行完了 [A: metadata 付き] … error=…
実行 [元のまま] / 実行完了 [元のまま] … error=…
```

### その他

- `LiveContainer/LCGuestIntent.swift`: 新しい子が起動しなかったとき (`pid=0`) を「起動成功」ではなく
  「新しい子プロセスは起動されず」と記録するようにした (処理の流れは変えていない)

### 手順

diag2.1 と同じ。上書きインストールでよく、型紙も作り直さなくてよい。
BridgeProbe は**1 回ずつ**押す (連打すると `pid=0` になり、保留中の要求が上書きされる)。

## diag2.3 の変更

### diag2.2 の実測 (2026-11-03 15:18)

| 項目 | 結果 |
|---|---|
| B: 2 つの判定 | どちらも元は YES → NO に固定できた |
| mainBundle | `com.example.bridgeprobe`、`Metadata.appintents` あり |
| LSBundleRecord (現在のプロセス) | `LSApplicationExtensionRecord` id=`com.kdt.livecontainer.48A5LFNW96.LiveProcess` 親=LiveContainer |
| `bundleIdentifierForCurrentProcess` | `com.kdt.livecontainer.48A5LFNW96.LiveProcess` (拡張の ID のまま) |
| A: ゲストのメタデータ | 読めた (actions 2 件: ProbeStopIntent, ProbeSnoozeIntent) |
| A: 付け直し | **試されず**。`instancesRespondToSelector:` が `_initWithIdentifier:…metadata:` に NO |
| 元のまま (B だけ効いた状態) | `intentNotFound` (22 ms) → **B だけでは足りない** |

### 変更

- `LCBActionWithMetadata` を 3 通りの作り方にした。どれで作れたかと、作れなかった理由を記録する
  1. `_initWithIdentifier:…:metadata:` を `class_getInstanceMethod` の IMP で直接呼ぶ (存在確認を `instancesRespondToSelector:` に頼らない)
  2. 複製 (`copy`) に KVC で `metadata` を入れる
  3. `initWithMetadata:mangledTypeName:parameters:`
- 1 のメソッドが見つからないときは、LNAction の init 系メソッドの一覧を記録する

### bridge.log で見る行

```
付け直し 1: class_getInstanceMethod=… instancesRespondToSelector=…
付け直し N で作れました
metadata 付き: … metadata=LNActionMetadata (11BridgeProbe0B12SnoozeIntentV) …
実行完了 [A: metadata 付き] … error=(null)   ← 成功
```

## diag2.4 の変更

- 包み替え先の LCGuestIntent を、**LiveContainer 自身の `Metadata.appintents`** から組み立てる。
  ゲストのプロセスから LiveContainer.app の場所を dyld のイメージ 0 で求め
  (LiveProcess では `PlugIns/LiveProcess.appex` から 2 つ上)、`LNBundleMetadata` で
  `com.kdt.livecontainer.guestIntent` の LNActionMetadata を読む。
  LNAction は `initWithMetadata:bundleIdentifier:parameters:`、だめなら `_initWithIdentifier:…:metadata:` で作る
- 型紙 (`template-lcguestintent.archive`) は不要。あれば予備として使う
- 実行時の metadata の付け直し (diag2.3) はそのまま

## diag2.4 の手順

1. このフォルダを push → Actions **Build IPA (LCGuestIntent diag2.4)** → `LiveContainer-guestintent-diag2.4.ipa` を SideStore で上書きインストール
2. `BridgeProbe-v2.0.0.zip` をビルドした ipa を LiveContainer に入れる (v1 を上書き)
3. BridgeProbe を開き、スヌーズの方式を選んで「アラームを登録」→ 画面をロックして待つ
4. 鳴ったら停止かスヌーズを **1 回だけ**押す
5. BridgeProbe を開き「統合ログを開く」→ 共有ボタンで 1 つのファイルを送る

bridge.log で見る行:

```
LiveContainer 本体: /…/LiveContainer.app (id=com.kdt.livecontainer.<TEAM>)
メタデータ: com.kdt.livecontainer.guestIntent を見つけました
組み立て: initWithMetadata:bundleIdentifier:parameters:
包み替え: LiveContainer のメタデータから組み立て
```
