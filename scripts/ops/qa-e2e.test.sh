#!/bin/bash
# qa-e2e.sh 的自測（LS-158）。CI rules job 每個 PR 都跑。
#
# 比照 tap-target-check.test.sh：PATH 換上假的 supabase／curl／xcrun／xcodebuild／docker，完全不碰真容器、
# 真模擬器；這裡只驗腳本自己的前置防線——參數與情境名檢查、票號推導、容器環境變數與 health 檢查——
# 全部要在碰到 xcrun／xcodebuild 之前就 fail closed。假 xcrun／xcodebuild／docker 一旦被呼叫就落標記檔，
# 每個案例都斷言標記不存在。「XCUITest 真的能驅動 app」不是這支腳本的責任，那是 LittleSproutUITests/QA 的。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/qa-e2e.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LS_QA_MAILPIT

bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/supabase" <<'STUB'
#!/bin/bash
case "${FAKE_SUPABASE_MODE:-ok}" in
  ok) printf 'ANON_KEY="fake-anon"\nAPI_URL="http://127.0.0.1:54321"\nMAILPIT_URL="http://127.0.0.1:54324"\nSERVICE_ROLE_KEY="fake-service"\n' ;;
  empty) ;;
  down) echo "failed to inspect container health" >&2; exit 1 ;;
esac
STUB
cat > "$bin/curl" <<'STUB'
#!/bin/bash
# 只回 -w 的 http_code：FAKE_CURL_MAILPIT／FAKE_CURL_AUTH 依 URL 選
url=; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
case "$url" in
  */api/v1/info) printf '%s' "${FAKE_CURL_MAILPIT:-200}" ;;
  */auth/v1/health) printf '%s' "${FAKE_CURL_AUTH:-200}" ;;
  *) printf '000' ;;
esac
STUB
for tool in xcrun xcodebuild docker; do
  printf '#!/bin/bash\ntouch "%s/INVOKED-%s"\nexit 99\n' "$work" "$tool" > "$bin/$tool"
done
chmod +x "$bin"/*

# 假 worktree：目錄名帶票號（票號推導用）＋一個不帶票號的
mkdir -p "$work/LS-321" "$work/plain"
git -C "$work/LS-321" init -q; git -C "$work/plain" init -q

run() {   # run <repo 目錄> [參數…]；FAKE_* 由呼叫端 export
  ( cd "$1" && shift && PATH="$bin:$PATH" bash "$script" "$@" 2>&1 )
}
expect() {   # expect <期望 exit> <名稱> <實得 exit> <輸出> [必含…]
  local want=$1 name=$2 got=$3 out=$4; shift 4
  local good=1 must
  [ "$got" -eq "$want" ] || good=0
  for must in "$@"; do printf '%s' "$out" | grep -qF -- "$must" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
  fi
}
no_tools() {   # 斷言 xcrun／xcodebuild／docker 都沒被叫到
  local name=$1 tool bad=0
  for tool in xcrun xcodebuild docker; do [ -e "$work/INVOKED-$tool" ] && { echo "✗ ${name}：不該呼叫 ${tool}" >&2; bad=1; }; done
  [ "$bad" -eq 0 ] && ok "${name}：未實跑 xcrun／xcodebuild／docker"
  rm -f "$work"/INVOKED-*
}

# ---- ① 參數 ----
out=$(run "$work/LS-321"); got=$?
expect 2 '① 無參數 → exit 2、印用法' "$got" "$out" '用法：qa-e2e.sh'
out=$(run "$work/LS-321" fly); got=$?
expect 2 '② 情境名錯 → exit 2、列出合法集合' "$got" "$out" '情境「fly」不存在' 'login|publish|browse'
no_tools '②'
out=$(run "$work/LS-321" login browse); got=$?
expect 2 '② 兩個情境 → exit 2' "$got" "$out" '多餘參數'
out=$(run "$work/LS-321" login --sim); got=$?
expect 2 '② --sim 缺值 → exit 2' "$got" "$out" '--sim 缺值'
out=$(run "$work/LS-321" login --bogus); got=$?
expect 2 '② 未知旗標 → exit 2' "$got" "$out" '未知參數'
out=$(run "$work/LS-321" --help); got=$?
expect 0 '① --help → exit 0' "$got" "$out" '用法：qa-e2e.sh'

# ---- ③ 票號 ----
out=$(run "$work/plain" login); got=$?
expect 2 '③ worktree 目錄名無票號且無 --ticket → exit 2' "$got" "$out" '推不出票號'
out=$(run "$work/plain" login --ticket nope); got=$?
expect 2 '③ --ticket 格式錯 → exit 2' "$got" "$out" '--ticket 須為 LS-<n>'
out=$(cd "$work" && PATH="$bin:$PATH" bash "$script" login 2>&1); got=$?
expect 2 '③ 不在 git repo 內 → exit 2' "$got" "$out" '不在 git repo 內'
no_tools '③'

# ---- ④ 容器環境（缺環境變數紅）----
out=$(FAKE_SUPABASE_MODE=empty run "$work/LS-321" login); got=$?
expect 2 '④ supabase status 無 API_URL／ANON_KEY → exit 2' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_SUPABASE_MODE=down run "$work/LS-321" publish); got=$?
expect 2 '④ supabase status 失敗 → exit 2' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_SUPABASE_MODE=empty run "$work/plain" browse --ticket LS-7); got=$?
expect 2 '④ --ticket 合法時走到容器檢查（票號推導不擋）' "$got" "$out" '取不到 API_URL／ANON_KEY'
out=$(FAKE_CURL_MAILPIT=000 run "$work/LS-321" login); got=$?
expect 2 '④ Mailpit 不可達 → exit 2' "$got" "$out" 'Mailpit http://127.0.0.1:54324 不可達（HTTP 000）'
out=$(LS_QA_MAILPIT=http://127.0.0.1:1 FAKE_CURL_MAILPIT=000 run "$work/LS-321" login); got=$?
expect 2 '④ LS_QA_MAILPIT 覆寫值被採用' "$got" "$out" 'Mailpit http://127.0.0.1:1 不可達'
out=$(FAKE_CURL_AUTH=503 run "$work/LS-321" login); got=$?
expect 2 '④ GoTrue health 非 200 → exit 2' "$got" "$out" 'auth/v1/health 回 HTTP 503'
no_tools '④'

# ---- ⑤ 環境齊全才會碰模擬器：假 xcrun 立刻失敗、腳本 exit 2 且沒碰 xcodebuild ----
out=$(run "$work/LS-321" login); got=$?
expect 2 '⑤ 環境齊全 → 進到模擬器階段（假 xcrun 失敗）' "$got" "$out" '找不到 iPhone 17 Pro devicetype'
if [ -e "$work/INVOKED-xcrun" ] && [ ! -e "$work/INVOKED-xcodebuild" ]; then ok '⑤ 呼叫了 xcrun、未碰 xcodebuild'; else echo "✗ ⑤ 應呼叫 xcrun 且不碰 xcodebuild" >&2; fail=1; fi
rm -f "$work"/INVOKED-*
out=$(run "$work/LS-321" login --sim no-such-sim); got=$?
expect 2 '⑤ --sim 指定不存在的模擬器 → exit 2（不自建）' "$got" "$out" '--sim「no-such-sim」不存在'
[ -e "$work/INVOKED-xcodebuild" ] && { echo "✗ ⑤ 不該呼叫 xcodebuild" >&2; fail=1; }
rm -f "$work"/INVOKED-*

if [ "$fail" -ne 0 ]; then echo "✗ qa-e2e 自測失敗" >&2; exit 1; fi
echo "✓ qa-e2e 自測通過（${n} 組樣本）"
