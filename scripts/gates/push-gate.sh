#!/bin/bash
# Push gate（pre-push）：全 repo lint + unit tests。規約見 CLAUDE.md §4。
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
  echo "→ push gate：執行 unit tests（scheme: ${XCODE_SCHEME}, destination: ${dest}）…"
  xcodebuild test \
    -scheme "$XCODE_SCHEME" \
    -destination "$dest" \
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

echo "✓ push gate 通過"
