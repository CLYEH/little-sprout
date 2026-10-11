#!/bin/bash
# scripts/gates/emu-all-guard.test.sh（LS-477）
#
# 自測 scripts/gates/emu-all-guard.sh：K1 `adb kill-server`、K2 `adb emu kill` 無 -s、K3 `avdmanager delete avd` 非本票——
# 正樣本（必 deny，含 `&&`／`;`／管線串接、wrapper 前綴、bash -c 遞迴、-e／-d 不算 -s）、負樣本（必 allow：
# `-s <serial> emu kill`、變數 serial、唯讀 adb、引號／echo／commit message／非 shell heredoc 內的字樣）、fail-open
# （空 stdin、JSON 壞、python3 缺席）、settings.json 接線（matcher=Bash、**不**接 `|| exit 2`＝fail-open 極性，
# 且既有 hook 條目一個不少）、mutation 負控（拿掉 K1／K2 的 -s 判斷／K3 的本票前綴比對 → 原本 deny 的樣本必須改判 allow）。
# 本票號一律由 JSON 的 cwd 推（餵 .claude/worktrees/LS-477 路徑），不依賴本機實際目錄。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${root}/scripts/gates/emu-all-guard.sh"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

CWD_T="/Users/x/little-sprout/.claude/worktrees/LS-477"
CWD_MAIN="/Users/x/little-sprout"

# payload <command> [cwd]：JSON 編碼（命令含引號／換行也不會壞）
payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "${2:-$CWD_T}"
}

# expect_at <script> <label> <want_exit> <command> [cwd]
expect_at() {
  local script=$1 label=$2 want=$3 cmd=$4 cwd=${5:-$CWD_T} out got
  out=$(payload "$cmd" "$cwd" | bash "$script" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ ${label}（期望 exit ${want}，實得 ${got}；輸出：${out}）" >&2; fail=1; return
  fi
  if [ "$want" -eq 0 ]; then
    [ -z "$out" ] || { echo "✗ ${label}（allow 應無輸出，實得：${out}）" >&2; fail=1; return; }
  else
    case "$out" in
      *'"permissionDecision":"deny"'*'LS-477'*) ;;
      *) echo "✗ ${label}（deny 輸出缺 deny JSON 或 LS-477 理由：${out}）" >&2; fail=1; return ;;
    esac
  fi
  echo "✓ ${label}"
}
expect() { expect_at "$gate" "$@"; }

# ---- K1 adb kill-server：任何形式都 deny ----
expect 'K1a adb kill-server → deny' 2 'adb kill-server'
expect 'K1b 帶 -s 也 deny（server 是共用的）' 2 'adb -s emulator-5554 kill-server'
expect 'K1c 絕對路徑 adb' 2 '$ANDROID_HOME/platform-tools/adb kill-server'
expect 'K1d && 串接' 2 'adb devices && adb kill-server'
expect 'K1e ; 串接' 2 'echo start; adb kill-server; adb start-server'
expect 'K1f 管線後段' 2 'true | adb kill-server'
expect 'K1g sudo／env 前綴' 2 'sudo env X=1 adb kill-server'
expect 'K1h bash -c 遞迴' 2 "bash -c 'adb kill-server'"
expect 'K1i 子 shell／括號' 2 '(adb kill-server)'
expect 'K1j if/then 關鍵字後' 2 'if true; then adb kill-server; fi'

# ---- K2 adb emu kill 無 -s ----
expect 'K2a adb emu kill → deny' 2 'adb emu kill'
expect 'K2b -e 不算 -s' 2 'adb -e emu kill'
expect 'K2c -d 不算 -s' 2 'adb -d emu kill'
expect 'K2d && 串接' 2 'cd android && adb emu kill'
expect 'K2e 前面有帶 -s 的另一條不影響後面無 -s 的' 2 'adb -s emulator-5554 emu kill && adb emu kill'
expect 'K2f timeout wrapper' 2 'timeout 5 adb emu kill'
expect 'K2g xargs wrapper' 2 'echo x | xargs adb emu kill'
expect 'K2h -s 的值是以 - 開頭的旗標（缺值）不算 -s' 2 'adb -s -P 5038 emu kill'
expect 'K2i -P port 選項不吞掉子命令判斷' 2 'adb -P 5038 emu kill'
expect 'K2j 換行分隔的第二條' 2 $'adb devices\nadb emu kill'

# ---- K3 avdmanager delete avd（本票號取自 cwd 的 LS-477）----
expect 'K3a 別票 AVD → deny' 2 'avdmanager delete avd -n LS-999-Pixel8'
expect 'K3b main-Pixel8 → deny' 2 'avdmanager delete avd -n main-Pixel8'
expect 'K3c 絕對路徑 avdmanager＋別票' 2 '$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager delete avd -n LS-12-Pixel8'
expect 'K3d --name 長旗標＋別票' 2 'avdmanager delete avd --name LS-1-Pixel8'
expect 'K3e 沒有 -n' 2 'avdmanager delete avd'
expect 'K3f 鄰近票號 LS-4770（本票 LS-477）→ deny（前綴比對含尾端連字號）' 2 'avdmanager delete avd -n LS-4770-Pixel8'
expect 'K3g 名稱含變數展開無法判斷 → deny' 2 'avdmanager delete avd -n "LS-$N-Pixel8"'
expect_at "$gate" 'K3h 不在票 worktree（主 checkout cwd）→ 連本票樣式也 deny' 2 'avdmanager delete avd -n LS-477-Pixel8' "$CWD_MAIN"

# ---- 放行 ----
expect 'A1 adb -s <serial> emu kill → allow' 0 'adb -s emulator-5554 emu kill'
expect 'A2 -s 值是變數 → allow' 0 'adb -s "$SERIAL" emu kill'
expect 'A3 -s 在其他全域選項之後 → allow' 0 'adb -P 5038 -s emulator-5556 emu kill'
expect 'A4 唯讀 adb devices／shell／start-server → allow' 0 'adb devices && adb -s emulator-5554 shell getprop sys.boot_completed && adb start-server'
expect 'A5 avdmanager 刪本票 AVD → allow' 0 'avdmanager delete avd -n LS-477-Pixel8'
expect 'A6 avdmanager --name=本票 → allow' 0 'avdmanager delete avd --name=LS-477-Pixel8'
expect 'A7 avdmanager create／list 不是 delete → allow' 0 'avdmanager create avd -n LS-999-Pixel8 -k x && avdmanager list avd'
expect 'A8 兩條都帶 -s → allow' 0 'adb -s emulator-5554 emu kill && adb -s emulator-5556 emu kill'
expect 'A9 echo 的引數不是命令位置 → allow' 0 'echo adb kill-server'
expect 'A10 引號內整段字樣 → allow' 0 'echo "adb emu kill"; echo '"'"'adb kill-server'"'"
expect 'A11 commit message 提到 → allow' 0 'git commit -m "fix: 文件說明 adb kill-server 與 adb emu kill 的風險"'
expect 'A12 本專案的 detect-emulator --stop → allow' 0 'bash scripts/gates/detect-emulator.sh --stop'
expect 'A13 不相干指令 → allow' 0 'ls -la && git status'
expect 'A14 非 shell heredoc（cat 寫 handoff）內文提到 → allow' 0 $'cat > h.md <<\'EOF\'\n用 adb kill-server 會砍共用 server\nadb emu kill 無 -s 也不行\nEOF\necho done'
expect 'A15 heredoc 之後的真實指令仍會被掃 → deny' 2 $'cat > h.md <<\'EOF\'\nfoo\nEOF\nadb kill-server'
expect 'A16 bash heredoc 內文會被當 shell 執行 → deny' 2 $'bash <<\'EOF\'\nadb kill-server\nEOF'
expect 'A17 找不到終止符 → 整段照掃（fail closed 於照掃方向）→ deny' 2 $'cat <<\'EOF\'\nadb kill-server\n'
expect 'A18 引號未閉合（shlex 失敗）→ 退回空白切詞仍判 K1' 2 "echo 'oops; adb kill-server"
expect 'A19 空 command／無 command 欄位 → allow' 0 ''

# ---- fail-open ----
out=$(printf '' | bash "$gate" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'fail-open'; then ok "F1 stdin 空 → fail-open 放行並註明"; else fail "F1 stdin 空應 exit 0＋fail-open 註記（exit ${rc}：${out}）"; fi
out=$(printf '{not json' | bash "$gate" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'fail-open'; then ok "F2 JSON 壞 → fail-open 放行並註明"; else fail "F2 JSON 壞應 exit 0＋fail-open 註記（exit ${rc}：${out}）"; fi
out=$(printf '{"tool_input":{"command":"adb kill-server"}}' | env PATH="$work/empty-path" "$(command -v bash)" "$gate" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'python3 不存在'; then ok "F3 python3 缺席 → fail-open 放行並註明"; else fail "F3 python3 缺席應 exit 0＋註記（exit ${rc}：${out}）"; fi
out=$(printf '{"tool_input":{"file_path":"x"}}' | bash "$gate" 2>&1); rc=$?
expect_exit 0 "$rc" "F4 非 Bash 工具（無 command）→ allow"
# 沒有 cwd 欄位：退回引擎行程的 cwd（此處是 repo 根，不是票 worktree）→ K3 一律 deny，K1／K2 照常
out=$(printf '{"tool_input":{"command":"avdmanager delete avd -n LS-477-Pixel8"}}' | bash "$gate" 2>&1); rc=$?
case "$PWD$root" in *'/.claude/worktrees/LS-'*) ;; *) expect_exit 2 "$rc" "F5 JSON 無 cwd 欄位且行程不在票 worktree → K3 deny（推不出本票號）" ;; esac

# ---- settings.json 接線：matcher=Bash、不接 || exit 2（fail-open 極性，與 fork-guard 同型）、既有 hook 一個不少 ----
settings="${root}/.claude/settings.json"
py_wiring() {
  python3 - "$settings" "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
mode = sys.argv[2]
entries = s["hooks"]["PreToolUse"]
if mode == "emu":
    hits = [e for e in entries for h in e["hooks"] if "emu-all-guard.sh" in h["command"]]
    assert len(hits) == 1, "emu-all-guard 應恰好掛一次，實得 %d" % len(hits)
    e = hits[0]
    assert e["matcher"] == "Bash", "matcher 應為 Bash，實得 %r" % e["matcher"]
    cmd = e["hooks"][0]["command"]
    assert "|| exit 2" not in cmd, "fail-open 極性不得接 || exit 2：%s" % cmd
    assert '"$CLAUDE_PROJECT_DIR/scripts/gates/emu-all-guard.sh"' in cmd, cmd
elif mode == "others":
    need = ["pretool.sh", "main-checkout-guard.sh", "background-bash-guard.sh", "prod-push-guard.sh",
            "large-file-read-guard.sh", "fork-guard.sh", "linear-issue-check.sh"]
    cmds = " ".join(h["command"] for e in entries for h in e["hooks"])
    missing = [n for n in need if n not in cmds]
    assert not missing, "既有 hook 條目缺：%s" % missing
PY
}
if py_wiring emu 2>"$work/w1.err"; then ok "W1 settings.json：emu-all-guard 掛一次、matcher=Bash、未接 || exit 2（fail-open 極性）"; else fail "W1 接線不符：$(cat "$work/w1.err")"; fi
if py_wiring others 2>"$work/w2.err"; then ok "W2 settings.json：既有七個 PreToolUse hook 條目都還在（只加不刪）"; else fail "W2 $(cat "$work/w2.err")"; fi

# ---- mutation 負控 ----
mutate() {  # mutate <錨點> <替換> <輸出檔>
  python3 - "$gate" "$1" "$2" "$3" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
assert sys.argv[2] in s, "mutation 錨點不在 emu-all-guard.sh：%s" % sys.argv[2]
open(sys.argv[4], "w", encoding="utf-8").write(s.replace(sys.argv[2], sys.argv[3], 1))
PY
}
mut_expect_allow() {  # <label> <mutant 檔> <原本 deny 的命令> [cwd]
  local out got
  out=$(payload "$3" "${4:-$CWD_T}" | bash "$2" 2>&1); got=$?
  if [ "$got" -eq 0 ]; then ok "$1"; else fail "$1（mutant 應改判 allow，實得 exit ${got}：${out}）"; fi
}
mutate 'if sub[:1] == ["kill-server"]:' 'if False:' "$work/mut-k1.sh" && mut_expect_allow "M1 mutant：拿掉 K1（kill-server 判斷）後 K1a 樣本改判 allow" "$work/mut-k1.sh" 'adb kill-server'
mutate 'if sub[:2] == ["emu", "kill"] and not serial_ok:' 'if sub[:2] == ["emu", "kill"] and False:' "$work/mut-k2.sh" && mut_expect_allow "M2 mutant：拿掉 K2 的「無 -s」判斷後 K2a 樣本改判 allow" "$work/mut-k2.sh" 'adb emu kill'
mutate 'return None if name.startswith("%s-" % ticket) else "K3"' 'return None' "$work/mut-k3.sh" && mut_expect_allow "M3 mutant：拿掉 K3 的本票前綴比對後 K3a 樣本改判 allow" "$work/mut-k3.sh" 'avdmanager delete avd -n LS-999-Pixel8'
mutate 'if base in ("adb", "avdmanager") and at_command_position(t, i):' 'if False:' "$work/mut-pos.sh" && mut_expect_allow "M4 mutant：整個命令位置掃描拿掉後 K1／K2 樣本都改判 allow（證明掃描主體在這支）" "$work/mut-pos.sh" 'adb emu kill'

if [ "$fail" -eq 0 ] && [ "${selftest_helpers_fail:-0}" -eq 0 ]; then echo "✓ emu-all-guard 自測通過"; exit 0; fi
exit 1
