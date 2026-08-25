#!/bin/bash
# pen-open.sh 的自測（LS-91）。CI 自測 step 每個 PR 都跑。
# stub `open`（記錄呼叫，不做任何事）與 `pen`（依控制檔決定 get_app_state 的輸出：命中目標路徑／命中別的
# 路徑／讀不到／掛住）——不碰真正的 Pen app 或 pen CLI session。
# 「前饋必有反饋」對 gate 本身也適用：若路徑比對退化成子字串、逾時判斷漏放行不一致案例、
# Pen 未開時誤放行、或 --status 模式意外呼叫了 `open`，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/pen-open.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bin="${work}/bin"
mkdir -p "$bin"
wt="${work}/wt"
mkdir -p "${wt}/design"
cat > "${wt}/design/littlesprout.pen" <<'JSON'
{"version":1,"children":[]}
JSON
want="$(cd "${wt}/design" && pwd -P)/littlesprout.pen"

export PEN_STUB_STATE="${work}/state"
export PEN_STUB_OPEN_LOG="${work}/open.log"
: > "$PEN_STUB_OPEN_LOG"

# stub `open`：只記錄呼叫參數，不真的開任何 app
cat > "${bin}/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${PEN_STUB_OPEN_LOG:?}"
exit 0
STUB
chmod +x "${bin}/open"

# stub `pen`：只認 `interactive --app desktop`（忽略餵進去的 stdin 內容），依 $PEN_STUB_STATE 決定輸出——
#   PATH:<path> → 印 get_app_state 格式的那一行；HANG → sleep 5（測 ATTEMPT_TIMEOUT 看門狗）；其他 → 模擬讀不到
cat > "${bin}/pen" <<'STUB'
#!/bin/bash
if [ "$1" != interactive ]; then exit 1; fi
content="$(cat "${PEN_STUB_STATE:?}" 2>/dev/null || true)"
case "$content" in
  PATH:*)
    p=${content#PATH:}
    printf 'Currently active canvas editor: `%s`\n' "$p"
    ;;
  HANG)
    sleep 5
    ;;
  *)
    echo "(no active document)"
    ;;
esac
STUB
chmod +x "${bin}/pen"

export PATH="${bin}:${PATH}"
export PEN_OPEN_TIMEOUT=2 PEN_OPEN_ATTEMPT_TIMEOUT=1 PEN_OPEN_POLL_INTERVAL=1

set_state() { printf '%s' "$1" > "$PEN_STUB_STATE"; }
open_calls() { wc -l < "$PEN_STUB_OPEN_LOG" | tr -d ' '; }

run() { bash "$script" "$@"; }

# ---- 一致 ----
set_state "PATH:${want}"
before=$(open_calls)
out="$(run "$wt" 2>&1)"; got=$?
after=$(open_calls)
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "Pen 目前文件＝${want}" \
  && [ "$after" -eq $((before + 1)) ] && grep -qF -- "-a Pen ${want}" "$PEN_STUB_OPEN_LOG"; then
  ok '一致：路徑相符 → exit 0，且真的呼叫了 open -a Pen <want>'
else
  bad "一致案例應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- 不一致 ----
other="${work}/wt-other/design/littlesprout.pen"
set_state "PATH:${other}"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "${want}" && printf '%s' "$out" | grep -qF "${other}"; then
  ok '不一致：Pen 目前是別的檔 → exit 1，訊息含兩邊路徑'
else
  bad "不一致案例應 exit 1 且印兩邊路徑（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- Pen 未開／讀不到（開檔模式） ----
set_state EMPTY
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '讀不到 Pen 文件路徑'; then
  ok 'Pen 未開（開檔模式）：讀不到路徑 → exit 2（fail closed）'
else
  bad "Pen 未開應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- 掛住：ATTEMPT_TIMEOUT 看門狗要能把卡住的 pen 進程殺掉，不讓整支腳本卡死 ----
set_state HANG
t0=$SECONDS
out="$(run "$wt" 2>&1)"; got=$?
elapsed=$((SECONDS - t0))
if [ "$got" -eq 2 ] && [ "$elapsed" -le 4 ]; then
  ok "掛住：pen 進程 sleep 5 但看門狗在 ${elapsed}s 內收工 → exit 2"
else
  bad "掛住案例應在數秒內 exit 2（實得 ${got}，耗時 ${elapsed}s）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- --status 模式 ----
set_state "PATH:${want}"
before=$(open_calls)
out="$(run --status 2>&1)"; got=$?
after=$(open_calls)
if [ "$got" -eq 0 ] && [ "$out" = "$want" ] && [ "$after" -eq "$before" ]; then
  ok '--status：讀到路徑就印出、exit 0，且不呼叫 open（不切檔）'
else
  bad "--status 成功案例應 exit 0 印出路徑且不呼叫 open（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

set_state EMPTY
out="$(run --status 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '讀不到 Pen 目前文件路徑'; then
  ok '--status：讀不到 → exit 2'
else
  bad "--status 失敗案例應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- 參數形狀 ----
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '無參數 → exit 2'; else bad "無參數應 exit 2（實得 ${got}）"; fi
out="$(run "$wt" extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '多參數 → exit 2'; else bad "多參數應 exit 2（實得 ${got}）"; fi

# ---- 環境與路徑錯誤 ----
out="$(PEN_BIN=does-not-exist-789 run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到 pen CLI'; then ok 'PEN_BIN 找不到 → exit 2'; else bad "PEN_BIN 缺應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

out="$(PEN_OPEN_TIMEOUT=abc run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '須為整數秒'; then ok '逾時參數非整數 → exit 2'; else bad "非整數逾時應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

out="$(run "${work}/nope" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到目錄'; then ok '目標目錄不存在 → exit 2'; else bad "目錄不存在應 exit 2（實得 ${got}）"; fi

mkdir -p "${work}/no-pen-file/design"
out="$(run "${work}/no-pen-file" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到'; then ok 'design/littlesprout.pen 不存在 → exit 2'; else bad ".pen 缺應 exit 2（實得 ${got}）"; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-open-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-open 自測通過（${n} 組樣本）"
