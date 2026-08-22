#!/bin/bash
# Commit gate（pre-commit）：保護分支、branch 命名、secrets 掃描、staged Swift 檔 lint。
# 規約見 docs/COLLABORATION.md §4、§7。
set -euo pipefail

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")

case "$branch" in
  main|test|development)
    if [ "${ALLOW_PROTECTED:-0}" != "1" ]; then
      echo "✗ commit gate：禁止直接 commit 到 ${branch}。請開 feature/fix/hotfix branch 走 PR。" >&2
      exit 1
    fi
    echo "⚠ commit gate：ALLOW_PROTECTED=1 覆寫，直接 commit 到 ${branch}" >&2
    ;;
  DETACHED)
    # rebase／cherry-pick 進行中，跳過命名檢查
    ;;
  *)
    if ! printf '%s' "$branch" | grep -qE '^(feature|fix|hotfix)/LS-[0-9]+-[a-z0-9][a-z0-9-]*$'; then
      echo "✗ commit gate：branch 名稱「${branch}」不符 (feature|fix|hotfix)/LS-<n>-<slug> 規約。" >&2
      exit 1
    fi
    ;;
esac

# Secrets 掃描（staged 新增行；排除 gate 腳本自身，否則掃描 pattern 會自我誤判）
added_lines=$(git diff --cached --diff-filter=ACM --unified=0 -- . ':(exclude)scripts/gates/' ':(exclude).githooks/' | grep '^+' | grep -v '^+++' || true)
if [ -n "$added_lines" ]; then
  # 只抓實際金鑰素材（private key 區塊、JWT、雲端金鑰格式），不抓裸關鍵字——
  # 「service_role」等字詞會出現在文件敘述裡，真 key 是 JWT、由 eyJhbGciOi 涵蓋
  secret_hits=$(printf '%s' "$added_lines" | grep -nE 'BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE KEY|eyJhbGciOi|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}' || true)
  if [ -n "$secret_hits" ]; then
    echo "✗ commit gate：staged 內容疑似含金鑰（規約：secrets 永不進 repo）：" >&2
    printf '%s\n' "$secret_hits" | head -5 >&2
    exit 1
  fi
fi

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
