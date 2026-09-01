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
#   - **輪次最高（最新）那份收據**的 head_sha 必須等於 base..HEAD 範圍內「最後一次觸碰這份 .pen 的
#     commit」（R2 F2：見下方「R2 修正」），較早輪次的收據只驗自己那個時點的快照，不必是最後一次
#   - 收據必須同時含兩支掃描的輸出：scans.sibling_intersection／scans.row_overflow（LS-67 R1：
#     ui-designer 只跑對兄弟碰撞無感的 ctx.problems 就宣稱 FLAGGED=0，reviewer 用絕對座標交集才抓到
#     真碰撞——本 gate 要求兩支掃描的輸出都要在，不能只交一支）
#   - 每一支掃描下 flagged 陣列裡的每一筆都要有非空的 classification（分類表）
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
#   "total_nodes": 87,
#   "scans": {
#     "sibling_intersection": {"flagged": [{"node_a": "...", "node_b": "...", "classification": "..."}]},
#     "row_overflow": {"flagged": [{"node": "...", "classification": "..."}]}
#   }
# }
#
# 用法：design-evidence-check.sh <path.pen> --ticket <LS-n> --base <ref>
#   --base 用來算 merge-base（同 branch-ticket-check.sh 的作法）：找出這個 PR 自己新增的收據檔
#   （<ref>...HEAD 三點語法）與這個 PR 自己對 <path.pen> 的 commit 清單（<merge-base(ref,HEAD)>..HEAD）。
set -euo pipefail

pen=""; ticket=""; base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket)
      [ -n "${2:-}" ] || { echo "✗ design-evidence gate：--ticket 缺值" >&2; exit 2; }
      ticket="$2"; shift 2 ;;
    --base)
      [ -n "${2:-}" ] || { echo "✗ design-evidence gate：--base 缺值" >&2; exit 2; }
      base="$2"; shift 2 ;;
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

base_sha=$(git merge-base "$base" HEAD 2>/dev/null) || {
  echo "✗ design-evidence gate：找不到 ${base} 與 HEAD 的共同祖先（fail closed）" >&2
  exit 2
}

gate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
landing_script="${gate_dir}/design-landing-check.sh"

list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! git diff --name-only -z --diff-filter=ACM "${base}...HEAD" -- "design/evidence/${ticket}-r*-overflow.json" > "$list"; then
  echo "✗ design-evidence gate：git diff（${base}...HEAD）失敗" >&2
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
pen_commits=$(git rev-list "${base_sha}..HEAD" -- "$pen") || {
  echo "✗ design-evidence gate：無法列出 ${base_sha}..HEAD 對 ${pen} 的 commit 清單" >&2
  exit 2
}
if [ -z "$pen_commits" ]; then
  echo "✗ design-evidence gate：${base_sha}..HEAD 範圍內找不到任何觸碰 ${pen} 的 commit（不應該發生——呼叫端應只在 .pen 有變更時才呼叫本腳本）" >&2
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

  if ! PYTHONIOENCODING=utf-8 python3 - "$ev" "$pen_commits" "$last_pen_commit" "$is_latest" "$pen_relpath" "$landing_script" <<'PY'
import json, os, subprocess, sys, tempfile

p, pen_commits_s, last_pen_commit, is_latest_s, pen_relpath, landing_script = sys.argv[1:7]
pen_commits = set(pen_commits_s.split())
is_latest = is_latest_s == "1"

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

scans = d.get("scans")
if not isinstance(scans, dict):
    errs.append("缺 scans 物件")
else:
    for key in ("sibling_intersection", "row_overflow"):
        scan = scans.get(key)
        if not isinstance(scan, dict) or "flagged" not in scan:
            errs.append(f"scans.{key} 缺失或缺 flagged 欄位——兩支掃描（兄弟交集／橫列溢出）都必須有輸出（LS-67 R1）")
            continue
        flagged = scan.get("flagged")
        if not isinstance(flagged, list):
            errs.append(f"scans.{key}.flagged 必須是陣列")
            continue
        for i, item in enumerate(flagged):
            if not isinstance(item, dict) or not str(item.get("classification") or "").strip():
                errs.append(f"scans.{key}.flagged[{i}] 缺分類（classification）")

if errs:
    print(f"✗ design-evidence gate：{p} 未通過：", file=sys.stderr)
    for e in errs:
        print(f"    - {e}", file=sys.stderr)
    sys.exit(1)

sha_disp = sha[:7] if isinstance(sha, str) else sha
tag = "（本輪最新）" if is_latest else ""
print(f"✓ design-evidence gate 通過：{p}（head_sha={sha_disp}{tag}，total_nodes={want_nodes}，兩支掃描皆有輸出）")
PY
  then
    fail=1
  fi
done

exit "$fail"
