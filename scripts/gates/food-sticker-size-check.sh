#!/bin/bash
# 食物圖鑑貼紙體積 gate（LS-387）。
#
# 背景：`project.yml` 以 folder reference 把 `design/food-stickers/stickers/` 整個資料夾打包進 app（LS-379），
# 274 張 384² RGBA PNG 曾共 ~43 MB，app 體積直接 +43 MB。LS-387 把裁切管線輸出改成調色盤量化
# （`scripts/design/food-sticker-crop.py` 的 quantize_sticker()），本 gate 釘住結果：
#   - 單張 ≤ 40960 bytes（40 KB，與裁切腳本的 MAX_STICKER_BYTES 同值）
#   - 總量 ≤ 11534336 bytes（11 MB）
# 任一超標即紅並點名。資料夾內所有一般檔都算（整個資料夾都進 bundle，不只 *.png）。
#
# 和 design-asset-size-check.sh 的差別：那支只看「這次 diff 新增／修改」的單檔 500 KB 門檻（擋 repo 體積
# 負債）；這支看的是資料夾的**現況總量**（擋 app bundle 體積），不論這次 diff 有沒有碰到——任何 PR 讓總量
# 越線都要紅，所以是整個目錄掃描、不吃 diff。
#
# 用法：food-sticker-size-check.sh [貼紙目錄]（預設 <repo>/design/food-stickers/stickers；自測餵臨時目錄）
set -uo pipefail

MAX_FILE_BYTES=40960       # 40 KB
MAX_TOTAL_BYTES=11534336   # 11 MB（11 * 1024 * 1024）

dir="${1:-$(git rev-parse --show-toplevel 2>/dev/null)/design/food-stickers/stickers}"
if [ ! -d "$dir" ]; then
  echo "✗ food-sticker-size gate：找不到目錄「${dir}」（fail closed）" >&2
  exit 2
fi

total=0
count=0
hits=""
while IFS= read -r -d '' f; do
  size=$(wc -c < "$f" | tr -d '[:space:]')
  total=$((total + size))
  count=$((count + 1))
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then  # PER-FILE-CHECK（自測 mutation 標記）
    hits+="    ${f#"${dir}"/}（${size} bytes ＞ ${MAX_FILE_BYTES} bytes）"$'\n'
  fi
done < <(find "$dir" -type f -print0 | sort -z)

rc=0
if [ -n "$hits" ]; then
  echo "✗ food-sticker-size gate：下列貼紙超過單張上限 ${MAX_FILE_BYTES} bytes：" >&2
  printf '%s' "$hits" >&2
  rc=1
fi
if [ "$total" -gt "$MAX_TOTAL_BYTES" ]; then  # TOTAL-CHECK（自測 mutation 標記）
  echo "✗ food-sticker-size gate：總量 ${total} bytes（${count} 個檔）＞ 上限 ${MAX_TOTAL_BYTES} bytes" >&2
  rc=1
fi
if [ "$rc" -ne 0 ]; then
  echo "  解法：用 scripts/design/food-sticker-crop.py 重切（輸出段會逐級降色數到 ≤40 KB），不要手動放未量化的 PNG；見 design/food-stickers/README.md「量化」段。" >&2
  exit 1
fi
echo "✓ food-sticker-size gate：${count} 個檔共 ${total} bytes（上限 ${MAX_TOTAL_BYTES}），單張皆 ≤ ${MAX_FILE_BYTES} bytes"
