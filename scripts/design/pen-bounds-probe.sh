#!/bin/bash
# LS-480：收據掃描前的「Pen 版面是否已刷新」探針。
#
# 背景（LS-471 R3 實錄）：螢幕鎖定時 Pen 不重新排版——Pencil MCP `Get` 回的 bounds 對新節點系統性 y+50、
# `fill_container` 兄弟的 x 呈二分序列錯位；整輪 `overflow-scan`／快照 dump 因此產出假陽性收據（R3 一次作廢）。
# 解鎖後 `open -a Pen` 一次才刷新。本探針讓收據掃描（SCAN_*／pen-snapshot-dump.js／overflow-scan.js --from-snapshot）
# 前先自檢，exit 3 就停下回報，**不產任何收據檔**（本腳本只印診斷，從不寫 .pen／收據）。
#
# 用法：pen-bounds-probe.sh [--pen <path>] [--root <dir>] [--ids id1,id2,…]
#   --pen   要探的 .pen（絕對或相對 --root；省略＝<root>/design/littlesprout.pen；解析見 scripts/ops/lib/pen-path.sh）
#   --root  相對路徑的基準（預設：cwd 的 git toplevel，非 git 則 cwd）
#   --ids   指定探針節點（逗號分隔；用來探「本票新建」的節點——對新節點的偏移最敏感）；省略＝自動取該 .pen 頂層
#           （depth-1）前 3 個有明確數值 x/y 的節點
# 兩道檢查，依序：
#   1. 鎖屏：`ioreg -n Root -d1 -a` 的 IOConsoleLocked 為 true → 直接 exit 3（不必再問 Pen）。ioreg 不存在（非 macOS）
#      → 印一行說明略過這道。
#   2. bounds 偏移：Pen 目前 active 文件須＝該 .pen（否則 exit 2，先 pen-open.sh）；經 `pen interactive --app desktop` 的
#      `execute` 對每個探針節點 `Get` 取 `c.bounds.x/y`，與參考檔（該 .pen 的 Pen autosave backup——較新、含新建節點；
#      沒有 backup 才用磁碟檔）記載的 x/y 比：頂層節點直接比；巢狀節點比「相對父節點」或「累加絕對」任一種（scoped Get 的
#      座標系語意以兩者之一為準，LS-480 未能實測 → PLAUSIBLE，故兩種都接受）。任一探針節點兩軸差 >1pt（PEN_PROBE_TOLERANCE）
#      → exit 3。
# Exit：0＝通過（可接著跑收據掃描）；2＝用法／.pen 不存在／Pen 沒開或開別檔／pen CLI 無回應／沒有可探節點（fail closed，
#      不當通過）；3＝鎖屏或 bounds 偏移——印「⚠ Pen 版面未刷新（鎖屏？先解鎖並 open -a Pen）」，**停下回報，不產收據**。
# 環境變數（自測夾具）：PEN_BIN（pen CLI，預設 pen）、PEN_BACKUP_DIR、PEN_PROBE_TIMEOUT（execute 看門狗秒，預設 30）、
#   PEN_PROBE_TOLERANCE（pt，預設 1）、PEN_PROBE_IOREG_BIN（ioreg，預設 ioreg）、PEN_PROBE_OPEN_SH（pen-open.sh 路徑）。
# 自測：scripts/design/pen-bounds-probe.test.sh（假 ioreg／假 pen 夾具）。規約見 .claude/agents/ui-designer.md、visual-reviewer.md、
#   docs/COLLABORATION.md §4-b。
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
# shellcheck source=../ops/lib/pen-path.sh
source "${repo_root}/scripts/ops/lib/pen-path.sh"

usage() { echo "用法：pen-bounds-probe.sh [--pen <path>] [--root <dir>] [--ids id1,id2,…]" >&2; }

pen_arg=""; root_arg=""; ids_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pen) [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }; pen_arg=$2; shift 2 ;;
    --root) [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }; root_arg=$2; shift 2 ;;
    --ids) [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }; ids_arg=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
tol=${PEN_PROBE_TOLERANCE:-1}
timeout_s=${PEN_PROBE_TIMEOUT:-30}
case "$tol$timeout_s" in *[!0-9.]*|'') echo "✗ pen-bounds-probe：PEN_PROBE_TOLERANCE／PEN_PROBE_TIMEOUT 須為數字" >&2; exit 2 ;; esac

STALE_MSG="⚠ Pen 版面未刷新（鎖屏？先解鎖並 open -a Pen）"

# ---- 1. 鎖屏 ----
ioreg_bin=${PEN_PROBE_IOREG_BIN:-ioreg}
if command -v "$ioreg_bin" >/dev/null 2>&1; then
  ioreg_out=$("$ioreg_bin" -n Root -d1 -a 2>/dev/null) || ioreg_out=""
  # plist：<key>IOConsoleLocked</key> 的下一行是 <true/>／<false/>。不用 `| grep -q`（pipefail+SIGPIPE 會誤判，LS-267／LS-270）
  lock_val=$(printf '%s\n' "$ioreg_out" | grep -A1 'IOConsoleLocked' | tail -1)
  case "$lock_val" in
    *'<true/>'*)
      echo "$STALE_MSG" >&2
      echo "  原因：ioreg IOConsoleLocked＝true（螢幕鎖定時 Pen 不重新排版，Get 回的 bounds 會偏移，LS-471 R3）。停下回報，不產收據。" >&2
      exit 3 ;;
  esac
else
  echo "（pen-bounds-probe：找不到 ${ioreg_bin}，略過鎖屏檢查，只做 bounds 比對）" >&2
fi

# ---- 2. bounds 偏移 ----
if [ -z "$root_arg" ]; then
  root_arg=$(git rev-parse --show-toplevel 2>/dev/null) || root_arg=$(pwd)
fi
root=$(cd "$root_arg" 2>/dev/null && pwd -P) || { echo "✗ pen-bounds-probe：找不到目錄「${root_arg}」" >&2; exit 2; }
pen_resolve_path pen-bounds-probe "$root" "$pen_arg" || exit 2
pen=$PEN_RESOLVED_PATH
command -v python3 >/dev/null 2>&1 || { echo "✗ pen-bounds-probe：需要 python3" >&2; exit 2; }
PEN_BIN=${PEN_BIN:-pen}
command -v "$PEN_BIN" >/dev/null 2>&1 || { echo "✗ pen-bounds-probe：找不到 pen CLI（PATH 上沒有「${PEN_BIN}」）" >&2; exit 2; }

# Pen 目前 active 文件須＝該 .pen（否則 Get 讀到的是別的文件，比出來沒意義）
open_sh=${PEN_PROBE_OPEN_SH:-${repo_root}/scripts/ops/pen-open.sh}
active=$(bash "$open_sh" --status 2>/dev/null) || active=""
if [ -z "$active" ]; then
  echo "✗ pen-bounds-probe：讀不到 Pen 目前文件路徑（Pen 沒開／pen CLI 未登入／連線失敗，fail closed）" >&2
  exit 2
fi
if [ "$active" != "$pen" ]; then
  echo "✗ pen-bounds-probe：Pen 目前文件「${active}」≠ 探測目標「${pen}」——先 bash scripts/ops/pen-open.sh ${root} --pen ${pen}" >&2
  exit 2
fi

backup=$(pen_backup_path "$pen")
if [ -f "$backup" ]; then ref=$backup; ref_label="Pen autosave backup"; else ref=$pen; ref_label="磁碟檔（無 backup）"; fi

# 參考節點：TSV「id<TAB>x<TAB>y<TAB>absx<TAB>absy」（abs 取不到印 -）
nodes_tsv=$(python3 - "$ref" "$ids_arg" <<'PY'
import json, sys
path, ids_arg = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as e:
    print("ERR\t%s: %s" % (type(e).__name__, e)); sys.exit(0)
def num(v): return isinstance(v, (int, float)) and not isinstance(v, bool)
found = []   # (id, x, y, absx|None, absy|None, depth)
def walk(n, depth, ax, ay):
    if not isinstance(n, dict): return
    x, y = n.get("x"), n.get("y")
    hx, hy = num(x), num(y)
    nax = (ax + x) if (ax is not None and hx) else None
    nay = (ay + y) if (ay is not None and hy) else None
    if depth >= 1 and hx and hy and n.get("id") is not None:
        found.append((str(n["id"]), x, y, nax, nay, depth))
    for c in n.get("children") or []:
        walk(c, depth + 1, nax, nay)
for c in doc.get("children") or []:
    walk(c, 1, 0, 0)
if ids_arg:
    want = [i for i in ids_arg.split(",") if i]
    by = {f[0]: f for f in found}
    missing = [i for i in want if i not in by]
    if missing:
        print("MISSING\t" + ",".join(missing))
    pick = [by[i] for i in want if i in by]
else:
    pick = [f for f in found if f[5] == 1][:3]
for f in pick:
    print("%s\t%s\t%s\t%s\t%s" % (f[0], f[1], f[2], "-" if f[3] is None else f[3], "-" if f[4] is None else f[4]))
PY
)
err_line=$(printf '%s\n' "$nodes_tsv" | grep -F "$(printf 'ERR\t')" | head -1)
if [ -n "$err_line" ]; then
  echo "✗ pen-bounds-probe：參考檔「${ref}」解析失敗（${err_line#*$'\t'}）" >&2
  exit 2
fi
missing_line=$(printf '%s\n' "$nodes_tsv" | grep -F "$(printf 'MISSING\t')" | head -1)
if [ -n "$missing_line" ]; then
  echo "✗ pen-bounds-probe：--ids 的節點在參考檔（${ref_label}）中找不到或缺數值 x/y：${missing_line#*$'\t'}（新建節點還沒 autosave？等 autosave 後重跑）" >&2
  exit 2
fi
nodes_tsv=$(printf '%s\n' "$nodes_tsv" | grep -v '^$')
if [ -z "$nodes_tsv" ]; then
  echo "✗ pen-bounds-probe：「${pen}」找不到有明確數值 x/y 的頂層節點可探（用 --ids 指定探針節點）——fail closed" >&2
  exit 2
fi

# 送 execute：每個探針節點 scoped Get 一次（skipChildren，不走訪子樹），Print 其 bounds
snippet=$(python3 - "$nodes_tsv" <<'PY'
import json, sys
ids = [l.split("\t")[0] for l in sys.argv[1].splitlines() if l]
body = "".join(
    "Get(%s, function (n, c) { Print('PROBE-BOUNDS id=' + n.id + ' x=' + c.bounds.x + ' y=' + c.bounds.y); c.skipChildren(); });\n" % json.dumps(i)
    for i in ids)
print("execute({ input: " + json.dumps(body, ensure_ascii=True) + " })")
PY
)
in_f=$(mktemp "${TMPDIR:-/tmp}/pen-probe-in.XXXXXX") || exit 2
out_f=$(mktemp "${TMPDIR:-/tmp}/pen-probe-out.XXXXXX") || { rm -f "$in_f"; exit 2; }
trap 'rm -f "$in_f" "$out_f"' EXIT
printf '%s\nexit()\n' "$snippet" > "$in_f"
"$PEN_BIN" interactive --app desktop < "$in_f" > "$out_f" 2>&1 &
cli_pid=$!
( sleep "$timeout_s"; kill "$cli_pid" 2>/dev/null ) >/dev/null 2>&1 &
wd_pid=$!
wait "$cli_pid" 2>/dev/null
kill "$wd_pid" 2>/dev/null

verdict=$(python3 - "$nodes_tsv" "$out_f" "$tol" <<'PY'
import re, sys
nodes = [l.split("\t") for l in sys.argv[1].splitlines() if l]
text = open(sys.argv[2], encoding="utf-8", errors="replace").read()
tol = float(sys.argv[3])
got = {}
for m in re.finditer(r"PROBE-BOUNDS id=(\S+) x=(-?[0-9.]+) y=(-?[0-9.]+)", text):
    got[m.group(1)] = (float(m.group(2)), float(m.group(3)))
bad, nores = [], []
for nid, x, y, ax, ay in nodes:
    if nid not in got:
        nores.append(nid); continue
    gx, gy = got[nid]
    rel = (abs(gx - float(x)), abs(gy - float(y)))
    ok = max(rel) <= tol
    if not ok and ax != "-" and ay != "-":
        ok = max(abs(gx - float(ax)), abs(gy - float(ay))) <= tol
    print("NODE\t%s\tref=(%s,%s)\tabs=(%s,%s)\tGet=(%g,%g)\t%s" % (nid, x, y, ax, ay, gx, gy, "ok" if ok else "OFFSET"))
    if not ok: bad.append(nid)
if nores:
    print("NORESP\t" + ",".join(nores))
print("VERDICT\t%s" % ("NORESP" if nores else ("OFFSET" if bad else "OK")))
PY
)
printf '%s\n' "$verdict" | awk -F'\t' '$1 == "NODE" { printf "  探針 %s  ref=%s  abs=%s  %s  %s\n", $2, $3, $4, $5, $6 }' >&2
case "$verdict" in
  *"VERDICT	OK"*)
    n_probed=$(printf '%s\n' "$nodes_tsv" | wc -l | tr -d ' ')
    echo "✓ pen-bounds-probe：${n_probed} 個探針節點 Get bounds 與${ref_label}一致（≤${tol}pt）——可跑收據掃描（${pen}）"
    exit 0 ;;
  *"VERDICT	NORESP"*)
    echo "✗ pen-bounds-probe：Pen 對探針節點沒有回 PROBE-BOUNDS（${timeout_s}s 內逾時／InternalError／節點不在 Pen 文件中；Pen 開的檔與 autosave backup 不同步？）——fail closed，不當通過" >&2
    exit 2 ;;
  *)
    echo "$STALE_MSG" >&2
    echo "  原因：探針節點 Get bounds 與${ref_label}記載的 x/y 差 >${tol}pt（見上方 OFFSET 列）。停下回報，不產收據；解鎖後 open -a Pen 一次、等 autosave 再重跑本探針。" >&2
    exit 3 ;;
esac
