#!/bin/bash
# tap-target-registry-check.sh 的自測（LS-95 M1，merge-review R1）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支腳本也適用：若退化成漏掉某個 View、把排除清單的比對規則改鬆（例如比對
# 子字串而非整行 basename）、或找不到必要檔案卻靜默放行，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/tap-target-registry-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

R="$work/repo"
mkdir -p "$R/LittleSprout/Features" "$R/scripts/gates"
git -C "$R" init -q

registry() {   # registry <case 內容…>：寫一份最小 TapTargetGateScreenName.swift
  {
    echo 'enum TapTargetGateScreenName: String {'
    for c in "$@"; do echo "    case x = \"${c}\""; done
    echo '}'
  } > "$R/LittleSprout/TapTargetGateScreenName.swift"
}
exemptions() {   # exemptions <一行一個「Name：理由」…>
  printf '%s\n' "$@" > "$R/scripts/gates/tap-target-exemptions.txt"
}
mk_view() { touch "$R/LittleSprout/Features/$1"; }   # mk_view <檔名.swift>
rm_views() { find "$R/LittleSprout/Features" -name '*View.swift' -delete; }

expect() {   # expect <期望 exit> <名稱> [輸出必含字串…]
  local want=$1 name=$2; shift 2
  local out got ok=1
  out=$(cd "$R" && bash "$checker" 2>&1); got=$?
  [ "$got" -eq "$want" ] || ok=0
  local must
  for must in "$@"; do
    printf '%s' "$out" | grep -qF -- "$must" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ① 兩支 View 都已註冊 → 綠
rm_views
mk_view OTPVerificationView.swift
mk_view SettingsView.swift
registry OTPVerificationView SettingsView
exemptions "# empty"
expect 0 '① 兩支 View 都在註冊表 → 綠'

# ② 一支已註冊、一支既未註冊也未排除 → 紅並點名
rm_views
mk_view OTPVerificationView.swift
mk_view NewFeatureView.swift
registry OTPVerificationView
exemptions "# empty"
expect 1 '② 未註冊未排除的畫面 → 紅並點名' 'NewFeatureView' 'Features/NewFeatureView.swift'

# ③ 未註冊但已具名排除 → 綠
rm_views
mk_view OTPVerificationView.swift
mk_view WelcomeView.swift
registry OTPVerificationView
exemptions "WelcomeView：測試用理由"
expect 0 '③ 未註冊但已具名排除 → 綠'

# ④ mutation-style 負控：排除清單只認整行 basename，不能被子字串誤配（例如
#    「WelcomeView：…」不該讓「NewWelcomeView」被誤判為已排除）
rm_views
mk_view NewWelcomeView.swift
registry OTPVerificationView
exemptions "WelcomeView：測試用理由"
expect 1 '④ 排除清單不可子字串誤配' 'NewWelcomeView'

# ⑤ 找不到 registry 檔 → exit 2（fail closed）
rm_views
rm -f "$R/LittleSprout/TapTargetGateScreenName.swift"
exemptions "# empty"
expect 2 '⑤ 找不到 TapTargetGateScreenName.swift → exit 2'

# ⑥ 找不到 exemptions 檔 → exit 2（fail closed）
registry OTPVerificationView
rm -f "$R/scripts/gates/tap-target-exemptions.txt"
expect 2 '⑥ 找不到 exemptions 檔 → exit 2'

# ⑦ 不在 git repo 內 → exit 2
registry OTPVerificationView
exemptions "# empty"
out=$(cd "$work" && bash "$checker" 2>&1); got=$?
if [ "$got" -eq 2 ]; then
  echo "✓ ⑦ 不在 git repo 內 → exit 2"
else
  echo "✗ ⑦ 不在 git repo 內應 exit 2，實得 ${got}" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ tap-target-registry-check.test.sh 全部通過"
else
  echo "✗ tap-target-registry-check.test.sh 有案例失敗" >&2
fi
exit "$fail"
