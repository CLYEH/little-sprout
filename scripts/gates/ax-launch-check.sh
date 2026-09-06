#!/bin/bash
# AX（Dynamic Type）字級啟動參數 gate（LS-211 範圍 7，來源 LS-210 merge-review R1 comment `24fc12db`
# i3、LS-96 池項 `b63b274a` (a)）：reviewer 實測 `app.launchEnvironment["UIPreferredContentSizeCategoryName"]`
# 對 XCUITest 目標 app **不生效**（「設定」標題高度：env 通道量到 AX5＝40.67pt＝實際上根本沒設成功；
# `launchArguments` 通道量到 AX5＝69.33pt＝真的放大了）——所有走 `launchEnvironment` 這個鍵設定 AX
# 字級的 UITest 都可能是假綠（app 其實一直跑在標準字級，斷言只是恰好在標準字級下也成立）。
#
# 掃描範圍：<root>/LittleSproutUITests 內所有 *.swift（不含註解文字提及、只認實際 subscript 語法
# `launchEnvironment[` 後面接著 `UIPreferredContentSizeCategoryName`——避免誤擋單純描述性的註解，如
# `UploadQueueSheetUITests.swift` 解釋「不是本票程式碼的 bug」那段純文字）。
#
# 已知現況（allowlist，過渡期）：`TapTargetMeasurement.swift` 目前仍用 `launchEnvironment` 設 AX 字級——
# LS-190（PR #331）已在 development 分支把這支共用 helper 改成 `launchArguments`＋放大前置斷言，但
# main／本票尚未併入那個修正。ALLOWLIST 裡的檔案命中時只印 informational（不算違規、不使 exit 非 0），
# LS-190 併主後應移除對應的 allowlist 項（讓 gate 對它也生效）——移除時機由下一個碰這支腳本的人核對
# `git grep -q 'launchEnvironment\[.*UIPreferredContentSizeCategoryName' LittleSprout UITests/TapTargetMeasurement.swift`
# 是否仍命中，命中就还不能移除。
#
# 用法：ax-launch-check.sh [--root <dir>]（預設 repo root；自測用 --root 指向合成 fixture 目錄）
# exit：0＝無非 allowlist 違規；1＝有違規；2＝參數／環境錯誤（fail closed）
# 自測：ax-launch-check.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ -n "${2:-}" ] || { echo "✗ ax-launch-check：--root 缺值" >&2; exit 2; }
      root=$2; shift 2 ;;
    *) echo "✗ ax-launch-check：未知參數 $1" >&2; exit 2 ;;
  esac
done
# R2（merge-review R1 N4）：--root 帶尾斜線時 `${root}/LittleSproutUITests/...` 抓出的 $file 前綴會多一個
# `/`，`relfile=${file#"${root}"/}` 剝不掉「$root 後面接一個 /」這個固定樣式（$root 本身結尾已經是 /、
# 相減後模式變成 `//`，對不上），allowlist 整字比對因此失效、對 TapTargetMeasurement.swift 誤紅。收乾淨
# 尾斜線即可（CI 不帶 --root、走 git rev-parse，本來就沒有這個問題，只影響手動呼叫）。
root=${root%/}

ui_dir="${root}/LittleSproutUITests"
[ -d "$ui_dir" ] || { echo "✗ ax-launch-check：找不到 ${ui_dir}" >&2; exit 2; }

# LS-190（PR #331）併主前的過渡期白名單——見檔頭說明；相對 <root> 的路徑，整字比對。
ALLOWLIST="LittleSproutUITests/TapTargetMeasurement.swift"

pattern='launchEnvironment\[[^]]*UIPreferredContentSizeCategoryName'
hits=$(grep -rnE "$pattern" "$ui_dir" --include='*.swift' 2>/dev/null) || hits=

fail=0
n_allow=0
n_bad=0
if [ -n "$hits" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file=${line%%:*}
    relfile=${file#"${root}"/}
    is_allowed=0
    for a in $ALLOWLIST; do
      [ "$relfile" = "$a" ] && is_allowed=1 && break
    done
    if [ "$is_allowed" -eq 1 ]; then
      echo "（允許期限內：${line} ——LS-190 併主前已知，不算違規；併主後應移除 allowlist）"
      n_allow=$((n_allow + 1))
    else
      echo "✗ ax-launch-check：${line} ——launchEnvironment 設 UIPreferredContentSizeCategoryName 對 XCUITest 目標 app 不生效（LS-210 merge-review R1 24fc12db i3 實測），請改用 launchArguments（\`-UIPreferredContentSizeCategoryName <UICTContentSizeCategory…>\`）並加字級真的放大的前置斷言" >&2
      n_bad=$((n_bad + 1))
      fail=1
    fi
  done <<< "$hits"
fi

if [ "$fail" -eq 1 ]; then
  exit 1
fi
echo "✓ ax-launch-check 通過（${n_bad} 項違規、${n_allow} 項在允許期限內）"
exit 0
