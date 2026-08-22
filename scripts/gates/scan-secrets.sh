#!/bin/bash
# Secrets 掃描：讀 stdin（diff 的新增行），發現金鑰素材即 exit 1。
# 供 pre-commit hook 與 CI rules job 共用（docs/COLLABORATION.md §7）。
# pattern 一律用 [x] 字元類寫法，讓本檔自身永遠不會匹配自己的 pattern——
# 因此不需要排除任何路徑，掃描沒有盲區。
set -uo pipefail

patterns='BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE[ ]KEY'
patterns="$patterns|eyJ[h]bGciOi"
patterns="$patterns|AKI[A][0-9A-Z]{16}"
patterns="$patterns|sk[-][A-Za-z0-9_-]{20,}"
patterns="$patterns|sb[_]secret_[A-Za-z0-9_-]{10,}"
patterns="$patterns|sb[_]publishable_[A-Za-z0-9_-]{10,}"
patterns="$patterns|gh[opsu][_][A-Za-z0-9]{20,}"
patterns="$patterns|AIz[a][0-9A-Za-z_-]{35}"
patterns="$patterns|xox[baprs][-]"
patterns="$patterns|postgres(ql)?[:]//[^:]+:[^@]+@"

hits=$(grep -nE "$patterns" || true)
if [ -n "$hits" ]; then
  echo "✗ secrets 掃描：內容疑似含金鑰（規約：secrets 永不進 repo）：" >&2
  printf '%s\n' "$hits" | head -5 >&2
  exit 1
fi
exit 0
