#!/bin/bash
# design/ 大檔二進位體積 gate（LS-74）。
#
# 背景：LS-46 PR #104 review 一度誤判「.pen 逐輪快照」是體積負債；LS-72 PR #119 review 實測推翻
# ——.pen 是純 JSON，git delta-pack 後每版增量極小（5 版 raw 6.98 MB → pack 0.15 MB）。真正吃掉
# repo 體積、且刪除後仍永留封包歷史的是 design/*.png 這類不可 delta 的二進位大檔（單張 1–2.6 MB）。
# 本 gate 只擋這一種形狀：design/ 目錄下新增或修改之後單檔仍超過 500 KB 的**二進位**檔；文字檔
# （.pen JSON、`design/evidence/<票>-r<n>-overflow.json` 等）不受限——LS-68 的溢出掃描收據就落在
# 後者，必須不受影響。
#
# 二進位判定：不重造輪子，借用 git 自己的判斷——`git diff --numstat` 對 git 視為二進位的檔案
# （`buffer_is_binary()`：只看內容前 8000 bytes 有沒有 NUL byte，或 .gitattributes 的 diff／-diff／
# binary 屬性覆寫）在新增／刪除欄位印 "-"。
#
# 誠實澄清（merge-review R1 F2，2026-09 實測推翻本行原先「與 delta-pack 同一套判準」的說法）：這**不是**
# git 決定「這個 blob 能不能 delta-pack」的同一套判準——pack 端的 delta 決策看的是版間內容是否相似
# （`gc --aggressive` 實測：整批換內容的 600 KB 級 base64 文字，5 版 pack 後仍佔 raw 的 78%；同尺寸每版
# 小改的大型文字則只佔 4%），跟 `--numstat` 的二進位旗標無關；`.gitattributes` 加一行 `design/*.png diff`
# 可以讓超標 PNG 在 numstat 顯示成文字，但對 pack 決策毫無影響。這裡只是借用一個**便宜的代理指標**：
# 對本 repo 真正的負債大宗（`design/*.png`）判定完全準確——真 PNG/JPEG 標頭在前 16 bytes 就含 NUL，
# 不會誤放；獨立量測 `design/littlesprout.pen`（86 版，raw 138.13 MB → pack 0.83 MB，0.6%）對比
# `design/*.png`（9 個 blob，raw 14.41 MB → pack 14.11 MB，98.0%，佔封包 72%）證實 LS-72 的體積歸因
# 在 86 版之後依然成立——但「巨大、低壓縮性的文字內容」（base64 內嵌圖片的 SVG／JSON、前段長 ASCII
# 的向量 PDF）會被判定為文字而放行，是已知盲區（§7「盲區」欄，記入 LS-96）。不用 `file --mime-type`
# （外部工具依賴，且判斷邏輯一樣不等於 pack 決策）、不自己重新掃 NUL byte（git 已經算過，重算只是
# 重複邏輯又可能與 git 實際掃描行為兜不起來）。
#
# LFS pointer 例外：刻意不留。LS-74 票文三選項中的方案 1（git-lfs）裁決緩議——repo 未設定
# `.gitattributes` 的 lfs filter、`git lfs` 未安裝，沒有 LFS 就不會有 LFS pointer 檔案，留一條
# 測不到、永遠走不到的例外分支是投機的複雜度（CLAUDE.md Rule 2：不寫沒被要求的靈活性）。真的導入
# LFS 那天，這個例外與它的自測一起補上，而不是現在先埋一個沒人驗證過的分支。
#
# 範圍：只看 design/ 目錄（pathspec 'design'，含 design/evidence/ 等子目錄）；`--diff-filter=ACM
# --no-renames`——新增／修改才算；純改名（內容不變）在 --no-renames 下拆成 delete+add，ACM 濾掉
# delete 只留 add，等同「改名也算碰了這個路徑」一併受檢（不特判成「未觸碰」——實測見
# design-asset-size-check.test.sh）；純刪除不擋（同 evidence-path-check 的 --diff-filter=d 邏輯：
# 清掉大檔要放行）。既有、這次 diff 完全沒碰到的大檔案不在 --cached／--base 的 diff 範圍內，天然
# 不會被掃到——不重寫歷史、不轉換既有檔。
#
# 門檻：500 KB＝512000 bytes（KiB 慣例）；只有「嚴格大於」才擋，剛好 500 KB 放行。
#
# 用法（同 evidence-path-check.sh 的 --base 模式，LS-69）：
#   design-asset-size-check.sh [--base <ref>] [repo 路徑]
# 不帶 --base 看 `--cached`（pre-commit 用）；--base <ref> 看 `<ref>...HEAD`（三點語法，CI rules
# job 對 PR merge ref 跑的模式——本機 `--no-verify` 繞過 pre-commit 時的伺服器端兜底）。repo 路徑
# 只給自測餵臨時 repo 用，hook／CI 不帶。
set -euo pipefail

THRESHOLD_BYTES=512000  # 500 KB（KiB 慣例：500 * 1024）

base=""
if [ "${1:-}" = "--base" ]; then
  if [ -z "${2:-}" ]; then
    echo "✗ design-asset-size gate：--base 需要接一個 ref 參數（fail closed）" >&2
    exit 2
  fi
  base="$2"
  shift 2
fi

repo="${1:-$(git rev-parse --show-toplevel)}"
if ! cd "$repo" 2>/dev/null; then
  echo "✗ design-asset-size gate：找不到目錄「${repo}」（fail closed）" >&2
  exit 2
fi

# 非 git 目錄時先探測（同 evidence-path-check N1）：讓下面的 git diff 直接吃到非 repo 路徑，
# 三點語法對 git 而言仍是合法選項組合，會誤判成 --no-index 執行，噴出完整 usage 把真正錯誤淹沒。
if ! git_dir_err=$(git rev-parse --git-dir 2>&1 >/dev/null); then
  echo "✗ design-asset-size gate：「${repo}」不是 git 目錄（fail closed）：${git_dir_err}" >&2
  exit 2
fi

mode_desc="staged"
size_ref="INDEX"
if [ -n "$base" ]; then
  mode_desc="${base}...HEAD"
  size_ref="HEAD"
fi

if [ -n "$base" ]; then
  numstat_cmd=(git diff --no-renames --diff-filter=ACM -z --numstat "${base}...HEAD" -- design)
else
  numstat_cmd=(git diff --cached --no-renames --diff-filter=ACM -z --numstat -- design)
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! "${numstat_cmd[@]}" > "$list"; then
  echo "✗ design-asset-size gate：「${repo}」git diff（${mode_desc}）失敗（fail closed）" >&2
  exit 2
fi

hits=""
# numstat -z：每筆記錄是 "<added>\t<deleted>\t<path>"，以 NUL 結尾（實測確認，無額外分隔符）。
# 二進位檔的 added/deleted 兩欄皆印 "-"；用 -z 讀取避免 name-only 那種引號檔名的坑（同
# evidence-path-check R1 I1）。
while IFS= read -r -d '' rec; do
  [ -n "$rec" ] || continue
  added="${rec%%$'\t'*}"
  rest="${rec#*$'\t'}"
  deleted="${rest%%$'\t'*}"
  path="${rest#*$'\t'}"
  [ -n "$path" ] || continue
  if [ "$added" != "-" ] || [ "$deleted" != "-" ]; then
    continue  # git 判定為文字檔（可 delta），不受本 gate 限制
  fi
  if [ "$size_ref" = "INDEX" ]; then
    size=$(git cat-file -s ":${path}" 2>/dev/null) || {
      echo "✗ design-asset-size gate：讀不到「${path}」staged 內容的大小（fail closed）" >&2
      exit 2
    }
  else
    size=$(git cat-file -s "HEAD:${path}" 2>/dev/null) || {
      echo "✗ design-asset-size gate：讀不到「${path}」在 HEAD 的內容大小（fail closed）" >&2
      exit 2
    }
  fi
  if [ "$size" -gt "$THRESHOLD_BYTES" ]; then
    hits+="    ${path}（二進位，${size} bytes ＞ ${THRESHOLD_BYTES} bytes）"$'\n'
  fi
done < "$list"

if [ -n "$hits" ]; then
  echo "✗ design-asset-size gate（${mode_desc}）：design/ 下列二進位檔超過 500 KB：" >&2
  printf '%s' "$hits" >&2
  echo "  解法：新增／修改的素材請先壓縮——設計稿內照片 placeholder 改 ≤1024px JPEG；字標／icon 素材保留 PNG 但限制尺寸（見 .claude/agents/ui-designer.md）。**若這個檔案是既有大檔的純搬移／改名（內容未變）**，壓縮並不能解決問題——本 gate 刻意把「改名」也視為觸碰而擋下（設計選擇，見上方「範圍」段），純搬移目前沒有機械逃生口，請回報 orchestrator 個案處理，不要為了通過而重壓一批本來合法的既有素材。文字檔（.pen、design/evidence/*.json）不受限、不算在內。既有、這次沒碰到的大檔不受影響——只擋這次新增或修改的檔。" >&2
  exit 1
fi
echo "✓ design-asset-size gate（${mode_desc}）：design/ 無超過 500 KB 的二進位新增／修改"
