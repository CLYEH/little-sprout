#!/bin/bash
# promote.sh 的自測（LS-85）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對晉升腳本也適用：若退化成方向不擋、非 FF 照推、check 紅／缺／skipped／未完成照推、同名多筆只看舊的
# 一筆而不是最新、gh 失敗當成綠、或推送時沒帶 PROMOTE_VIA_SCRIPT=1（真的晉升會被 push-gate 擋）——這裡會紅。
# 合成 repo：file:// 裸 origin（main／development／test）＋clone；gh 用 PATH 上的 stub（把 --jq 交給真 jq 對罐頭 JSON 跑，
# 驗的是腳本自己的 jq 表達式）；clone 掛一個 pre-push hook 記錄環境變數與 stdin，驗 (e) 與 push-gate 的契約。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
promote="${root}/scripts/ops/promote.sh"
fail=0
command -v jq >/dev/null 2>&1 || { echo "✗ promote 自測需要 jq（stub gh 用它跑 --jq）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# ---- stub gh：記錄參數；GH_STUB_FAIL=1 模擬失敗；--jq 交給真 jq 對 $GH_STUB_JSON 跑 ----
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
[ "${GH_STUB_FAIL:-0}" = 1 ] && { echo "gh: HTTP 401 (stub)" >&2; exit 1; }
expr=
while [ $# -gt 0 ]; do case "$1" in --jq) expr=$2; shift ;; esac; shift; done
if [ -n "$expr" ]; then jq -r "$expr" "${GH_STUB_JSON:?}"; else cat "${GH_STUB_JSON:?}"; fi
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_LOG="$work/gh.log" GH_STUB_JSON="$work/runs.json"
# runs <name:status:conclusion>…：產生 check-runs 罐頭 JSON，id 依序遞增（越後面越新）；conclusion 寫 null 即 JSON null
runs() {
  local id=100 items= spec n rest s c
  for spec in "$@"; do
    n=${spec%%:*}; rest=${spec#*:}; s=${rest%%:*}; c=${rest#*:}
    if [ "$c" = null ]; then c=null; else c="\"${c}\""; fi
    items="${items:+${items},}{\"id\":${id},\"name\":\"${n}\",\"status\":\"${s}\",\"conclusion\":${c},\"html_url\":\"https://x/${id}\",\"app\":{\"id\":15368}}"
    id=$((id + 1))
  done
  printf '{"total_count":%s,"check_runs":[%s]}' "$#" "$items" > "$GH_STUB_JSON"
}
ALL_GREEN="ci:completed:success db:completed:success lint:completed:success rules:completed:success"

# ---- pre-push hook 記錄器：驗 promote.sh 推送時帶 PROMOTE_VIA_SCRIPT=1 與 refspec 形狀；PREPUSH_FAIL=1 模擬遠端拒收 ----
mkdir -p "$work/hooks"
cat > "$work/hooks/pre-push" <<'EOF'
#!/bin/bash
{ echo "PROMOTE_VIA_SCRIPT=${PROMOTE_VIA_SCRIPT:-unset}"; cat; } > "${PREPUSH_LOG:?}"
[ "${PREPUSH_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
chmod +x "$work/hooks/pre-push"
export PREPUSH_LOG="$work/prepush.log"

# ---- 合成 repo ----
remote="$work/remote.git"; g init -q --bare -b main "$remote"
seed="$work/seed"; g init -q -b main "$seed"
echo a > "$seed/f.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'chore: LS-0 seed'
g -C "$seed" branch development; g -C "$seed" branch test
g -C "$seed" remote add origin "$remote"; g -C "$seed" push -q origin main development test
base=$(g -C "$seed" rev-parse main)
repo="$work/repo"; g clone -q "$remote" "$repo"
g -C "$repo" config core.hooksPath "$work/hooks"
# development 領先 test 一個 commit
g -C "$seed" checkout -q development; echo d > "$seed/d.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'feat: LS-1 dev'
g -C "$seed" push -q origin development
dev1=$(g -C "$seed" rev-parse development)

rsha() { g -C "$remote" rev-parse "refs/heads/$1"; }
out=; rc=
# expect <期望 exit> <名稱> <輸出必含|''> <promote 參數…>；輸出與 rc 留在全域 out／rc 供後續斷言
expect() {
  local want=$1 name=$2 must=$3; shift 3
  out="$(cd "$repo" && bash "$promote" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then echo "✓ ${name}"
  else echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
}
is()    { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ ${1}（期望「${3}」，實得「${2}」）" >&2; fail=1; fi; }
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
reset_logs() { : > "$GH_STUB_LOG"; rm -f "$PREPUSH_LOG"; }
no_push() { if [ -f "$PREPUSH_LOG" ]; then echo "✗ ${1}（不該嘗試 push，但 pre-push 被觸發）" >&2; fail=1; else echo "✓ $1"; fi; }

# ---- ① 方向：只准 development→test、test→main；其餘 exit 2、不碰 gh、不推 ----
runs $ALL_GREEN
for pair in "development main" "test development" "main test" "feature/LS-1-x test" "development" "" "development test extra"; do
  reset_logs
  # shellcheck disable=SC2086
  expect 2 "① 方向「${pair}」→ exit 2" '' $pair
  is "① 方向「${pair}」不呼叫 gh" "$(cat "$GH_STUB_LOG")" ''
  no_push "① 方向「${pair}」不推"
done
is '① remote test 未動' "$(rsha test)" "$base"

# ---- ② 非 FF：test 被直接 push 一個 commit（不在 development）→ exit 1、指示併回、不呼叫 gh、不推 ----
g -C "$seed" checkout -q test; echo t > "$seed/t.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'chore: LS-0 stray on test'
g -C "$seed" push -q origin test
stray=$(g -C "$seed" rev-parse test)
reset_logs
expect 1 '② 非 FF → exit 1' '非 fast-forward' development test
has   '② 點名 test 有 1 commit 不在 development' "$out" 'origin/test 有 1 commit 不在 origin/development'
has   '② 指示先併回 development' "$out" '併回 development'
is    '② FF 先於 check：不呼叫 gh' "$(cat "$GH_STUB_LOG")" ''
no_push '② 非 FF 不推'
is    '② remote test 未動' "$(rsha test)" "$stray"
# 還原 test 到 base（裸 remote 無保護）
g -C "$seed" push -q -f origin "${base}:refs/heads/test"; g -C "$seed" reset -q --hard "$base"

# ---- ③ check 紅：ci failure → exit 1、點名 ci、不推 ----
runs "ci:completed:failure" "db:completed:success" "lint:completed:success" "rules:completed:success"
reset_logs
expect 1 '③ ci failure → exit 1' 'check ci: ✗ completed/failure' development test
has   '③ 查的是 origin/development 的 SHA' "$(cat "$GH_STUB_LOG")" "commits/${dev1}/check-runs"
has   '③ 其他三個仍印綠' "$out" 'check rules: ✓ success'
no_push '③ check 紅不推'
is    '③ remote test 未動' "$(rsha test)" "$base"

# ---- ④ check 缺：沒有 rules → exit 1、印「缺」 ----
runs "ci:completed:success" "db:completed:success" "lint:completed:success"
reset_logs
expect 1 '④ 缺 rules → exit 1' 'check rules: 缺' development test
no_push '④ check 缺不推'

# ---- ⑤ skipped：rules 在 push 事件下整 job 跳過（LS-85 之前的 ci.yml 形狀）→ 拒 ----
runs "ci:completed:success" "db:completed:success" "lint:completed:success" "rules:completed:skipped"
reset_logs
expect 1 '⑤ rules skipped → exit 1' 'check rules: ✗ completed/skipped' development test
no_push '⑤ skipped 不推'

# ---- ⑥ 未完成：ci in_progress（conclusion null）→ 拒 ----
runs "ci:in_progress:null" "db:completed:success" "lint:completed:success" "rules:completed:success"
reset_logs
expect 1 '⑥ ci in_progress → exit 1' 'check ci: ✗ in_progress/-' development test
no_push '⑥ 未完成不推'

# ---- ⑦ 同名多筆取最新（id 最大）：ci 舊綠新紅 → 拒 ----
runs "ci:completed:success" "db:completed:success" "lint:completed:success" "rules:completed:success" "ci:completed:failure"
reset_logs
expect 1 '⑦ ci 舊綠新紅 → 看最新 → exit 1' 'check ci: ✗ completed/failure' development test
no_push '⑦ 舊綠新紅不推'
is    '⑦ remote test 未動' "$(rsha test)" "$base"

# ---- ⑧ 正常：全綠（ci 舊紅新綠）→ 推、remote test＝origin/development、hook 收到 PROMOTE_VIA_SCRIPT=1 與 refspec ----
runs "ci:completed:failure" "db:completed:success" "lint:completed:success" "rules:completed:success" "ci:completed:success"
reset_logs
expect 0 '⑧ 全綠（ci 舊紅新綠）→ exit 0' '已晉升 test' development test
is    '⑧ remote test 前進到 origin/development' "$(rsha test)" "$dev1"
has   '⑧ 摘要：FF 與 commit 數' "$out" '晉升 1 commit'
has   '⑧ 摘要：四個 check 綠' "$out" 'check rules: ✓ success'
hasnt '⑧ dev→test 不印 tag 提醒' "$out" 'tag'
has   '⑧ pre-push 收到 PROMOTE_VIA_SCRIPT=1' "$(cat "$PREPUSH_LOG" 2>/dev/null)" 'PROMOTE_VIA_SCRIPT=1'
has   '⑧ pre-push stdin：local ref＝refs/remotes/origin/development、目標 refs/heads/test、remote sha＝舊 test' "$(cat "$PREPUSH_LOG" 2>/dev/null)" "refs/remotes/origin/development ${dev1} refs/heads/test ${base}"

# ---- ⑨ 已是最新：再跑一次 → exit 0、不呼叫 gh、不推 ----
reset_logs
expect 0 '⑨ origin/test 已等於 origin/development → exit 0' '無需晉升' development test
is    '⑨ 不呼叫 gh' "$(cat "$GH_STUB_LOG")" ''
no_push '⑨ 無需晉升不推'

# ---- ⑩ gh 失敗 → exit 2（fail closed）、不推 ----
g -C "$seed" checkout -q development; echo d2 > "$seed/d2.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'feat: LS-2 dev again'
g -C "$seed" push -q origin development
dev2=$(g -C "$seed" rev-parse development)
runs $ALL_GREEN
reset_logs
out="$(cd "$repo" && GH_STUB_FAIL=1 bash "$promote" development test 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'gh api check-runs 失敗'; then echo "✓ ⑩ gh 失敗 → exit 2"; else echo "✗ ⑩ gh 失敗應 exit 2 並說明（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
no_push '⑩ gh 失敗不推'
is    '⑩ remote test 未動' "$(rsha test)" "$dev1"

# ---- ⑪ 遠端拒收（fetch 之後遠端又前進／required checks 未滿足；用 hook 回非 0 模擬）→ exit 1 ----
reset_logs
out="$(cd "$repo" && PREPUSH_FAIL=1 bash "$promote" development test 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'push 被拒'; then echo "✓ ⑪ push 被拒 → exit 1"; else echo "✗ ⑪ push 被拒應 exit 1 並說明（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
is    '⑪ remote test 未動' "$(rsha test)" "$dev1"

# ---- ⑫ test→main：test（dev1）領先 main（base）、全綠 → 推、印 tag 提醒 ----
reset_logs
expect 0 '⑫ test→main 全綠 → exit 0' '已晉升 main' test main
is    '⑫ remote main 前進到 origin/test' "$(rsha main)" "$dev1"
has   '⑫ test→main 提醒打 tag' "$out" 'tag'
has   '⑫ 查的是 origin/test 的 SHA' "$(cat "$GH_STUB_LOG")" "commits/${dev1}/check-runs"
has   '⑫ pre-push stdin：目標 refs/heads/main' "$(cat "$PREPUSH_LOG" 2>/dev/null)" "refs/remotes/origin/test ${dev1} refs/heads/main ${base}"
is    '⑫ remote test 未動（dev2 仍待晉升）' "$(rsha test)" "$dev1"
is    '⑫ development 未動' "$(rsha development)" "$dev2"

# ---- ⑬ 不在 git repo → exit 2 ----
out="$(cd "$work" && bash "$promote" development test 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '不在 git repo'; then echo "✓ ⑬ 不在 git repo → exit 2"; else echo "✗ ⑬ 不在 git repo 應 exit 2（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ promote 自測失敗" >&2
  exit 1
fi
echo "✓ promote 自測通過（13 組樣本）"
