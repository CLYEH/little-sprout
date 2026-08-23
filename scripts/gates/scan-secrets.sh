#!/bin/bash
# Secrets 掃描：讀 stdin（diff 的新增行），發現金鑰素材即 exit 1。
# 供 pre-commit hook 與 CI rules job 共用（docs/COLLABORATION.md §7）。
# pattern 一律用 [x] 字元類寫法，讓本檔自身永遠不會匹配自己的 pattern——
# 因此不需要排除任何路徑，掃描沒有盲區。
#
# 逃生口（LS-10）：同一行若含 `gate:allow-example` 標記，該行跳過不掃描——
# 給文件裡刻意寫的示範連線字串用（例：postgres://user:pw@host/db  # gate:allow-example）。
# 標記逐行生效（只濾掉含標記的那一行本身），不會連帶放行同段落其他行的真金鑰。
# 規約禁止拿這個標記去救真的金鑰；本 gate 無法分辨「示範」與「真的忘記標記」，
# 誠實核可仍靠人（merge-reviewer／orchestrator）。
set -uo pipefail

patterns='BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE[ ]KEY'
patterns="$patterns|eyJ[h]bGciOi"
patterns="$patterns|AKI[A][0-9A-Z]{16}"
patterns="$patterns|sk[-][A-Za-z0-9_-]{20,}"
patterns="$patterns|sb[_]secret_[A-Za-z0-9_-]{10,}"
patterns="$patterns|sb[_]publishable_[A-Za-z0-9_-]{10,}"
patterns="$patterns|gh[opsu][_][A-Za-z0-9]{20,}"
patterns="$patterns|fig[d][_][A-Za-z0-9_-]{20,}"   # Figma PAT（LS-42）
patterns="$patterns|AIz[a][0-9A-Za-z_-]{35}"
patterns="$patterns|xox[baprs][-]"
patterns="$patterns|postgres(ql)?[:]//[^:]+:[^@]+@"

hits=$(grep -v 'gate:allow-example' | grep -nE "$patterns" || true)
if [ -n "$hits" ]; then
  echo "✗ secrets 掃描：內容疑似含金鑰（規約：secrets 永不進 repo）：" >&2
  printf '%s\n' "$hits" | head -5 >&2
  exit 1
fi
exit 0
