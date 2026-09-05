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
#   2. 建立失敗，或 `DETECT_SIMULATOR_SHARED=1`（手動強制） → 直接退回共用第一台的 UDID，**這裡不再持鎖**
#      （R1 的鎖只包住這支腳本自己印字那一瞬間，兩個 worktree 若同時走 fallback，鎖早就放掉、後面各自的
#      `xcodebuild test` 依然併發打同一台——鎖錯地方，merge-reviewer R2 F1 抓到）。真正需要序列化的是
#      「執行 xcodebuild test」那一段，改由呼叫端（`push-gate.sh`）以這裡輸出的 UDID 為鍵，把
#      `xcodebuild test` 整段包進 `scripts/ops/simulator-lock.sh`（mkdir 原子 lock，比照 supabase-lock.sh
#      最小複製，LS-70）——專屬機彼此 UDID 不同，鎖不會互相競爭；只有退回共用第一台時才會真的排隊。
#   3. CI（`CI=true`）維持共用第一台、不建、不查專屬機——CI 是單一 runner、且每個 workflow run 在各自獨立
#      的 VM 上，devices 互不共用，`simctl create` 建出的專屬模擬器也不會被下一輪重用，只會白建。
# 呼叫端（push-gate.sh／CI）不變：仍只是把整段輸出塞進 `-destination`；push-gate.sh 另外用這裡的 UDID 包鎖。
#
# LS-10 的坑仍在：`simctl list devices available` 的分節標題只印 major.minor，但 `simctl create` 的
# runtime 參數要精確比對到實際安裝的版本，用 `simctl list runtimes` 查出來；查不到就退回分節標題本身。
set -uo pipefail

list=$(xcrun simctl list devices available)

# 單一 pass 取「清單第一台可用、非本腳本建立的 iPhone」的 os 分節標題、機型名、UDID：
#   - name／udid 是共用 fallback 用的第一台裝置；devicetype／runtime 建專屬機也靠它們當範本。
#   - LS-83 R2 F2：必須排除本腳本自己建的專屬機（名稱 `<票號>-<機型無空白>`，如 `LS-101-iPhone17Pro`）——
#     它一樣含 "iPhone" 子字串，一旦排在清單較前面（例如原廠機被刪除重建、或未來 simctl 排序改變），
#     name 會被誤判成這台專屬機，後續 devicetype／runtime 查找全部落空、shared_udid 也指錯裝置
#     （merge-reviewer R2 F2 用「專屬機排第一」重現）。
#   - PR #164 R1 F2：demo 環境的持久機（`demo-<機型無空白>`，如 `demo-iPhone17Pro`）同樣含 "iPhone" 子
#     字串、且不是這裡管的「本 worktree 專屬機」，原本沒被排除——一旦它排在清單較前面（例如某個 OS
#     分節唯一的候選就是它），會被誤判成「共用第一台」，連帶被 push-gate.sh 的模擬器用完必關（LS-100）
#     選中並關掉，而 demo 機在其餘三處（push-gate.sh／patrol.sh／§6）都刻意豁免。
first=$(printf '%s\n' "$list" | awk '
  /^-- iOS / {
    os = $0
    sub(/^-- iOS /, "", os)
    sub(/ --$/, "", os)
    next
  }
  /iPhone/ {
    line = $0
    cand = line
    sub(/^[ \t]*/, "", cand)
    sub(/ *\(.*/, "", cand)
    if (cand ~ /^(LS-[0-9]+|main|demo)-/) next
    name = cand
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

# ---- 本 worktree 專屬模擬器的名稱：<票號>-<機型無空白>（票號取自 worktree 目錄名或分支名，抓不到用 main）----
extract_ticket() { printf '%s' "$1" | grep -oE 'LS-[0-9]+' | head -1; }
toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || toplevel=$(pwd)
branch=$(git -C "$toplevel" symbolic-ref --short -q HEAD 2>/dev/null || true)

# ---- LS-205：釘住的 CI runtime（`.ios-runtime`，比照 `.xcode-version` 的單一來源讀法）。
#      沒有這個檔（例如尚未落地的過渡狀態、或下面自測用的非 repo 合成目錄）就當「無釘住」，
#      整段新邏輯自然不生效、退回 LS-83 原本只認 header_os 的行為——不 fail-closed，因為
#      這裡管的是「本機建機挑哪個 runtime」這個體驗細節，不是正確性紅線（正確性紅線交給
#      push-gate.sh 對 .xcode-version 那種 fail-closed）。
pinned_os=
[ -f "${toplevel}/.ios-runtime" ] && pinned_os=$(tr -d '[:space:]' < "${toplevel}/.ios-runtime")

os_of_udid() {   # $1＝UDID；印出該裝置所在的 OS 分節標題（找不到印空字串）
  xcrun simctl list devices available 2>/dev/null | awk -v u="$1" '
    /^-- iOS / { os = $0; sub(/^-- iOS /, "", os); sub(/ --$/, "", os); next }
    {
      line = $0
      udid = line
      sub(/^[^(]*\(/, "", udid)
      sub(/\).*/, "", udid)
      if (udid == u) { print os; exit }
    }
  '
}

warn_runtime_mismatch() {   # $1＝UDID $2＝顯示名稱；pinned_os 有值且與該 UDID 實際 runtime 不同才印（不重建）
  [ -n "$pinned_os" ] || return 0
  local actual
  actual=$(os_of_udid "$1")
  [ -n "$actual" ] && [ "$actual" != "$pinned_os" ] || return 0
  echo "⚠ detect-simulator：既有專屬機「$2」目前是 iOS ${actual}，與釘住版 iOS ${pinned_os} 不同（CI 為 iOS ${pinned_os}）；不自動重建，tap-target／版面量測可能不一致，如需對齊請 xcrun simctl delete 該機後重跑" >&2
}
ticket=$(extract_ticket "$(basename "$toplevel")")
[ -n "$ticket" ] || ticket=$(extract_ticket "${branch:-}")
[ -n "$ticket" ] || ticket=main
model_slug=$(printf '%s' "$name" | tr -d '[:space:]')
dedicated_name="${ticket}-${model_slug}"

find_udid_by_name() {   # $1＝精確裝置名；印第一個相符「可用」裝置（任何 runtime）的 UDID，沒有就空字串
  # LS-83 R2 m3：查 `devices available`（非全部 devices）——Xcode／runtime 升級後舊 runtime 被移除，
  # 專屬機會變成 unavailable 但仍留在「全部 devices」清單裡；若還照樣選中它，`xcodebuild test` 對一台
  # unavailable 的裝置永遠打不動，push-gate 從此對這個 worktree 永久紅。查不到「可用」的就會落空，
  # 呼叫端自然改用 create_dedicated() 建一台新的（同名可以並存，不影響）。
  xcrun simctl list devices available 2>/dev/null | awk -v n="$1" '
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

find_udid_same_ticket() {   # LS-176：同票（名稱 `<票號>-` 開頭）、同 iOS runtime 分節（header_os）的第一台可用裝置，印 "name\tudid"
  # 同票專屬機的機型可能跟現在「清單第一台原廠機」不同（原廠機被刪／重建、Xcode 升級換了預設機型後 name 就變了），
  # 舊版只認精確名稱 `<票號>-<機型無空白>`，找不到就再建一台——LS-107 因此堆到 4 台（LS-96 池項 7c9fe5bd (c)）。
  # 單元測試不挑機型，同 runtime 的既有專屬機直接重用；**不同 runtime 的不重用**（舊 runtime 可能跑不了目前的
  # deployment target），那一種仍走 create_dedicated。同 find_udid_by_name 只看「可用」裝置。
  xcrun simctl list devices available 2>/dev/null | awk -v pfx="${ticket}-" -v os="$header_os" '
    /^-- iOS / { cur = $0; sub(/^-- iOS /, "", cur); sub(/ --$/, "", cur); next }
    cur == os && /^[ \t]+[^ \t]/ {
      line = $0
      nm = line
      sub(/^[ \t]*/, "", nm)
      sub(/ *\(.*/, "", nm)
      if (index(nm, pfx) != 1) next
      udid = line
      sub(/^[^(]*\(/, "", udid)
      sub(/\).*/, "", udid)
      printf "%s\t%s\n", nm, udid
      exit
    }
  '
}

create_dedicated() {   # 成功印新 UDID、exit 0；失敗印訊息到 stderr、回 1（呼叫端退回共用）
  local devicetype_id runtime_id created target_os avail
  devicetype_id=$(xcrun simctl list devicetypes 2>/dev/null | grep -F "${name} (" \
    | sed -E 's/.*\(([^()]+)\)[[:space:]]*$/\1/' | head -1)
  # LS-205：優先建在釘住版（`.ios-runtime`）——找不到本機該版 runtime 就 fail-open，
  # 印 ⚠ 並退回 header_os（原 LS-83 行為），不擋這次建機。
  target_os="$header_os"
  runtime_id=
  if [ -n "$pinned_os" ]; then
    runtime_id=$(xcrun simctl list runtimes 2>/dev/null | grep -m1 "^iOS ${pinned_os} " \
      | sed -E 's/.* - (com\.apple\.[^[:space:]]+)[[:space:]]*$/\1/')
    if [ -n "$runtime_id" ]; then
      target_os="$pinned_os"
    else
      avail=$(xcrun simctl list runtimes 2>/dev/null | awk '/^iOS /{print $2}' | paste -sd '、' -)
      echo "⚠ detect-simulator：本機無 iOS ${pinned_os} runtime（有：${avail:-無}），改用 iOS ${header_os}；CI 為 iOS ${pinned_os}，tap-target／版面量測可能不一致" >&2
    fi
  fi
  if [ -z "$runtime_id" ]; then
    runtime_id=$(xcrun simctl list runtimes 2>/dev/null | grep -m1 "^iOS ${target_os} " \
      | sed -E 's/.* - (com\.apple\.[^[:space:]]+)[[:space:]]*$/\1/')
  fi
  if [ -z "$devicetype_id" ] || [ -z "$runtime_id" ]; then
    echo "⚠ detect-simulator：找不到「${name}」的 devicetype／「iOS ${target_os}」的 runtime identifier，無法建立專屬模擬器" >&2
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
  # DETECT_SIMULATOR_SHARED=1：強制走共用，連本 worktree 專屬模擬器是否已存在都不查
  # （這支旗標本身就是「不要用專屬模擬器」的手動逃生口／自測用）。
  if [ "${DETECT_SIMULATOR_SHARED:-0}" != 1 ]; then
    udid=$(find_udid_by_name "$dedicated_name")
    if [ -n "$udid" ]; then
      warn_runtime_mismatch "$udid" "$dedicated_name"   # LS-205：既有專屬機 runtime ≠ 釘住版只印警告，不重建
    else
      # LS-176：精確名稱找不到 → 先重用同票、同 runtime 的既有專屬機（不論機型），都沒有才建新的
      reuse=$(find_udid_same_ticket)
      if [ -n "$reuse" ]; then
        udid=$(printf '%s' "$reuse" | cut -f2)
        echo "→ detect-simulator：重用同票既有專屬機「$(printf '%s' "$reuse" | cut -f1)」（同 runtime iOS ${header_os}，不另建 ${dedicated_name}；LS-176）" >&2
        warn_runtime_mismatch "$udid" "$(printf '%s' "$reuse" | cut -f1)"   # LS-205
      else
        udid=$(create_dedicated) || udid=
      fi
    fi
  fi
  [ -n "$udid" ] || udid=$shared_udid   # 找不到／建立失敗／強制共用：直接回共用第一台，序列化交給呼叫端
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
