#!/bin/bash
# 偵測第一台可用 iPhone 模擬器，輸出可直接餵給 xcodebuild -destination 的完整值
# （含 OS 版本）。供 push-gate 與 CI 共用（本機與 CI 的 Xcode 版本不同，不可寫死機型）。
#
# LS-10：只輸出機型名稱時，若同一台 Mac 裝了多個 runtime（例如同時有 iOS 26.0 與
# iOS 26.5 的 iPhone 17 Pro），xcodebuild 會自行從同名裝置裡挑一台，挑到哪一台不可
# 重現（LS-5 handoff 觀察）。改成連 OS 版本一起輸出，呼叫端直接把整段值填進
# -destination，不必也不應該再自己拼 "platform=iOS Simulator,name=...".
#
# 這裡的坑（實測抓到）：`simctl list devices available` 的 `-- iOS 26.0 --` 分節
# 標題只印 major.minor，但 xcodebuild 的 -destination OS= 要精確比對到實際安裝的
# runtime 版本（例如 26.0.1），拿分節標題直接當 OS= 餵進去會找不到裝置。所以還要
# 用 `simctl list runtimes` 把分節標題對應的精確版本查出來；查不到就退回分節標題
# 本身（不比原本沒有 OS= 的情況更差）。
set -uo pipefail

list=$(xcrun simctl list devices available)

header_os=$(printf '%s\n' "$list" | awk '
  /^-- iOS / {
    os = $0
    sub(/^-- iOS /, "", os)
    sub(/ --$/, "", os)
    next
  }
  /iPhone/ { print os; exit }
')
name=$(printf '%s\n' "$list" | awk '
  /iPhone/ {
    name = $0
    sub(/^[ \t]*/, "", name)
    sub(/ *\(.*/, "", name)
    print name
    exit
  }
')

if [ -z "$name" ] || [ -z "$header_os" ]; then
  echo "✗ 找不到可用的 iPhone 模擬器（xcrun simctl list devices available）。" >&2
  exit 1
fi

exact_os=$(xcrun simctl list runtimes | grep -m1 "^iOS ${header_os} " \
  | sed -E 's/^iOS [0-9.]+ \(([0-9.]+)( - .*)?\).*/\1/')
os="${exact_os:-$header_os}"

printf 'platform=iOS Simulator,name=%s,OS=%s\n' "$name" "$os"
