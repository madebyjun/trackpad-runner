#!/bin/bash
# E2E: リリースビルドした実行ファイルで
#   1. 実機のトラックパッドを MultitouchSupport 経由で認識できるか
#   2. e2e/fixtures の入力列を判定ロジックに流して、期待どおりの動作になるか
# を確認し、e2e-artifacts/ に report.md / report.json を残す。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=.build/release/trackpad-runner
OUT=e2e-artifacts
mkdir -p "$OUT"

devices=$("$BIN" --list-devices)
echo "トラックパッド数: $devices"
if [ "$devices" -lt 1 ]; then
  echo "トラックパッドが見つかりません" >&2
  exit 1
fi

"$BIN" --replay e2e/fixtures/*.json --report-dir "$OUT"
echo "レポート: $OUT/report.md"
