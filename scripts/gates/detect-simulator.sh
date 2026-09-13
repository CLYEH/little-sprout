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

# LS-260（LS-96 池項 `1b7a0d5d`）：$1＝釘住版；印出「同一個 major 裡最接近釘住版的已安裝 runtime」
# ——優先 ≥ 釘住版裡最小的那個，沒有更新的才取同 major 裡最新的（兩段式選法同
# `pick-ipad-runtime.sh`，LS-211 I-b 已驗證過的形狀）；同 major 一個都沒有就印空字串，呼叫端退回
# `header_os`（LS-83 原行為）。版本比較走零填補的 key，不做字串比較（26.10 > 26.9）。
nearest_same_major_runtime() {
  xcrun simctl list runtimes 2>/dev/null | awk -v pin="$1" '
    function verkey(v,   n, a, i, key) {
      n = split(v, a, ".")
      key = ""
      for (i = 1; i <= 4; i++) key = key sprintf("%06d.", (i <= n ? a[i] + 0 : 0))
      return key
    }
    BEGIN { pk = verkey(pin); split(pin, qv, ".") }
    /^iOS / {
      v = $2
      split(v, pv, ".")
      if (pv[1] + 0 != qv[1] + 0) next
      k = verkey(v)
      if (k >= pk) { if (ge_k == "" || k < ge_k) { ge_k = k; ge = v } }
      else         { if (lt_k == "" || k > lt_k) { lt_k = k; lt = v } }
    }
    END {
      if (ge != "") { print ge; exit }
      if (lt != "") { print lt }
    }
  '
}

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

find_udid_same_ticket() {   # LS-176：同票（名稱 `<票號>-` 開頭）、同「有效目標 runtime」（`target_os`，
  # LS-205 R2 起與 create_dedicated() 共用同一個解析結果——見上方定義，不再各自各算）分節的第一台可用
  # 裝置，印 "name\tudid"
  # 同票專屬機的機型可能跟現在「清單第一台原廠機」不同（原廠機被刪／重建、Xcode 升級換了預設機型後 name 就變了），
  # 舊版只認精確名稱 `<票號>-<機型無空白>`，找不到就再建一台——LS-107 因此堆到 4 台（LS-96 池項 7c9fe5bd (c)）。
  # 單元測試不挑機型，同 runtime 的既有專屬機直接重用；**不同 runtime 的不重用**（舊 runtime 可能跑不了目前的
  # deployment target），那一種仍走 create_dedicated。同 find_udid_by_name 只看「可用」裝置。
  xcrun simctl list devices available 2>/dev/null | awk -v pfx="${ticket}-" -v os="$target_os" '
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
  local devicetype_id runtime_id created avail
  devicetype_id=$(xcrun simctl list devicetypes 2>/dev/null | grep -F "${name} (" \
    | sed -E 's/.*\(([^()]+)\)[[:space:]]*$/\1/' | head -1)
  # LS-205 R2：建在共用的 `target_os`（上方已算好——優先釘住版，本機沒裝該版時已挑同 major 最接近者）。
  # LS-260：「本機沒有釘住版」的 ⚠ 從這裡搬到 `target_os` 解析處印一次——重用既有專屬機那條路徑
  # 根本不會走到 create_dedicated()，警告掛在這裡等於一整類呼叫都看不到（正是 LS-246 的情形）。
  runtime_id=$(xcrun simctl list runtimes 2>/dev/null | grep -m1 "^iOS ${target_os} " \
    | sed -E 's/.* - (com\.apple\.[^[:space:]]+)[[:space:]]*$/\1/')
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
  # ---- LS-205 R2（merge-review R1 M2；merge-review R2 b907173c n1 移到這裡才算）：「有效目標 runtime」
  #      只在這裡算一次，find_udid_same_ticket() 與 create_dedicated() 共用同一個值——原本兩處各自各算
  #      （前者比 header_os、後者建在 pinned_os），一旦釘住版在本機生效，用它建出來的機器就落在
  #      target_os≠header_os 的分節，下一次呼叫的「同票重用」判斷（比 header_os）永遠看不到那台既有機，
  #      同票就會不斷堆出新機（LS-107 的舊坑、LS-176 要防的正是這個）。優先 pinned_os，本機真的裝得到
  #      （`simctl list runtimes` 命中）才採用；沒有釘住或本機沒裝該版就退回 header_os（原 LS-83 行為，
  #      fail-open）。CI=true 分支完全用不到這個值卻原本無條件算過一次（多一次 xcrun simctl list runtimes），
  #      挪到這個 else 分支裡才算——CI 分支的呼叫點不再付這個成本。
  #      LS-260（LS-96 池項 `1b7a0d5d`，orchestrator 09-14 裁決——覆寫票文字面的「缺 runtime 就
  #      exit 非 0」）：釘住版本機沒裝時不再直接退回 `header_os`（＝清單第一台原廠機的分節，實務上
  #      常是**最舊**的那個 runtime——LS-246 正是本機 26.0 對 CI 26.2，iOS 26.2 特有的
  #      `AVPlayerViewController` 自動收起在本機重現不出，fix 多花約一小時），改成先挑同一個 major
  #      裡最接近釘住版的已裝 runtime（`nearest_same_major_runtime`），同 major 一個都沒有才退回
  #      `header_os`。仍然 fail-open、不擋：iOS 26.2 runtime Apple 已不提供下載（LS-261 實測、LS-253
  #      前幾支 agent 同樣撞到），擋下去等於本機完全跑不了 UITest；改成每次都把差異印在 stderr，
  #      派工單／handoff 依此揭露。
  target_os="$header_os"
  if [ -n "$pinned_os" ]; then
    picked_os=$(nearest_same_major_runtime "$pinned_os")
    [ -n "$picked_os" ] && target_os="$picked_os"
    if [ "$target_os" != "$pinned_os" ]; then
      # LS-260 R2 B1：串接用 awk，**不可**用 `paste -sd '、' -`——`paste -d` 的分隔字串在 GNU
      # coreutils 是逐「位元組」取用，3 bytes 的 `、` 在 Linux 只會吐出第一個位元組（U+FFFD），
      # macOS 的 BSD paste 才會整個字元輸出。本機（BSD）綠、CI `rules` job（ubuntu）紅，正是本票
      # 項 3 要消滅的那種形狀。實測 `printf 'iOS 26.0\niOS 26.5\n'` 經本行：BSD 與 ubuntu:24.04
      # 皆輸出同樣 12 bytes（`26.0` ＋ `343 200 201` ＋ `26.5` ＋ `\n`）；空輸入兩邊皆空輸出。
      avail=$(xcrun simctl list runtimes 2>/dev/null | awk '/^iOS /{printf "%s%s", (n++ ? "、" : ""), $2} END{if (n) print ""}')
      # LS-260 R2 m3（merge-review R1）：這裡印的 `target_os` 是「這次**要建**的 runtime」，重用既有
      # 專屬機時實際跑的是那台機器自己的版本（可能更舊，由下方 `warn_runtime_mismatch` 另行點名）。
      # 照抄這一行寫進 handoff 會揭露錯的版本——權威來源是 `push-gate.sh` 取自實機的
      # `simulator: <name> <udid> iOS <ver>（pinned <ver>）`，所以這裡明講「新建時」並指去那一行。
      echo "⚠ detect-simulator：runtime ${target_os} ≠ 釘住 ${pinned_os}（本機無 ${pinned_os}；派工單／handoff 須揭露）——本機可用 iOS：${avail:-無}；${target_os} 是**新建專屬機**時採用的版本，重用既有機時以 push-gate 印的 \`simulator: … iOS <ver>\` 為準；CI 跑 iOS ${pinned_os}，本機重現不出 CI 紅時先懷疑 runtime 差（LS-260）" >&2
    fi
  fi
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
        echo "→ detect-simulator：重用同票既有專屬機「$(printf '%s' "$reuse" | cut -f1)」（同 runtime iOS ${target_os}，不另建 ${dedicated_name}；LS-176）" >&2
        warn_runtime_mismatch "$udid" "$(printf '%s' "$reuse" | cut -f1)"   # LS-205
      else
        udid=$(create_dedicated) || udid=
      fi
    fi
  fi
  [ -n "$udid" ] || udid=$shared_udid   # 找不到／建立失敗／強制共用：直接回共用第一台，序列化交給呼叫端

  # LS-236：回傳這顆 UDID 前確認沒有殘留的 xcodebuild 還在跑（同 push-gate.sh 對 sim_udid 那段理由；
  # 保護直接呼叫本腳本、自己另外跑 xcodebuild 的呼叫端——如 CI workflow 之外未來可能新增的呼叫點——
  # push-gate.sh 自己在拿到這裡回傳的 UDID 之後還會再做一次同款檢查，屬刻意的雙重防線，不衝突）。
  # 帶上呼叫端接下來會用的鎖目錄（同 push-gate.sh 的預設慣例 `/tmp/simulator-lock-<udid>`，可用
  # SIMULATOR_LOCK_DIR 覆寫，同一份環境變數兩邊共用同一個值）——命中的若是另一個持鎖中的合法呼叫
  # （常見於退回共用第一台、多個 worktree 排隊的情境），放行、不誤判為殘留（同 test ⑧ 的重現理由）。
  # CI（`CI=true`）分支不查：GitHub Actions 每個 job 跑在獨立 VM，沒有跨 job 殘留可言。
  # `set -uo pipefail` 沒有 `-e`，非 0 需自己傳遞。
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stale-xcodebuild-check.sh" "$udid" "${SIMULATOR_LOCK_DIR:-/tmp/simulator-lock-${udid}}" || exit $?
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
