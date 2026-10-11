#!/bin/bash
# release-version.sh 的自測（LS-466）。CI rules job 每個 PR 都跑。
# 若退化成——無 tag 時不是 0.0.0、版本沒去掉開頭 v、build 號不是 HEAD 的 commit 數、被非 `v*` tag 誤導
# （例如 `qa-1`）、取到不可達的較新 tag、重跑內容漂移、Version.xcconfig 沒被 .gitignore——這裡會紅。
# 每案用獨立合成 repo（腳本以 `git rev-parse --show-toplevel` 找根目錄，所以在 repo 內放一份腳本副本）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/release-version.sh"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

check() { # <name> <expected-file-content> <actual-file-content>
  if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1"; echo "  期望：$(printf '%s' "$2" | tr '\n' '|')"; echo "  實際：$(printf '%s' "$3" | tr '\n' '|')"; fail=1; fi
}

newrepo() { # <name> -> 印 repo 路徑
  local d="$work/$1"
  mkdir -p "$d/Config" "$d/scripts/ops"
  g -C "$d" init -q -b main
  cp "$script" "$d/scripts/ops/release-version.sh"
  echo "$d"
}
commit() { g -C "$1" commit -q --allow-empty -m "$2"; }
run() { (cd "$1" && bash scripts/ops/release-version.sh >/dev/null); cat "$1/Config/Version.xcconfig"; }

# ① 無 tag → 0.0.0，build＝commit 數
r="$(newrepo notag)"; commit "$r" a; commit "$r" b
check "① 無 tag → 0.0.0／2" $'MARKETING_VERSION = 0.0.0\nCURRENT_PROJECT_VERSION = 2' "$(run "$r")"

# ② v 前綴去掉；tag 之後的 commit 計入 build 號
r="$(newrepo tagged)"; commit "$r" a; g -C "$r" tag v1.2.3; commit "$r" b; commit "$r" c
check "② v1.2.3 + 3 commits → 1.2.3／3" $'MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 3' "$(run "$r")"

# ③ 非 v* tag 不干擾（qa-1 較新也不取）
g -C "$r" tag qa-1
check "③ 非 v* tag 被忽略" $'MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 3' "$(run "$r")"

# ④ 取「可達的最近」v* tag，不取不可達分支上的較新 tag
r="$(newrepo reach)"; commit "$r" a; g -C "$r" tag v0.1.0; g -C "$r" checkout -q -b side; commit "$r" s; g -C "$r" tag v9.9.9
g -C "$r" checkout -q main; commit "$r" b
check "④ 不取不可達 tag" $'MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 2' "$(run "$r")"

# ⑤ 重跑內容不漂移
first="$(run "$r")"
check "⑤ 重跑一致" "$first" "$(run "$r")"

# ⑥ repo 的 .gitignore 涵蓋 Version.xcconfig
if (cd "$root" && git check-ignore -q Config/Version.xcconfig); then echo "✓ ⑥ Version.xcconfig 被 .gitignore"; else echo "✗ ⑥ Config/Version.xcconfig 未被 .gitignore"; fail=1; fi

exit "$fail"
