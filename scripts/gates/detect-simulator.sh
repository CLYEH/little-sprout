#!/bin/bash
# 偵測第一台可用 iPhone 模擬器並輸出名稱；找不到則 exit 1。
# 供 push-gate 與 CI 共用（本機與 CI 的 Xcode 版本不同，不可寫死機型）。
set -uo pipefail

dest_name=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//' || true)
if [ -z "$dest_name" ]; then
  echo "✗ 找不到可用的 iPhone 模擬器（xcrun simctl list devices available）。" >&2
  exit 1
fi
printf '%s\n' "$dest_name"
