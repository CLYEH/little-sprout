#!/bin/bash
# LS-91：.pen 落地腳本——把 Pen app 的 autosave 備份（~/.pencil/backup/<sha1("file://<abs path>")>）複製回
# worktree 的 design/littlesprout.pen，複製前做結構 diff 把關，複製後跑 design-landing-check.sh 收尾。
# 取代 LS-26 手動 SOP 的機械版本（LS-91 comment 0fb5f855）。
#
# backup 目錄與命名格式（本票實測確認，2026-08-25）：`~/.pencil/backup/<sha1>`，檔名＝
# `printf '%s' "file://<絕對路徑>" | shasum` 的十六進位摘要（40 hex、無副檔名）——對主 checkout
# `design/littlesprout.pen` 算出的 sha1，與該目錄下一份既有備份檔名完全相符（mtime 也對得上最近一次
# `open -a Pen` 之後）。
#
# 用法：pen-land.sh <worktree-or-repo-root> [--expect-nodes N] [--dry-run]
#
# 流程：
#   1. 算 want = <root>/design/littlesprout.pen 的絕對路徑；sha1(file://want) 找 backup。
#   2. python3 結構 diff：want（落地檔／舊）vs backup（Pen 記憶體／新）——節點總數（含巢狀 children）、
#      id 集合（新增／刪除）、meta（variables／themes／fileToken）是否不變、逐 (id, prop) 差異
#      （排除 children，避免整棵子樹洗版）。印出變更清單。
#   3. meta 變了，或 diff 本身失敗（JSON 壞掉、頂層非物件等）→ 不 cp，exit 1。
#   4. --dry-run：印完清單就結束，不 cp、不跑 landing gate（零副作用）。
#   5. 否則：cp backup → want；跑 design-landing-check.sh want --expect-nodes N
#      （N 省略時用 backup 的節點數）；把它的 exit code 當作本腳本的 exit code。
#
# 測試用可覆寫 backup 目錄（$PEN_BACKUP_DIR，預設 ~/.pencil/backup）：自測用合成 fixture，不碰真正的
# ~/.pencil/backup 或 design/littlesprout.pen（真檔落地仍由 orchestrator 執行，auto-mode 分類器會擋 agent
# 直接覆寫）。
#
# 自測：scripts/ops/pen-land.test.sh。
set -uo pipefail

usage() {
  echo "用法：pen-land.sh <worktree-or-repo-root> [--expect-nodes N] [--dry-run]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

target=$1
shift
expect=""
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-nodes)
      if [ $# -lt 2 ] || ! printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then
        echo "✗ pen-land：--expect-nodes 需要一個非負整數參數" >&2
        exit 2
      fi
      expect=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *)
      echo "✗ pen-land：不認得的參數「$1」" >&2
      usage
      exit 2
      ;;
  esac
done

root=$(cd "$target" 2>/dev/null && pwd -P) || {
  echo "✗ pen-land：找不到目錄「${target}」" >&2
  exit 2
}
want="${root}/design/littlesprout.pen"
[ -f "$want" ] || {
  echo "✗ pen-land：找不到「${want}」" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "✗ pen-land：需要 python3 解析 .pen 結構" >&2
  exit 2
}
command -v shasum >/dev/null 2>&1 || {
  echo "✗ pen-land：需要 shasum 計算 backup 檔名" >&2
  exit 2
}

backup_dir="${PEN_BACKUP_DIR:-$HOME/.pencil/backup}"
sha=$(printf '%s' "file://${want}" | shasum | awk '{print $1}')
backup="${backup_dir}/${sha}"
[ -f "$backup" ] || {
  echo "✗ pen-land：找不到 backup「${backup}」（Pen 可能沒開過這個路徑，或 autosave 還沒發生——先 pen-open.sh 切檔並等 autosave）" >&2
  exit 2
}

# python 結構 diff：清單印到 stdout，最後兩行印 `NODES=<N>`／`META_OK=0|1` 供 shell 解析，事後濾掉。
diff_out=$(PYTHONIOENCODING=utf-8 python3 - "$want" "$backup" <<'PY'
import json, sys

old_path, new_path = sys.argv[1], sys.argv[2]


def load(p):
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


try:
    old = load(old_path)
except Exception as e:
    print(f"✗ pen-land：落地檔「{old_path}」解析失敗（{type(e).__name__}: {e}）", file=sys.stderr)
    print("META_OK=0")
    sys.exit(1)
try:
    new = load(new_path)
except Exception as e:
    print(f"✗ pen-land：backup「{new_path}」解析失敗（{type(e).__name__}: {e}）", file=sys.stderr)
    print("META_OK=0")
    sys.exit(1)

if not isinstance(old, dict) or not isinstance(new, dict):
    print("✗ pen-land：頂層不是物件，不是 .pen 格式", file=sys.stderr)
    print("META_OK=0")
    sys.exit(1)


def collect(d):
    """回傳 {id: node} 與節點總數（含巢狀 children）。"""
    nodes = {}
    count = 0
    stack = list(d.get("children") or [])
    while stack:
        n = stack.pop()
        if isinstance(n, dict):
            count += 1
            nid = n.get("id")
            if nid is not None:
                nodes[nid] = n
            stack.extend(n.get("children") or [])
    return nodes, count


old_nodes, old_count = collect(old)
new_nodes, new_count = collect(new)

meta_ok = True
for key in ("variables", "themes", "fileToken"):
    if old.get(key) != new.get(key):
        meta_ok = False
        print(f"meta 變更：{key} 不同（落地檔 → backup）")

added = sorted(set(new_nodes) - set(old_nodes), key=str)
removed = sorted(set(old_nodes) - set(new_nodes), key=str)
if added:
    print(f"新增節點（{len(added)}）：{added}")
if removed:
    print(f"刪除節點（{len(removed)}）：{removed}")

prop_changes = 0
for nid in sorted(set(old_nodes) & set(new_nodes), key=str):
    o, n = old_nodes[nid], new_nodes[nid]
    keys = (set(o) | set(n)) - {"children"}
    diffs = sorted(k for k in keys if o.get(k) != n.get(k))
    if diffs:
        prop_changes += 1
        print(f"節點 {nid} 屬性變更：{diffs}")

print(f"節點總數：落地檔 {old_count} → backup {new_count}")
if not added and not removed and prop_changes == 0 and old_count == new_count:
    print("（結構無差異——可能已經落地過，或本輪沒有實質變更）")

print(f"NODES={new_count}")
print(f"META_OK={1 if meta_ok else 0}")
sys.exit(0 if meta_ok else 1)
PY
)
py_rc=$?
printf '%s\n' "$diff_out" | grep -v -E '^(NODES=|META_OK=)'

if [ "$py_rc" -ne 0 ]; then
  echo "✗ pen-land：結構 diff 失敗或 meta 變更（見上方訊息）——不複製" >&2
  exit 1
fi

nodes=$(printf '%s\n' "$diff_out" | grep '^NODES=' | tail -1 | cut -d= -f2)
if [ -z "$nodes" ]; then
  echo "✗ pen-land：無法取得 backup 節點數（NODES= 缺失，diff 腳本異常）" >&2
  exit 1
fi
if [ -z "$expect" ]; then
  expect=$nodes
fi

if [ "$dry_run" -eq 1 ]; then
  echo "（dry-run：未複製、未執行 landing gate）"
  exit 0
fi

cp "$backup" "$want" || {
  echo "✗ pen-land：cp「${backup}」→「${want}」失敗" >&2
  exit 1
}

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "${script_root}/scripts/gates/design-landing-check.sh" "$want" --expect-nodes "$expect"
