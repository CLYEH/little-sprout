#!/bin/bash
# Push gate（pre-push）：目標 ref 分類（刪除／tag 早退；test／main 只准 promote.sh 的 FF 晉升）+ 全 repo lint +
# API 契約／錯誤碼對帳 + migration 版本號撞號／分級 + unit tests（LS-65：秒級便宜檢查前移到 xcodebuild 之前執行）。
# 規約見 docs/COLLABORATION.md §4。
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

# 0b) 純文件變更偵測（LS-76）：純文件／harness 設定的 PR 也會跑到第 1／2 步（SwiftLint／xcodebuild
#     test），沒有 Swift 檔可 lint、也沒有任何行為受影響，卻一樣要吃模擬器 flake（PR #113 R1 push 案例：
#     一行文件變更被模擬器啟動 app 失敗擋下，重推即過）。判定本分支相對 target 的 diff 是否含
#     LittleSprout/、LittleSproutTests/、project.yml、*.xcodeproj、Package.resolved、.swiftlint.yml、
#     *.xcconfig、.xcode-version——皆無才跳過第 1／2 步；CI 的 ci job 不受影響（仍無條件全跑，這裡只省
#     本機時間，不動 CI 那道強制層）。方向矩陣與下面第 5／7 步一致（hotfix/* 對 origin/main，其餘對
#     origin/development）；保護分支（main/test/development）與 detached HEAD 沒有自然的「相對 target」
#     概念，維持原行為（不跳過，兩步照跑）。target ref 不存在（未 fetch）時同樣不跳過——這只是本機最佳化，
#     抓不到就退回原行為，不新增一個「找不到 ref」的失敗模式（與第 5／7 步刻意 fail-closed 不同：那兩步
#     是正確性把關，這裡只是省時間）。
#     R1 F1（major）：allowlist 原漏 `Config/*.xcconfig`——`project.yml` 的 configFiles 對 Debug/Release
#     都指向 `Config/Base.xcconfig`，注入 SUPABASE_URL／ANON_KEY 等 build settings，格式錯會讓 AppConfig
#     的 precondition 在啟動時崩潰（LS-49）；xcconfig 內容不寫進 pbxproj，只改它的 PR 不會命中
#     `.xcodeproj`／`project.yml`，若不單獨列出會被誤判「無變更」而跳過本機 build/test——該跑卻跳，是本
#     機制唯一該避免的 unsafe 方向。R1 F2（minor）：`.xcode-version` 同理補上，避免只改它時連帶跳過 1b
#     工具鏈對齊步。LS-95 merge-review R1 m2：`(^|/)LittleSprout/` 只匹配「LittleSprout/」這個精確路徑
#     片段，不會匹配 `LittleSproutUITests/`（同名前綴、不同資料夾）——只改該目錄下既有 Swift 檔會被誤判
#     「無變更」而跳過本機 SwiftLint／unit tests／tap-target 三步，是同一種「該跑卻跳」的 unsafe 方向，
#     單獨補上。
skip_swift_steps=0
diff_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
case "$diff_branch" in
  main|test|development|DETACHED) ;;
  *)
    case "$diff_branch" in hotfix/*) diff_target_ref=origin/main ;; *) diff_target_ref=origin/development ;; esac
    if git rev-parse -q --verify "$diff_target_ref" >/dev/null; then
      diff_changed=$(git diff --name-only "$diff_target_ref"...HEAD)
      if ! printf '%s\n' "$diff_changed" | grep -qE '(^|/)LittleSprout/|(^|/)LittleSproutTests/|(^|/)LittleSproutUITests/|(^|/)project\.yml$|\.xcodeproj(/|$)|(^|/)Package\.resolved$|(^|/)\.swiftlint\.yml$|(^|/)Config/.*\.xcconfig$|(^|/)\.xcode-version$'; then
        skip_swift_steps=1
      fi
    fi
    ;;
esac

# 1) SwiftLint（有 Swift 檔才要求；有檔沒工具 → fail loud；LS-76：無 Swift／專案檔變更則跳過）
if [ -n "$(git ls-files '*.swift')" ]; then
  if [ "$skip_swift_steps" = 1 ]; then
    echo "→ push gate：無 Swift 變更，跳過 SwiftLint（CI 仍跑）"
  else
    if ! command -v swiftlint >/dev/null 2>&1; then
      echo "✗ push gate：repo 內有 Swift 檔但未安裝 SwiftLint（brew install swiftlint）。" >&2
      exit 1
    fi
    swiftlint lint --strict --quiet
  fi
fi

# scheme 名稱：1b／2 兩步都要用，提到最前面單一定義（Phase 0 建專案時如 scheme 不同請更新此處與 CI）
XCODE_SCHEME="${XCODE_SCHEME:-LittleSprout}"

# 1a) XcodeGen 漂移檢查（project.yml ↔ .xcodeproj；LS-106，前移到 xcodebuild 之前——同 LS-65
#     劃定的位置，便宜檢查排在昂貴的 xcodebuild 之前）。PR #165 head 4a3bfa9：commit 的 project.pbxproj
#     不是乾淨 xcodegen generate 產物（新檔 GUID 不同），本機兩次綠、CI 才紅——本機從未有一關會跑這個檢查。
#     比對「暫存目錄剛產生出來那份 .xcodeproj 的檔案集合」逐檔對 repo 側同路徑（R1 F1：舊版只比
#     project.pbxproj，漏掉 project.xcworkspace/xcshareddata、xcshareddata/xcschemes/*.xcscheme
#     這類同樣是 xcodegen 產物、CI 也會比對的檔案——實測改 project.yml 的 parallelizable 設定不
#     重跑 xcodegen，只有 .xcscheme 變、pbxproj 不變，本機因此漏放）。以「新產生側」的檔案集合為
#     準天然不含 project.xcworkspace/xcshareddata/swiftpm/**／Package.resolved（xcodebuild 解析
#     SPM 時才寫入、不是 xcodegen 產物，新產生的專案不會有這些檔案），不會像整目錄比對那樣假紅。
#     暫存目錄不能直接指到系統 tmp——xcodegen 以 spec 所在目錄為基準輸出**相對**路徑、且不解析
#     symlink（R1 I1 校正：與暫存目錄跟 repo 根的絕對深度是否一致無關，先前的說法把「輸出相對
#     路徑」的成因誤記成「深度需一致」）。解法：在暫存目錄內用符號連結鏡射 repo 根的每個項目
#     （排除 .git 與既有的 LittleSprout.xcodeproj——後者若被連結，xcodegen 寫入時會直接透過
#     符號連結覆寫到真正的專案，等於這個唯讀檢查偷偷改了工作目錄），讓 xcodegen 在暫存目錄內
#     產生時看到的相對路徑與 repo 根一致（本票實測：鏡射後的 project.pbxproj 與 repo 根生成的
#     版本逐位元組相同）。
if [ -f project.yml ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "✗ push gate：repo 內有 project.yml 但未安裝 xcodegen（brew install xcodegen）。" >&2
    exit 1
  fi
  # CI 用 `brew install xcodegen` 裝當下最新版、未鎖版號，沒有固定值可比對——只印本機版本供人判斷，
  # 不擋（版本差異若真的造成產物不同，會直接反映在下面的 diff 結果上）。
  echo "→ push gate：本機 xcodegen（$(xcodegen --version 2>/dev/null | tr '\n' ' ')）；CI 以 brew install xcodegen 裝當下最新版、未鎖版號，可能不同" >&2
  xg_work=$(mktemp -d)
  # R1 I5：ln -s 中途失敗（set -e）或 Ctrl-C 時暫存目錄先前不會被清掉——trap 一設好就涵蓋接下來
  # 所有離開路徑；成功路徑結尾用 `trap - EXIT` 收掉，讓後面 section 2 的模擬器 shutdown trap
  # 可以乾淨接手同一個 EXIT slot（此時 xg_work 已經 rm -rf 過，即使沒清掉 trap 也只是多一次
  # 對已不存在目錄的 no-op rm -rf，不會有副作用）。
  trap 'rm -rf "$xg_work"' EXIT
  xg_repo_root="$(pwd)"
  for xg_entry in "$xg_repo_root"/* "$xg_repo_root"/.[!.]*; do
    [ -e "$xg_entry" ] || continue
    xg_base=$(basename "$xg_entry")
    case "$xg_base" in
      .git|LittleSprout.xcodeproj) continue ;;
    esac
    ln -s "$xg_entry" "$xg_work/$xg_base"
  done
  if ! (cd "$xg_work" && xcodegen generate --spec project.yml --project . -q); then
    echo "✗ push gate：xcodegen generate 失敗（漂移檢查）。" >&2
    exit 1
  fi
  # R1 F1：走訪暫存目錄剛產生出來的 .xcodeproj 裡的每個檔案，逐一與 repo 版比對（不是固定只比
  # project.pbxproj）——「新產生側」的檔案集合天生不含 CI 也不比的 swiftpm/**，不會假紅。
  xg_diff_files=""
  while IFS= read -r xg_rel; do
    [ -n "$xg_rel" ] || continue
    if ! diff -q "$xg_work/LittleSprout.xcodeproj/$xg_rel" "LittleSprout.xcodeproj/$xg_rel" >/dev/null 2>&1; then
      xg_diff_files="${xg_diff_files}${xg_rel}
"
    fi
  done < <(cd "$xg_work/LittleSprout.xcodeproj" && find . -type f | sed 's#^\./##')
  if [ -n "$xg_diff_files" ]; then
    # R1 F4：擋下時列出差異檔＋diff 摘要（不再丟 /dev/null），並提示未追蹤 .swift 檔這個常見誤擋
    # 成因（xcodegen 掃工作目錄，CI checkout 只有 tracked 檔——未追蹤的 .swift 會讓 pbxproj 改變、
    # 本機因此紅、CI 卻是綠）。
    echo "✗ push gate：project.yml 與 LittleSprout.xcodeproj 不同步——改 project.yml 後須重跑 xcodegen generate 一併 commit；若是在 Xcode GUI 改了設定，請把改動搬回 project.yml；有未追蹤／未 commit 的 Swift 檔也會造成這個結果（xcodegen 掃工作目錄、CI 只看 tracked 檔），請先 git add 或刪除" >&2
    echo "  差異檔：" >&2
    printf '%s' "$xg_diff_files" | sed 's/^/    /' >&2
    printf '%s' "$xg_diff_files" | while IFS= read -r xg_rel; do
      [ -n "$xg_rel" ] || continue
      echo "  --- ${xg_rel} ---" >&2
      diff -u "LittleSprout.xcodeproj/$xg_rel" "$xg_work/LittleSprout.xcodeproj/$xg_rel" 2>&1 | head -n 20 >&2
    done
    exit 1
  fi
  trap - EXIT
  rm -rf "$xg_work"
fi

# 3) API 契約對帳（docs/API.md ↔ supabase/migrations，LS-41）：有 migrations 才跑。
#    本機固定用文字模式（best-effort，不需要活資料庫）；CI 的 db job 另外用
#    --catalog 模式對套用完 migrations 的活資料庫做權威對帳（PR #58 review）。
#    LS-65：步驟 3／3b／4／5／6／7（本組秒級便宜檢查）前移到步驟 2（xcodebuild，分鐘級）之前——
#    原順序 1→2→3→4→5→6→7，改為 1→3→4→5→6→7→2；不衝突／不撞號才值得等測試跑完，衝突或票號
#    錯不必等數分鐘的 xcodebuild 才被擋（LS-50 PR #90 review I6）。步驟編號不變，只動物理順序。
if [ -d supabase/migrations ]; then
  bash "$(git rev-parse --show-toplevel)/scripts/gates/api-contract-check.sh"
fi

# 3b) 點擊目標畫面覆蓋對帳（LS-95 M1，merge-review R1）：純文字比對 Features/**/*View.swift
#     對 TapTargetGateScreenName／tap-target-exemptions.txt，不需要 Xcode／模擬器，無條件跑
#     （有 Features 目錄才跑——Phase 0-1 完成前這個目錄不存在）。跟第 2 步的 Features/ diff
#     判斷不同：那個是「這次要不要跑 XCUITest 量測」，這個是「畫面清單本身有沒有被靜默漏掉」，
#     兩者互補、不能互相取代。
if [ -d LittleSprout/Features ]; then
  bash "$(git rev-parse --show-toplevel)/scripts/gates/tap-target-registry-check.sh"
fi

# 4) 錯誤碼三方對帳（docs/API.md §5 ↔ LSErrorCode ↔ migrations errcode，LS-54／LS-56）：
#    無條件跑——三個來源任一搬家就直接紅，逼著同 PR 更新這裡與 CI 的路徑，不靜默跳過。
bash "$(git rev-parse --show-toplevel)/scripts/gates/error-codes-check.sh"

# 5) Migration 分級（LS-53）：對「本分支相對 base 的 migrations 新增行」跑
#    scripts/gates/migration-breaking-check.sh（規則表見該檔檔頭）。PR 上的標記（核可標記——使用者本人的
#    PR comment 或 body，LS-123；BREAKING: 段落）只有 CI 看得到，這裡只印分級提醒；但 BREAKING 要求的「docs/API.md 同 PR 有變更」
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
      # 4c) 已併入 base 的 migration 檔不可變（LS-80）：擋在分級之前——已被悄悄改掉內容的檔，分級／覆寫
      #     判斷都沒有意義。本機沒有 PR body 可驗，只驗 commit body 的逃生口宣告；CI Migration rules
      #     step 另外對 PR body／使用者本人 PR comment 再驗一次（伺服器端兜底，逃生口使用必須在 PR 可見；LS-123）。
      bash "$(git rev-parse --show-toplevel)/scripts/gates/migration-immutable-check.sh" --base "$base_ref"
      base_sha=$(git merge-base "$base_ref" HEAD)
      findings=$(bash "$(git rev-parse --show-toplevel)/scripts/gates/migration-breaking-check.sh" --base "$base_sha")
      if printf '%s\n' "$findings" | grep -q '^DESTRUCTIVE'; then
        echo "⚠ push gate：migration 含 DESTRUCTIVE 敘述——需使用者本人在 PR 留 comment 獨佔一行 DESTRUCTIVE-APPROVED（建議；PR body 亦可），CI 會擋（COLLABORATION §6，LS-123）：" >&2
        printf '%s\n' "$findings" | grep '^DESTRUCTIVE' | sed 's/^/    /' >&2
      fi
      if printf '%s\n' "$findings" | grep -q '^BREAKING'; then
        echo "⚠ push gate：migration 含 BREAKING 敘述——PR body 需行首 BREAKING: 段落，CI 會擋（COLLABORATION §6）；enum 加值（B7）另列 ENUM／CONSUMER 行，每個 CONSUMER 路徑都要在該段交代處置（LS-181）：" >&2
        printf '%s\n' "$findings" | grep -E '^(BREAKING|ENUM|CONSUMER)' | sed 's/^/    /' >&2
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

# 2) Unit tests（Xcode 專案存在才跑；Phase 0 建專案時如 scheme 不同請更新此處與 CI；LS-76：無 Swift／
#    專案檔變更則跳過整段——省純文件 harness PR 吃模擬器 flake 的成本，CI 的 ci job 不受影響仍全跑）
#    LS-65：本步驟（xcodebuild，分鐘級）移到步驟 3／3b／4／5／6／7（秒級便宜檢查）之後執行，
#    理由與位置見上方步驟 3 註記。
if [ "$skip_swift_steps" = 1 ]; then
  echo "✓ push gate：無 Swift 變更，跳過 unit tests（CI 仍跑）"
elif ls -d ./*.xcodeproj >/dev/null 2>&1 || ls -d ./*.xcworkspace >/dev/null 2>&1; then
  # 1b) Xcode 版本對齊（LS-106 R1 F2／F5；PR #165 head 8b7a0fa 同型：8b7a0fa 已修好 1a 的 xcodegen
  #     漂移，但 KeyboardHeightObserver.swift 仍留著 UIScreen.main.bounds，CI 用 .xcode-version
  #     釘住的 Xcode／SDK 對它的 MainActor 隔離判斷較嚴格判成編譯錯，本機當時裝的版本較寬鬆沒
  #     攔到——本機兩次綠、CI 才紅）。`.xcode-version` 是本機與 CI 共用的單一來源
  #     （`.github/workflows/ci.yml` 的 `ci` job 第一步 xcode-select 無條件讀它，缺檔直接紅）；
  #     本機比照 fail-closed，不再靜默略過整段（R1 F5）。
  #     舊版「版本不一致→額外跑一次 SWIFT_STRICT_CONCURRENCY=complete 的 build」對本專案是
  #     no-op（R1 F2：project.pbxproj 兩個 build config 的 SWIFT_VERSION 已是 6.0，語言模式本身
  #     就隱含 complete 且是 error；`swiftc` 對照 v6／v6+complete／v5／v5+complete 四組診斷逐字
  #     相同）——那個旗標分不出「本機工具鏈」跟「CI 工具鏈」，等於每次 push 白付一次全量重編、
  #     診斷卻是零。真正能讓本機重現 CI 那個工具鏈的診斷嚴格度，只有真的換掉 xcodebuild 用的
  #     工具鏈：pin 的 Xcode 若本機有裝（預設 `/Applications/Xcode_<pin>.app`，可用
  #     XCODE_APPS_DIR 覆寫路徑；已經是目前 xcode-select 選定版本的情況會在下面比對時直接顯示
  #     一致，不需要另外接 DEVELOPER_DIR），整支 push-gate 剩下的 xcodebuild 呼叫（SPM 解析／
  #     test）全部改用它的 DEVELOPER_DIR——這才是真的讓「8b7a0fa 本機轉紅」成立的做法。沒裝就
  #     只印一行警告＋安裝指引，不再跑那個沒有意義的替代 build（R1 F3 隨之自然解——沒有
  #     build-only 步驟需要顧慮是否佔用以 UDID 為鍵的模擬器鎖）。
  if [ ! -f .xcode-version ]; then
    echo "✗ push gate：缺 .xcode-version，CI 會紅（ci job 的 xcode-select 步驟讀不到單一來源）。" >&2
    exit 1
  fi
  xcode_pin="$(tr -d '[:space:]' < .xcode-version)"
  xcode_apps_dir="${XCODE_APPS_DIR:-/Applications}"
  xcode_pinned_dev_dir="${xcode_apps_dir}/Xcode_${xcode_pin}.app/Contents/Developer"
  if [ -d "$xcode_pinned_dev_dir" ]; then
    export DEVELOPER_DIR="$xcode_pinned_dev_dir"
    echo "→ push gate：pin 的 Xcode ${xcode_pin}（${xcode_pinned_dev_dir}）本機已安裝，本次 push gate 剩下的 xcodebuild 全部改用此版本執行（與 CI 對齊）"
  else
    local_xcode_ver="$(xcodebuild -version | awk 'NR==1{print $2}')"
    if [ "$local_xcode_ver" != "$xcode_pin" ]; then
      echo "⚠ push gate：Xcode 主次版號不一致（本機 ${local_xcode_ver}／.xcode-version 指定 ${xcode_pin}），且本機未安裝 pin 版本（找不到 ${xcode_pinned_dev_dir}）——本機驗證的嚴格度可能與 CI 不同。可執行 \`xcodes install ${xcode_pin}\` 或至 https://developer.apple.com/download/all/ 下載安裝後再 push。" >&2
    else
      echo "→ push gate：Xcode 主次版號一致，略過對齊（本機／.xcode-version 皆 ${local_xcode_ver}）"
    fi
  fi

  # LS-205：`.ios-runtime` 是本機與 CI 共用的模擬器 runtime 單一來源（比照 `.xcode-version`
  # 同款 fail-closed——缺檔代表下面「印出 pinned 版本」這件事本身就做不到，CI 的對應步驟
  # 也讀不到，寧可本機先擋）。detect-simulator.sh 自己另外讀這個檔決定建機／既有機比對的
  # fail-open 邏輯（見該腳本），這裡只用來組出下面的可見化那一行。
  if [ ! -f .ios-runtime ]; then
    echo "✗ push gate：缺 .ios-runtime，CI 會紅（ci job 對應步驟讀不到單一來源；LS-205）。" >&2
    exit 1
  fi
  ios_runtime_pin="$(tr -d '[:space:]' < .ios-runtime)"

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
  #
  # PR #164 R1 F1：只關「本 worktree 專屬機」，不分青紅皂白關掉 detect-simulator.sh:125 退回的共用
  # 第一台——共用機路徑上多個 worktree 可能拿到同一顆 UDID，鎖只包住下面「執行 xcodebuild test」那
  # 一段，EXIT trap 原本要等本腳本剩下的第 3～7 步（真環境好幾秒）跑完才觸發，那時鎖早已釋放：A 跑完自己
  # 剩下的 gate、trap 觸發關機時，B 可能正拿著同一顆共用機在鎖內跑測試，會被 A 關掉（stub 重現的時間
  # 軸見 PR #164 R1 F1）。LS-65：第 3～7 步已前移到本步驟之前執行，trap 觸發前不再等它們——只剩下面
  # 視 diff 而定的 LS-95 點擊目標量測（未觸發時幾乎是鎖一釋放就觸發），窗口因此大幅縮小，但不是歸零
  # （仍可能與其他 worktree 的鎖持有時間重疊）；共用機不設 trap、以及下面「shutdown 前查鎖目錄是否仍
  # 在」這第二道防線都仍然必要，不能因為窗口縮小就拿掉。設 trap 前先查這顆 UDID 對應的裝置名稱，只有
  # 專屬機（`<票號>-<機型>`，含主 checkout 用的 `main-`）才設；共用機／R1 F2 提到的 demo-* 常駐機都落在下面 pattern 之外，不設
  # trap、不關。第二道防線：即使是專屬機，shutdown 前若鎖目錄仍在就跳過並印一行——不在 trap 內重新
  # 取鎖，中斷情境下持鎖的子行程可能還活著，重新取鎖會卡到 simulator-lock.sh 的 timeout（該腳本檔頭
  # 理由）。
  # I2：鎖目錄路徑可用 SIMULATOR_LOCK_DIR 覆寫（自測用；預設仍是 /tmp/simulator-lock-<udid>），讓多份
  # push-gate.test.sh 併行時各自用 mktemp -d 出來的路徑，不會互刪對方的鎖目錄。
  sim_lock_dir="${SIMULATOR_LOCK_DIR:-/tmp/simulator-lock-${sim_udid}}"
  # LS-205：名稱與所在 OS 分節一次查出來——下面「可見化」那行與 KEEP_SIMULATOR 判斷（原本各自
  # 查一次 sim_name）共用同一次 xcrun 呼叫，移到 KEEP_SIMULATOR 判斷之前變成無條件執行。
  sim_info=$(xcrun simctl list devices available 2>/dev/null | awk -v u="$sim_udid" '
    /^-- iOS / { os = $0; sub(/^-- iOS /, "", os); sub(/ --$/, "", os); next }
    { line = $0
      udid = line
      sub(/^[^(]*\(/, "", udid)
      sub(/\).*/, "", udid)
      if (udid != u) next
      nm = line
      sub(/^[ \t]*/, "", nm)
      sub(/ *\(.*/, "", nm)
      printf "%s\t%s", nm, os
      exit
    }
  ')
  sim_name=$(printf '%s' "$sim_info" | cut -f1)
  sim_ios_ver=$(printf '%s' "$sim_info" | cut -f2)
  echo "→ push gate：simulator: ${sim_name:-?} ${sim_udid} iOS ${sim_ios_ver:-?}（pinned ${ios_runtime_pin}）"
  if [ "${KEEP_SIMULATOR:-0}" != 1 ]; then
    if [[ "$sim_name" =~ ^(LS-[0-9]+|main)- ]]; then
      shutdown_dedicated_simulator() {
        if [ -d "$sim_lock_dir" ]; then
          echo "→ push gate：${sim_lock_dir} 仍在，跳過 shutdown ${sim_udid}（可能有其他呼叫使用中）" >&2
          return 0
        fi
        xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1 || true
      }
      trap shutdown_dedicated_simulator EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
    else
      echo "→ push gate：模擬器 ${sim_udid}（${sim_name:-未知裝置}）非本 worktree 專屬機，跳過 shutdown（避免關掉共用機／demo 常駐機，PR #164 R1 F1／F2）" >&2
    fi
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
  # LS-199：unit tests 看門狗。來源 LS-197 R2 push：測試宿主 app 啟動即 crash（`SupabaseClientFactory.makeClient()`
  # 的 XCTest 偵測 assert——XCTest 未注入、runner 沒連上），之後 xcodebuild 0% CPU 掛 28 分鐘，agent 只能乾等
  # 「背景 push 完成通知」，orchestrator 人工 kill 重跑即過（環境性 flake）。任何 lane 的 push 都走這條 gate，
  # 一卡就是整條 lane 停擺。兩條中止路徑：
  #   (1) 逾時：PUSH_GATE_XCODEBUILD_TIMEOUT_MIN（預設 25 分）；PUSH_GATE_XCODEBUILD_TIMEOUT_SEC 秒級覆寫（自測用）。
  #   (2) 早期偵測：xcodebuild 自己的輸出（-quiet 下掛住時什麼都不印）或本 worktree 的 xcresult session log
  #       （Xcode 在測試進行中把 Session-*.log 寫在 DerivedData/<專案>/Logs/Test/<xcresult>/Staging/ 底下、跑完才
  #       打包收掉；掛住的 run 就一直留在那裡——LS-197 的「Handling Crash: … Dropping test runner session call …
  #       because the test runner hasn't connected yet」就在這份 log；健康的 run 同一份 log 會有每個
  #       `Test Case '-[…]' started.`，實測 xcresult 匯出確認）出現 `test runner hasn't connected yet`／
  #       `Handling Crash:`／`Early unexpected exit` 任一樣式，之後 PUSH_GATE_CRASH_GRACE_SEC（預設 60）秒內兩處都
  #       沒有任何 `Test Case '-[` 開始 → 視為宿主 crash，不等到逾時。
  # session log 只認 info.plist 的 WorkspacePath 落在本 repo 根之下的 DerivedData 目錄（Xcode 為每個專案路徑各建
  # 一個 `LittleSprout-<hash>/`，info.plist 記 `<repo>/LittleSprout.xcodeproj`），且檔案須晚於看門狗啟動——多 worktree
  # 併發 push 是常態，拿整個 DerivedData 最新一份會把別票的 crash 誤判成自己的：對方 crash 時本 worktree 可能還在
  # 編譯，60 秒內看不到 test case 開始，殺掉的是一個健康的 run。對應不到目錄就只看 xcodebuild 輸出，診斷印「找不到」。
  # 中止流程：先抓 session log 尾（kill 之後 Staging 可能被收掉）→ 殺整棵行程樹（先收集子孫再 TERM、3 秒後 KILL
  # 殘留——先殺父會讓子孫被 launchd 收養、pgrep -P 再也找不到）→ 回收自己那把 simulator-lock（holder pid 是剛被殺
  # 的子孫才收；別人的鎖不動，讓上方 shutdown_dedicated_simulator 的「鎖仍在就跳過」照常保護共用機）→ 印診斷
  # （session log 尾 20 行、~/Library/Logs/DiagnosticReports 最新 LittleSprout*.ips 路徑與 exception／termination／
  # faultingThread 前三幀）＋「環境性 flake、建議 erase 後重跑」→ exit 124（timeout(1) 慣例，與 xcodebuild 測試
  # 失敗的 65 區分）；EXIT trap 照常關專屬機。CI（GITHUB_ACTIONS=true）有 workflow 級 timeout，不包看門狗。
  # 命令得放背景跑前景才能輪詢，而 bash 對背景命令預設忽略 SIGINT——使用者 Ctrl-C 只會打到本腳本、xcodebuild
  # 會活下來；看門狗期間把 INT／TERM 接成「先殺行程樹再 exit」，不留沒人管的 xcodebuild。完成與否看 rc 標記檔、
  # 不用 kill -0（未 wait 的子行程死了也是 zombie、kill -0 照樣成功）。
  wd_timeout_sec="${PUSH_GATE_XCODEBUILD_TIMEOUT_SEC:-}"
  wd_timeout_min="${PUSH_GATE_XCODEBUILD_TIMEOUT_MIN:-25}"
  wd_grace_sec="${PUSH_GATE_CRASH_GRACE_SEC:-60}"
  for wd_v in "$wd_timeout_min" "$wd_grace_sec" "${wd_timeout_sec:-1}"; do
    case "$wd_v" in ''|0|*[!0-9]*)
      echo "✗ push gate：PUSH_GATE_XCODEBUILD_TIMEOUT_MIN／PUSH_GATE_XCODEBUILD_TIMEOUT_SEC／PUSH_GATE_CRASH_GRACE_SEC 須為正整數（得到「${wd_v}」）" >&2
      exit 1 ;;
    esac
  done
  [ -n "$wd_timeout_sec" ] || wd_timeout_sec=$((wd_timeout_min * 60))
  wd_crash_re="test runner hasn't connected yet|Handling Crash:|Early unexpected exit"
  wd_repo_root=$(pwd -P)
  wd_pid=
  wd_descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do printf '%s ' "$c"; wd_descendants "$c"; done; }
  wd_kill_tree() {   # $1＝根 pid；設 wd_killed_pids（含根）；回傳時整棵樹已 TERM、殘留已 KILL
    local p alive i
    wd_killed_pids="$1 $(wd_descendants "$1")"
    kill -TERM $wd_killed_pids 2>/dev/null || true
    for i in 1 2 3 4 5 6; do
      alive=0
      for p in $wd_killed_pids; do [ "$p" = "$1" ] && continue; kill -0 "$p" 2>/dev/null && alive=1; done
      [ "$alive" -eq 0 ] && break
      sleep 0.5
    done
    kill -KILL $wd_killed_pids 2>/dev/null || true
  }
  wd_session_logs() {   # 本 worktree 專案的 DerivedData 內、晚於看門狗啟動的 Staging Session-*.log，每行一個
    local d
    for d in "$HOME"/Library/Developer/Xcode/DerivedData/*/; do
      [ -f "${d}info.plist" ] || continue
      grep -qF "<string>${wd_repo_root}/" "${d}info.plist" 2>/dev/null || continue
      # `|| true`：Logs/Test 在第一個測試 session 開始前還不存在，find 非 0 會讓 set -e 把這個掃描子殼整個結束
      find "${d}Logs/Test" -path '*.xcresult/Staging/*' -name 'Session-*.log' -newer "$wd_stamp" 2>/dev/null || true
    done
  }
  wd_latest_session_log() {
    local list; list=$(wd_session_logs)
    [ -n "$list" ] || return 0
    printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -n 1
  }
  wd_hit() {   # $@＝grep 旗標＋樣式；掃 xcodebuild 輸出與每份 session log，任一命中即 0
    local f
    grep -q "$@" "$wd_log" 2>/dev/null && return 0
    while IFS= read -r f; do
      [ -n "$f" ] && grep -q "$@" "$f" 2>/dev/null && return 0
    done < <(wd_session_logs)
    return 1
  }
  wd_run() {   # $@＝要包的命令；正常結束回傳其 exit code；逾時／宿主 crash → 殺樹、收鎖、印診斷、exit 124
    if [ "${GITHUB_ACTIONS:-}" = true ]; then "$@"; return; fi
    local started now crash_at= wd_reason= wd_rc session_log= session_tail= holder= ips=
    wd_tmp=$(mktemp -d); wd_log="$wd_tmp/xcodebuild.log"; wd_stamp="$wd_tmp/stamp"
    : > "$wd_log"; touch "$wd_stamp"
    echo "→ push gate：unit tests 看門狗啟用（逾時 ${wd_timeout_sec} 秒；宿主 crash 樣式後 ${wd_grace_sec} 秒無 test case 開始即中止；LS-199）"
    ( wd_rc=0; "$@" || wd_rc=$?; echo "$wd_rc" > "$wd_tmp/rc" ) > >(tee -a "$wd_log") 2>&1 &
    wd_pid=$!
    trap '[ -n "$wd_pid" ] && wd_kill_tree "$wd_pid"; exit 130' INT
    trap '[ -n "$wd_pid" ] && wd_kill_tree "$wd_pid"; exit 143' TERM
    started=$(date +%s); now=$started
    while [ ! -f "$wd_tmp/rc" ]; do
      sleep 1
      now=$(date +%s)
      if [ $((now - started)) -ge "$wd_timeout_sec" ]; then wd_reason=逾時; break; fi
      if [ -z "$crash_at" ] && wd_hit -E "$wd_crash_re"; then
        crash_at=$now
        echo "⚠ push gate：xcodebuild 輸出／session log 出現宿主 crash 樣式，${wd_grace_sec} 秒內沒有 test case 開始就中止…" >&2
      fi
      if [ -n "$crash_at" ]; then
        if wd_hit -F "Test Case '-["; then
          echo "→ push gate：已看到 test case 開始，取消宿主 crash 判定" >&2
          crash_at=
        elif [ $((now - crash_at)) -ge "$wd_grace_sec" ]; then
          wd_reason="宿主 crash"; break
        fi
      fi
    done
    if [ -z "$wd_reason" ]; then
      wait "$wd_pid" 2>/dev/null || true
      wd_rc=$(cat "$wd_tmp/rc"); wd_pid=
      rm -rf "$wd_tmp"
      return "$wd_rc"
    fi
    session_log=$(wd_latest_session_log)
    [ -n "$session_log" ] && session_tail=$(tail -n 20 "$session_log" 2>/dev/null)
    wd_kill_tree "$wd_pid"
    wait "$wd_pid" 2>/dev/null || true
    wd_pid=
    if [ -f "$sim_lock_dir/holder" ]; then
      holder=$(sed -n 's/^pid=//p' "$sim_lock_dir/holder" 2>/dev/null)
      case " $wd_killed_pids " in
        *" ${holder:-NONE} "*)
          if ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$sim_lock_dir"
            echo "→ push gate：回收看門狗中止後殘留的 simulator-lock（持有者 pid ${holder} 已被殺；${sim_lock_dir}）" >&2
          fi ;;
      esac
    fi
    echo "✗ push gate：unit tests ${wd_reason}（xcodebuild 已跑 $((now - started)) 秒、看門狗上限 ${wd_timeout_sec} 秒），已中止並殺掉整棵行程樹（LS-199）" >&2
    if [ -n "$session_log" ]; then
      echo "  最近的 xcresult session log 尾 20 行：${session_log}" >&2
      printf '%s\n' "$session_tail" | sed 's/^/    /' >&2
    else
      echo "  找不到本次的 xcresult session log（~/Library/Developer/Xcode/DerivedData/<本 worktree 專案>/Logs/Test/*.xcresult/Staging/**/Session-*.log，且須晚於看門狗啟動）" >&2
    fi
    # `|| true`：沒有任何 .ips 時 ls 非 0，pipefail 會讓這個賦值在 set -e 下直接結束腳本、診斷全沒印（自測 ㉙）。
    # 新舊判斷用 find -newer 而不是 [ -nt ]：bash 3.2（/bin/bash，pre-push hook 用的殼）的 -nt 只比到秒。
    ips=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/LittleSprout*.ips 2>/dev/null | head -n 1 || true)
    if [ -n "$ips" ]; then
      if [ -n "$(find "$ips" -newer "$wd_stamp" 2>/dev/null)" ]; then
        echo "  最新 crash report：${ips}" >&2
      else
        echo "  最新 crash report：${ips}（早於本次看門狗啟動，可能不是這次的）" >&2
      fi
      python3 - "$ips" <<'PY' 2>&1 | sed 's/^/    /' >&2 || true
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        head, _, body = fh.read().partition("\n")
    hdr = json.loads(head)
    rep = json.loads(body)
except Exception as e:  # 檔案格式不如預期就只報原因，不讓診斷本身炸掉
    print("（無法解析 .ips：%s）" % e)
    sys.exit(0)
print("時間 %s  app %s %s" % (hdr.get("timestamp", "?"), hdr.get("app_name", "?"), hdr.get("app_version", "?")))
exc = rep.get("exception") or {}
print("exception：%s (%s) codes=%s" % (exc.get("type", "?"), exc.get("signal", "?"), exc.get("codes", "?")))
term = rep.get("termination") or {}
print("termination：%s %s %s" % (term.get("namespace", "?"), term.get("code", "?"), term.get("indicator", "")))
ft = rep.get("faultingThread")
threads = rep.get("threads") or []
images = rep.get("usedImages") or []
if isinstance(ft, int) and 0 <= ft < len(threads):
    print("faultingThread：%d（前三幀）" % ft)
    for i, fr in enumerate((threads[ft].get("frames") or [])[:3]):
        idx = fr.get("imageIndex")
        img = images[idx].get("name", "?") if isinstance(idx, int) and 0 <= idx < len(images) else "?"
        loc = " %s:%s" % (fr.get("sourceFile"), fr.get("sourceLine")) if fr.get("sourceFile") else ""
        print("  #%d %s %s%s" % (i, img, fr.get("symbol", "?"), loc))
else:
    print("faultingThread：無")
PY
    else
      echo "  找不到 crash report（~/Library/Logs/DiagnosticReports/LittleSprout*.ips）" >&2
    fi
    echo "  可能是環境性 flake（LS-197 同型：宿主 app 啟動即 crash、runner 沒連上），建議先 xcrun simctl erase ${sim_udid} 再重跑 git push；重跑仍紅再依上面的摘要修 code" >&2
    rm -rf "$wd_tmp"
    exit 124
  }

  echo "→ push gate：執行 unit tests（scheme: ${XCODE_SCHEME}, destination: ${dest}）…"
  # LS-54 N8：與 CI 一致，明確序列執行（MockURLProtocol 全域 handler 不可平行）
  # LS-83 R2 F1：整段包進 simulator-lock.sh，鍵＝目的地 UDID（scripts/ops/simulator-lock.sh 檔頭注解）
  # LS-95：明確帶 -only-testing:LittleSproutTests——scheme 新增了 LittleSproutUITests
  # target（≥44pt 點擊目標 gate）之後，不帶篩選的話這裡會連 UI test 一起跑，讓每次 push
  # 都多付一次開 app 的成本；UI test 是否要跑另外由下面的 tap-target-check.sh 依 Features/
  # diff 決定，此處維持原本只跑 unit tests 的範圍與耗時不變。
  # LS-199：整段交給上方 wd_run 看門狗（背景執行＋輪詢；命令本身不變）。
  run_unit_tests() {
    bash "$(git rev-parse --show-toplevel)/scripts/ops/simulator-lock.sh" --dir "$sim_lock_dir" -- \
      xcodebuild test \
      -scheme "$XCODE_SCHEME" \
      -destination "$dest" \
      -only-testing:LittleSproutTests \
      -parallel-testing-enabled NO \
      -quiet
  }
  wd_run run_unit_tests

  # LS-95：≥44pt 點擊目標機械 gate。Swift diff 含 Features/ 或 DesignSystem/ 才跑（COLLABORATION
  # §4／§7）——非 UI 票的 Swift 變更（例如只動 Services/／Models/）不需要多付一次 XCUITest 開 app
  # 的成本。merge-review R1 m1：點擊區 padding 的 token（`AppSpacing`）與共用按鈕元件
  # （`PrimaryButton`／`AuthButtons`／`Pill`）都住在 `DesignSystem/`，只改那裡（例如把
  # `AppSpacing.item` 調小）原本不會觸發本機這一步——CI 的 `ci` job 無條件跑會兜住，但本機這裡
  # 該一併認列，不要讓「UI 票」的定義漏掉點擊區 token 的來源。復用第 5／7 步同一套方向矩陣
  # （hotfix/* 對 origin/main，其餘對 origin/development）；保護分支與 detached HEAD 跳過；找不到
  # target ref 就不跑（跟第 0b 步一致，這裡不是正確性把關，找不到就略過，不新增一個「找不到 ref」
  # 的失敗模式）。
  tap_target_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
  case "$tap_target_branch" in
    main|test|development|DETACHED) ;;
    *)
      case "$tap_target_branch" in hotfix/*) tap_target_base=origin/main ;; *) tap_target_base=origin/development ;; esac
      if git rev-parse -q --verify "$tap_target_base" >/dev/null; then
        tap_target_diff=$(git diff --name-only "$tap_target_base"...HEAD)
        if printf '%s\n' "$tap_target_diff" | grep -qE '(^|/)(Features|DesignSystem)/'; then
          echo "→ push gate：Swift diff 含 Features/ 或 DesignSystem/，執行 ≥44pt 點擊目標 gate（LS-95）…"
          bash "$(git rev-parse --show-toplevel)/scripts/ops/simulator-lock.sh" --dir "$sim_lock_dir" -- \
            bash "$(git rev-parse --show-toplevel)/scripts/gates/tap-target-check.sh" "$sim_udid" "$XCODE_SCHEME"
        fi
      fi
      ;;
  esac
else
  echo "⚠ push gate：尚未建立 Xcode 專案，跳過 unit tests（Phase 0-1 完成後自動生效）"
fi

echo "✓ push gate 通過"
