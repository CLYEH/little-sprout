#!/bin/bash
# food-sticker-size-check.sh 的自測（LS-387）。CI rules job 每個 PR 都跑。
# 若門檻反轉、邊界算錯（剛好 40960／剛好 11 MB 該放行）、單張或總量檢查任一被拿掉，這裡會紅：
#   1. 小檔放行；2. 單張剛好 40960 放行；3. 單張 41 KB 擋、點名檔名；4. 總量剛好 11534336 放行；
#   5. 總量超標（每張都合規）擋；6. 非 .png 的檔也算進單張檢查（整個資料夾都進 bundle）；
#   7. 目錄不存在 fail closed；8. 版控內真實 stickers/ 綠；
#   9／10. mutation：拿掉 PER-FILE-CHECK → 3 翻綠；拿掉 TOTAL-CHECK → 5 翻綠（證明 3／5 真的在測）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/food-sticker-size-check.sh"
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# mkfile <目錄> <檔名> <bytes>
mkfile() { mkdir -p "$1"; head -c "$3" /dev/zero > "$1/$2"; }

run() { out="$(bash "$1" "$2" 2>&1)"; rc=$?; }

# 1. 小檔放行
d1="${work}/d1"; mkfile "$d1" a.png 1024; mkfile "$d1" b.png 2048
run "$checker" "$d1"
expect_exit 0 "$rc" "1. 小檔放行"

# 2. 單張剛好 40960 放行（只有嚴格大於才擋）
d2="${work}/d2"; mkfile "$d2" edge.png 40960
run "$checker" "$d2"
expect_exit 0 "$rc" "2. 單張剛好 40960 bytes 放行"

# 3. 單張 41 KB 擋
d3="${work}/d3"; mkfile "$d3" ok.png 1024; mkfile "$d3" big.png 41984
run "$checker" "$d3"; out3=$out
expect_exit 1 "$rc" "3. 單張 41 KB（41984 bytes）→ exit 1"
expect_has "$out3" "big.png（41984 bytes" "3. 訊息點名超標檔與大小"
expect_not_has "$out3" "ok.png（" "3. 合規檔不被點名"

# 4. 總量剛好 11534336 放行：281 × 40960 ＋ 24576
d4="${work}/d4"; mkdir -p "$d4"
head -c 40960 /dev/zero > "${work}/blk"
for i in $(seq 1 281); do cp "${work}/blk" "${d4}/s${i}.png"; done
mkfile "$d4" tail.png 24576
run "$checker" "$d4"
expect_exit 0 "$rc" "4. 總量剛好 11534336 bytes 放行"

# 5. 總量超標（每張都合規）：再加 1 byte
mkfile "$d4" extra.png 1
run "$checker" "$d4"; out5=$out
expect_exit 1 "$rc" "5. 總量 11534337 bytes（每張皆 ≤40960）→ exit 1"
expect_has "$out5" "總量 11534337 bytes" "5. 訊息點名總量"
expect_not_has "$out5" "超過單張上限" "5. 只因總量紅，不誤報單張"

# 6. 非 .png 也算
d6="${work}/d6"; mkfile "$d6" stray.heic 50000
run "$checker" "$d6"
expect_exit 1 "$rc" "6. 非 .png 超標檔也擋（整個資料夾都進 bundle）"
expect_has "$out" "stray.heic" "6. 訊息點名非 .png 檔"

# 7. 目錄不存在 fail closed
run "$checker" "${work}/nope"
expect_exit 2 "$rc" "7. 目錄不存在 → exit 2（fail closed）"

# 8. 版控內真實 stickers/
run "$checker" "${root}/design/food-stickers/stickers"
expect_exit 0 "$rc" "8. 版控內 design/food-stickers/stickers/ 綠"

# 9／10. mutation
mutate() {  # mutate <標記> <輸出檔>：把標記所在的 if 條件改成 false
  awk -v m="$1" 'index($0, "# " m) > 0 { sub(/if \[.*\]; then/, "if false; then"); print; next } { print }' "$checker" > "$2"
}
mut_file="${work}/no-per-file.sh"; mutate "PER-FILE-CHECK" "$mut_file"
if grep -q 'if false; then  # PER-FILE-CHECK' "$mut_file"; then
  run "$mut_file" "$d3"
  expect_exit 0 "$rc" "9. mutant（拿掉單張檢查）：3 的夾具改判 exit 0——證明 3 真的在測單張上限"
else
  fail "9. 找不到 PER-FILE-CHECK 標記行，負控本身無效"
fi
mut_total="${work}/no-total.sh"; mutate "TOTAL-CHECK" "$mut_total"
if grep -q 'if false; then  # TOTAL-CHECK' "$mut_total"; then
  run "$mut_total" "$d4"
  expect_exit 0 "$rc" "10. mutant（拿掉總量檢查）：5 的夾具改判 exit 0——證明 5 真的在測總量上限"
else
  fail "10. 找不到 TOTAL-CHECK 標記行，負控本身無效"
fi

if [ "$selftest_helpers_fail" -eq 0 ]; then
  echo "✓ food-sticker-size-check 自測通過（${selftest_helpers_n} 組樣本）"
  exit 0
fi
exit 1
