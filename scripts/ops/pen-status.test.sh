#!/bin/bash
# pen-status.sh 的自測（LS-180）。stub `pgrep`（依樣式分「Pen 主行程」／「mcp-server」兩路，各讀一個 pid 檔）、`lsof`
# （`-p <pid>` 讀 $STUB_LSOF_DIR/<pid> 的 `-F dn` 格式內容）、`pen`（get_app_state 依狀態檔），全程不碰真的 Pen／pen CLI／
# 真的 lsof。「前饋必有反饋」對探針本身也適用：若交集邏輯退化成「有 mcp-server 行程就算 ✓」、斷線判成 ✓、缺 lsof 判成 ✗、
# Pen 沒開還去打 pen CLI、或 exit 碼與 ✗ 不對應，這裡會紅。
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
export STUB_PEN_PID="${work}/pen.pid" STUB_MCP_PIDS="${work}/mcp.pids" STUB_LSOF_DIR="${work}/lsof" STUB_PEN_STATE="${work}/state" STUB_PEN_CALLS="${work}/pen.calls"
mkdir -p "$STUB_LSOF_DIR"

cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
case "$*" in
  *mcp-server*) [ -s "${STUB_MCP_PIDS:?}" ] && cat "${STUB_MCP_PIDS}" ;;
  *) [ -s "${STUB_PEN_PID:?}" ] && cat "${STUB_PEN_PID}" ;;
esac
exit 0
STUB
cat > "${bin}/lsof" <<'STUB'
#!/bin/bash
pid=
while [ $# -gt 0 ]; do
  if [ "$1" = -p ]; then pid=$2; shift 2; else shift; fi
done
[ -n "$pid" ] && [ -f "${STUB_LSOF_DIR:?}/${pid}" ] && cat "${STUB_LSOF_DIR}/${pid}"
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
chmod +x "${bin}/pgrep" "${bin}/lsof" "${bin}/pen"
export PATH="${bin}:${PATH}"
export PEN_OPEN_ATTEMPT_TIMEOUT=1

# Pen pid 3185 的 unix socket：listen socket（有路徑）＋一條已接受的連線（peer 0xC）；同本票實機 `lsof -F dn` 的形狀
pen_lsof_connected() {
  printf 'p3185\nf42\nd0xAAAA\nn/Users/x/.pencil/socket/pencil-desktop.sock\nf43\nd0xBBBB\nn->0xCCCC\n' > "${STUB_LSOF_DIR}/3185"
}
mcp_lsof_connected() { printf 'p%s\nf0\nd0x1111\nn->0x9991\nf1\nd0x2222\nn->0x9992\nf2\nd0x3333\nn->0x9993\nf5\nd0xCCCC\nn->0xBBBB\n' "$1" > "${STUB_LSOF_DIR}/$1"; }
mcp_lsof_disconnected() { printf 'p%s\nf0\nd0x1111\nn->0x9991\nf1\nd0x2222\nn->0x9992\nf2\nd0x3333\nn->0x9993\n' "$1" > "${STUB_LSOF_DIR}/$1"; }
set_pen() { printf '%s' "$1" > "$STUB_PEN_PID"; }
set_mcp() { printf '%s\n' "$1" > "$STUB_MCP_PIDS"; }
set_state() { printf '%s' "$1" > "$STUB_PEN_STATE"; }
pen_calls() { wc -l < "$STUB_PEN_CALLS" 2>/dev/null | tr -d ' ' || echo 0; }
reset() { : > "$STUB_PEN_PID"; : > "$STUB_MCP_PIDS"; : > "$STUB_PEN_CALLS"; rm -f "${STUB_LSOF_DIR}"/*; set_state EMPTY; }
run() { bash "$script" "$@"; }
want=/x/design/littlesprout.pen

# ---- ① 全部正常：行程 ✓、路徑讀到、mcp-server 的 peer 落在 Pen 位址集合 → ✓ exit 0 ----
reset; set_pen 3185; set_mcp 24097; pen_lsof_connected; mcp_lsof_connected 24097; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '行程 ✓（pid 3185）' && printf '%s' "$out" | grep -qF "路徑 ${want}" \
  && printf '%s' "$out" | grep -qF 'MCP 探針 ✓（mcp-server 1 支皆有 unix socket 連到 Pen pid 3185）'; then
  ok '① 行程 ✓／路徑 ✓／MCP socket 交集命中 → ✓ exit 0'
else
  bad "① 應 exit 0 三項 ✓（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ② mcp-server 存活但只剩 stdio fd（peer 皆不在 Pen 位址集合）→ ✗ exit 1，指示 /mcp 重連（本票斷線現場的形狀）----
reset; set_pen 3185; set_mcp 24097; pen_lsof_connected; mcp_lsof_disconnected 24097; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'MCP 探針 ✗（mcp-server 1 支皆無 Pen socket 連線' \
  && printf '%s' "$out" | grep -qF '/mcp 重連 pencil' && printf '%s' "$out" | grep -qF '行程 ✓'; then
  ok '② mcp-server 無 Pen socket 連線 → ✗ exit 1，含 /mcp 重連指引'
else
  bad "② 應 exit 1 且標 ✗（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ③ 沒有 mcp-server 行程 → ✗ exit 1（本機沒有任何 session 連著 pencil）----
reset; set_pen 3185; pen_lsof_connected; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '沒有 Pencil mcp-server 行程'; then
  ok '③ 無 mcp-server 行程 → ✗ exit 1'
else
  bad "③ 應 exit 1（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ④ 缺 lsof → 不可測（不判 ✗）；其餘 ✓ 時 exit 0 ----
reset; set_pen 3185; set_mcp 24097; set_state "PATH:${want}"
out="$(PEN_STATUS_LSOF_BIN=no-such-lsof-xyz run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF 'MCP 探針 不可測（無 lsof'; then
  ok '④ 缺 lsof → 不可測、不判 ✗，exit 0'
else
  bad "④ 應 exit 0 且標不可測（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑤ lsof 讀不到 Pen 的 unix socket（空輸出）→ 不可測 ----
reset; set_pen 3185; set_mcp 24097; mcp_lsof_connected 24097; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '不可測（lsof 讀不到 Pen pid 3185'; then
  ok '⑤ lsof 讀不到 Pen socket → 不可測，exit 0'
else
  bad "⑤ 應 exit 0 且標不可測（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑥ Pen 沒開：行程 ✗、路徑不查（pen CLI 零呼叫）、mcp-server 存活也判 ✗ → exit 1 ----
reset; set_mcp 24097; mcp_lsof_connected 24097; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '行程 ✗（Pen 沒開）' && printf '%s' "$out" | grep -qF '路徑 —' \
  && printf '%s' "$out" | grep -qF '但 Pen 沒開——必然斷線' && [ "$(pen_calls)" -eq 0 ]; then
  ok '⑥ Pen 沒開 → 行程 ✗、不打 pen CLI、MCP ✗，exit 1'
else
  bad "⑥ 應 exit 1 且 pen CLI 零呼叫（實得 ${got}，pen 呼叫 $(pen_calls) 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑦ 行程在但 pen CLI 讀不到路徑 → 路徑 ✗ exit 1（MCP 仍照探）----
reset; set_pen 3185; set_mcp 24097; pen_lsof_connected; mcp_lsof_connected 24097; set_state EMPTY
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '路徑 ✗（pen CLI 讀不到' && printf '%s' "$out" | grep -qF 'MCP 探針 ✓'; then
  ok '⑦ pen CLI 讀不到路徑 → 路徑 ✗ exit 1，MCP 仍 ✓'
else
  bad "⑦ 應 exit 1（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑧ 多支 mcp-server、只有一支連著 → ✗（分不出哪支是本 session）exit 1 ----
reset; set_pen 3185; set_mcp $'24097\n24098'; pen_lsof_connected; mcp_lsof_connected 24097; mcp_lsof_disconnected 24098; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'mcp-server 2 支、僅 1 支連到 Pen'; then
  ok '⑧ 兩支 mcp-server 僅一支連著 → ✗ exit 1'
else
  bad "⑧ 應 exit 1（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
reset; set_pen 3185; set_mcp $'24097\n24098'; pen_lsof_connected; mcp_lsof_connected 24097; mcp_lsof_connected 24098; set_state "PATH:${want}"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF 'mcp-server 2 支皆有'; then
  ok '⑧ 兩支皆連著 → ✓ exit 0'
else
  bad "⑧ 兩支皆連著應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑨ mutation 防退化：mcp-server 有「多一個非 stdio 的 unix fd」但 peer 不在 Pen 集合（連到別的 socket）→ 仍 ✗ ----
reset; set_pen 3185; set_mcp 24097; pen_lsof_connected; set_state "PATH:${want}"
printf 'p24097\nf0\nd0x1111\nn->0x9991\nf5\nd0xDDDD\nn->0xEEEE\n' > "${STUB_LSOF_DIR}/24097"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'MCP 探針 ✗'; then
  ok '⑨ 有額外 unix fd 但 peer 不是 Pen → 仍 ✗（交集判定，不是「有 socket 就算」）'
else
  bad "⑨ 應 exit 1 ✗（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑩ 用法 ----
out="$(run extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '⑩ 帶參數 → exit 2'; else bad "⑩ 應 exit 2（實得 ${got}）"; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-status 自測失敗" >&2
  exit 1
fi
echo "✓ pen-status 自測通過（${n} 組樣本）"
