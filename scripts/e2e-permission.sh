#!/bin/bash
# E2E（実機・手動操作あり）: 起動中にアクセシビリティ権限を外しても、クリックが止まらないか（#3, failure-modes 37〜41）。
#   1. build/TrackpadRunner.app を作り直して起動し、左クリックのタップが有効になるのを待つ
#   2. 権限を外してもらい、タップが取り外されることと、クリックが効くことを確認する
#   3. 権限を戻してもらい、アプリを再起動しなくてもタップが作り直されることを確認する
# 結果は e2e-artifacts/permission/ に report.md と log.txt（unified log）として残す。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=e2e-artifacts/permission
mkdir -p "$OUT"
BIN=.build/release/trackpad-runner
TIMEOUT=180

./scripts/bundle.sh >/dev/null
pkill -f 'TrackpadRunner.app/Contents/MacOS/trackpad-runner' || true
sleep 1

log stream --level info --style compact --predicate 'subsystem == "com.madebyjun.trackpad-runner"' >"$OUT/log.txt" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null || true' EXIT

results=()
record() { # 結果 ケース 詳細
  results+=("| $1 | $2 | $3 |")
  echo "$1 $2: $3"
}

app_pid() { pgrep -f 'TrackpadRunner.app/Contents/MacOS/trackpad-runner' | head -1; }
taps() { local pid; pid=$(app_pid); [ -n "$pid" ] && "$BIN" --event-taps "$pid" || echo "total=0 enabled=0 (not running)"; }

# $1 が taps の出力に出るまで待つ。見つかれば 0
wait_taps() {
  local want=$1 deadline=$((SECONDS + TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    [[ "$(taps)" == "$want"* ]] && return 0
    sleep 1
  done
  return 1
}

ask() { # y/n を聞く
  local answer
  read -r -p "$1 [y/n] " answer
  [[ "$answer" == y* ]]
}

echo "== 1. 起動"
open build/TrackpadRunner.app
echo "権限を求められたら許可して、もう一度 build/TrackpadRunner.app を起動してください（最大 ${TIMEOUT} 秒待ちます）。"
until wait_taps "total=1 enabled=1"; do
  echo "タップが有効になりません。権限を確認して再度起動してください。"
done
record ✅ "起動後に左クリックのタップが有効" "$(taps)"
PID=$(app_pid)

echo
echo "== 2. 権限を外す"
echo "システム設定 > プライバシーとセキュリティ > アクセシビリティ で TrackpadRunner をオフにしてください。"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
if wait_taps "total=0"; then
  record ✅ "権限を外すとタップが取り外される (#37 #38)" "$(taps)"
else
  record ❌ "権限を外すとタップが取り外される (#37 #38)" "$(taps)"
fi
if [ "$(app_pid)" == "$PID" ]; then
  record ✅ "アプリは終了せずに動き続ける" "pid=$PID"
else
  record ❌ "アプリは終了せずに動き続ける" "pid=$(app_pid)（起動時は $PID）"
fi
if ask "トラックパッドとマウスで、ウインドウやボタンを普通にクリックできますか？"; then
  record ✅ "権限が無い状態でもクリックが効く (#37)" "目視"
else
  record ❌ "権限が無い状態でもクリックが効く (#37)" "目視"
fi
if ask "メニューバーのアイコンが警告表示になり、メニューに「アクセシビリティ権限がありません」と出ていますか？"; then
  record ✅ "権限が無いことがメニューバーで分かる (#39)" "目視"
else
  record ❌ "権限が無いことがメニューバーで分かる (#39)" "目視"
fi

echo
echo "== 3. 権限を戻す"
echo "同じ画面で TrackpadRunner をオンに戻してください（アプリは再起動しないでください）。"
if wait_taps "total=1 enabled=1" && [ "$(app_pid)" == "$PID" ]; then
  record ✅ "権限を戻すと、再起動せずにタップが作り直される (#41)" "$(taps)"
else
  record ❌ "権限を戻すと、再起動せずにタップが作り直される (#41)" "$(taps) pid=$(app_pid)"
fi
echo "トラックパッドを3本指でクリックしてください（最大 60 秒待ちます）。"
start_line=$(wc -l <"$OUT/log.txt")
deadline=$((SECONDS + 60))
converted=""
while [ $SECONDS -lt $deadline ]; do
  converted=$(tail -n +"$((start_line + 1))" "$OUT/log.txt" | grep -m1 'fingers=3 decision=convertToMiddle' || true)
  [ -n "$converted" ] && break
  sleep 1
done
if [ -n "$converted" ]; then
  record ✅ "再開後に3本指クリックが中クリックに変換される" "ログに fingers=3 decision=convertToMiddle"
else
  record ❌ "再開後に3本指クリックが中クリックに変換される" "60 秒以内にログに fingers=3 decision=convertToMiddle が出なかった"
fi

sleep 1
kill $LOG_PID 2>/dev/null || true
failed=$(printf '%s\n' "${results[@]}" | grep -c '❌' || true)
{
  echo "# 権限の取り外し E2E レポート"
  echo
  echo "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "- 日時: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- コミット: $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Sources || echo ' + 未コミットの変更')"
  echo "- 結果: **$(( ${#results[@]} - failed ))/${#results[@]} passed**"
  echo
  echo "| | ケース | 詳細 |"
  echo "|---|---|---|"
  printf '%s\n' "${results[@]}"
  echo
  echo "## ログ（抜粋）"
  echo
  echo '```'
  grep -E 'アクセシビリティ権限' "$OUT/log.txt" || echo "（権限に関するログなし）"
  echo '```'
} >"$OUT/report.md"
echo
echo "レポート: $OUT/report.md"
[ "$failed" -eq 0 ]
