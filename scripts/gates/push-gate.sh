#!/bin/bash
# Push gate（pre-push）：目標 ref 分類（刪除／tag 早退；test／main 只准 promote.sh 的 FF 晉升）+ 全 repo lint + unit tests +
# API 契約／錯誤碼對帳 + migration 版本號撞號／分級。規約見 docs/COLLABORATION.md §4。
set -euo pipefail

# LS-73：pre-push hook 由 git 啟動時會 export GIT_DIR／GIT_WORK_TREE／GIT_INDEX_FILE（linked worktree 指向
# .git/worktrees/<n>）。xcodebuild 內嵌的 SPM 用 git 操作相依套件 mirror 時會繼承它們，跑去本 repo 找套件的
# tree → 「fatal: unable to read tree <sha>」（LS-46 merge 帶進新相依時 100% 重現；先前被誤判為 SPM 瞬斷）。
# 在任何 git／xcodebuild 呼叫前一律清掉；本腳本自己的 git 指令以 cwd 為準不受影響。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

cd "$(git rev-parse --show-toplevel)"

# 0) 目標 ref 分類（LS-85 G4／LS-87 G4；scripts/gates/push-ref-check.sh 讀 pre-push 的 stdin）：
#    刪除分支／tag → 沒有要驗的內容，早退（29 條分支刪除與 2 個 tag 各跑了整套 gate）；目標 test／main → 只准
#    scripts/ops/promote.sh（PROMOTE_VIA_SCRIPT=1）且 fast-forward，否則擋；通過也早退——被推的是 origin/<from> 的 SHA，
#    check 由 promote.sh 與 GitHub required checks 驗，本機 lint／tests 跑的是當前 worktree、與它無關。
#    stdin 是 tty（手動執行）或空 → 維持既有：跑完整 gate。
if [ ! -t 0 ]; then
  rc=0; bash "$(git rev-parse --show-toplevel)/scripts/gates/push-ref-check.sh" || rc=$?
  case "$rc" in
    0) ;;
    3) echo "✓ push gate：本次 push 無需完整 gate（刪除／tag／promote.sh 的 FF 晉升）"; exit 0 ;;
    *) exit "$rc" ;;
  esac
fi

# 1) SwiftLint（有 Swift 檔才要求；有檔沒工具 → fail loud）
if [ -n "$(git ls-files '*.swift')" ]; then
  if ! command -v swiftlint >/dev/null 2>&1; then
    echo "✗ push gate：repo 內有 Swift 檔但未安裝 SwiftLint（brew install swiftlint）。" >&2
    exit 1
  fi
  swiftlint lint --strict --quiet
fi

# 2) Unit tests（Xcode 專案存在才跑；Phase 0 建專案時如 scheme 不同請更新此處與 CI）
XCODE_SCHEME="${XCODE_SCHEME:-LittleSprout}"
if ls -d ./*.xcodeproj >/dev/null 2>&1 || ls -d ./*.xcworkspace >/dev/null 2>&1; then
  dest=$(bash "$(git rev-parse --show-toplevel)/scripts/gates/detect-simulator.sh") || {
    echo "✗ push gate：模擬器偵測失敗。" >&2
    exit 1
  }
  # LS-83 R2 F1：真正會併發撞台的是「執行 xcodebuild test」這一段，不是 detect-simulator.sh 印字那幾行
  # （R1 把鎖包在那裡等於沒鎖——鎖早釋放了，兩個 worktree 退回共用機時 xcodebuild 照樣同時打上去）。
  # 以 destination 帶的 UDID 為鍵包住整段 xcodebuild test：專屬機彼此 UDID 不同、鎖從不競爭；
  # 退回共用第一台時多個 worktree 才會真的排隊序列跑。
  sim_udid=$(printf '%s' "$dest" | sed -n 's/.*id=//p')
  [ -n "$sim_udid" ] || { echo "✗ push gate：解不出 destination 的 UDID（${dest}）。" >&2; exit 1; }
  # LS-100：模擬器用完必關——不論下面的 test 跑成功、跑失敗、或整支 push gate 途中被中斷，都要關掉這次
  # 用到的模擬器；機器空跑浪費資源，也會讓下一個 agent／patrol.sh 誤判「已有人在用」。用 EXIT trap 做
  # （涵蓋失敗：set -e 觸發的 exit 一樣算 EXIT，且涵蓋腳本本身之後任何一步失敗）；INT／TERM 另外顯式
  # trap 成 `exit <code>`——同 scripts/ops/simulator-lock.sh 檔頭理由，訊號不保證會讓還在等前景指令的
  # bash 立刻觸發 EXIT trap，顯式接成 exit 才可靠。KEEP_SIMULATOR=1 可跳過（除錯時想留著看畫面）。
  if [ "${KEEP_SIMULATOR:-0}" != 1 ]; then
    trap 'xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  # LS-56：fresh worktree 首次 SPM 解析偶發瞬斷（xcodebuild「Could not resolve package
  # dependencies / Couldn't check out revision」，重跑即過——LS-54 back-merge 實測）。先單獨
  # 解析一次、失敗隔 10 秒再重試一次：LS-56 自己的首次 push 實測「立刻重試」3 秒後仍紅、
  # 隔一陣子再跑就綠，所以退避要有；解析步驟很快，不必把整套 test 重跑（也不會順手蓋掉
  # 真正的測試 flaky）。重試那次不帶 -quiet，再紅時才看得到是哪個 package 為什麼 checkout 失敗。
  if ! xcodebuild -resolvePackageDependencies -scheme "$XCODE_SCHEME" -quiet; then
    echo "⚠ push gate：SPM 解析失敗，10 秒後重試一次…" >&2
    sleep 10
    xcodebuild -resolvePackageDependencies -scheme "$XCODE_SCHEME"
  fi
  echo "→ push gate：執行 unit tests（scheme: ${XCODE_SCHEME}, destination: ${dest}）…"
  # LS-54 N8：與 CI 一致，明確序列執行（MockURLProtocol 全域 handler 不可平行）
  # LS-83 R2 F1：整段包進 simulator-lock.sh，鍵＝目的地 UDID（scripts/ops/simulator-lock.sh 檔頭注解）
  bash "$(git rev-parse --show-toplevel)/scripts/ops/simulator-lock.sh" --dir "/tmp/simulator-lock-${sim_udid}" -- \
    xcodebuild test \
    -scheme "$XCODE_SCHEME" \
    -destination "$dest" \
    -parallel-testing-enabled NO \
    -quiet
else
  echo "⚠ push gate：尚未建立 Xcode 專案，跳過 unit tests（Phase 0-1 完成後自動生效）"
fi

# 3) API 契約對帳（docs/API.md ↔ supabase/migrations，LS-41）：有 migrations 才跑。
#    本機固定用文字模式（best-effort，不需要活資料庫）；CI 的 db job 另外用
#    --catalog 模式對套用完 migrations 的活資料庫做權威對帳（PR #58 review）。
if [ -d supabase/migrations ]; then
  bash "$(git rev-parse --show-toplevel)/scripts/gates/api-contract-check.sh"
fi

# 4) 錯誤碼三方對帳（docs/API.md §5 ↔ LSErrorCode ↔ migrations errcode，LS-54／LS-56）：
#    無條件跑——三個來源任一搬家就直接紅，逼著同 PR 更新這裡與 CI 的路徑，不靜默跳過。
bash "$(git rev-parse --show-toplevel)/scripts/gates/error-codes-check.sh"

# 5) Migration 分級（LS-53）：對「本分支相對 base 的 migrations 新增行」跑
#    scripts/gates/migration-breaking-check.sh（規則表見該檔檔頭）。PR body 標記（核可標記／
#    BREAKING: 段落）只有 CI 看得到，這裡只印分級提醒；但 BREAKING 要求的「docs/API.md 同 PR 有變更」
#    本機就驗得到，直接擋，省一趟 CI 來回。base：hotfix/* 對 origin/main，其餘對 origin/development
#    （fetch 過才準；找不到 base ref 直接紅，不靜默跳過）。保護分支與 detached HEAD 不做——
#    沒有「相對 base 的變更」可言。
if [ -d supabase/migrations ]; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
  case "$branch" in
    main|test|development|DETACHED) ;;
    *)
      case "$branch" in hotfix/*) base_ref=origin/main ;; *) base_ref=origin/development ;; esac
      if ! git rev-parse -q --verify "$base_ref" >/dev/null; then
        echo "✗ push gate：找不到 ${base_ref}（先 git fetch origin），無法做 migration 分級。" >&2
        exit 1
      fi
      # 4b) Migration 版本號撞號（LS-70）：本分支 tree 內版本號唯一、且不與 base_ref 既有版本撞號（同版本、
      #     不同檔名——LS-57／LS-66 同取 20260825030000，先併的把後併的擠掉）。放在分級之前：撞號的檔連套用
      #     順序都未定義，分級沒有意義。對 base 當前 tip 比、不是 merge-base（撞號正是別張票先併進去）；
      #     CI Migration rules step 對 origin/$BASE 再驗一次（伺服器端兜底）。
      bash "$(git rev-parse --show-toplevel)/scripts/gates/migration-version-check.sh" --target "$base_ref"
      base_sha=$(git merge-base "$base_ref" HEAD)
      findings=$(bash "$(git rev-parse --show-toplevel)/scripts/gates/migration-breaking-check.sh" --base "$base_sha")
      if printf '%s\n' "$findings" | grep -q '^DESTRUCTIVE'; then
        echo "⚠ push gate：migration 含 DESTRUCTIVE 敘述——PR body 需使用者本人蓋核可標記，CI 會擋（COLLABORATION §6）：" >&2
        printf '%s\n' "$findings" | grep '^DESTRUCTIVE' | sed 's/^/    /' >&2
      fi
      if printf '%s\n' "$findings" | grep -q '^BREAKING'; then
        echo "⚠ push gate：migration 含 BREAKING 敘述——PR body 需行首 BREAKING: 段落，CI 會擋（COLLABORATION §6）：" >&2
        printf '%s\n' "$findings" | grep '^BREAKING' | sed 's/^/    /' >&2
        if [ -z "$(git diff --name-only "$base_sha"...HEAD -- docs/API.md)" ]; then
          echo "✗ push gate：migration 被判 BREAKING 但本分支沒動 docs/API.md——契約文件須同 PR 更新（COLLABORATION §6）。" >&2
          exit 1
        fi
      fi
      ;;
  esac
fi

# 6) 分支起點乾淨度（LS-50）：工作分支自 merge-base 以來的每個非 merge commit，subject 票號必須等於分支票號
#    （scripts/gates/branch-ticket-check.sh，規則與逃生口見該檔檔頭）——LS-38 分支疊了 LS-31 三個從未開 PR 的
#    commit 而沒有任何 gate 攔到。刻意夾帶：本票 commit body 獨佔一行 `Bundles: LS-<m>`，PR body 同步宣告（CI 驗）。
# 7) 合併衝突預檢（LS-50，PR #77 事件）：`git merge-tree --write-tree origin/<target> HEAD` 有衝突即擋
#    （scripts/gates/merge-conflict-check.sh；本機 origin/<target> 落後遠端也擋，先 fetch）。GitHub 對不可合併的
#    PR 不觸發 pull_request workflow——CI 零紀錄、沒有任何機械訊號，這一關只有本機 push 前做得到。
# 兩步共用第 5 步的方向矩陣（hotfix/* 對 origin/main，其餘對 origin/development）；保護分支與 detached HEAD
# 跳過；找不到 origin/<target> 由腳本直接紅，不靜默跳過。
branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
case "$branch" in
  main|test|development|DETACHED) ;;
  *)
    case "$branch" in hotfix/*) target_ref=origin/main ;; *) target_ref=origin/development ;; esac
    bash "$(git rev-parse --show-toplevel)/scripts/gates/branch-ticket-check.sh" --base "$target_ref"
    bash "$(git rev-parse --show-toplevel)/scripts/gates/merge-conflict-check.sh" --target "$target_ref"
    ;;
esac

echo "✓ push gate 通過"
