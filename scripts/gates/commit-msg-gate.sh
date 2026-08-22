#!/bin/bash
# Commit-msg gate：驗證 commit message 第一行格式（docs/COLLABORATION.md §3）。
set -euo pipefail

msg_file="$1"
first_line=$(head -n 1 "$msg_file")

# merge／revert／autosquash commit 豁免
case "$first_line" in
  Merge\ *|Revert\ *|fixup!*|squash!*) exit 0 ;;
esac

if ! printf '%s' "$first_line" | grep -qE '^(feat|fix|chore|docs|refactor|test|perf|design)(\([a-z0-9-]+\))?: LS-[0-9]+ .+'; then
  cat >&2 <<'MSG'
✗ commit-msg gate：第一行須為「<type>(<scope>): LS-<n> <摘要>」
  type ∈ feat|fix|chore|docs|refactor|test|perf|design；scope 可省略
  例：feat(album): LS-12 批次上傳進度列
MSG
  exit 1
fi

echo "✓ commit-msg gate 通過"
