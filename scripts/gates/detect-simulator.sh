#!/bin/bash
# 偵測模擬器，輸出可直接餵給 xcodebuild -destination 的 `platform=iOS Simulator,id=<UDID>` 值。
# 供 push-gate 與 CI 共用（本機與 CI 的 Xcode 版本不同，不可寫死機型）。
#
# LS-83：原本輸出 `platform=iOS Simulator,name=<機型>,OS=<版本>`——用機型名而非 UDID，多 worktree／多 agent
# 併行時全部解析到清單第一台，併發 `xcodebuild test` 打同一顆模擬器 → runner 崩潰（LS-62 PR #120 review F5）。
# 改成：
#   1. 先找「本 worktree 專屬」模擬器（名稱 `<票號>-<機型無空白>`，票號取自 worktree 目錄名或分支名，
#      主 checkout／非票號分支用 `main`）：存在就直接用它的 UDID；不存在就用清單第一台可用 iPhone 的
#      devicetype／runtime `simctl create` 一台，用完不刪（>7 天未用由 scripts/ops/patrol.sh 只列不刪，
#      印 `simctl delete` 指令）。
#   2. 建立失敗，或 `DETECT_SIMULATOR_SHARED=1`（手動強制） → 退回共用第一台，經
#      scripts/ops/simulator-lock.sh（mkdir 原子 lock，鍵＝共用裝置 UDID，演算法比照 supabase-lock.sh，LS-70）。
#   3. CI（`CI=true`）維持共用第一台、不建、不 lock——CI 是單一 runner，本來就序列，且 CI 容器每次都是全新
#      環境，`simctl create` 建出的專屬模擬器不會被下一輪重用，只會白建。
# 呼叫端（push-gate.sh／CI）不變：仍只是把整段輸出塞進 `-destination`。
#
# LS-10 的坑仍在：`simctl list devices available` 的分節標題只印 major.minor，但 `-destination`／`simctl create`
# 要精確比對到實際安裝的 runtime 版本，用 `simctl list runtimes` 查出來；查不到就退回分節標題本身。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

list=$(xcrun simctl list devices available)

# 單一 pass 取「清單第一台可用 iPhone」的 os 分節標題、機型名、UDID：
#   - os／name 沿用 LS-10 的邏輯不變；
#   - udid 是共用 fallback 用的第一台裝置 UDID，也用來在強制共用模式下當 lock 的鍵。
first=$(printf '%s\n' "$list" | awk '
  /^-- iOS / {
    os = $0
    sub(/^-- iOS /, "", os)
    sub(/ --$/, "", os)
    next
  }
  /iPhone/ {
    line = $0
    name = line
    sub(/^[ \t]*/, "", name)
    sub(/ *\(.*/, "", name)
    udid = line
    sub(/^[^(]*\(/, "", udid)
    sub(/\).*/, "", udid)
    printf "%s\t%s\t%s\n", os, name, udid
    exit
  }
')
header_os=$(printf '%s' "$first" | cut -f1)
name=$(printf '%s' "$first" | cut -f2)
shared_udid=$(printf '%s' "$first" | cut -f3)

if [ -z "$name" ] || [ -z "$header_os" ] || [ -z "$shared_udid" ]; then
  echo "✗ 找不到可用的 iPhone 模擬器（xcrun simctl list devices available）。" >&2
  exit 1
fi

exact_os=$(xcrun simctl list runtimes | grep -m1 "^iOS ${header_os} " \
  | sed -E 's/^iOS [0-9.]+ \(([0-9.]+)( - .*)?\).*/\1/')
os="${exact_os:-$header_os}"

# ---- 本 worktree 專屬模擬器的名稱：<票號>-<機型無空白>（票號取自 worktree 目錄名或分支名，抓不到用 main）----
extract_ticket() { printf '%s' "$1" | grep -oE 'LS-[0-9]+' | head -1; }
toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || toplevel=$(pwd)
branch=$(git -C "$toplevel" symbolic-ref --short -q HEAD 2>/dev/null || true)
ticket=$(extract_ticket "$(basename "$toplevel")")
[ -n "$ticket" ] || ticket=$(extract_ticket "${branch:-}")
[ -n "$ticket" ] || ticket=main
model_slug=$(printf '%s' "$name" | tr -d '[:space:]')
dedicated_name="${ticket}-${model_slug}"

find_udid_by_name() {   # $1＝精確裝置名；印第一個相符裝置（任何 runtime、任何狀態）的 UDID，沒有就空字串
  xcrun simctl list devices 2>/dev/null | awk -v n="$1" '
    {
      line = $0
      nm = line
      sub(/^[ \t]*/, "", nm)
      sub(/ *\(.*/, "", nm)
      if (nm == n) {
        udid = line
        sub(/^[^(]*\(/, "", udid)
        sub(/\).*/, "", udid)
        print udid
        exit
      }
    }
  '
}

create_dedicated() {   # 成功印新 UDID、exit 0；失敗印訊息到 stderr、回 1（呼叫端退回共用）
  local devicetype_id runtime_id created
  devicetype_id=$(xcrun simctl list devicetypes 2>/dev/null | grep -F "${name} (" \
    | sed -E 's/.*\(([^()]+)\)[[:space:]]*$/\1/' | head -1)
  runtime_id=$(xcrun simctl list runtimes 2>/dev/null | grep -m1 "^iOS ${header_os} " \
    | sed -E 's/.* - (com\.apple\.[^[:space:]]+)[[:space:]]*$/\1/')
  if [ -z "$devicetype_id" ] || [ -z "$runtime_id" ]; then
    echo "⚠ detect-simulator：找不到「${name}」的 devicetype／「iOS ${header_os}」的 runtime identifier，無法建立專屬模擬器" >&2
    return 1
  fi
  if ! created=$(xcrun simctl create "$dedicated_name" "$devicetype_id" "$runtime_id" 2>&1); then
    echo "⚠ detect-simulator：simctl create「${dedicated_name}」失敗：${created}" >&2
    return 1
  fi
  printf '%s' "$created"
}

udid=
if [ "${CI:-}" = true ]; then
  udid=$shared_udid
else
  # DETECT_SIMULATOR_SHARED=1：強制走共用＋lock，連本 worktree 專屬模擬器是否已存在都不查
  # （這支旗標本身就是「不要用專屬模擬器」的手動逃生口／自測用）。
  if [ "${DETECT_SIMULATOR_SHARED:-0}" != 1 ]; then
    udid=$(find_udid_by_name "$dedicated_name")
    if [ -z "$udid" ]; then
      udid=$(create_dedicated) || udid=
    fi
  fi
  if [ -z "$udid" ]; then
    lock_dir="${DETECT_SIMULATOR_LOCK_DIR:-/tmp/simulator-lock-${shared_udid}}"
    udid=$(bash "$here/../ops/simulator-lock.sh" --dir "$lock_dir" -- printf '%s' "$shared_udid") || {
      echo "✗ detect-simulator：等待共用模擬器 lock 失敗（${lock_dir}）" >&2
      exit 1
    }
  fi
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
