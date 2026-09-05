#!/bin/bash
# LS-68 規則 4：.pen 掃描收據 gate（R2：merge-review R1 F1／F2 修正）。
#
# 溢出掃描（兄弟節點交集／橫列內容溢出）需要 Pen app 的版面引擎才能算出絕對座標，GitHub runner
# 沒有 Pen，掃描本身沒辦法在 CI 跑。改為 ui-designer handoff 時把掃描結果寫成
# design/evidence/<票號>-r<n>-overflow.json 隨 PR 提交（`design/evidence/` 是明文 JSON、要進版控的
# 收據，不是 `.claude/evidence/` 那種 gitignored 的審查取證——evidence-path-check.sh 的 review*／ls[0-9]*
# 目錄層規則與 png 白名單都不擋這個路徑，已實測確認）。這支腳本驗收據本身 CI 端能機械驗的部分：
#   - .pen 有變更的 PR 必須附上本票這一輪的收據檔（找不到就紅）
#   - 每一份收據的 head_sha 必須是「這個 PR 自己對這份 .pen 檔的其中一次 commit」（不是隨便貼一個 sha、
#     也不是別票／別分支留下的舊收據）
#   - 每一份收據的 total_nodes 必須等於 design-landing-check.sh 對「該收據 head_sha 那個時點的 .pen
#     快照」算出的節點數（R2 F1：不是比對工作區當下／PR 最終那份 .pen——見下方「R2 修正」）
#   - **輪次最高（最新）那份收據**的 head_sha 必須等於 base..head 範圍內「最後一次觸碰這份 .pen 的
#     commit」（R2 F2：見下方「R2 修正」；head 本機＝HEAD、CI＝--head-sha 傳入的 PR head，LS-127），較早輪次的收據
#     只驗自己那個時點的快照，不必是最後一次
#   - 收據必須同時含兩支掃描的輸出：scans.sibling_intersection／scans.row_overflow（LS-67 R1：
#     ui-designer 只跑對兄弟碰撞無感的 ctx.problems 就宣稱 FLAGGED=0，reviewer 用絕對座標交集才抓到
#     真碰撞——本 gate 要求兩支掃描的輸出都要在，不能只交一支）
#   - 每一支掃描下 flagged 陣列裡的每一筆都要有非空的 classification（分類表）
#   - **LS-122：四支掃描**——scans 另須含 cross_parent_collision（跨 parent 絕對座標碰撞，flagged 每筆有分類）與
#     corner_anchor（角托錨點核對：containers／points／mismatch／document_mismatch 四個非負整數，**mismatch 必為 0、
#     flagged 必為空**——角托錯位不接受白名單；`boards`＝本票觸碰的 root frame id 清單、非空，每個都要是 head_sha 快照的
#     頂層節點，且 merge-base→head_sha 之間頂層節點有變更（含新增）的板都必須列在其中——mismatch 只算 boards 內，
#     全稿另列 document_mismatch 供參考不擋（orchestrator 裁定 a106f940：他票 43 點舊債另開 chore）；`unresolved`
#     ＝找不到吻合紙面的角托容器清單，每筆須有 classification）。LS-119 R5 的兩個 BLOCKER（角托縮進紙面 148 點、
#     相鄰格角托跨 parent 重疊 80 筆）與 MJ-6（instance descendants 才 enable 的徽章被裁）都是兩支既有掃描結構上抓不到
#     的類別；四支的正典腳本是 scripts/design/overflow-scan.js（供 Pencil execute 載入，node 自測 overflow-scan.test.js）。
#     **舊 schema 不回溯紅**：head_sha 那次 commit 的 committer 時間早於 LEGACY_CUTOFF（2026-09-02T04:00Z，本 gate
#     落地時點）的收據沿用兩支 schema——「既有收據」＝本 gate 之前就落地的收據（LS-119 r5／r6），不看輪次（merge-review
#     R1 MJ-1：R1 版另加 round ≤ 5 會把 cutoff 前的 LS-119 r6 踢紅）；之後任何票的任何輪次（含新票 r1）都要四支。
#   - **LS-168：第五支＋新鮮度**——收據另須含 `tree_hash`（掃描當下未展開 instance 全樹的 FNV-1a 64 雜湊，正典腳本印在
#     SUMMARY）與 `scans.text_occlusion`（文字被 Action Bar／Tab Bar／Capsule／Footer／Toast／Banner 蓋住，**flagged 必為空**、
#     不接受白名單——VR R1 f1cf27d0 的 BL-2／BL-3 都該被它抓到）。gate 用 scripts/gates/design_tree_hash.py（與 overflow-scan.js
#     同規格）對 `head_sha` 那份 .pen 快照算一次 tree_hash 比對，不符即紅「收據不是對這份 .pen 單一次掃描」——LS-152 r1
#     sibling_intersection 是修前、row_overflow 是修後拼接（1792 vs 重跑 1791）、LS-142 r4 拆段跑，舊 gate 只驗欄位與
#     head_sha、完全盲。**舊收據放行條件**：`head_sha` 那個 commit 的 tree 裡 `scripts/design/overflow-scan.js` 不含第五支
#     （FIFTH_MARKER `scanTextOcclusion`）——那個時點的正典腳本印不出 tree_hash，設計端不可能填；缺兩個新欄位時印一行放行
#     （欄位若在仍驗）。用「腳本在不在該 commit 的 tree」而非 cutoff 時間，是因為 in-flight 設計分支要等併回 development
#     才拿得到新腳本，用時間切會把它們誤紅。**輪次最高的收據另看 PR head 的 tree**（本機 HEAD／CI --head-sha；merge-review
#     R1 N1）：PR head 已含第五支就必填——最新輪次的 head_sha＝last_pen_commit（F2），.pen 內容與工作區相同，拿新腳本重跑一次
#     就填得出對得上的 tree_hash；只看 head_sha tree 會留下「分支先併入新腳本、之後不再動 .pen」的窗口，新欄位可以永遠不填。
#     舊輪次的收據產於新腳本存在之前、回填不可能，維持只看 head_sha tree。git 本身失敗（ls-tree／show 非 0，淺 clone／物件
#     缺失）不算「檔案不存在」、不放行（fail closed）。盲區：tree_hash 只證明「收據對應這份 .pen 的**節點樹**」（`children`
#     全樹；頂層 `variables`／`themes`／`fileToken` 不在雜湊內——Pencil `Get` 只走節點樹，掃描後只改 design token 再落地
#     gate 看不到，R1 N4），不證明各支掃描的數字算對（支數以 scripts/design/overflow-scan.js 檔頭為準）。
#   - **LS-185：第六支＋scan_scope**——收據另須含 `scans.board_clip`（可見葉節點伸出有 `clip:true` 的 root frame 被裁：LS-120 R2
#     六個 spacer 把 Card Diary／Load More 推出板外、LS-177 R2 Header Row 移到 y=−770 捲離畫面；**flagged 必為空**、不接受白名單
#     ——即使帶 classification 也紅；刻意出血請包進與板同尺寸的 clip 容器，`document_flagged` 的他票板用固定字面
#     `intentional_bleed`）與頂層 `scan_scope`（`boards`＝快照限縮到 SCAN_BOARDS 子樹／`document`＝全稿，只接受這兩個字面——
#     LS-120 R3／R4 逐板繞過逾時後 `document_*` 塌縮成 boards 值、LS-177 `cross_parent_collision` 限縮 17 板，收據語意只靠
#     scan_note 自述，VR MJ-9／MN-5）；每支可帶同值 `scope`（若在也只接受這兩值）。**舊收據放行條件同 LS-168、不用時間切**
#     （cutoff＝`head_sha` tree 的正典腳本含 SIXTH_MARKER `scanBoardClip`；in-flight 設計分支 LS-177 要等 main→development
#     back-merge 才拿得到新腳本）：不含 → 缺 `board_clip`／`scan_scope` 放行並印一行（欄位若在仍驗）；輪次最高的收據另看 PR head
#     tree（同 R1 N1）。
# 掃描「有沒有真的跑對」（演算法本身正確性）不是這支腳本能驗的——那需要 Pen 的版面引擎，只能靠
# visual-reviewer 用同方法重掃比對（見 .claude/agents/visual-reviewer.md）。
#
# 為什麼 head_sha 不能直接比對「PR 最終 head sha」：一個 commit 不可能把自己最終的 sha 寫進自己的
# tree 裡（sha 是內容的雜湊，內容變了 sha 就變，無法自我指涉）。ui-designer 的正確工作流程是兩支分開
# 的 commit：先落地＋commit .pen 變更（拿到這次 commit 的 sha）→ 把這個 sha 寫進收據 → 收據另開一個
# commit 提交。
#
# R2 修正（merge-review R1，同一支修法解兩個 major）：
#   F1（假陽性）：R1 版本把每一份收據都拿去比對「工作區當下」那份 .pen 的節點數——但設計票一 PR
#     多輪（CLAUDE.md／§1 規定 ≥3 輪迭代），r1／r2／r3 收據會累積在同一個 PR 的 diff 裡，r1 收據記
#     錄的是第 1 輪那個時點的 .pen，永遠不可能等於第 2 輪之後的節點數——逼 ui-designer 造假或刪除
#     舊收據才能過 gate，正好違反規則 2／3。R2 改為每份收據對帳**它自己 head_sha 那個時點**的 .pen
#     快照（`git show <head_sha>:<pen>`），歷史輪各對各的時點、不再互踩。
#   F2（假陰性）：只驗 head_sha 屬於本 PR（歸屬），不驗是不是最後一次——commit A 落地 .pen → commit B
#     交收據引用 A → commit C 修正版面但**節點數不變**（搬位置／改寬高是溢出修正的標準動作，節點數
#     天生不變，不是巧合）→ 舊版 gate 綠、C 這次真正的修正完全沒有收據把關。「自我指涉不可能」只否
#     定了「比對 PR 最終 head sha」，沒有否定「比對最後一次觸碰這份 .pen 的 commit」——後者完全可驗，
#     且本票規定的兩支分開 commit 工作流程天然滿足它（收據那支 commit 不碰 .pen，最後一次 .pen commit
#     就是收據該引用的那一支）。R2 要求：輪次最高的收據 head_sha＝`git rev-list <base>..HEAD -- <pen>`
#     的第一筆（最新）。
#
# 收據 JSON 形狀：
# {
#   "ticket": "LS-67", "round": 2, "head_sha": "<40 hex，本 PR 落地這份 .pen 的其中一次 commit>",
#   "total_nodes": 87, "tree_hash": "<16 hex，SUMMARY 印的值（LS-168）>",
#   "scan_scope": "document"  ←（LS-185）boards|document；每支物件可帶同值 "scope"
#   "scans": {
#     "sibling_intersection": {"flagged": [{"node_a": "...", "node_b": "...", "classification": "..."}]},
#     "row_overflow": {"flagged": [{"node": "...", "classification": "..."}]},
#     "cross_parent_collision": {"flagged": [{"node_a": "...", "node_b": "...", "classification": "..."}]},
#     "corner_anchor": {"boards": ["<root frame id>", ...], "containers": 91, "points": 728, "mismatch": 0, "flagged": [],
#                       "document_containers": 130, "document_points": 1040, "document_mismatch": 43, "document_flagged": [...],
#                       "unresolved": [{"container": "...", "classification": "..."}]},
#     "text_occlusion": {"flagged": [], "document_flagged": [...]},
#     "board_clip": {"flagged": [], "document_flagged": [{"board": "...", "node": "...", "side": "bottom", "overflow_px": 123, "classification": "intentional_bleed"}]}
#   }
# }
#
# 用法：design-evidence-check.sh <path.pen> --ticket <LS-n> --base <ref> [--head-sha <sha>]
#   --base 用來算 merge-base（同 branch-ticket-check.sh 的作法）：找出這個 PR 自己新增的收據檔
#   （<ref>...<head> 三點語法）與這個 PR 自己對 <path.pen> 的 commit 清單（<merge-base(ref,head)>..<head>）。
#   --head-sha（LS-127，CI 用）：<head> 預設是 HEAD。CI 的 actions/checkout 把 HEAD 放在 refs/pull/N/merge（PR head＋base tip
#   的雙親合併 commit），以它為終點時 merge-base(ref, HEAD) 退化成 base tip，base 自分出後對 .pen 的變更與合併 commit 本身
#   都被算成本 PR 的（PR #223：LS-114 動的 PXPcH 被列為漏列板、合併 commit c47edc0 被當成最後一次 .pen commit）。CI 改傳
#   --head-sha ${{ github.event.pull_request.head.sha }}，所有「本 PR 的範圍」一律以 merge-base(ref, head)..head 計算；本機
#   不給時沿用 HEAD、行為不變。另 (a)：每份收據「本 PR 觸碰的頂層節點」的基準是 merge-base(<merge-base(ref,head)>, 該收據
#   head_sha)、不是 merge-base(ref,head) 本身——PR 分支自己把 base 併進來後，後者會前進到併入點，歷史收據（快照停在 base
#   變更前）拿它當基準會把 base 側變更算成自己漏列的板（LS-119 merge-review comment 3d5851ac 實測）。total_nodes 對帳不受
#   影響，仍以收據 head_sha 那個時點的快照計算；LEGACY_CUTOFF 仍看收據 head_sha 的 committer time（設計分支不得 rebase）。
set -euo pipefail

pen=""; ticket=""; base=""; head_sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket)
      [ -n "${2:-}" ] || { echo "✗ design-evidence gate：--ticket 缺值" >&2; exit 2; }
      ticket="$2"; shift 2 ;;
    --base)
      [ -n "${2:-}" ] || { echo "✗ design-evidence gate：--base 缺值" >&2; exit 2; }
      base="$2"; shift 2 ;;
    --head-sha)
      [ -n "${2:-}" ] || { echo "✗ design-evidence gate：--head-sha 缺值" >&2; exit 2; }
      head_sha="$2"; shift 2 ;;
    -*) echo "✗ design-evidence gate：未知參數 $1" >&2; exit 2 ;;
    *)
      if [ -n "$pen" ]; then echo "✗ design-evidence gate：只接受一個 .pen 路徑（多給了 $1）" >&2; exit 2; fi
      pen="$1"; shift ;;
  esac
done
[ -n "$pen" ] || { echo "✗ design-evidence gate：缺 .pen 路徑" >&2; exit 2; }
[ -f "$pen" ] || { echo "✗ design-evidence gate：找不到「${pen}」" >&2; exit 2; }
[ -n "$ticket" ] || { echo "✗ design-evidence gate：缺 --ticket" >&2; exit 2; }
printf '%s' "$ticket" | grep -qE '^LS-[1-9][0-9]*$' || { echo "✗ design-evidence gate：--ticket「${ticket}」不是 LS-<n> 格式" >&2; exit 2; }
[ -n "$base" ] || { echo "✗ design-evidence gate：缺 --base" >&2; exit 2; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ design-evidence gate：不在 git 目錄內" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ design-evidence gate：需要 python3" >&2
  exit 1
fi

# LS-127：CI 傳 --head-sha <PR head>，本 PR 的範圍一律以 merge-base(base, head)..head 計算（見檔頭「用法」）；本機沿用 HEAD。
head="HEAD"
if [ -n "$head_sha" ]; then
  head=$(git rev-parse --verify --quiet "${head_sha}^{commit}") || {
    echo "✗ design-evidence gate：--head-sha「${head_sha}」不是可解析的 commit（fail closed）" >&2
    exit 2
  }
fi

base_sha=$(git merge-base "$base" "$head" 2>/dev/null) || {
  echo "✗ design-evidence gate：找不到 ${base} 與 ${head} 的共同祖先（fail closed）" >&2
  exit 2
}

gate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
landing_script="${gate_dir}/design-landing-check.sh"

list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! git diff --name-only -z --diff-filter=ACM "${base}...${head}" -- "design/evidence/${ticket}-r*-overflow.json" > "$list"; then
  echo "✗ design-evidence gate：git diff（${base}...${head}）失敗" >&2
  exit 2
fi

candidates=()
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue
  candidates+=("$p")
done < "$list"

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "✗ design-evidence gate：${pen} 有變更但本 PR 找不到 design/evidence/${ticket}-r<n>-overflow.json（規則 4，LS-68）——ui-designer handoff 時須把全樹溢出掃描結果（TOTAL_NODES／FLAGGED／分類表／HEAD sha）寫成這份收據隨 PR 提交" >&2
  exit 1
fi

# 這份 .pen 的 repo 根相對路徑（git show <sha>:<path> 要用這個，不是呼叫端給的相對／絕對路徑寫法）
pen_relpath=$(git ls-files --full-name -- "$pen" | head -1)
if [ -z "$pen_relpath" ]; then
  echo "✗ design-evidence gate：${pen} 不是 git 追蹤的檔案，無法解析 repo 相對路徑" >&2
  exit 2
fi

# 這個 PR 自己對這份 .pen 檔的 commit 清單（本分支相對 base 新增的，排除 base 既有的；
# git rev-list 預設由新到舊排序，第一筆就是「最後一次觸碰這份 .pen 的 commit」，R2 F2 要用）。
# 收據的 head_sha 必須是這個集合的成員——不能是 PR 最終那個 commit（自我指涉不可能），
# 也不能是別票／別分支複製過來的舊 sha。
pen_commits=$(git rev-list "${base_sha}..${head}" -- "$pen") || {
  echo "✗ design-evidence gate：無法列出 ${base_sha}..${head} 對 ${pen} 的 commit 清單" >&2
  exit 2
}
if [ -z "$pen_commits" ]; then
  echo "✗ design-evidence gate：${base_sha}..${head} 範圍內找不到任何觸碰 ${pen} 的 commit（不應該發生——呼叫端應只在 .pen 有變更時才呼叫本腳本）" >&2
  exit 2
fi
last_pen_commit=$(printf '%s\n' "$pen_commits" | head -1)

# 第一輪：從檔名解析輪次、決定「輪次最高」是哪一份（R2 F2 只對它要求 head_sha＝last_pen_commit）。
# 檔名不符 <ticket>-r<n>-overflow.json（git diff 的 glob 用 * 比對，理論上可能混進非數字）一律 fail
# closed——這裡決定哪份收據該扛「最新」責任，不能悄悄跳過任何一份。
max_round=-1
for ev in "${candidates[@]}"; do
  fname=$(basename "$ev")
  round=$(printf '%s' "$fname" | sed -nE "s/^${ticket}-r([0-9]+)-overflow\\.json\$/\\1/p")
  if [ -z "$round" ]; then
    echo "✗ design-evidence gate：${ev} 檔名不符 ${ticket}-r<n>-overflow.json 格式，無法判定輪次（fail closed）" >&2
    exit 2
  fi
  if [ "$round" -gt "$max_round" ]; then
    max_round="$round"
  fi
done

fail=0
for ev in "${candidates[@]}"; do
  fname=$(basename "$ev")
  round=$(printf '%s' "$fname" | sed -nE "s/^${ticket}-r([0-9]+)-overflow\\.json\$/\\1/p")
  is_latest=0
  [ "$round" = "$max_round" ] && is_latest=1

  # PYTHONDONTWRITEBYTECODE：import design_tree_hash 不得在 scripts/gates/ 留下 __pycache__（R1 N7）
  if ! PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 python3 - "$ev" "$pen_commits" "$last_pen_commit" "$is_latest" "$pen_relpath" "$landing_script" "$base_sha" "$head" <<'PY'
import json, os, re, subprocess, sys, tempfile

p, pen_commits_s, last_pen_commit, is_latest_s, pen_relpath, landing_script, base_sha, head = sys.argv[1:9]
pen_commits = set(pen_commits_s.split())
is_latest = is_latest_s == "1"
# LS-122：舊 schema（兩支）只給本 gate 落地前就存在的收據——head_sha 的 committer 時間早於此時點（不看輪次，MJ-1）。
LEGACY_CUTOFF = 1788321600  # 2026-09-02T04:00:00Z
FOUR = ("sibling_intersection", "row_overflow", "cross_parent_collision", "corner_anchor")
# LS-168：head_sha 那個 commit 的 tree 裡正典腳本含第五支 → 收據必須有 tree_hash 與 scans.text_occlusion；輪次最高的收據
# 另看 PR head 的 tree（R1 N1，見檔頭）
FIFTH_SCRIPT = "scripts/design/overflow-scan.js"
FIFTH_MARKER = "scanTextOcclusion"
# LS-185：第六支 board_clip＋scan_scope 的 cutoff——同一支腳本含 SIXTH_MARKER 才要求（放行條件與第五支同形，見檔頭）
SIXTH_MARKER = "scanBoardClip"
SCAN_SCOPES = ("boards", "document")
sys.path.insert(0, os.path.dirname(os.path.abspath(landing_script)))
import design_tree_hash  # noqa: E402


def has_marker(rev, marker):
    """rev 的 tree 裡正典腳本是否含 marker：True／False（檔案不存在或無標記）；git 本身失敗回 None（呼叫端 fail closed）。"""
    ls = subprocess.run(["git", "ls-tree", rev, "--", FIFTH_SCRIPT], capture_output=True)
    if ls.returncode != 0:
        return None
    if not ls.stdout.strip():
        return False
    show = subprocess.run(["git", "show", f"{rev}:{FIFTH_SCRIPT}"], capture_output=True)
    if show.returncode != 0:
        return None
    return marker.encode("utf-8") in show.stdout


def has_fifth(rev):
    return has_marker(rev, FIFTH_MARKER)

def top_level(blob):
    """.pen 快照的頂層節點 {id: 正規化 JSON}（board／元件定義都在這一層）；解析失敗回 None。"""
    try:
        doc = json.loads(blob.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(doc, dict):
        return None
    out = {}
    for c in doc.get("children") or []:
        if isinstance(c, dict) and isinstance(c.get("id"), str):
            out[c["id"]] = (c.get("name") or "", json.dumps(c, sort_keys=True, ensure_ascii=False))
    return out

try:
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
except (OSError, json.JSONDecodeError, UnicodeDecodeError) as e:
    print(f"✗ design-evidence gate：{p} 讀取／解析失敗（{type(e).__name__}: {e}）", file=sys.stderr)
    sys.exit(1)

if not isinstance(d, dict):
    print(f"✗ design-evidence gate：{p} 頂層不是物件（{type(d).__name__}）", file=sys.stderr)
    sys.exit(1)

errs = []
sha = d.get("head_sha")
want_nodes = None
head_roots = None
want_hash = None
fifth = False
fifth_at_sha = False
sixth = False
sixth_at_sha = False

if not isinstance(sha, str) or sha not in pen_commits:
    errs.append(
        f"head_sha 不是本 PR 對這份 .pen 的其中一次 commit：收據={sha!r}"
        "（不是本 PR 自己的 commit——可能是別票／別分支留下的舊收據，或忘記在落地後把 commit sha 寫回收據）"
    )
else:
    # R2 F1：對帳這份收據自己 head_sha 那個時點的 .pen 快照，不是工作區當下／PR 最終那份。
    show = subprocess.run(
        ["git", "show", f"{sha}:{pen_relpath}"], capture_output=True
    )
    if show.returncode != 0:
        errs.append(
            f"無法用 git show 讀出 {sha}:{pen_relpath}（{show.stderr.decode('utf-8', 'replace').strip()}）"
        )
    else:
        head_roots = top_level(show.stdout)
        try:
            want_hash = design_tree_hash.tree_hash(json.loads(show.stdout.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as e:
            errs.append(f"無法對 {sha[:7]}:{pen_relpath} 快照算 tree_hash（{type(e).__name__}: {e}）")
        fifth_at_sha = has_fifth(sha)
        fifth_at_head = has_fifth(head) if is_latest else False
        sixth_at_sha = has_marker(sha, SIXTH_MARKER)
        sixth_at_head = has_marker(head, SIXTH_MARKER) if is_latest else False
        if fifth_at_sha is None or fifth_at_head is None or sixth_at_sha is None or sixth_at_head is None:
            errs.append(
                f"無法判定 {FIFTH_SCRIPT} 在 {sha[:7]}／PR head 的 tree 裡是否含第五／六支（git ls-tree／show 失敗，淺 clone 或物件缺失）"
                "——不能靠猜放行舊收據（fail closed）"
            )
        fifth = bool(fifth_at_sha) or (is_latest and bool(fifth_at_head))
        sixth = bool(sixth_at_sha) or (is_latest and bool(sixth_at_head))
        tmp_path = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".pen", delete=False) as tf:
                tf.write(show.stdout)
                tmp_path = tf.name
            r = subprocess.run(
                ["bash", landing_script, tmp_path, "--print-nodes"],
                capture_output=True, text=True,
            )
        finally:
            if tmp_path:
                os.unlink(tmp_path)
        if r.returncode != 0:
            errs.append(
                f"無法從 {sha}:{pen_relpath} 這個時點的快照算出節點數"
                f"（design-landing-check.sh 失敗：{r.stderr.strip()}）"
            )
        else:
            want_nodes = int(r.stdout.strip())

    # R2 F2：輪次最高（最新）的收據必須引用「最後一次觸碰這份 .pen 的 commit」，不能只引用較早
    # 那輪的 commit——溢出修正的標準動作是搬位置／改寬高，節點數天生不變，不是巧合，不能只靠
    # total_nodes 比對守住「最後一次變更有沒有收據」。
    if is_latest and sha != last_pen_commit:
        errs.append(
            "本 PR 輪次最高的收據，但 head_sha 不是本 PR 對這份 .pen 最後一次的 commit："
            f"收據={sha!r}，最後一次={last_pen_commit!r}"
            "（規則 4 F2：最新輪次的收據必須對應最後一次 .pen 變更，不能只引用較早那輪落地的 commit）"
        )

nodes = d.get("total_nodes")
if want_nodes is not None and nodes != want_nodes:
    errs.append(
        f"total_nodes 不符：收據={nodes!r}，對 head_sha={sha[:7] if isinstance(sha, str) else sha!r} "
        f"那個時點的 .pen 快照算出的節點數={want_nodes}"
    )

legacy = False
if isinstance(sha, str) and sha in pen_commits:
    ct = subprocess.run(["git", "show", "-s", "--format=%ct", sha], capture_output=True, text=True)
    legacy = ct.returncode == 0 and ct.stdout.strip().isdigit() and int(ct.stdout.strip()) < LEGACY_CUTOFF
required = FOUR[:2] if legacy else FOUR
why = "兩支掃描（兄弟交集／橫列溢出）都必須有輸出（LS-67 R1）" if legacy else (
    "四支掃描（兄弟交集／橫列溢出／跨 parent 碰撞／角托錨點）都必須有輸出（LS-122；只有 .pen 落地早於 2026-09-02T04:00Z 的既有收據沿用兩支）"
)


def check_corner_anchor(scan, flagged):
    """LS-122 corner_anchor 區塊：計數整數、mismatch==0、boards 覆蓋本 PR 觸碰的板、unresolved 每筆有分類。"""
    for k in ("containers", "points", "mismatch", "document_mismatch"):
        v = scan.get(k)
        if isinstance(v, bool) or not isinstance(v, int) or v < 0:
            errs.append(f"scans.corner_anchor.{k} 必須是非負整數（收據={v!r}）")
    if scan.get("mismatch") != 0 or flagged:
        errs.append(
            f"scans.corner_anchor.mismatch 必須為 0 且 flagged 必須為空（收據 mismatch={scan.get('mismatch')!r}，flagged {len(flagged)} 筆）"
            "——角托錯位不接受白名單，回稿把角托外緣壓過紙緣 corner-out 5pt（期望＝紙面邊 − 角托實測寬高 + 5，見 flagged 的 expected）後重跑 scripts/design/overflow-scan.js（LS-122）"
        )
    boards = scan.get("boards")
    if not isinstance(boards, list) or not boards or any(not isinstance(b, str) or not b.strip() for b in boards):
        errs.append("scans.corner_anchor.boards 必須是非空字串陣列（本票觸碰的 root frame id；Pencil 端在腳本 snippet 第一行加 SCAN_BOARDS 再跑正典腳本，a106f940）")
    elif head_roots is not None:
        unknown = [b for b in boards if b not in head_roots]
        if unknown:
            errs.append(f"scans.corner_anchor.boards 含不存在於 head_sha 快照頂層的 id：{unknown}")
        # LS-127 (a)：「本 PR 觸碰的頂層節點」的基準是這份收據自己的共同祖先 merge-base(base_sha, head_sha)，不是 base_sha 本身——
        # PR 分支把 base 併進來後 base_sha 會前進到併入點，歷史收據（快照停在 base 變更前）若拿 base_sha 快照當基準，base 側的
        # 變更會被算成它漏列的板（LS-119 merge-review comment 3d5851ac 實測：base 前進後歷史收據全紅）。
        mb = subprocess.run(["git", "merge-base", base_sha, sha], capture_output=True, text=True)
        touch_base = mb.stdout.strip() if mb.returncode == 0 else ""
        if not touch_base:
            errs.append(f"無法算出 merge-base({base_sha[:7]}, {sha[:7]})，不能判定本 PR 觸碰的頂層節點（fail closed）")
        else:
            base_show = subprocess.run(["git", "show", f"{touch_base}:{pen_relpath}"], capture_output=True)
            base_roots = top_level(base_show.stdout) if base_show.returncode == 0 else {}
            touched = [rid for rid, (_, blob) in head_roots.items() if rid not in base_roots or base_roots[rid][1] != blob]
            missing = [rid for rid in touched if rid not in boards]
            if missing:
                names = ", ".join(f"{rid}（{head_roots[rid][0]}）" for rid in missing)
                errs.append(f"scans.corner_anchor.boards 漏列本 PR 對 .pen 有變更的頂層節點：{names}——本票觸碰的板都要在範圍內，不得靠縮小 boards 讓自己的角托錯位進 document_mismatch")
    unresolved = scan.get("unresolved")
    if not isinstance(unresolved, list):
        errs.append("scans.corner_anchor.unresolved 必須是陣列（找不到吻合紙面的角托容器清單，可為空）")
    else:
        for i, item in enumerate(unresolved):
            if not isinstance(item, dict) or not str(item.get("classification") or "").strip():
                errs.append(f"scans.corner_anchor.unresolved[{i}] 缺分類（classification）——找不到紙面的角托容器要說明原因")

scans = d.get("scans")
if not isinstance(scans, dict):
    errs.append("缺 scans 物件")
else:
    for key in required:
        scan = scans.get(key)
        if not isinstance(scan, dict) or "flagged" not in scan:
            errs.append(f"scans.{key} 缺失或缺 flagged 欄位——{why}")
            continue
        flagged = scan.get("flagged")
        if not isinstance(flagged, list):
            errs.append(f"scans.{key}.flagged 必須是陣列")
            continue
        if key == "corner_anchor":
            check_corner_anchor(scan, flagged)
            continue
        for i, item in enumerate(flagged):
            if not isinstance(item, dict) or not str(item.get("classification") or "").strip():
                errs.append(f"scans.{key}.flagged[{i}] 缺分類（classification）")

# LS-168：tree_hash（收據對應 head_sha 那份 .pen）與第五支 text_occlusion（flagged 必為空）。
# 新欄位只對「head_sha 快照的正典腳本已含第五支」的收據要求；舊收據缺欄位放行並印一行，欄位若在仍驗。
receipt_hash = d.get("tree_hash")
tx = scans.get("text_occlusion") if isinstance(scans, dict) else None
if fifth and not fifth_at_sha and (receipt_hash is None or tx is None):
    errs.append(
        f"本 PR 輪次最高的收據：head_sha={sha[:7]} 落地時正典腳本尚無第五支，但 PR head 的 tree 已含（新腳本已併入本分支）"
        "——最新輪次的 .pen 內容＝工作區，用現行 scripts/design/overflow-scan.js 對它重跑一次，把 tree_hash 與 scans.text_occlusion 補進這份收據（LS-168 R1 N1）"
    )
if receipt_hash is None and not fifth:
    pass
elif not isinstance(receipt_hash, str) or not re.fullmatch(r"[0-9a-f]{16}", receipt_hash):
    errs.append(f"tree_hash 必須是 16 碼小寫 hex（收據={receipt_hash!r}）——抄 overflow-scan.js SUMMARY 印的 tree_hash（LS-168）")
elif want_hash is not None and receipt_hash != want_hash:
    errs.append(
        f"tree_hash 不符：收據={receipt_hash}，對 head_sha={sha[:7]} 那份 .pen 算出={want_hash}"
        "——收據不是對這份 .pen 單一次掃描（修前後拼接、或掃完又改稿再落地）；末次落地後重跑正典腳本、整份收據只能來自同一次 execute（LS-168，LS-152 r1／LS-142 r4 事故）"
    )
if tx is None and not fifth:
    pass
elif not isinstance(tx, dict) or not isinstance(tx.get("flagged"), list):
    errs.append("scans.text_occlusion 缺失或缺 flagged 陣列——第五支文字遮蔽掃描（text × Action Bar／Tab Bar／Capsule／Footer／Toast／Banner）必須有輸出（LS-168）")
elif tx["flagged"]:
    heads = ", ".join(f"{i.get('node')}×{i.get('overlay')}" for i in tx["flagged"][:5] if isinstance(i, dict))
    errs.append(
        f"scans.text_occlusion.flagged 必須為空（收據 {len(tx['flagged'])} 筆：{heads}）"
        "——文字被覆蓋層蓋住不接受白名單，把整列移出膠囊／動作帶或改覆蓋層版面後重跑（LS-168；VR R1 BL-2／BL-3 同 class）"
    )

# LS-185：第六支 board_clip（flagged 必為空）與 scan_scope（boards|document）。新欄位只對「正典腳本已含第六支」的收據要求
# （head_sha tree；輪次最高另看 PR head tree），舊收據缺欄位放行並印一行，欄位若在仍驗。
scan_scope = d.get("scan_scope")
bc = scans.get("board_clip") if isinstance(scans, dict) else None
if sixth and not sixth_at_sha and (bc is None or scan_scope is None):
    errs.append(
        f"本 PR 輪次最高的收據：head_sha={sha[:7]} 落地時正典腳本尚無第六支，但 PR head 的 tree 已含第六支（新腳本已併入本分支）"
        "——最新輪次的 .pen 內容＝工作區，用現行 scripts/design/overflow-scan.js 對它重跑一次，把 scan_scope 與 scans.board_clip 補進這份收據（LS-185）"
    )
if scan_scope is None and not sixth:
    pass
elif scan_scope is None:
    errs.append(f"缺 scan_scope——收據必須標明快照範圍：{'|'.join(SCAN_SCOPES)}（boards＝限縮到 SCAN_BOARDS 子樹、document＝全稿；抄 SUMMARY 的 scan_scope，LS-185）")
elif scan_scope not in SCAN_SCOPES:
    errs.append(f"scan_scope 只接受 {'|'.join(SCAN_SCOPES)}（收據={scan_scope!r}）——document_* 是全稿還是限縮板的數字必須用這兩個字面標明（LS-185）")
if isinstance(scans, dict):
    for key, scan in scans.items():
        if isinstance(scan, dict) and "scope" in scan and scan.get("scope") not in SCAN_SCOPES:
            errs.append(f"scans.{key}.scope 只接受 {'|'.join(SCAN_SCOPES)}（收據={scan.get('scope')!r}，LS-185）")
if bc is None and not sixth:
    pass
elif not isinstance(bc, dict) or not isinstance(bc.get("flagged"), list):
    errs.append("scans.board_clip 缺失或缺 flagged 陣列——第六支板裁切掃描（可見葉節點伸出有 clip 的 root frame）必須有輸出（LS-185）")
elif bc["flagged"]:
    heads = ", ".join(f"{i.get('node')}@{i.get('board')}:{i.get('side')}" for i in bc["flagged"][:5] if isinstance(i, dict))
    errs.append(
        f"scans.board_clip.flagged 必須為空（收據 {len(bc['flagged'])} 筆：{heads}）"
        "——內容被板裁掉不接受白名單（帶 classification 也一樣）：把被推出板外的內容收回板內，刻意出血請包進與板同尺寸的 clip:true 容器後重跑（LS-185；LS-120 R2 spacer／LS-177 R2 Header Row 同 class）"
    )

if errs:
    print(f"✗ design-evidence gate：{p} 未通過：", file=sys.stderr)
    for e in errs:
        print(f"    - {e}", file=sys.stderr)
    sys.exit(1)

sha_disp = sha[:7] if isinstance(sha, str) else sha
tag = "（本輪最新）" if is_latest else ""
# LS-198：支數不寫死——依本收據實際要求的層數算（LS-122 四＋LS-168 第五＋LS-185 第六），全部支數以 scripts/design/overflow-scan.js 檔頭為準
n_scans = len(required) + (1 if fifth else 0) + (1 if sixth else 0)
n_zh = {4: "四", 5: "五", 6: "六"}.get(n_scans, str(n_scans))   # legacy（兩支）走下面的舊 schema 字串，這裡不得 KeyError
schema = "兩支掃描皆有輸出（gate 落地前的既有收據，舊 schema）" if legacy else f"{n_zh}支掃描皆有輸出（支數以 {FIFTH_SCRIPT} 檔頭為準）、corner_anchor.mismatch=0、boards 覆蓋本 PR 觸碰的板"
if fifth:
    schema += "、tree_hash 對應 head_sha 快照、text_occlusion.flagged 為空"
elif receipt_hash is None or tx is None:
    also = "、PR head 的亦無" if is_latest else ""
    print(f"（{p}：head_sha={sha_disp} 快照的 {FIFTH_SCRIPT} 尚無第五支{also}，LS-168 新欄位 tree_hash／text_occlusion 不要求——舊收據放行）")
if sixth:
    schema += f"、board_clip.flagged 為空、scan_scope={scan_scope}"
elif bc is None or scan_scope is None:
    also = "、PR head 的亦無" if is_latest else ""
    print(f"（{p}：head_sha={sha_disp} 快照的 {FIFTH_SCRIPT} 尚無第六支{also}，LS-185 新欄位 board_clip／scan_scope 不要求——舊收據放行）")
print(f"✓ design-evidence gate 通過：{p}（head_sha={sha_disp}{tag}，total_nodes={want_nodes}，{schema}）")
PY
  then
    fail=1
  fi
done

exit "$fail"
