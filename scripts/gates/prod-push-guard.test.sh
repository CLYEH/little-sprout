#!/bin/bash
# scripts/gates/prod-push-guard.test.sh（LS-78）
#
# 自測 scripts/gates/prod-push-guard.sh：localhost 放行／遠端無 token 擋／當日 token 放行／過期 token
# 擋／functions deploy／secrets set／--linked 無 token 擋／不相干與本機容器指令放行／前綴與包裝
# （lock wrapper、bash -c、env）／fail-closed（空 stdin、JSON 壞、python3 缺、意外中止 trap）／
# settings.json 接線（matcher=Bash、接 `|| exit 2`＝fail-closed 極性）／mutation 負控（拿掉 token 比對、
# 拿掉 db push 預設 linked 判斷、拿掉 --db-url 主機判斷 → 原本 deny 的樣本必須改判 allow）。
# 日期一律用 PROD_PUSH_GUARD_TODAY 固定（不依賴真實日期）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${root}/scripts/gates/prod-push-guard.sh"
fail=0
TODAY=2026-10-11
export PROD_PUSH_GUARD_TODAY="$TODAY"

_tmp_dirs=()
_cleanup_tmp() { local d; for d in "${_tmp_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap _cleanup_tmp EXIT

# payload <command 字串>：用 python3 做 JSON 編碼（命令字串含引號／換行時不會壞）
payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}

# expect_at <script> <label> <want_exit> <command>：deny(2) 驗輸出含 deny JSON 與 §6；allow(0) 驗無輸出
expect_at() {
  local script=$1 label=$2 want=$3 cmd=$4 out got
  out=$(payload "$cmd" | bash "$script" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ ${label}（期望 exit ${want}，實得 ${got}；輸出：${out}）" >&2
    fail=1
    return
  fi
  if [ "$want" -eq 0 ]; then
    [ -z "$out" ] || { echo "✗ ${label}（allow 應無輸出，實得：${out}）" >&2; fail=1; return; }
  else
    case "$out" in
      *'"permissionDecision":"deny"'*'COLLABORATION.md §6'*) ;;
      *) echo "✗ ${label}（deny 輸出缺 deny JSON 或 §6 指引：${out}）" >&2; fail=1; return ;;
    esac
  fi
  echo "✓ ${label}"
}
expect() { expect_at "$gate" "$@"; }

REMOTE='postgresql://postgres.abc@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres'
LOCALDB='postgresql://postgres@127.0.0.1:54322/postgres'

# ---- 票文驗收：本機放行／遠端無 token 擋／有當日 token 放行／過期 token 擋 ----
expect '① db push --db-url 本機 127.0.0.1（allow）' 0 "supabase db push --db-url ${LOCALDB}"
expect '①b --db-url localhost（allow）' 0 'supabase db push --db-url postgresql://postgres@localhost:54322/postgres'
expect '①c --db-url host.docker.internal（allow）' 0 'supabase db push --db-url postgresql://postgres@host.docker.internal:54322/postgres'
expect '② db push --db-url 遠端無 token（deny）' 2 "supabase db push --db-url ${REMOTE}"
expect '③ 遠端＋當日 token（allow）' 0 "env PROD-PUSH-APPROVED-BY-USER=${TODAY} supabase db push --db-url ${REMOTE}"
expect '③b 當日 token 以註解形式帶在同一條命令（allow）' 0 "supabase db push --linked # PROD-PUSH-APPROVED-BY-USER=${TODAY}"
expect '④ 過期 token（昨日，deny）' 2 "env PROD-PUSH-APPROVED-BY-USER=2026-10-10 supabase db push --db-url ${REMOTE}"
expect '④b token 日期後多接數字（deny）' 2 "env PROD-PUSH-APPROVED-BY-USER=${TODAY}5 supabase db push --linked"
expect '④c token 在另一條命令（不同 Bash 呼叫）不算——此條無 token（deny）' 2 'supabase db push --linked'

# ---- 部署面其他指令 ----
expect '⑤ functions deploy 無 token（deny）' 2 'supabase functions deploy purge-media'
expect '⑤b functions deploy 有當日 token（allow）' 0 "env PROD-PUSH-APPROVED-BY-USER=${TODAY} supabase functions deploy purge-media"
expect '⑥ secrets set 無 token（deny）' 2 'supabase secrets set FOO=bar'
expect '⑦ db push --linked 無 token（deny）' 2 'supabase db push --linked'
expect '⑦b db push 裸跑（預設 linked，deny）' 2 'supabase db push'
expect '⑦c db push --local（allow）' 0 'supabase db push --local'
expect '⑧ migration up --linked 無 token（deny）' 2 'supabase migration up --linked'
expect '⑧b migration up 遠端 --db-url 無 token（deny）' 2 "supabase migration up --db-url ${REMOTE}"
expect '⑧c migration up 裸跑（CLI 預設本機，allow）' 0 'supabase migration up'
expect '⑨ db query --linked 無 token（deny）' 2 "supabase db query --linked 'select 1'"
expect '⑨b --db-url 值是 shell 變數（無法判斷，fail closed deny）' 2 'supabase db push --db-url "$DB_URL"'
expect '⑨c --db-url= 等號形式遠端（deny）' 2 "supabase db push --db-url=${REMOTE}"

# ---- 不相干／本機容器 ----
expect '⑩ 不相干命令（allow）' 0 'ls -la && git status'
expect '⑩b supabase start（allow）' 0 'supabase start'
expect '⑩c supabase db reset（allow）' 0 'supabase db reset'
expect '⑩d supabase db query 無 --linked（本機，allow）' 0 "supabase db query 'select 1'"
expect '⑩e commit 訊息內提到 db push（非命令位置，allow）' 0 'git commit -m "docs: supabase db push 需使用者授權"'
expect '⑩f echo 提到 supabase db push（allow）' 0 'echo "never run supabase db push --linked"'

# ---- 前綴／包裝 ----
expect '⑪ lock wrapper 包住遠端 db push（deny）' 2 'bash scripts/ops/supabase-lock.sh -- supabase db push --linked'
expect '⑪b lock wrapper 包住本機 db reset（allow）' 0 'bash scripts/ops/supabase-lock.sh -- supabase db reset'
expect '⑪c cd && 後的 db push（deny）' 2 'cd /tmp/x && supabase db push'
expect '⑪d bash -c 內的 secrets set（deny）' 2 "bash -c 'supabase secrets set A=b'"
expect '⑪e npx supabase db push --linked（deny）' 2 'npx supabase db push --linked'
expect '⑪f 絕對路徑 supabase（deny）' 2 '/opt/homebrew/bin/supabase db push --linked'
expect '⑪g 管線後的 supabase（deny）' 2 'yes | supabase db push --linked'

# ---- R2：引號感知（M2）／行尾續行（M3）／任意位置前綴（m1）／涵蓋面（m2）----
expect 'R2-M2a 旗標在含括號的 SQL 後面（deny）' 2 'supabase db query "select count(*) from t" --linked'
expect 'R2-M2b 旗標在含分號的 SQL 後面（deny）' 2 'supabase db query "alter table t add c int;" --linked'
expect 'R2-M2c 遠端 --db-url 在 SQL 後面（deny）' 2 "supabase db query \"select now()\" --db-url ${REMOTE}"
expect 'R2-M2d 引號內的 && 不當分段符（deny）' 2 'supabase db query "a && b" --linked'
expect 'R2-M2e SQL 內容寫 db push 的本機查詢不誤擋（allow）' 0 "supabase db query \"select 'db push'\""
expect 'R2-M2f 未閉合引號 fail closed（deny）' 2 'supabase db push --linked "'
expect 'R2-M3a 續行：supabase 與子指令分兩行（deny）' 2 $'supabase \\\n  db push'
expect 'R2-M3b 續行：--linked 在最後一行（deny）' 2 $'supabase db query \\\n  -f x.sql \\\n  --linked'
expect 'R2-m1a timeout 前綴（deny）' 2 'timeout 60 supabase db push'
expect 'R2-m1b gtimeout -k 前綴（deny）' 2 'gtimeout -k 5 60 supabase db push --linked'
expect 'R2-m1c if then 後（deny）' 2 'if true; then supabase db push; fi'
expect 'R2-m1d 大括號群組（deny）' 2 '{ supabase db push; }'
expect 'R2-m1e 黏在一起的 true&&supabase（deny）' 2 'true&&supabase db push'
expect 'R2-m1f eval 內文（deny）' 2 "eval 'supabase db push --linked'"
expect 'R2-m1g heredoc 餵 bash（deny）' 2 $'bash <<\'X\'\nsupabase db push --linked\nX'
expect 'R2-m1h --workdir 夾在中間（deny）' 2 'supabase --workdir x db push'
expect 'R2-m1i URL 查詢字串有 & 後面接 --linked（deny）' 2 'supabase db push --db-url "postgresql://postgres@127.0.0.1:54322/postgres?a=1&b=2" --linked'
expect 'R2-m1j 本機 URL 含 & 的 db push（allow）' 0 'supabase db push --db-url "postgresql://postgres@127.0.0.1:54322/postgres?a=1&b=2"'
expect 'R2-m1k cd supabase 目錄後做本機 reset（allow）' 0 'cd supabase && supabase db reset'
expect 'R2-m1l 多行：先 start 再本機 reset（allow）' 0 $'supabase start\nsupabase db reset'
expect 'R2-m2a secrets unset（deny）' 2 'supabase secrets unset FOO'
expect 'R2-m2b functions delete（deny）' 2 'supabase functions delete foo'
expect 'R2-m2c config push（deny）' 2 'supabase config push'
expect 'R2-m2d migration repair 預設 linked（deny）' 2 'supabase migration repair --status applied 20260101000000'
expect 'R2-m2e migration repair --local（allow）' 0 'supabase migration repair --local --status applied 20260101000000'
expect 'R2-m2f storage rm（deny）' 2 'supabase storage rm ss:///media/x.png'
expect 'R2-m2g storage cp --local（allow）' 0 'supabase storage cp --local a.png ss:///media/a.png'
expect 'R2-m2h secrets unset 有當日 token（allow）' 0 "env PROD-PUSH-APPROVED-BY-USER=${TODAY} supabase secrets unset FOO"

# ---- fail-closed ----
out=$(printf '' | bash "$gate" 2>&1); got=$?
if [ "$got" -eq 2 ]; then echo '✓ fail-closed：stdin 空（deny）'; else echo "✗ fail-closed：stdin 空期望 2 實得 ${got}：${out}" >&2; fail=1; fi
out=$(printf '%s' 'not json {' | bash "$gate" 2>&1); got=$?
if [ "$got" -eq 2 ]; then echo '✓ fail-closed：JSON 壞（deny）'; else echo "✗ fail-closed：JSON 壞期望 2 實得 ${got}：${out}" >&2; fail=1; fi
# python3 缺席：PATH 只放 bash／date 所在的符號連結農場，不含 python3
nopy_dir=$(mktemp -d); _tmp_dirs+=("$nopy_dir")
for b in bash date; do ln -s "$(command -v "$b")" "${nopy_dir}/${b}"; done
out=$(payload 'ls' | PATH="$nopy_dir" "${nopy_dir}/bash" "$gate" 2>&1); got=$?
if [ "$got" -eq 2 ]; then echo '✓ fail-closed：python3 缺席（deny）'; else echo "✗ fail-closed：python3 缺席期望 2 實得 ${got}：${out}" >&2; fail=1; fi
# tool_input 沒有 command：沒東西可判斷，allow
out=$(printf '%s' '{"tool_input":{}}' | bash "$gate" 2>&1); got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ]; then echo '✓ tool_input 無 command（allow）'; else echo "✗ tool_input 無 command 期望 0 無輸出，實得 ${got}：${out}" >&2; fail=1; fi

# ---- trap 負控：腳本中途未預期中止，有 trap 仍 deny；拿掉 trap 則不 deny ----
mut_dir=$(mktemp -d); _tmp_dirs+=("$mut_dir")
# 注入中途 exit 1（在讀 stdin 之後、引擎之前）
awk '{print} /^today=/{print "exit 1"}' "$gate" > "${mut_dir}/with_trap.sh"
awk '$0 == "trap on_exit EXIT" {next} {print} /^today=/{print "exit 1"}' "$gate" > "${mut_dir}/no_trap.sh"
out=$(payload 'ls' | bash "${mut_dir}/with_trap.sh" 2>&1); got=$?
if [ "$got" -eq 2 ]; then echo '✓ trap：中途 exit 1 仍 deny（exit 2）'; else echo "✗ trap：有 trap 應 deny（實得 ${got}：${out}）" >&2; fail=1; fi
out=$(payload 'ls' | bash "${mut_dir}/no_trap.sh" 2>&1); got=$?
if [ "$got" -eq 1 ]; then echo '✓ trap：拿掉 trap 後同樣中止不再 deny（證明 trap 是關鍵）'; else echo "✗ trap：拿掉 trap 行為竟沒變（實得 ${got}：${out}）" >&2; fail=1; fi

# ---- settings.json 接線：matcher=Bash 的 PreToolUse 有 prod-push-guard.sh 且接 `|| exit 2`（fail-closed 極性）----
wiring=$(python3 - "${root}/.claude/settings.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for ent in d["hooks"]["PreToolUse"]:
    if ent.get("matcher") == "Bash":
        for h in ent["hooks"]:
            if "prod-push-guard.sh" in h.get("command", ""):
                print(h["command"])
PYEOF
)
if [ -n "$wiring" ]; then echo '✓ wiring①：settings.json 有 matcher=Bash 的 prod-push-guard.sh'; else echo '✗ wiring①：settings.json 找不到 matcher=Bash 的 prod-push-guard.sh' >&2; fail=1; fi
case "$wiring" in
  *'|| exit 2'*) echo '✓ wiring②：command 接 `|| exit 2`（fail-closed，與腳本內極性一致）' ;;
  *) echo "✗ wiring②：command 未接 || exit 2（實得：${wiring}）" >&2; fail=1 ;;
esac
case "$wiring" in
  *scripts/gates/prod-push-guard.sh*) echo '✓ wiring③：路徑指向 scripts/gates/prod-push-guard.sh' ;;
  *) echo "✗ wiring③：路徑不是 scripts/gates/prod-push-guard.sh（${wiring}）" >&2; fail=1 ;;
esac

# ---- mutation 負控：拿掉某段判斷後，原本 deny 的樣本必須改判 allow（測試真的測到那一段）----
mutate_expect_allow() {  # $1=label $2=sed 表達式 $3=原本會 deny 的 command
  local label=$1 expr=$2 cmd=$3 m="${mut_dir}/m.sh"
  sed "$expr" "$gate" > "$m"
  if cmp -s "$gate" "$m"; then echo "✗ ${label}（sed 沒改到任何東西，負控本身無效）" >&2; fail=1; return; fi
  local out got
  out=$(payload "$cmd" | bash "$m" 2>&1); got=$?
  if [ "$got" -eq 0 ]; then echo "✓ ${label}"; else echo "✗ ${label}（mutant 仍判 ${got}：${out}）" >&2; fail=1; fi
}
mutate_expect_allow 'M1：拿掉 token 比對（一律放行已偵測者）→ 無 token 的 --linked 改判 allow' \
  's/^sys.exit(0 if tok.search(cmd) else 2)$/sys.exit(0)/' 'supabase db push --linked'
mutate_expect_allow 'M2：拿掉 db push 預設 linked 判斷 → 裸跑 db push 改判 allow' \
  's/ and dburl is None and not has_local/ and False/' 'supabase db push'
mutate_expect_allow 'M3：拿掉 --db-url 主機判斷 → 遠端 --db-url 改判 allow' \
  's/if dburl is not None and host_of(dburl) not in LOCAL_HOSTS:/if False:/' "supabase migration up --db-url ${REMOTE}"
mutate_expect_allow 'M4：拿掉 functions deploy／secrets set 規則 → functions deploy 改判 allow' \
  's/^    if re.search(ALWAYS_REMOTE, text):$/    if False:/' 'supabase functions deploy foo'
mutate_expect_allow 'M5：拿掉 --linked 判斷 → db query --linked 改判 allow' \
  's/^    if linked:$/    if False:/' "supabase db query --linked 'select 1'"
mutate_expect_allow 'M6：拿掉行尾續行摺疊 → 續行寫法的 --linked 改判 allow' \
  's/^    command = command.replace.*$/    command = command/' $'supabase db query \\\n  -f x.sql \\\n  --linked'
mutate_expect_allow 'M7：拿掉 migration repair 預設 linked → 改判 allow' \
  's/migration\\s+repair/zzz_never/' 'supabase migration repair --status applied 20260101000000'
mutate_expect_allow 'M8：拿掉 secrets unset 規則 → 改判 allow' \
  's/secrets\\s+(?:set|unset)/secrets\\s+set/' 'supabase secrets unset FOO'
mutate_expect_allow 'M9：tokenize 改成不認引號的括號切段 → 旗標在含括號 SQL 後面的 --linked 改判 allow' \
  's/^    return list(s)$/    return re.split(r"[();]", cmd)/' 'supabase db query "select count(*) from t" --linked'

if [ "$fail" -ne 0 ]; then
  echo "✗ prod-push-guard.test.sh 有失敗項目" >&2
  exit 1
fi
echo "✓ prod-push-guard.test.sh 全數通過"
