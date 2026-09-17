#!/bin/bash
# LS-316：設計 PR body `Design:` 行內容 gate——板名／id 對 head .pen 頂層節點逐筆核對。
#
# 為什麼：現行 CI Design gate（ci.yml「Design gate（新增 SwiftUI View 需附設計稿標記）」step）只驗
# `Design:` 欄位非空（`grep -qE 'Design:[[:space:]]*[^[:space:]]'`），沒有驗內容真假——LS-252 #471
# merge-review R1 抓到 sonnet 開設計 PR 時 body 的板描述是杜撰的，非空檢查完全擋不住（LS-96 池項
# `216c3a2d`）。這支補上「板名／id 真的對得上 .pen」這一層：解析 body 裡所有 `Design:` 行，對每個 id
# 在 head .pen 快照的頂層節點（含 reusable component——與板同一層級的頂層 children，不特別過濾）查
# name，逐筆比對。
#
# 支援兩種寫法（LS-307 #475 body 實例：`Design: Import / 00 時間軸入口 (iPhone)（\`e1cOqx\`）、cmp/Button
# Import（\`o8zYlX\`）`）：
#   1. `<板名>（<id>）`：id 可用反引號包住、全形括號前後空白容忍；板名本身可含半形括號
#      （如 `Import / 00 時間軸入口 (iPhone)`）——只認整條目**最後**一組全形括號當 id，其餘都算板名。
#   2. 純 id：不含全形括號、整條目就是一個 id 形 token（反引號可省）。
#   同一 `Design:` 行內多條目以 `、` 或 `,` 分隔（該行用了哪個就切哪個；都沒有就整行當一條）。
#   id 形＝5–6 碼英數（沿 design_notes_check.py 既有慣例：Pencil id 實測皆 5–6 碼）。
#
# 判定：
#   - id 不在 head .pen 頂層節點裡 → ✗ 缺 id
#   - 寫法 1 且 id 存在但宣稱的板名與 .pen 實際名稱不符（全形括號內外空白正規化、內部連續空白壓一個、
#     頭尾去空白後逐字比對）→ ✗ 名稱不符
#   - 寫法 2（純 id）：id 存在即通過（沒有宣稱名稱可比，只驗存在性）
#   - 無 `Design:` 行 → exit 0，是否非空交既有 CI 檢查決定（這支不重複做那件事）
#   - 條目解析不出寫法 1 或寫法 2（形狀不明）→ 不算違規，印一行（略過）——寧可漏放行也不要對未預期
#     的合法寫法誤擋（同 design_notes_check.py 一貫「明寫盲區」的取態），是本 gate 的已知盲區。
#
# 用法：design-ref-check.sh <body-file> <path.pen> [--head-sha <sha>]
#   --head-sha 預設 HEAD（`git show <sha>:<pen>` 讀快照，同 design-notes-check.sh 慣例；CI 傳 PR head
#   sha 避開 LS-127 merge-ref 誤讀）。body-file 直接讀檔（非 git 物件——PR body 是暫存檔，不進版控）。
# exit：0＝無 Design: 行，或逐筆核對皆通過；1＝有缺失（缺 id／名稱不符）；2＝參數／git／python 錯誤
#   （fail closed）。自測：design-ref-check.test.sh（CI rules job）。
set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/design_ref_check.py"

body=""; pen=""; head_sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head-sha)
      [ -n "${2:-}" ] || { echo "✗ design-ref gate：--head-sha 缺值" >&2; exit 2; }
      head_sha="$2"; shift 2 ;;
    -*) echo "✗ design-ref gate：未知參數 $1" >&2; exit 2 ;;
    *)
      if [ -z "$body" ]; then body="$1"; shift
      elif [ -z "$pen" ]; then pen="$1"; shift
      else echo "✗ design-ref gate：只接受 <body-file> <path.pen>（多給了 $1）" >&2; exit 2
      fi ;;
  esac
done
[ -n "$body" ] || { echo "✗ design-ref gate：缺 body 檔路徑" >&2; exit 2; }
[ -r "$body" ] || { echo "✗ design-ref gate：讀不到 body 檔「${body}」" >&2; exit 2; }
[ -n "$pen" ] || { echo "✗ design-ref gate：缺 .pen 路徑" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ design-ref gate：需要 python3" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ design-ref gate：找不到 ${py}" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ design-ref gate：不在 git 目錄內" >&2; exit 2; }

head="HEAD"
if [ -n "$head_sha" ]; then
  head=$(git rev-parse --verify --quiet "${head_sha}^{commit}") || {
    echo "✗ design-ref gate：--head-sha「${head_sha}」不是可解析的 commit（fail closed）" >&2
    exit 2
  }
fi
head=$(git rev-parse --verify --quiet "${head}^{commit}") || { echo "✗ design-ref gate：解析不到 head" >&2; exit 2; }
pen_relpath=$(git ls-files --full-name -- "$pen" | head -1)
[ -n "$pen_relpath" ] || { echo "✗ design-ref gate：${pen} 不是 git 追蹤的檔案" >&2; exit 2; }

python3 "$py" --body "$body" --pen "$pen_relpath" --head "$head"
