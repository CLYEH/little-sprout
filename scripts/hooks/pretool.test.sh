#!/bin/bash
# pretool.sh 自測（LS-88；R2 補 merge-reviewer R1 blocker/major/informational——
# https://github.com/CLYEH/little-sprout/pull/157#issuecomment-5413222970）。CI rules job
# 每個 PR 都跑。「前饋必有反饋」對 gate 本身也適用：H1–H3 若退化（字面比對變寬鬆、fail-closed
# 漏接）這裡會紅。R1 抓到的洞（多行 command 只看第一行、grep 異常當沒命中放行、.env／run.sh
# 邊界要求空白或行尾、放行形式整條字串比對）都各自補了對應的正負樣本，避免同一個洞回來。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pretool="${root}/scripts/hooks/pretool.sh"
fail=0

# ---- bash 3.2：不用陣列／${var,,}，${name} 展開＋case ----
bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
read_json() { printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1"; }

# expect <label> <want_exit> <payload> [env VAR=val ...]：allow（want=0）驗無輸出；
# deny（want!=0，本檔案只用 2）驗輸出含 deny JSON。額外參數交給 `env` 覆寫子行程環境
# （PATH／SUPABASE_LOCK_HELD 等），不影響本測試腳本自己的環境。
expect() {
  local label=$1 want=$2 payload=$3 out got
  shift 3
  out=$(printf '%s' "$payload" | env "$@" bash "$pretool" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ ${label}（期望 exit ${want}，實得 ${got}；輸出：${out}）" >&2
    fail=1
    return
  fi
  if [ "$want" -eq 0 ]; then
    if [ -n "$out" ]; then
      echo "✗ ${label}（allow 應無輸出，實得：${out}）" >&2
      fail=1
      return
    fi
  else
    case "$out" in
      *'"permissionDecision":"deny"'*) ;;
      *) echo "✗ ${label}（exit=${want} 但輸出缺 deny JSON：${out}）" >&2; fail=1; return ;;
    esac
  fi
  echo "✓ ${label}"
}

# ============================================================
# H1：--no-verify／force push 到 development／test／main
# ============================================================
expect 'H1① --no-verify（deny）' 2 "$(bash_json 'git push --no-verify')"
expect 'H1② force push 明寫 main（deny）' 2 "$(bash_json 'git push --force origin main')"
expect 'H1③ -f ＋ development refspec（deny）' 2 "$(bash_json 'git push -f origin development:development')"
expect 'H1④ 一般 push（allow）' 0 "$(bash_json 'git push origin feature/LS-88-pretool-hooks')"
expect 'H1⑤ force push 到非保護分支（allow，看目標而非只看旗標）' 0 "$(bash_json 'git push --force origin feature/LS-88-scratch')"
expect 'H1⑥ 無關命令（allow）' 0 "$(bash_json "git commit -m 'fix: something'")"

# ============================================================
# H2：讀 .env value（Bash 與 Read 兩種 matcher）
# ============================================================
expect 'H2① cat .env（deny）' 2 "$(bash_json 'cat .env')"
expect 'H2② grep 抓值 .env（deny）' 2 "$(bash_json 'grep SECRET_KEY .env')"
expect 'H2③ sed -n .env（deny）' 2 "$(bash_json "sed -n '1,5p' .env")"
expect 'H2④ 放行：grep -oE key-only（allow）' 0 "$(bash_json "grep -oE '^[A-Z_]+=' .env")"
expect 'H2⑤ 放行：source .env（allow，注入不印出）' 0 "$(bash_json 'source .env')"
expect 'H2⑥ 放行：set -a; . .env（allow）' 0 "$(bash_json 'set -a; . .env; set +a')"
expect 'H2⑦ 放行：cut -d= -f1（allow，只取 key 欄）' 0 "$(bash_json 'cut -d= -f1 .env')"
expect 'H2⑧ cut -d= -f2 抓值（deny，非 key-only）' 2 "$(bash_json 'cut -d= -f2 .env')"
expect 'H2⑨ Read 直讀 .env（deny）' 2 "$(read_json '.env')"
expect 'H2⑩ Read 直讀 .env.production（deny）' 2 "$(read_json '.env.production')"
expect 'H2⑪ Read 讀無關檔（allow）' 0 "$(read_json 'README.md')"
expect 'H2⑫ Bash 對無關檔操作（allow，不含 .env）' 0 "$(bash_json 'cat environment.json')"

# ============================================================
# H3：supabase db reset／run.sh 必經 supabase-lock.sh --
# ============================================================
expect 'H3① 裸跑 supabase db reset（deny）' 2 "$(bash_json 'supabase db reset')"
expect 'H3② 裸跑 run.sh（deny）' 2 "$(bash_json 'bash supabase/tests/run.sh')"
expect 'H3③ 包在 supabase-lock.sh --（allow）' 0 "$(bash_json 'bash scripts/ops/supabase-lock.sh -- supabase db reset')"
expect 'H3④ 帶 --timeout 仍算包裹（allow）' 0 "$(bash_json 'bash scripts/ops/supabase-lock.sh --timeout 30 -- supabase db reset')"
# R1 informational I2：重入判定原本讀 SUPABASE_LOCK_HELD（hook 是獨立行程、不繼承那個環境
# 變數，這條分支實務上永遠不會為真——見 pretool.sh h3_reentrant() 的檔頭說明），改用
# supabase-lock.sh 真正的祖先判定：讀 SUPABASE_LOCK_DIR/holder 的 `pid=` 行，往上走本行程
# 祖先鏈。用假的 lock 目錄測，不碰真正的 /tmp/supabase-lock-<project_id>。
i2_lockdir=$(mktemp -d)
printf 'pid=%s\n' "$$" > "$i2_lockdir/holder"
expect 'H3⑤a 重入：holder pid 是本程序的祖先（allow）' 0 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_DIR="$i2_lockdir"
printf 'pid=1\n' > "$i2_lockdir/holder"
expect 'H3⑤b 重入：holder pid 不是祖先（deny，同 supabase-lock.sh is_ancestor 對 pid 1／0 一律視為到頂放棄）' 2 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_DIR="$i2_lockdir"
rm -rf "$i2_lockdir"
expect 'H3⑤c 舊機制 SUPABASE_LOCK_HELD 不再有效（deny，證明真的換掉了、不是兩條路徑並存）' 2 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_HELD=/tmp/fake-lock
expect 'H3⑥ 無關命令（allow）' 0 "$(bash_json 'ls supabase/migrations')"

# ============================================================
# 非 Bash／Read 工具：不受任何規則管
# ============================================================
expect '非 Bash／Read（Write，allow）' 0 '{"tool_name":"Write","tool_input":{"file_path":"foo.txt"}}'

# ============================================================
# R1 F1（blocker）：多行 command 只評估第一行——H1/H2/H3 各補一組「違規在第二行」
# ============================================================
# 注意：JSON 字串裡的換行必須是 `\n`（反斜線加 n 兩個字元，讓 jq／python3 解成真正的換行），
# 不能是原始換行位元組——原始換行在嚴格 JSON 裡是未跳脫的控制字元，jq／python3 兩邊都會直接
# parse error（試過：兩邊都拒絕），那樣測到的只是「JSON 壞掉」的 fail-closed 分支，不是 F1 真正
# 要驗的「多行 command 有沒有被完整讀進來」。
expect 'F1-H1 多行：違規在第二行（deny）' 2 "$(bash_json 'git add -A\ngit commit --no-verify -m x')"
expect 'F1-H1b 多行：force push 在第二行（deny）' 2 "$(bash_json 'echo prep\ngit push --force origin main')"
expect 'F1-H2 多行：cat .env 在第二行（deny，R1 實測案例）' 2 "$(bash_json 'cd /tmp\ncat .env')"
expect 'F1-H3 多行：db reset 在第二行（deny）' 2 "$(bash_json 'echo start\nsupabase db reset')"
expect 'F1 多行：違規在第一行、第二行無關（deny，回歸）' 2 "$(bash_json 'cat .env\necho done')"

# ============================================================
# R1 F2（blocker）：grep 異常（非 0/1）須 fail-closed，不當「沒命中」放行
# ============================================================
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bash_bin=$(bash -c 'type -P bash' 2>/dev/null || echo /bin/bash)
real_jq=$(bash -c 'type -P jq' 2>/dev/null || true)
real_python3=$(bash -c 'type -P python3' 2>/dev/null || true)
real_grep=$(bash -c 'type -P grep' 2>/dev/null || echo /usr/bin/grep)

mkdir -p "$work/empty" "$work/nogrep" "$work/badgrep"
[ -n "$real_jq" ] && ln -sf "$real_jq" "$work/nogrep/jq"
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/nogrep/python3"
[ -n "$real_jq" ] && ln -sf "$real_jq" "$work/badgrep/jq"
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/badgrep/python3"
cat > "$work/badgrep/grep" <<'STUB'
#!/bin/bash
exit 2
STUB
chmod +x "$work/badgrep/grep"

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/nogrep" "$bash_bin" "$pretool" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：PATH 缺 grep（deny）'
else
  echo "✗ F2：PATH 缺 grep 應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

out=$(printf '%s' "$(bash_json 'cat .env')" | env PATH="$work/badgrep" "$bash_bin" "$pretool" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：grep 執行異常（regex 弄壞的等價情境，rc=2 一律 deny）'
else
  echo "✗ F2：grep 異常應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

# ============================================================
# R1 F3（blocker）：.env／run.sh 邊界要求後接空白或行尾，漏放引號／分號／重導向／命令替換
# ============================================================
expect 'F3① cat .env;（deny）' 2 "$(bash_json 'cat .env; echo hi')"
expect 'F3② cat .env;ls 無空白（deny）' 2 "$(bash_json 'cat .env;ls')"
expect 'F3③ 單引號包住 .env（deny）' 2 "$(bash_json "cat '.env'")"
expect 'F3④ 雙引號包住 .env（deny）' 2 "$(bash_json 'cat ".env"')"
expect 'F3⑤ 命令替換 $(cat .env)（deny）' 2 "$(bash_json 'echo $(cat .env)')"
expect 'F3⑥ < 重導向讀 .env（deny，無需具名動詞）' 2 "$(bash_json 'while read l; do echo $l; done < .env')"
expect 'F3⑦ H3：run.sh 帶結尾分號（deny）' 2 "$(bash_json 'bash supabase/tests/run.sh;')"
expect 'F3⑧ 回歸：路徑前綴 config/.env 仍判定（deny）' 2 "$(bash_json 'cat config/.env')"
expect 'F3⑨ 回歸：不相關檔名 myapp.environment 不誤判（allow）' 0 "$(bash_json 'cat myapp.environment')"

# ============================================================
# 空 stdin／JSON 壞掉／解析工具皆缺
# ============================================================
expect 'fail-closed：空 stdin（deny）' 2 ''
expect 'fail-closed：JSON 語法壞掉（deny）' 2 '{"tool_name":"Bash",'
expect 'fail-closed：JSON 頂層不是物件（deny）' 2 '[1,2,3]'

mkdir -p "$work/py-only"
[ -n "$real_grep" ] && ln -sf "$real_grep" "$work/py-only/grep"
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/py-only/python3"

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/empty" "$bash_bin" "$pretool" 2>&1)
got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ fail-closed：jq／python3 皆缺（PATH 清空，deny）'
else
  echo "✗ fail-closed：jq／python3 皆缺（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
  fail=1
fi

if [ -n "$real_python3" ]; then
  out=$(printf '%s' "$(bash_json 'git push --no-verify')" | env PATH="$work/py-only" "$bash_bin" "$pretool" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（H1 判定仍正確，deny）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/py-only" "$bash_bin" "$pretool" 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（無關命令仍 allow）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（無關命令期望 exit 0 allow，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(bash_json 'cd /tmp\ncat .env')" | env PATH="$work/py-only" "$bash_bin" "$pretool" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（多行 command 仍能正確判定 H2，見 F1）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（多行 command 期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
else
  echo '⚠ 略過 jq-缺-python3-備援 測試（本機找不到 python3）'
fi

# ============================================================
# R1 F4（major）：放行形式原本是整條字串比對，鏈式命令裡一段放行形式會讓另一段的真違規免疫
# ============================================================
expect 'F4① grep key-only 段 ; 真違規段（deny，原本被免疫）' 2 "$(bash_json "grep -oE '^[A-Z_]+=' .env; cat .env")"
expect 'F4② cut key-only 段 && 真違規段（deny）' 2 "$(bash_json 'cut -d= -f1 .env && cat .env')"
expect 'F4③ source .env; cat .env（deny——source 從不在放行判定裡，cat 才是觸發點；§7／PR body 曾記成「這是已知盲區」是文件記錯洞，已修正）' 2 "$(bash_json 'source .env; cat .env')"
expect 'F4④ 全段皆放行形式、無真違規（allow）' 0 "$(bash_json "grep -oE '^[A-Z_]+=' .env; echo done")"

# ============================================================
# R2 F1（merge-reviewer R2 blocker，F4 切段引入的回歸）：切段不看引號，分隔字元其實在引號內時
# 會把「動詞在這段、.env 在另一段」，兩段各自都不成立、整條被誤放行。修法：整條命令同時符合
# .env 引用與讀取動詞，但沒有任何一段同時符合兩者——歧義即 deny。
# ============================================================
expect 'R2F1① grep -E 雙引號內含 |（deny，回歸）' 2 "$(bash_json 'grep -E \"^(SUPABASE|ANON)=\" .env')"
expect 'R2F1② grep -E 單引號內含 |（deny，回歸）' 2 "$(bash_json "grep -E 'SECRET|TOKEN' .env")"
expect 'R2F1③ awk 欄位分隔字元在引號內（deny，回歸）' 2 "$(bash_json "awk -F'|' '{print \$2}' .env")"
expect 'R2F1④ sed -e 腳本內含 ;（deny，回歸）' 2 "$(bash_json "sed -e 's/a/b/;s/c/d/' .env")"
expect 'R2F1⑤ grep 樣式內含 ;（deny，回歸）' 2 "$(bash_json "grep 'a;b' .env")"
expect 'R2F1⑥ 放行形式＋真正的管線到 sort（allow，不受影響——放行段本身就同時命中兩者）' 0 "$(bash_json "grep -oE '^[A-Z_]+=' .env | sort")"
expect 'R2F1⑦ 無關命令不受影響（allow）' 0 "$(bash_json 'grep -E \"a|b\" notes.txt')"

# ============================================================
# R1 F6（major）：git commit -n（--no-verify 官方短旗標）；git push -n 是 --dry-run 不算
# ============================================================
expect 'F6① git commit -n（deny）' 2 "$(bash_json 'git commit -n -m x')"
expect 'F6② git commit --no-verify -n 同時出現（deny，H1a 先命中也行）' 2 "$(bash_json 'git commit --no-verify -n -m x')"
expect 'F6③ git push -n（allow，--dry-run 語意不同）' 0 "$(bash_json 'git push -n origin main')"
expect 'F6④ git commit 一般用法（allow）' 0 "$(bash_json "git commit -m 'x'")"

# ============================================================
# R1 F7（major）：內建 Grep 工具的 path／glob 指向 .env，原本 matcher 沒蓋到
# ============================================================
expect 'F7① Grep path=.env（deny）' 2 '{"tool_name":"Grep","tool_input":{"pattern":".","path":".env","output_mode":"content"}}'
expect 'F7② Grep glob=.env*（deny）' 2 '{"tool_name":"Grep","tool_input":{"pattern":"SECRET","glob":".env*"}}'
expect 'F7③ Grep path 為目錄（allow）' 0 '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"scripts"}}'
expect 'F7④ Grep 一般用法（allow）' 0 '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"scripts","glob":"*.sh"}}'

# ============================================================
# R1 I1（informational，便宜順修）：H2 讀取動詞白名單擴充 bat／xxd／base64／strings／rg／wc
# ============================================================
expect 'I1① bat .env（deny）' 2 "$(bash_json 'bat .env')"
expect 'I1② xxd .env（deny）' 2 "$(bash_json 'xxd .env')"
expect 'I1③ base64 .env（deny）' 2 "$(bash_json 'base64 .env')"
expect 'I1④ strings .env（deny）' 2 "$(bash_json 'strings .env')"
expect 'I1⑤ rg SECRET .env（deny）' 2 "$(bash_json 'rg SECRET .env')"
expect 'I1⑥ wc -l .env（deny）' 2 "$(bash_json 'wc -l .env')"

# ============================================================
# R1 I6（informational，便宜順修）：settings.json 的 PreToolUse 真的接著 pretool.sh、matcher
# 含 Grep、且用 `|| exit 2` 把 wiring 層的 fail-open 關起來（I4）——把 PreToolUse 區塊刪掉／
# matcher 漏列 Grep／忘了 `|| exit 2` 之前 CI 全綠，這裡補上直接讀 settings.json 斷言。
# ============================================================
settings_json="${root}/.claude/settings.json"
i6_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read|Grep") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null)
if [ -n "$i6_cmd" ]; then
  echo '✓ I6①：settings.json 的 PreToolUse matcher 含 Bash|Read|Grep 且接著 command'
else
  echo "✗ I6①：settings.json 找不到 matcher=Bash|Read|Grep 的 PreToolUse command" >&2
  fail=1
fi
case "$i6_cmd" in
  *pretool.sh*) echo '✓ I6②：command 確實呼叫 pretool.sh' ;;
  *) echo "✗ I6②：command 沒有呼叫 pretool.sh（實得：${i6_cmd}）" >&2; fail=1 ;;
esac
case "$i6_cmd" in
  *'|| exit 2'*) echo '✓ I6③：command 帶 || exit 2（I4，腳本缺席／執行失敗時 wiring 層仍 fail-closed）' ;;
  *) echo "✗ I6③：command 沒有 || exit 2（實得：${i6_cmd}）" >&2; fail=1 ;;
esac

# ============================================================
# R1 F5（major）：自測完全沒有覆蓋 trap——把 trap 那行拿掉重跑，31 組原本全綠（票文驗收「腳本
# 被弄壞時仍 deny」不成立）。做兩份暫存副本：都在 `input=` 之後插入 `exit 1`（模擬腳本中途一個
# 沒被任何 if／&&／|| 包住、未捕捉的失敗），一份保留 trap、一份把 trap 那行拿掉——若移除 trap
# 這件事不會改變行為，代表這組測試沒測到 trap 的作用（假綠）；本測試斷言兩者行為確實不同。
# ============================================================
mut_dir=$(mktemp -d)
build_mutant() {   # $1=輸出路徑 $2=yes/no（是否保留 trap）
  awk -v keep="$2" '
    $0 == "trap on_exit EXIT" && keep != "yes" { next }
    { print }
    $0 == "input=" { print "exit 1  # LS-88 R2 mutation-test：模擬腳本中途未捕捉錯誤" }
  ' "$pretool" > "$1"
}
build_mutant "$mut_dir/with_trap.sh" yes
build_mutant "$mut_dir/no_trap.sh" no

out=$(printf '%s' "$(bash_json 'echo hi')" | bash "$mut_dir/with_trap.sh" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F5：trap on_exit EXIT 在——腳本中途未捕捉錯誤（注入 exit 1）仍 deny（exit 2）'
else
  echo "✗ F5：trap 在時應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

out=$(printf '%s' "$(bash_json 'echo hi')" | bash "$mut_dir/no_trap.sh" 2>&1); got=$?
if [ "$got" -ne 2 ] || ! case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F5：拿掉 trap 後同樣的中途錯誤不再變成 deny（證明 trap 是關鍵、不是巧合過關）'
else
  echo "✗ F5：拿掉 trap 後行為竟然沒變——這組測試沒測到 trap 的效果（實得 exit ${got}：${out}）" >&2
  fail=1
fi
rm -rf "$mut_dir"

rm -rf "$work"
trap - EXIT

if [ "$fail" -eq 0 ]; then
  echo "✓ pretool.sh 自測通過"
fi
exit "$fail"
