#!/bin/bash
# LS-68 規則 4：.pen 掃描收據 gate。
#
# 溢出掃描（兄弟節點交集／橫列內容溢出）需要 Pen app 的版面引擎才能算出絕對座標，GitHub runner
# 沒有 Pen，掃描本身沒辦法在 CI 跑。改為 ui-designer handoff 時把掃描結果寫成
# design/evidence/<票號>-r<n>-overflow.json 隨 PR 提交（`design/evidence/` 是明文 JSON、要進版控的
# 收據，不是 `.claude/evidence/` 那種 gitignored 的審查取證——evidence-path-check.sh 的 review*／ls[0-9]*
# 目錄層規則與 png 白名單都不擋這個路徑，已實測確認）。這支腳本驗收據本身 CI 端能機械驗的部分：
#   - .pen 有變更的 PR 必須附上本票這一輪的收據檔（找不到就紅）
#   - 收據的 head_sha 必須是「這個 PR 自己對這份 .pen 檔的其中一次 commit」（不是隨便貼一個 sha、
#     也不是別票／別分支留下的舊收據）
#   - 收據的 total_nodes 必須等於 design-landing-check.sh 對「PR 現在這份 .pen」算出的節點數（順帶
#     擋住「收據寫完後 .pen 又被改過、收據沒跟著更新」——node 數對不上就代表內容已經漂移）
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
# commit 提交。這支腳本因此驗的是「head_sha 是不是這個 PR 自己對這份 .pen 檔的其中一次 commit」
# （`git rev-list <merge-base>..HEAD -- <pen>` 的成員），而不是要求它等於 PR 最終那個 commit。
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

# 這個 PR 自己對這份 .pen 檔的 commit 清單（本分支相對 base 新增的，排除 base 既有的）；
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

expect_nodes=$(bash "${gate_dir}/design-landing-check.sh" "$pen" --print-nodes) || {
  echo "✗ design-evidence gate：無法從 ${pen} 算出節點數（design-landing-check.sh 失敗，見上方輸出）" >&2
  exit 1
}

fail=0
for ev in "${candidates[@]}"; do
  if ! PYTHONIOENCODING=utf-8 python3 - "$ev" "$expect_nodes" "$pen_commits" <<'PY'
import json, sys

p, want_nodes_s, pen_commits_s = sys.argv[1], sys.argv[2], sys.argv[3]
want_nodes = int(want_nodes_s)
pen_commits = set(pen_commits_s.split())

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
if not isinstance(sha, str) or sha not in pen_commits:
    errs.append(
        f"head_sha 不是本 PR 對這份 .pen 的其中一次 commit：收據={sha!r}"
        "（不是本 PR 自己的 commit——可能是別票／別分支留下的舊收據，或忘記在落地後把 commit sha 寫回收據）"
    )

nodes = d.get("total_nodes")
if nodes != want_nodes:
    errs.append(f"total_nodes 不符：收據={nodes!r}，design-landing-check 算出的節點數={want_nodes}")

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

print(f"✓ design-evidence gate 通過：{p}（head_sha={sha[:7]}，total_nodes={want_nodes}，兩支掃描皆有輸出）")
PY
  then
    fail=1
  fi
done

exit "$fail"
