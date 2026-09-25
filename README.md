# trackpad-runner

BetterTouchTool で実際に使っていた機能だけを抜き出した、最小のトラックパッドジェスチャーアプリ。

| トリガー | 動作 | ハプティック |
|---|---|---|
| 3本指でクリック | 中クリック | 4 |
| 4本指でクリック | ⇧⌘5（スクリーンショット。CleanShot などに割り当てていればそちらが起動する） | 6 |
| TipTap左（2本指を置いたまま、その左側を1本指でタップ） | 中クリック | 3 |

ハプティックの値は BTT の設定値（`BTTGestureForceFeedbackPattern`）と同じで、トラックパッドの振動API（`MTActuatorActuate`）に渡す振動パターンのIDです。値は `Sources/trackpad-runner/Live.swift` の `hapticPatterns` で変えられます。どんな感触かは、トラックパッドに指を置いたまま次を実行すると試せます。

```bash
swift run trackpad-runner --haptic 6
```

アプリごとの設定の切り替えや、設定ファイルはありません。

## ビルドと起動

```bash
./scripts/bundle.sh
```

```bash
open build/TrackpadRunner.app
```

初回起動時にアクセシビリティ権限を求められるので、システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可してから、もう一度起動してください。メニューバーのアイコンから一時的に無効にしたり、終了したりできます。

- アドホック署名なので、ビルドし直すと権限がリセットされることがあります。その場合は、一覧からいったん削除して許可し直してください。
- BetterTouchTool と併用する場合は、二重に発火しないよう BTT 側の同じトリガーを無効にしてください。

ターミナルから直接動かす場合（権限はターミナルアプリに付与されます）:

```bash
swift run trackpad-runner --headless
```

## 仕組み

- `MultitouchSupport.framework`（非公開）から指の位置と本数をフレームごとに受け取る
- `CGEventTap` で左クリックを横取りし、押した瞬間の指の本数で「中クリックに変換 / 握りつぶして ⇧⌘5 を送る / そのまま通す」を決める
  - 押下時の判定は離すまで保持するので、途中で指の本数が変わってもボタンが押しっぱなしにならない
- TipTap左は、固定の2本が 0.1 秒以上置かれている状態で、その左に置いた指が 0.35 秒以内・ほぼ動かずに離れたときに発火する

判定ロジックは `Sources/TrackpadRunnerCore` にあり、実機の入力もリプレイもこの同じ `Engine` を通ります。

## ログ

クリック時の指の本数・判定・発火したジェスチャーを unified log に出しています。

```bash
log stream --level info --predicate 'subsystem == "com.madebyjun.trackpad-runner"'
```

## E2E

```bash
./scripts/e2e.sh
```

リリースビルドした実行ファイルで、次の2つを確認します。

1. 実機のトラックパッドを認識できるか
2. `e2e/fixtures/*.json` の入力列（指のフレームとクリック）を流したとき、期待どおりの動作になるか

結果は `e2e-artifacts/report.md` と `report.json` に出力されます。各ケースは [docs/failure-modes.md](docs/failure-modes.md) の失敗パターンに対応しています。

実機の入力を記録してケースにすることもできます（アクセシビリティ権限が必要です）。

```bash
swift run trackpad-runner --record e2e/fixtures/my-gesture.json --seconds 5
```

記録したファイルに `"expect": {"actions": [...]}` を追記すれば、E2E のケースになります。生成しているケースは `e2e/gen_fixtures.py` にまとまっています。
