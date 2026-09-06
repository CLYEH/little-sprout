#!/bin/bash
# pick-ipad-runtime.sh 的自測（LS-211 I-b，來源 LS-96 池項 edbc460c）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若「找最接近 pin 的較新版本」退化成「單純取最大版本」（不管
# pin 是什麼都選最新，等於失去了「貼近釘住版」的意義）、或退化回舊版「取第一個找到的」（等於永遠
# 選到最舊），這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/pick-ipad-runtime.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture="$work/devices.txt"
cat > "$fixture" <<'EOF'
== Devices ==
-- iOS 17.0 --
    iPad Air 11-inch (M3) (AAAAAAAA-0000-0000-0000-000000000001) (Shutdown)
    iPhone 17 Pro (AAAAAAAA-0000-0000-0000-0000000000FF) (Shutdown)
-- iOS 18.0 --
    iPad Air 11-inch (M3) (AAAAAAAA-0000-0000-0000-000000000002) (Shutdown)
-- iOS 26.0 --
    iPad Air 11-inch (M3) (AAAAAAAA-0000-0000-0000-000000000003) (Booted)
-- iOS 26.2 --
    iPad Air 11-inch (M3) (AAAAAAAA-0000-0000-0000-000000000004) (Shutdown)
EOF

# expect <期望輸出|''> <名稱> <checker 參數…>（都讀 $fixture 當 stdin）
expect() {
  local want=$1 name=$2 out got
  shift 2
  out="$(bash "$check" "$@" < "$fixture" 2>&1)"; got=$?
  if [ "$got" -eq 0 ] && [ "$out" = "$want" ]; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望輸出「${want}」exit 0，實得輸出「${out}」exit ${got}）" >&2
    fail=1
  fi
}

# ==== ① 正樣本 ====
expect $'AAAAAAAA-0000-0000-0000-000000000004\t26.2' '①a pin=26.2（釘住版剛好存在）→ 選它自己（不是最舊也不是隨便一台）' '26.2'
expect $'AAAAAAAA-0000-0000-0000-000000000003\t26.0' '①b pin=20.0（無 20.0，較新版本中最接近的是 26.0）→ 選 26.0（不是 17.0／18.0 這些較舊版本，也不是 26.2）' '20.0'
expect $'AAAAAAAA-0000-0000-0000-000000000004\t26.2' '①c pin=99.0（沒有任何版本 ≥ 99.0）→ 退回所有可用版本裡最新（26.2，不是最舊的 17.0）' '99.0'
expect $'AAAAAAAA-0000-0000-0000-000000000004\t26.2' '①d pin 空字串 → 視為無釘住版，直接取最新' ''
expect $'AAAAAAAA-0000-0000-0000-000000000001\t17.0' '①e pin=17.0（釘住版本身是最舊的）→ 選它自己' '17.0'

# ==== ②：只認裝置型號 pattern（自訂 pattern，不含正則特殊字元，驗證第二參數真的生效）====
fixture2="$work/devices2.txt"
cat > "$fixture2" <<'EOF'
== Devices ==
-- iOS 17.0 --
    OtherModel XL (CCCCCCCC-0000-0000-0000-000000000001) (Shutdown)
-- iOS 18.0 --
    OtherModel XL (CCCCCCCC-0000-0000-0000-000000000002) (Shutdown)
EOF
out2="$(bash "$check" '18.0' 'OtherModel XL' < "$fixture2" 2>&1)"; got2=$?
if [ "$got2" -eq 0 ] && [ "$out2" = $'CCCCCCCC-0000-0000-0000-000000000002\t18.0' ]; then
  echo "✓ ② 自訂裝置型號 pattern（不含正則特殊字元）真的生效"
else
  echo "✗ ② 自訂 pattern 應選到 18.0（實得「${out2}」exit ${got2}）" >&2; fail=1
fi

# ==== ③ 找不到裝置型號 → 空輸出、exit 0（不是 fail closed；呼叫端自行判斷空輸出）====
out3="$(bash "$check" '26.2' 'iPhone 99' < "$fixture" 2>&1)"; got3=$?
if [ "$got3" -eq 0 ] && [ -z "$out3" ]; then
  echo "✓ ③ 找不到裝置型號 → 空輸出、exit 0"
else
  echo "✗ ③ 找不到裝置型號應空輸出 exit 0（實得「${out3}」exit ${got3}）" >&2; fail=1
fi

# ==== ④ 參數／--help ====
out4a="$(bash "$check" --help 2>&1)"; got4a=$?
if [ "$got4a" -eq 0 ] && printf '%s' "$out4a" | grep -qF '用法：'; then
  echo "✓ ④a --help → exit 0"
else
  echo "✗ ④a --help（期望 exit 0，實得 ${got4a}）" >&2; fail=1
fi
out4b="$(bash "$check" 2>&1)"; got4b=$?
if [ "$got4b" -eq 2 ]; then
  echo "✓ ④b 缺參數 → exit 2"
else
  echo "✗ ④b 缺參數（期望 exit 2，實得 ${got4b}）" >&2; fail=1
fi
out4c="$(bash "$check" a b c 2>&1)"; got4c=$?
if [ "$got4c" -eq 2 ]; then
  echo "✓ ④c 多餘參數 → exit 2"
else
  echo "✗ ④c 多餘參數（期望 exit 2，實得 ${got4c}）" >&2; fail=1
fi

# ==== ⑤ mutation：拿掉「優先選 >= pin 最接近」分支（只留「最新」分支）→ ①b 必須改判成選最新（26.2），
#        證明①b 選到 26.0（而非 26.2）是這段判準造成的，不是巧合 ====
py_src="$check"
mut="$work/pick-ipad-runtime.no-nearest.sh"
sed 's/if (pk != "" && best_ge != "") { print best_ge; exit 0 }/if (0) { print best_ge; exit 0 }/' "$py_src" > "$mut"
if grep -qF 'if (0) { print best_ge; exit 0 }' "$mut"; then
  echo "✓ ⑤ mutate：確認已拿掉「優先選最接近」分支"
  out5="$(bash "$mut" '20.0' < "$fixture" 2>&1)"; got5=$?
  if [ "$got5" -eq 0 ] && [ "$out5" = $'AAAAAAAA-0000-0000-0000-000000000004\t26.2' ]; then
    echo "✓ ⑤ mutant：pin=20.0 改判選到最新 26.2（而非①b 的 26.0）——確認①b 的答案是「選最接近」分支造成的"
  else
    echo "✗ ⑤ mutant 未如預期退化成「永遠選最新」（實得「${out5}」exit ${got5}）" >&2; fail=1
  fi
else
  echo "✗ ⑤ mutate：找不到標記行，負控本身無效" >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ pick-ipad-runtime 自測通過"
fi
exit "$fail"
