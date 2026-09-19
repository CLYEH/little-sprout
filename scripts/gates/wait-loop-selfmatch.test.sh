#!/bin/bash
# LS-346 範圍 3：驗證 ios-dev.md 記載的「背景 push gate 等待迴圈」（`.claude/agents/ios-dev.md` 的
# 「背景 push gate 等待迴圈限 worktree 範圍」段落）不會自我比對而卡住。
#
# 背景：LS-344 agent 回報，迴圈用 `pgrep -f 'worktrees/LS-<n>/'` 找自己 worktree 下的 xcodebuild／
# push-gate 行程——迴圈本身（外層 bash 行程）的命令列字面本來就含這個 pattern（那是迴圈自己拿來當
# pgrep 引數的字面），而 GNU／Linux 的 `pgrep` 預設**只排除呼叫者自己，不排除祖先行程**（`man pgrep`
# 的 `-a` 選項說明：「By default, the current pgrep or pkill process and all of its ancestors are
# excluded」——這句只在 BSD／macOS 的 man page 出現；本票在 `ubuntu:24.04` 容器內實測
# `pgrep -fl 'worktrees/LS-999/'` 對含這個字面的外層 bash 行程確實列出「自己」，見 handoff）。外層
# 行程的完整命令列同時含 `xcodebuild`／`push-gate`（迴圈自己拿來 grep 的字面），於是舊寫法會把自己
# 判定成「push-gate 還在跑」、永遠不退出。**在 macOS（BSD pgrep 預設排除祖先）不會重現**——這是既有
# BSD/GNU 分野的同型案例（`docs/COLLABORATION.md` §7、`scripts/gates/pipefail-grep-q-check.sh`），本檔
# ③ 的 mutation 段只在 Linux（`$(uname) = Linux`）才真正驗證得到；macOS 上新舊寫法都會通過（誠實聲明，
# 不假裝驗過，CI `rules` job 跑在 `ubuntu-latest`，是唯一實際覆蓋這條回歸的通道）。
#
# 修法（已落地於 ios-dev.md）：`pgrep` 結果先用 `grep -v -x "$_self"` 排除迴圈自己的 PID，再交給
# `ps`／`grep` 判定，不論平台差異都正確；**不改用 `[w]orktrees` 這類 bracket 自我迴避寫法**——那是
# LS-330 i7 已裁定淘汰的手法，H4（`scripts/hooks/pretool_engine.py`）專門盯防 `[x]codebuild`／
# `[p]ush-gate` 這類 bracket 規避字面比對的形狀，用了會被 `pretool.sh`（H4）擋下。
#
# 驗的三件事：① ios-dev.md 記載的迴圈含 `$_self` 排除、且未用已淘汰的 bracket 寫法；② 新迴圈在無
# 真正 push-gate 行程時 1 輪內（遠小於逾時上限）判定「真的跑完了」；③（Linux 限定）拿掉 `$_self`
# 排除的舊寫法在同樣情境下會卡住直到自己設的逾時上限——證明 ② 的判定是這段排除造成的，不是巧合。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

# shellcheck source=lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"

doc="${root}/.claude/agents/ios-dev.md"
[ -f "$doc" ] || { echo "✗ 找不到 ${doc}" >&2; exit 2; }
doc_text="$(cat "$doc")"

# ---- ① 文件與修法同步 ----
if has "$doc_text" 'grep -v -x "$_self"'; then
  echo "✓ ① ios-dev.md 記載的等待迴圈含 \$_self 排除（自我比對修法落地）"
else
  echo "✗ ① ios-dev.md 找不到 \$_self 排除寫法——文件與修法不同步" >&2
  fail=1
fi
# 只取「等待迴圈那條命令自己」的文字窗口（`_self=$$; _ws=$SECONDS` 到那句的「真的跑完了」）判斷有沒有
# 用 bracket 寫法——不能對整份文件做無範圍的字面掃描：同一段稍後還有一句正常說明 H4 會擋
# `pgrep -f '[x]codebuild'`／`pgrep -f '[p]ush-gate'` 這類全域寫法（那是在描述「這樣寫會被擋」，不是
# 建議這樣寫），整份文件掃描會把這句正確的說明文字誤判成「還在用 bracket 寫法」。
snippet="$(python3 - "$doc" <<'PY'
import sys
doc = open(sys.argv[1], encoding="utf-8").read()
try:
    start = doc.index("_self=$$; _ws=$SECONDS")
    end = doc.index("真的跑完了", start) + len("真的跑完了")
    print(doc[start:end])
except ValueError:
    pass
PY
)"
if [ -z "$snippet" ]; then
  echo '✗ ① 在 ios-dev.md 找不到等待迴圈命令片段（_self=$$; _ws=$SECONDS … 真的跑完了）——無法檢查是否用了 bracket 寫法' >&2
  fail=1
elif has "$snippet" '[x]codebuild' || has "$snippet" '[p]ush-gate'; then
  echo "✗ ① 等待迴圈命令本身仍出現 [x]codebuild／[p]ush-gate bracket 自我迴避寫法——LS-330 i7 已裁定淘汰、會被 H4 擋" >&2
  fail=1
else
  echo "✓ ① 等待迴圈命令本身未使用已淘汰的 [x]codebuild／[p]ush-gate bracket 自我迴避寫法"
fi

# ---- ②③：無真正 push-gate 行程時的行為（縮短逾時到 3 秒，不跑滿文件裡的 570s）----
pattern="worktrees/LS-346-selftest-$$/"

run_loop() {   # $1 = 1（新寫法，排除 $_self）｜0（舊寫法，LS-344 回報的樣子）
  local exclude=$1
  if [ "$exclude" -eq 1 ]; then
    bash -c "
      _self=\$\$
      _ws=\$SECONDS
      while [ \$((SECONDS - _ws)) -lt 3 ] && pgrep -f '${pattern}' | grep -v -x \"\$_self\" | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -q 'xcodebuild\\|push-gate'; do
        sleep 1
      done
      pgrep -f '${pattern}' | grep -v -x \"\$_self\" | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -q 'xcodebuild\\|push-gate' && echo STILL || echo DONE
    "
  else
    bash -c "
      _ws=\$SECONDS
      while [ \$((SECONDS - _ws)) -lt 3 ] && pgrep -f '${pattern}' | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -q 'xcodebuild\\|push-gate'; do
        sleep 1
      done
      pgrep -f '${pattern}' | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -q 'xcodebuild\\|push-gate' && echo STILL || echo DONE
    "
  fi
}

t0=$SECONDS
new_result=$(run_loop 1)
t1=$SECONDS
new_elapsed=$((t1 - t0))
if [ "$new_result" = "DONE" ]; then
  echo "✓ ② 新迴圈（排除 \$_self）在無 push-gate 行程時判定「真的跑完了」（耗時 ${new_elapsed}s，遠小於 3 秒逾時）"
else
  echo "✗ ② 新迴圈未如預期判定 DONE（實得 ${new_result}，耗時 ${new_elapsed}s）" >&2
  fail=1
fi

if [ "$(uname)" = "Linux" ]; then
  t0=$SECONDS
  old_result=$(run_loop 0)
  t1=$SECONDS
  old_elapsed=$((t1 - t0))
  if [ "$old_result" = "STILL" ] && [ "$old_elapsed" -ge 3 ]; then
    echo "✓ ③ mutant（拿掉 \$_self 排除，即 LS-344 回報的舊寫法）：Linux 上真的自我比對、卡到自己設的 3 秒逾時才截斷（耗時 ${old_elapsed}s）——證明 ② 的『判定 DONE』是 \$_self 排除造成的，不是巧合"
  else
    echo "✗ ③ mutant 未如預期翻轉（實得 ${old_result}，耗時 ${old_elapsed}s）——Linux 上應自我比對而卡住" >&2
    fail=1
  fi
else
  echo "→ ③（未驗證）：本機非 Linux（$(uname)），BSD/macOS pgrep 預設排除祖先行程，重現不了 LS-344 回報的自我比對——只有 CI 的 ubuntu-latest（rules job）能實際覆蓋這條回歸，見本檔檔頭說明"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ wait-loop-selfmatch 自測通過"
fi
exit "$fail"
