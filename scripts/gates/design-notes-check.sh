#!/bin/bash
# LS-168：設計稿 Notes 板節點 id 存在性 gate（LS-96 池項 dbdbbaba 第一級）。
#
# 設計稿的 Notes 板（頂層 frame 名稱含「實作註記」或「Handoff Notes」）是 ios-dev 的契約，裡面引用的節點 id
# 若在改稿後已被刪除重建（LS-142 五度復發：Agczg 段 Q8xZl9／s4VXMV、oYEi0 段 C0GuD／CVOkb），讀者拿去稿內找不到。
# 判定邏輯在 design_notes_check.py（sh＋py 分工同 privacy-manifest-check）：Notes text 內的 id 形裸 token，若「曾是本 PR
# 範圍內某個 .pen 快照（merge-base 或範圍內任一觸碰 .pen 的 commit）的節點 id、但 head 快照已無」即缺失；同子句含沿革標記
# （原／當時／已刪除／取代舊 等，清單見 .py 檔頭 HISTORY_MARKERS；`→` 只放行緊鄰箭頭左側的舊 id，R1 N3）者視為沿革敘述放行並印 info 行。
# 這支只做 git 端的算術：head（本機 HEAD／CI --head-sha，LS-127 同 design-evidence-check）、merge-base(base, head)、
# 範圍內觸碰 .pen 的 commit 清單，交給 .py 用 git show 讀快照。
#
# 觸發條件與 design-evidence-check 相同：.pen 有變更的 PR 才跑（CI rules job「.pen Notes 節點 id gate」step）。
#
# LS-202 署名年齡片語 NBSP（LS-96 池項 ed90c6ab）：同一支順便驗 `cmp/Card Album`／`cmp/Card Diary` 的署名文字（元件定義內的 text
# ＋全稿實例的 descendants content 覆寫）裡 `歲`／`個月` 前的空白只准 U+00A0／U+2060／換行——含 U+0020 即命中，印節點（或實例 id／
# override 鍵）與 codepoint 序列。--base 增量：命中所在的頂層節點在 merge-base→head 有變更才算違規（紅），未觸碰的板列「（舊債）」
# 警告不擋（LS-201 未併前 development 現況：X9PfG HIdMW／HLXo3 fZ3KF 與 cmp/Card Diary 定義 zk1yE／x7k2o6，皆為他票舊債）。
#
# 盲區（明寫）：(1) 從未存在過的 id（打字錯）與同一 commit 內建又刪的 id 不在候選集、抓不到；(2) 只驗 id 存在，不驗
# Notes 裡的數字（板高／欄寬）是否與稿相符——dbdbbaba 第二級〔量:節點.屬性〕標記另評；(3) 沿革標記是子句級字面比對，
# 子句內剛好含「舊」「曾」等字的活指標會被放行（誤放行方向，不誤擋）——merge-review R1 N3 實測 development 4 塊 Notes 板 768 次活 id
# 引用有 195（25.4%）所在子句已含標記（`→` 60／`原` 76 最大宗）；`→` 已收窄為緊鄰箭頭左側，其餘字面標記維持；(4) NBSP 檢查只看
# 兩個卡片元件（legacy 板的非元件 Age Text、Notes 散文不在範圍）、只看單位**前**的空白（「2 歲 3 個月」中 歲 與 3 之間不驗）、
# 只擋 U+0020（U+3000 全形空白或完全無空白不擋）；「觸碰的板」用頂層 JSON 是否變更判定——動 `cmp/Card Diary` 定義就得順手修掉
# 定義內的 U+0020，動某板就得修掉該板實例的覆寫。
#
# LS-300 畫面級屬性清單（LS-96 池項 3aa46c78）：同一支再驗第三件事——本 PR 新增的**正典畫面**（頂層 frame，名稱形如
# 「<群組> / <編號或名稱>」，排除 Notes 板本身與 `cmp/` 元件定義）是否每一個都在 Notes 板「畫面級屬性」段（子字串
# 「畫面級屬性」之後的文字，跨全部 Notes 板）裡被任一變體板名子字串比對命中——缺 Notes 段落或段內未提及任一變體
# 即紅，逐正典畫面點名。
#
# R2（merge-review R1 M1）正典畫面歸併：深色／AX3／iPad（含編號後綴 `-iPad`）等同一畫面的裝置／外觀變體板，
# 原版各自當一塊「新畫面板」，對 LS-251 分支（六畫面）逼出 30 行缺列——與票文「畫面級屬性」欄位本身就含深色/AX3/iPad
# 特例的設計意圖矛盾（設計意圖是一個畫面一行、差異記在該行欄位裡）。
#
# R3（merge-review R2 M2）正典鍵改含基底群，不再無條件丟棄群組前綴：R2 版把「/」之前的群組前綴整段丟棄，只憑編號
# 歸併，導致 `Import / 01` 與 `Growth / 01` 這種語意完全不同、只是恰好都從 01 開始編號的畫面被誤併——Notes 只寫其中
# 一個、另一個完全沒寫也判過（reviewer 端對端重放證實，major）。正典鍵改成「基底群 ＋（編號或去裝飾名）」：
# `screen_key_and_display()` 只剝裝飾字樣（`DERIVED_SUFFIX_RE`）算出編號或去裝飾名，不處理群組；`new_screen_boards()`
# 先把非衍生群組（不符 `DERIVED_GROUP_RE`，如 `Import`／`Growth`）的 `(群組, 編號)` 登記起來，只有明確在
# `DERIVED_GROUP_RE`（`A11y`／`Stress` 白名單）裡的衍生群組，才用編號回查本批候選裡「非衍生群組」用了同一個編號的
# 有幾個——恰好一個才映射過去併入該基底群，查不到或有多個不同候選（撞號）一律不歸併、退回用衍生群組自己的字面當
# 基底群（安全預設）。`screen_attr_missing()` 對每個正典畫面只要任一 member 變體板名出現在「畫面級屬性」段之後即
# 算放行。LS-251 實測：30 個變體板 → 8 個正典畫面（`Import/01`…`Import/06b`），且合成的跨群組撞號夾具（`Import / 01`
# ＋ `Growth / 01`）驗證不再誤併。
#
# 欄位格式（隱藏 Tab Bar／標題型態／釘底動作帶／失敗文案鍵／深色特例／AX3 特例／iPad 重排放大）見
# docs/COLLABORATION.md §1 與 .claude/agents/ui-designer.md Notes 段；本 gate 只驗「這個正典畫面有沒有被提到」，
# 不驗欄位內容是否填齊——欄位完整度是 ios-dev handoff／merge-reviewer 的責任（handoff_evidence_check.py 認「畫面
# 級屬性（逐條勾選）」子段）。盲區：(5) 衍生群組（`A11y`／`Stress`）與基準群組同編號即歸併，不同編號（或名稱型
# 畫面去裝飾字樣後文字不同）則各自獨立正典畫面——若某衍生變體的板編號打錯（如誤植 `02` 而非 `01`），會被歸到錯誤
# 的正典畫面而非抓出這個打字錯，見 design_notes_check.py 檔頭；(5b) 衍生群組回查基底群只在「本批新增候選裡恰好
# 一個非衍生群組用了這個編號」時才映射——若該基底群的板早已存在（不在本 PR 新增範圍內，只有衍生變體是新增的），
# 回查不到候選、衍生變體會退回用自己的字面（`A11y`／`Stress`）當基底群、要求獨立一行，即使實際上它就是某個既有
# 畫面的衍生變體（誤要求方向，不誤放行）；(6) 只驗變體板名子字串出現在段落之後的文字裡，不驗「這一列真的是這塊板
# 的列」——板名恰好出現在段落內其他畫面的敘述文字裡也會被誤判命中（誤放行方向，不誤擋；R2 起同一正典畫面本來就
# 允許任一變體命中，這個盲區只影響「命中的是不是同一正典畫面內的敘述」這個更細的判斷）。
#
# 用法：design-notes-check.sh <path.pen> --base <ref> [--head-sha <sha>]
# exit：0＝無缺失且無 NBSP 違規；1＝有缺失或 NBSP 違規；2＝參數／git 錯誤（fail closed）。自測：design-notes-check.test.sh（CI rules job）。
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
