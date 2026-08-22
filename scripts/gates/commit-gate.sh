#!/bin/bash
# Commit gate（pre-commit）：保護分支 + staged Swift 檔 lint。規約見 CLAUDE.md §4。
set -euo pipefail

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")

# 保護分支禁止直接 commit（bootstrap／緊急救援用 ALLOW_PROTECTED=1 覆寫，事後須補記錄）
case "$branch" in
  main|test|development)
    if [ "${ALLOW_PROTECTED:-0}" != "1" ]; then
      echo "✗ commit gate：禁止直接 commit 到 ${branch}。請開 feature/fix/hotfix branch 走 PR。" >&2
      exit 1
    fi
    echo "⚠ commit gate：ALLOW_PROTECTED=1 覆寫，直接 commit 到 ${branch}" >&2
    ;;
esac

# staged Swift 檔 lint（fail loud：有 Swift 變更但沒裝 SwiftLint 就擋下，不靜默跳過）
staged_swift=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$' || true)
if [ -n "$staged_swift" ]; then
  if ! command -v swiftlint >/dev/null 2>&1; then
    echo "✗ commit gate：有 Swift 變更但未安裝 SwiftLint（brew install swiftlint）。" >&2
    exit 1
  fi
  echo "$staged_swift" | xargs swiftlint lint --strict --quiet
fi

echo "✓ commit gate 通過"
