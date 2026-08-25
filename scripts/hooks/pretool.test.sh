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
expect 'H3⑤ 重入：SUPABASE_LOCK_HELD 已設（allow）' 0 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_HELD=/tmp/fake-lock
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

rm -rf "$work"
trap - EXIT

if [ "$fail" -eq 0 ]; then
  echo "✓ pretool.sh 自測通過"
fi
exit "$fail"
