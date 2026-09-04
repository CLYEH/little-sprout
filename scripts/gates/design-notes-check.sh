#!/bin/bash
# LS-168：設計稿 Notes 板節點 id 存在性 gate（LS-96 池項 dbdbbaba 第一級）。
#
# 設計稿的 Notes 板（頂層 frame 名稱含「實作註記」或「Handoff Notes」）是 ios-dev 的契約，裡面引用的節點 id
# 若在改稿後已被刪除重建（LS-142 五度復發：Agczg 段 Q8xZl9／s4VXMV、oYEi0 段 C0GuD／CVOkb），讀者拿去稿內找不到。
# 判定邏輯在 design_notes_check.py（sh＋py 分工同 privacy-manifest-check）：Notes text 內的 id 形裸 token，若「曾是本 PR
# 範圍內某個 .pen 快照（merge-base 或範圍內任一觸碰 .pen 的 commit）的節點 id、但 head 快照已無」即缺失；同子句含沿革標記
# （原／當時／已刪除／取代舊／→ 等，清單見 .py 檔頭 HISTORY_MARKERS）者視為沿革敘述放行並印 info 行。
# 這支只做 git 端的算術：head（本機 HEAD／CI --head-sha，LS-127 同 design-evidence-check）、merge-base(base, head)、
# 範圍內觸碰 .pen 的 commit 清單，交給 .py 用 git show 讀快照。
#
# 觸發條件與 design-evidence-check 相同：.pen 有變更的 PR 才跑（CI rules job「.pen Notes 節點 id gate」step）。
#
# 盲區（明寫）：(1) 從未存在過的 id（打字錯）與同一 commit 內建又刪的 id 不在候選集、抓不到；(2) 只驗 id 存在，不驗
# Notes 裡的數字（板高／欄寬）是否與稿相符——dbdbbaba 第二級〔量:節點.屬性〕標記另評；(3) 沿革標記是子句級字面比對，
# 子句內剛好含「舊」「曾」等字的活指標會被放行（誤放行方向，不誤擋）。
#
# 用法：design-notes-check.sh <path.pen> --base <ref> [--head-sha <sha>]
# exit：0＝無缺失；1＝有缺失；2＝參數／git 錯誤（fail closed）。自測：design-notes-check.test.sh（CI rules job）。
set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/design_notes_check.py"

pen=""; base=""; head_sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ -n "${2:-}" ] || { echo "✗ design-notes gate：--base 缺值" >&2; exit 2; }
      base="$2"; shift 2 ;;
    --head-sha)
      [ -n "${2:-}" ] || { echo "✗ design-notes gate：--head-sha 缺值" >&2; exit 2; }
      head_sha="$2"; shift 2 ;;
    -*) echo "✗ design-notes gate：未知參數 $1" >&2; exit 2 ;;
    *)
      if [ -n "$pen" ]; then echo "✗ design-notes gate：只接受一個 .pen 路徑（多給了 $1）" >&2; exit 2; fi
      pen="$1"; shift ;;
  esac
done
[ -n "$pen" ] || { echo "✗ design-notes gate：缺 .pen 路徑" >&2; exit 2; }
[ -f "$pen" ] || { echo "✗ design-notes gate：找不到「${pen}」" >&2; exit 2; }
[ -n "$base" ] || { echo "✗ design-notes gate：缺 --base" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ design-notes gate：需要 python3" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ design-notes gate：找不到 ${py}" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ design-notes gate：不在 git 目錄內" >&2; exit 2; }

head="HEAD"
if [ -n "$head_sha" ]; then
  head=$(git rev-parse --verify --quiet "${head_sha}^{commit}") || {
    echo "✗ design-notes gate：--head-sha「${head_sha}」不是可解析的 commit（fail closed）" >&2
    exit 2
  }
fi
head=$(git rev-parse --verify --quiet "${head}^{commit}") || { echo "✗ design-notes gate：解析不到 head" >&2; exit 2; }
base_sha=$(git merge-base "$base" "$head" 2>/dev/null) || {
  echo "✗ design-notes gate：找不到 ${base} 與 ${head} 的共同祖先（fail closed）" >&2
  exit 2
}
pen_relpath=$(git ls-files --full-name -- "$pen" | head -1)
[ -n "$pen_relpath" ] || { echo "✗ design-notes gate：${pen} 不是 git 追蹤的檔案" >&2; exit 2; }

# 本 PR 範圍內觸碰這份 .pen 的 commit（含 head）；候選死 id＝這些快照 ∪ merge-base 快照的 id − head 快照 id
history=$(git rev-list "${base_sha}..${head}" -- "$pen_relpath") || {
  echo "✗ design-notes gate：無法列出 ${base_sha}..${head} 對 ${pen_relpath} 的 commit" >&2
  exit 2
}
# shellcheck disable=SC2086
python3 "$py" --pen "$pen_relpath" --head "$head" --base "$base_sha" --history $history
