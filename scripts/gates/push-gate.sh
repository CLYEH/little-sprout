#!/bin/bash
# Push gate（pre-push）：全 repo lint + unit tests + API 契約／錯誤碼對帳 + migration 分級。規約見 docs/COLLABORATION.md §4。
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

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

echo "✓ push gate 通過"
