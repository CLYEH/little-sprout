#!/bin/bash
# pretool.sh 自測（LS-88）。CI rules job 每個 PR 都跑。「前饋必有反饋」對 gate 本身也適用：
# H1–H3 若退化（字面比對變寬鬆、fail-closed 漏接）這裡會紅。
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
# fail-closed：JSON 壞掉／stdin 空／解析工具皆缺
# ============================================================
expect 'fail-closed：空 stdin（deny）' 2 ''
expect 'fail-closed：JSON 語法壞掉（deny）' 2 '{"tool_name":"Bash",'
expect 'fail-closed：JSON 頂層不是物件（deny）' 2 '[1,2,3]'

# jq／python3 皆缺（PATH 清空）——bash 內建解析全炸，最終仍要 deny。用絕對路徑呼叫 bash
# 本身（env 底下的 PATH 已清空，裸 "bash" 找不到自己）。
bash_bin=$(command -v bash || echo /bin/bash)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/empty" "$work/py-only"
ln -sf /usr/bin/grep "$work/py-only/grep" 2>/dev/null || true
real_python3=$(bash -c 'type -P python3' 2>/dev/null || true)
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/py-only/python3"

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/empty" "$bash_bin" "$pretool" 2>&1)
got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ fail-closed：jq／python3 皆缺（PATH 清空，deny）'
else
  echo "✗ fail-closed：jq／python3 皆缺（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
  fail=1
fi

# jq 缺、python3 在（備援成功）：H1 規則仍要正確判斷——證明備援路徑真的有解析出 tool_input，
# 不是「反正都 deny」矇對。本機／CI 找不到 python3 才略過（極端環境）。
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
else
  echo '⚠ 略過 jq-缺-python3-備援 測試（本機找不到 python3）'
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ pretool.sh 自測通過"
fi
exit "$fail"
