#!/bin/bash
# db-reset-retry.sh 的自測（LS-186）。CI rules job 每個 PR 都跑。不碰真容器：PATH 前置假 `supabase`／`sleep`——假 supabase 把
# 每次呼叫的參數追加到 $FAKE_LOG、依 $FAKE_MODE 與「第幾次 db reset」決定輸出與 exit code；假 sleep 只記錄不等待。
# 「前饋必有反饋」對這支也適用：port 競態不重試、其他錯誤也重試、重試兩次以上、stop 失敗連帶紅、原錯誤訊息被吞、exit code 被
# 改寫、重試前沒有 stop → sleep → db start 的序列，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ci/db-reset-retry.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; sed 's/^/    /' "$work/out" >&2; echo "    calls: $(paste -s -d '|' "$FAKE_LOG")" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# LS-184 run 33934840343 的原句（假 supabase 從環境變數讀，heredoc 不展開）
PORT_ERR='failed to start docker container "supabase_db_little-sprout": Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint supabase_db_little-sprout (87196b89): failed to bind host port for 0.0.0.0:54322:172.18.0.2:5432/tcp: address already in use'
OTHER_ERR='ERROR: syntax error at or near "SELEC" (SQLSTATE 42601) At statement 3: supabase/migrations/20250901000000_x.sql'
export PORT_ERR OTHER_ERR
cat > "$work/bin/supabase" <<'EOF'
#!/bin/bash
log="${FAKE_LOG:?}"
printf '%s\n' "$*" >> "$log"
case "$*" in
  'db reset')
    k=$(grep -c '^db reset$' "$log")
    case "${FAKE_MODE:?}" in
      ok) echo 'Finished supabase db reset.'; exit 0 ;;
      flake_once|stop_fails|start_fails)
        if [ "$k" -eq 1 ]; then echo 'Resetting local database...'; echo "$PORT_ERR" >&2; echo 'Error: failed to start containers: c8863dc6' >&2; exit 1; fi
        echo 'Finished supabase db reset.'; exit 0 ;;
      flake_stdout)
        if [ "$k" -eq 1 ]; then echo "$PORT_ERR"; exit 1; fi
        echo 'Finished supabase db reset.'; exit 0 ;;
      flake_twice) echo "$PORT_ERR" >&2; exit 1 ;;
      other_error) echo "$OTHER_ERR" >&2; exit 3 ;;
    esac
    echo "stub supabase: unknown FAKE_MODE ${FAKE_MODE}" >&2; exit 98 ;;
  'stop --no-backup')
    if [ "${FAKE_MODE:?}" = stop_fails ]; then echo 'stub: stop failed' >&2; exit 1; fi
    exit 0 ;;
  'db start')
    if [ "${FAKE_MODE:?}" = start_fails ]; then echo 'stub: start failed' >&2; exit 5; fi
    exit 0 ;;
esac
echo "stub supabase: unexpected args: $*" >&2
exit 99
EOF
cat > "$work/bin/sleep" <<'EOF'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "${FAKE_LOG:?}"
EOF
chmod +x "$work/bin/supabase" "$work/bin/sleep"
export PATH="$work/bin:$PATH"
export FAKE_LOG="$work/calls.log"

# run <FAKE_MODE>：清 log、跑腳本；輸出到 $work/out、exit code 到 $rc
run() { export FAKE_MODE=$1; : > "$FAKE_LOG"; bash "$script" > "$work/out" 2>&1; rc=$?; }
seq_is() { [ "$(paste -s -d '|' "$FAKE_LOG")" = "$1" ]; }
out_has() { grep -qF -- "$1" "$work/out"; }

# ① 首次就成功：只呼叫一次、不 stop／sleep／start
run ok
if [ "$rc" -eq 0 ] && seq_is 'db reset'; then ok '① 首次成功 → exit 0、只呼叫一次 db reset'; else bad "① 首次成功應 exit 0 且只呼叫一次（實得 exit ${rc}）"; fi

# ② 54322 port 競態一次 → stop --no-backup → sleep 10 → db start → 重試一次 → 綠
run flake_once
if [ "$rc" -eq 0 ] && seq_is 'db reset|stop --no-backup|sleep 10|db start|db reset'; then ok '② port 競態一次 → 序列 reset→stop→sleep 10→db start→reset、exit 0'; else bad "② port 競態一次應重試一次並 exit 0（實得 exit ${rc}）"; fi
if out_has 'address already in use' && out_has 'Error: failed to start containers: c8863dc6'; then ok '② 第一次失敗的 stderr 原樣串流到輸出'; else bad '② 第一次失敗的錯誤輸出應原樣出現'; fi
if out_has '54322 port 綁定競態' && out_has 'Finished supabase db reset.'; then ok '② 印出重試原因、第二次成功輸出也在'; else bad '② 應印重試原因與第二次輸出'; fi

# ③ 其他錯誤：不重試、只呼叫一次、原 exit code、原錯誤訊息
run other_error
if [ "$rc" -eq 3 ] && seq_is 'db reset'; then ok '③ 其他錯誤 → 不重試、只呼叫一次、exit 3（原 exit code）'; else bad "③ 其他錯誤應只呼叫一次且 exit 3（實得 exit ${rc}）"; fi
if out_has "$OTHER_ERR" && out_has '不是 54322 port 綁定競態——不重試'; then ok '③ 原錯誤訊息原樣印出＋說明不重試'; else bad '③ 應原樣印出錯誤並說明不重試'; fi
if ! grep -q '^sleep' "$FAKE_LOG" && ! grep -q '^stop' "$FAKE_LOG" && ! grep -q '^db start' "$FAKE_LOG"; then ok '③ 其他錯誤不 stop／sleep／db start'; else bad '③ 其他錯誤不得 stop／sleep／db start'; fi

# ④ 重試仍是 port 競態：只重試一次（reset 恰兩次）、exit 非 0
run flake_twice
if [ "$rc" -eq 1 ] && seq_is 'db reset|stop --no-backup|sleep 10|db start|db reset'; then ok '④ 重試仍失敗 → reset 恰兩次（不再重試）、exit 1'; else bad "④ 重試仍失敗應恰兩次 reset 且 exit 1（實得 exit ${rc}）"; fi
if out_has '重試一次後 supabase db reset 仍失敗'; then ok '④ 印出「重試一次後仍失敗」'; else bad '④ 應印出重試後仍失敗'; fi

# ⑤ stop 失敗不影響（|| true）：序列與 ② 相同、仍綠
run stop_fails
if [ "$rc" -eq 0 ] && seq_is 'db reset|stop --no-backup|sleep 10|db start|db reset'; then ok '⑤ stop --no-backup 失敗不影響重試、exit 0'; else bad "⑤ stop 失敗不應影響（實得 exit ${rc}）"; fi

# ⑥ 重試前 db start 失敗：不再跑第二次 reset、以 db start 的 exit code 結束
run start_fails
if [ "$rc" -eq 5 ] && seq_is 'db reset|stop --no-backup|sleep 10|db start'; then ok '⑥ 重試前 db start 失敗 → 不跑第二次 reset、exit 5（原 exit code）'; else bad "⑥ db start 失敗應 exit 5 且不跑第二次 reset（實得 exit ${rc}）"; fi
if out_has '重試前 supabase db start 失敗'; then ok '⑥ 印出 db start 失敗'; else bad '⑥ 應印出 db start 失敗'; fi

# ⑦ port 錯誤印在 stdout（不是 stderr）也認得：偵測看合併輸出
run flake_stdout
if [ "$rc" -eq 0 ] && seq_is 'db reset|stop --no-backup|sleep 10|db start|db reset'; then ok '⑦ port 錯誤在 stdout 也觸發重試'; else bad "⑦ stdout 的 port 錯誤也應重試（實得 exit ${rc}）"; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ db-reset-retry 自測失敗" >&2
  exit 1
fi
echo "✓ db-reset-retry 自測通過（${n} 組樣本）"
