# LCGuestIntent 検証版 (diag1)

> diag2 (ゲストを改変しない透過ブリッジ) は [AlarmKitBridge-diag2.md](AlarmKitBridge-diag2.md) を参照。
> diag1 は 2026-11-03 に実機で成功を確認済み (ロック中・背面から LiveProcess 起動 214 ms)。

本家 main `9108ae62` (2026-10-17, 3.3.55) に、ゲスト用の汎用 Intent と
LiveProcess 起動の診断を追加したもの。

## 何を確かめるか

これまで「背面のアプリからは LiveProcess.appex を起動できない（条件は前面）」と
結論していたが、根拠は **completion が nil UUID で返り、理由が分からない** ことだけだった。

iPadOS 26.6.1 の ExtensionFoundation を逆アセンブルすると、
`-[EXConcreteExtension _beginExtensionRequest:completion:]` は失敗時に
**`completion(nil, error)` と 2 引数で呼んでいる**。本家の `FoundationPrivate.h` も
これまでの検証コードも completion を 1 引数で宣言していたので、エラーを捨てていた。

この版はエラーを受け取り、次の条件と一緒に記録する。

| 記録するもの | 切り分けたい仮説 |
|---|---|
| 呼び出し元 (`LiveActivityIntent` / 通常の `AppIntent`) | Intent の種類で RunningBoard の権利が違う (LinkServices は LiveActivityIntent だけ専用アサーションを使う) |
| ロック状態 (`isProtectedDataAvailable`) | ロック中だけ起動できない |
| `applicationState` / RunningBoard の状態 | 前面・背面そのものが条件 |
| エラーの domain / code / 下位エラー | 上のどれでもない原因 |

## 変更点

| ファイル | 内容 |
|---|---|
| `LiveContainer/LCGuestIntent.swift` | 新規。`LCGuestIntent` (LiveActivityIntent) と `LCGuestProbeIntent` (通常の AppIntent、ショートカット用) |
| `LiveContainer.xcodeproj/project.pbxproj` | 上のファイルをアプリターゲットの Sources に追加 (4 行) |
| `.github/workflows/build-guest-intent.yml` | 新規。submodule を固定 SHA で取り直してビルドし、メタデータに Intent が入ったかを検査する |

`Info.plist` と entitlements は変えていない。**上書きインストールで検証できる**（端末の再起動も不要）。

本家の `build.yml` / `update_source.yml` は残してある。ZIP から作ったリポジトリでは
submodule が空なので `build.yml` は毎回失敗する。邪魔なら GitHub の web UI から削除してよい。

## 動き

```
停止ボタン (AlarmKit) ─→ LCGuestIntent.perform()          ┐
ショートカット       ─→ LCGuestProbeIntent.perform()      ┘ 同じ処理
  1. 環境を記録
  2. payload の documents からゲストを特定
  3. LiveProcess.appex でゲストを画面なしで起動
       成功 → ゲスト (AlarmClock の HeadlessRunner) が音源を差し替えて exit
       失敗 → エラーをすべて記録し、Tweaks の dylib をこのプロセスで呼ぶ (従来どおり)
```

失敗しても従来の経路に戻るので、アラームの曲の差し替えは止まらない。
成功した場合は二重に差し替えないよう、プロセス内のハンドラは呼ばない。

## 手順

1. このフォルダをリポジトリに push → Actions の **Build IPA (LCGuestIntent)** が走る
2. `LiveContainer-guestintent.ipa` を SideStore でインストール
   （拡張は残す: "Keep App Extensions (Use Main Profile)"。LiveProcess.appex が要る）
3. AlarmClock v51 はそのまま（スヌーズ方式はオフのまま）
4. 次の 4 通りを試す。1 回ごとに `ファイル > このデバイス内 > LiveContainer > lc-guest-intent.log` を保存

| # | 起点 | 端末の状態 |
|---|---|---|
| A | アラームを鳴らし、ロック画面で停止 | ロック中 |
| B | 使用中にアラームを鳴らし、バナーで停止 | ロック解除中 |
| C | ショートカットアプリで「Guest Probe (LiveContainer)」を実行 | ロック解除中 |
| D | 時刻オートメーション（すぐに実行）で同じアクション | ロック中 |

C と D は直前に停止ボタンで受け取った要求を再生するので、**A か B を先に 1 回やっておく**。
C はショートカットの結果に要約が表示される。

## ログの読み方

```
──── 呼び出し元: LiveActivityIntent (AlarmKit など)
  handler=AlarmClockGuestPerform action=reshuffle
  pid=… applicationState=background ロック=ロック中 (保護データ利用不可)
  RBS状態: <RBSProcessState| … assertions … >
  ゲスト: com.example.alarmclock.app コンテナ: 0E44E47E-…
  起動要求: com.kdt.livecontainer.XXXX.LiveProcess scheme=livecontainer bookmarks=4
  completion: UUID=nil (72 ms)
  completion のエラー:
    <domain> code=<n>: <説明>
      <userInfo>
      ↳ 下位のエラー:
        <domain> code=<n>: …
  [結果] LiveProcess 起動失敗: UUID=nil [<domain> code=<n>]
  プロセス内ハンドラ: AlarmClockGuestPerform result=0
```

**`completion のエラー` の数行が今回の目的**です。4 通りのログをそのまま見せてください。

成功した場合はこうなる。

```
  completion: 起動しました pid=1234 (180 ms)
  [結果] LiveProcess 起動成功 pid=1234 (6.4 秒後に終了)。処理はゲスト側に任せる
```

## 既知の制限

- **+SideStore 版では使えない。** `build_github.sh` が SideStore の `Metadata.appintents` で
  上書きするので、この Intent が消える。このワークフローは素の版だけを作る。
- 共有アプリ（App Group 側に置いたアプリ）はゲストを特定できない。その場合は起動を省略し、従来の経路で処理する。
- `LiveActivityIntent` の実行時間には上限がある。待機は合計で最大約 25 秒にしている。
