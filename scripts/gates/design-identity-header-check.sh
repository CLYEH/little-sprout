#!/bin/bash
# LS-309 C：Identity Header 年齡字串 NBSP gate（LS-96 池項 `285d3310`；來源 LS-252 VR R2/R3 comment `8dbba1c8`／
# `ba033c73`：01/04/06 三張板各自 Identity Header 的 9 個年齡字串全違反稿內 NBSP 規則，`design-notes-check.sh`
# 既有的署名 NBSP 檢查只掃 `cmp/Card Album`／`cmp/Card Diary` 兩個元件，掃不到板自己的 Identity Header 節點，
# 靠人工 hex dump 才抓到）。
#
# 判定邏輯在 design_identity_header_check.py（sh＋py 分工同 design-notes-check.sh）：掃本 PR 觸碰的板（頂層
# 節點，merge-base→head JSON 有變更即觸碰，取法同 design_notes_check.py 的 touched_roots()）子樹內全部 text
# 節點與 ref 實例 descendants 覆寫，年齡字串（「N 歲 N 個月」／「N 個月」兩種樣式）每個分隔位置須恰為
# `cmp/Card Diary` 參照節點 `zk1yE` 的 codepoint（三個 U+00A0＋一個 U+2060）——缺分隔／退化成一般空白／多字元
# 皆算違規。
#
# 觸發條件同 design-notes-check.sh：.pen 有變更的 PR 才跑（CI rules job 對應 step）。
#
# 盲區（明寫）：(1) 只認「N 歲 N 個月」「N 個月」兩種文字樣式——年齡文案改別的措辭（例如英文、或不含
# 「歲」「個」「月」字面的呈現）偵測不到；(2) 只掃本 PR 觸碰板的子樹，未觸碰板上的既有違規（舊債）不擋，
# 也不像 design-notes-check.sh 的署名 NBSP 檢查那樣印「（舊債）」警告行——這支的範圍本來就限定觸碰板；
# (3) 「觸碰的板」用頂層 JSON 是否變更判定，動某板子樹深處的一個節點就得順手核對整塊板的年齡字串。
#
# 用法：design-identity-header-check.sh <path.pen> --base <ref> [--head-sha <sha>]
# exit：0＝無違規；1＝有違規；2＝參數／git 錯誤（fail closed）。自測：design-identity-header-check.test.sh（CI rules job）。
set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/design_identity_header_check.py"

pen=""; base=""; head_sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ -n "${2:-}" ] || { echo "✗ design-identity-header gate：--base 缺值" >&2; exit 2; }
      base="$2"; shift 2 ;;
    --head-sha)
      [ -n "${2:-}" ] || { echo "✗ design-identity-header gate：--head-sha 缺值" >&2; exit 2; }
      head_sha="$2"; shift 2 ;;
    -*) echo "✗ design-identity-header gate：未知參數 $1" >&2; exit 2 ;;
    *)
      if [ -n "$pen" ]; then echo "✗ design-identity-header gate：只接受一個 .pen 路徑（多給了 $1）" >&2; exit 2; fi
      pen="$1"; shift ;;
  esac
done
[ -n "$pen" ] || { echo "✗ design-identity-header gate：缺 .pen 路徑" >&2; exit 2; }
[ -f "$pen" ] || { echo "✗ design-identity-header gate：找不到「${pen}」" >&2; exit 2; }
[ -n "$base" ] || { echo "✗ design-identity-header gate：缺 --base" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ design-identity-header gate：需要 python3" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ design-identity-header gate：找不到 ${py}" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ design-identity-header gate：不在 git 目錄內" >&2; exit 2; }

head="HEAD"
if [ -n "$head_sha" ]; then
  head=$(git rev-parse --verify --quiet "${head_sha}^{commit}") || {
    echo "✗ design-identity-header gate：--head-sha「${head_sha}」不是可解析的 commit（fail closed）" >&2
    exit 2
  }
fi
head=$(git rev-parse --verify --quiet "${head}^{commit}") || { echo "✗ design-identity-header gate：解析不到 head" >&2; exit 2; }
base_sha=$(git merge-base "$base" "$head" 2>/dev/null) || {
  echo "✗ design-identity-header gate：找不到 ${base} 與 ${head} 的共同祖先（fail closed）" >&2
  exit 2
}
pen_relpath=$(git ls-files --full-name -- "$pen" | head -1)
[ -n "$pen_relpath" ] || { echo "✗ design-identity-header gate：${pen} 不是 git 追蹤的檔案" >&2; exit 2; }

python3 "$py" --pen "$pen_relpath" --head "$head" --base "$base_sha"
