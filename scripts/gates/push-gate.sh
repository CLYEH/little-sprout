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

# 2) Unit tests（Xcode 專案存在才跑；Phase 0 建專案時如 scheme 不同請更新此處與 CI）
if ls -d ./*.xcodeproj >/dev/null 2>&1 || ls -d ./*.xcworkspace >/dev/null 2>&1; then
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
  # 一段，EXIT trap 要等本腳本剩下的第 3～7 步（真環境好幾秒）跑完才觸發，那時鎖早已釋放：A 跑完自己
  # 剩下的 gate、trap 觸發關機時，B 可能正拿著同一顆共用機在鎖內跑測試，會被 A 關掉（stub 重現的時間
  # 軸見 PR #164 R1 F1）。設 trap 前先查這顆 UDID 對應的裝置名稱，只有專屬機（`<票號>-<機型>`，含主
  # checkout 用的 `main-`）才設；共用機／R1 F2 提到的 demo-* 常駐機都落在下面 pattern 之外，不設
  # trap、不關。第二道防線：即使是專屬機，shutdown 前若鎖目錄仍在就跳過並印一行——不在 trap 內重新
  # 取鎖，中斷情境下持鎖的子行程可能還活著，重新取鎖會卡到 simulator-lock.sh 的 timeout（該腳本檔頭
  # 理由）。
  # I2：鎖目錄路徑可用 SIMULATOR_LOCK_DIR 覆寫（自測用；預設仍是 /tmp/simulator-lock-<udid>），讓多份
  # push-gate.test.sh 併行時各自用 mktemp -d 出來的路徑，不會互刪對方的鎖目錄。
  sim_lock_dir="${SIMULATOR_LOCK_DIR:-/tmp/simulator-lock-${sim_udid}}"
  if [ "${KEEP_SIMULATOR:-0}" != 1 ]; then
    sim_name=$(xcrun simctl list devices available 2>/dev/null | awk -v u="$sim_udid" '
      { line = $0
        udid = line
        sub(/^[^(]*\(/, "", udid)
        sub(/\).*/, "", udid)
        if (udid != u) next
        nm = line
        sub(/^[ \t]*/, "", nm)
        sub(/ *\(.*/, "", nm)
        print nm
        exit
      }
    ')
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
  echo "→ push gate：執行 unit tests（scheme: ${XCODE_SCHEME}, destination: ${dest}）…"
  # LS-54 N8：與 CI 一致，明確序列執行（MockURLProtocol 全域 handler 不可平行）
  # LS-83 R2 F1：整段包進 simulator-lock.sh，鍵＝目的地 UDID（scripts/ops/simulator-lock.sh 檔頭注解）
  bash "$(git rev-parse --show-toplevel)/scripts/ops/simulator-lock.sh" --dir "$sim_lock_dir" -- \
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
