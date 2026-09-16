#!/bin/bash
# pen-status.sh 的自測（LS-180；**LS-308 改寫**：MCP 訊號從 lsof fd 交集改成 ps 父行程判定，見 pen-status.sh 檔頭沿革）。
# stub `pgrep`（依樣式分「Pen 主行程」／「mcp-server」兩路，各讀一個 pid 檔）、`ps`（`-o ppid= -p <pid>` 與
# `-o command= -p <pid>` 依 $STUB_PS_DB 的「pid ppid command」表回答）、`pen`（get_app_state 依狀態檔），全程不碰
# 真的 Pen／pen CLI／真的 ps。「前饋必有反饋」對探針本身也適用：若「本 session」判定退化成「有 mcp-server 行程就算
# ✓」（不看父行程命令）、MCP 訊號誤影響 exit code、或 Pen 沒開時仍去打 pen CLI，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/pen-status.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"; mkdir -p "$bin"
export STUB_PEN_PID="${work}/pen.pid" STUB_MCP_PIDS="${work}/mcp.pids" STUB_PS_DB="${work}/ps.db" STUB_PEN_STATE="${work}/state" STUB_PEN_CALLS="${work}/pen.calls"

cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
case "$*" in
  *mcp-server*) [ -s "${STUB_MCP_PIDS:?}" ] && cat "${STUB_MCP_PIDS}" ;;
  *) [ -s "${STUB_PEN_PID:?}" ] && cat "${STUB_PEN_PID}" ;;
esac
exit 0
STUB
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
mode=; pid=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) mode=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "${STUB_PS_DB:?}" ] || exit 0
row=$(awk -v p="$pid" '$1 == p { $1=""; sub(/^ /, ""); print }' "${STUB_PS_DB}")
[ -n "$row" ] || exit 0
ppid=${row%% *}
cmd=${row#* }
case "$mode" in
  ppid=) printf '%s\n' "$ppid" ;;
  command=) printf '%s\n' "$cmd" ;;
esac
exit 0
STUB
cat > "${bin}/pen" <<'STUB'
#!/bin/bash
echo x >> "${STUB_PEN_CALLS:?}"
cat >/dev/null
content="$(cat "${STUB_PEN_STATE:?}" 2>/dev/null || true)"
case "$content" in
  PATH:*) printf 'Currently active canvas editor: `%s`\n' "${content#PATH:}" ;;
  *) echo "(no active document)" ;;
esac
STUB
chmod +x "${bin}/pgrep" "${bin}/ps" "${bin}/pen"
export PATH="${bin}:${PATH}"
export PEN_OPEN_ATTEMPT_TIMEOUT=1

set_pen() { printf '%s' "$1" > "$STUB_PEN_PID"; }
set_mcp() { printf '%s\n' "$1" > "$STUB_MCP_PIDS"; }
# ps.db 每行「<查詢用 pid> <該 pid 自己的 ppid> <該 pid 自己的 command>」——pen-status.sh 對同一支 mcp-server 會
# 查兩次：先 `ps -o ppid= -p <mcp pid>` 拿父行程 pid，再 `ps -o command= -p <父行程 pid>` 拿父行程自己的 command。
# set_mcp_parent 一次補齊這兩筆：mcp pid 自己的 ppid＝parent_pid；parent_pid 自己的 command＝parent_cmd。
set_mcp_parent() {
  local mcp_pid=$1 parent_pid=$2 parent_cmd=$3
  printf '%s %s -\n' "$mcp_pid" "$parent_pid" >> "$STUB_PS_DB"
  printf '%s 1 %s\n' "$parent_pid" "$parent_cmd" >> "$STUB_PS_DB"
}
set_state() { printf '%s' "$1" > "$STUB_PEN_STATE"; }
pen_calls() { wc -l < "$STUB_PEN_CALLS" 2>/dev/null | tr -d ' ' || echo 0; }
reset() { : > "$STUB_PEN_PID"; : > "$STUB_MCP_PIDS"; : > "$STUB_PS_DB"; : > "$STUB_PEN_CALLS"; set_state EMPTY; }
run() { bash "$script" "$@"; }
want=/x/design/littlesprout.pen

# ---- ① 本 session 有 mcp-server（父行程 pid 900 命令含 claude、活著）→ MCP ✓，exit 0（proc／path 皆正常） ----
reset; set_pen 3185; set_mcp 24097; set_mcp_parent 24097 900 claude; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '行程 ✓（pid 3185）' && printf '%s' "$out" | grep -qF "路徑 ${want}" \
  && printf '%s' "$out" | grep -qF 'MCP：本 session mcp-server ✓（pid 24097，懶連線，派工前實測一次 get_app_state）' \
  && ! printf '%s' "$out" | grep -qF 'informational'; then
  ok '① 父行程是活著的 claude → 判「本 session」✓，exit 0，無殘留 informational'
else
  bad "① 應 exit 0 且印本 session ✓（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ② mcp-server 存在但父行程命令不是 claude（如已死、重新掛到別的父行程或 codex）→「本 session 沒有」，
#      但 MCP 訊號不影響 exit code（LS-308：mcp-server 懶連線，缺「本 session」的那支不是壞掉，只是這次還沒打過）----
reset; set_pen 3185; set_mcp 24097; set_mcp_parent 24097 1 launchd; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '本 session 沒有 mcp-server 行程' \
  && printf '%s' "$out" | grep -qF '另有 1 支別 session 的 mcp-server（informational）'; then
  ok '② 父行程非 claude（孤兒／別的父行程）→「本 session 沒有」＋1 支殘留 informational，exit 0 不受影響'
else
  bad "② 應 exit 0 且印本 session 沒有＋殘留（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ③ 完全沒有 mcp-server 行程 → 「本機沒有 Pencil mcp-server 行程」，exit 0（proc／path 正常時） ----
reset; set_pen 3185; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '本機沒有 Pencil mcp-server 行程'; then
  ok '③ 無 mcp-server 行程 → 印「本機沒有」，exit 0（不影響 exit）'
else
  bad "③ 應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ④ 一支本 session（父行程 claude）＋兩支殘留（父行程各自不同）→ 殘留數＝2 ----
reset; set_pen 3185; set_mcp $'24097\n24098\n24099'
set_mcp_parent 24097 900 claude; set_mcp_parent 24098 1 launchd; set_mcp_parent 24099 500 codex
set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF 'MCP：本 session mcp-server ✓（pid 24097' \
  && printf '%s' "$out" | grep -qF '另有 2 支別 session 的 mcp-server（informational）'; then
  ok '④ 一支本 session＋兩支殘留 → 殘留數＝其餘 mcp-server 行程數（2），exit 0'
else
  bad "④ 應印殘留數 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑤ 防退化：mcp-server 存在但父行程 ps 查無資料（ppid 讀不到）→ 仍判「本 session 沒有」，不是「有 mcp-server
#      行程就算 ✓」；exit 仍 0 ----
reset; set_pen 3185; set_mcp 24097; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '本 session 沒有 mcp-server 行程' \
  && ! printf '%s' "$out" | grep -qF '本 session mcp-server ✓'; then
  ok '⑤ 父行程資訊讀不到 → 不誤判「本 session」✓（判定看父行程命令，不是「有行程就算」）'
else
  bad "⑤ 應印「本 session 沒有」不誤判 ✓（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑥ Pen 沒開：行程 ✗、路徑不查（pen CLI 零呼叫）、exit 1（MCP 完全不影響——這裡紅是因為 proc ✗）----
reset; set_mcp 24097; set_mcp_parent 24097 900 claude; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '行程 ✗（Pen 沒開）' && printf '%s' "$out" | grep -qF '路徑 —' \
  && [ "$(pen_calls)" -eq 0 ] && printf '%s' "$out" | grep -qF 'MCP：本 session mcp-server ✓'; then
  ok '⑥ Pen 沒開 → 行程 ✗ exit 1（proc 造成，非 MCP），不打 pen CLI，MCP 訊號照印'
else
  bad "⑥ 應 exit 1 且 pen CLI 零呼叫（實得 ${got}，pen 呼叫 $(pen_calls) 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑦ 行程在但 pen CLI 讀不到路徑 → 路徑 ✗ exit 1（MCP 仍照印，不受影響）----
reset; set_pen 3185; set_mcp 24097; set_mcp_parent 24097 900 claude; set_state EMPTY
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '路徑 ✗（pen CLI 讀不到' \
  && printf '%s' "$out" | grep -qF 'MCP：本 session mcp-server ✓'; then
  ok '⑦ pen CLI 讀不到路徑 → 路徑 ✗ exit 1（proc 造成），MCP 仍照印'
else
  bad "⑦ 應 exit 1（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑧ 用法 ----
out="$(run extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '⑧ 帶參數 → exit 2'; else bad "⑧ 應 exit 2（實得 ${got}）"; fi

# ---- ⑨（LS-211 I-c，來源 LS-96 池項 edbc460c）：--path 機器可讀輸出——只印路徑一行，供 patrol.sh 讀取（與 MCP 訊號無關，
#      這段沿用 LS-180 舊行為，只是換掉上面已刪的 lsof 夾具） ----
reset; set_pen 3185; set_mcp 24097; set_mcp_parent 24097 900 claude; set_state "PATH:${want}"
out="$(run --path 2>&1)"; got=$?
if [ "$got" -eq 0 ] && [ "$out" = "$want" ]; then
  ok '⑨a --path：Pen 開著且路徑讀得到 → 只印路徑一行、exit 0'
else
  bad "⑨a 應輸出「${want}」exit 0（實得「${out}」exit ${got}）"
fi

reset; set_mcp 24097; set_mcp_parent 24097 900 claude; set_state "PATH:${want}"
out="$(run --path 2>&1)"; got=$?
if [ "$got" -eq 1 ] && [ -z "$out" ]; then
  ok '⑨b --path：Pen 沒開 → 不印任何東西、exit 1'
else
  bad "⑨b 應空輸出 exit 1（實得「${out}」exit ${got}）"
fi

reset; set_pen 3185; set_mcp 24097; set_mcp_parent 24097 900 claude; set_state EMPTY
out="$(run --path 2>&1)"; got=$?
if [ "$got" -eq 1 ] && [ -z "$out" ]; then
  ok '⑨c --path：Pen 開著但 pen CLI 讀不到路徑 → 不印任何東西、exit 1'
else
  bad "⑨c 應空輸出 exit 1（實得「${out}」exit ${got}）"
fi

out="$(run --path extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then
  ok '⑨d --path 帶多餘參數 → exit 2'
else
  bad "⑨d 應 exit 2（實得 ${got}）"
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-status 自測失敗" >&2
  exit 1
fi
echo "✓ pen-status 自測通過（${n} 組樣本）"
