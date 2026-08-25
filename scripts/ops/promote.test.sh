#!/bin/bash
# promote.sh 的自測（LS-85）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對晉升腳本也適用：若退化成方向不擋、非 FF 照推、check 紅／缺／skipped／未完成照推、同名多筆只看舊的
# 一筆而不是最新、別的 app 貼的同名 check 也算（R1 F5）、推的不是驗過的 SHA 而是 ref（R1 F1：巡檢 fetch 會移動 remote-tracking
# ref）、gh 失敗當成綠、推送時沒帶 PROMOTE_VIA_SCRIPT=1（真的晉升會被 push-gate 擋）、commit status merge-review 缺／failure／
# pending 照推、test→main 沒有 qa success 照推、development→test 誤要求 qa、status 端點失敗當成綠（LS-87）——這裡會紅。
# 合成 repo：file:// 裸 origin（main／development／test）＋clone；gh 用 PATH 上的 stub（把 --jq 交給真 jq 對罐頭 JSON 跑，
# 驗的是腳本自己的 jq 表達式；依 endpoint 選罐頭：…/check-runs → GH_STUB_JSON、…/status → GH_STUB_STATUS_JSON）；
# clone 掛一個 pre-push hook 記錄環境變數與 stdin，驗 (e) 與 push-gate 的契約。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
promote="${root}/scripts/ops/promote.sh"
fail=0
command -v jq >/dev/null 2>&1 || { echo "✗ promote 自測需要 jq（stub gh 用它跑 --jq）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# ---- stub gh：記錄參數；GH_STUB_FAIL=1 全部失敗、GH_STUB_FAIL_STATUS=1 只有 …/status 失敗；--jq 交給真 jq 對罐頭跑
#      （endpoint 以 /status 結尾 → $GH_STUB_STATUS_JSON，其餘 → $GH_STUB_JSON）----
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
[ "${GH_STUB_FAIL:-0}" = 1 ] && { echo "gh: HTTP 401 (stub)" >&2; exit 1; }
expr=; ep=
while [ $# -gt 0 ]; do case "$1" in --jq) expr=$2; shift ;; repos/*) ep=$1 ;; esac; shift; done
case "$ep" in
  */status)
    [ "${GH_STUB_FAIL_STATUS:-0}" = 1 ] && { echo "gh: HTTP 500 (stub)" >&2; exit 1; }
    src=${GH_STUB_STATUS_JSON:?} ;;
  *) src=${GH_STUB_JSON:?} ;;
esac
if [ -n "$expr" ]; then jq -r "$expr" "$src"; else cat "$src"; fi
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_LOG="$work/gh.log" GH_STUB_JSON="$work/runs.json" GH_STUB_STATUS_JSON="$work/status.json"
# runs <name:status:conclusion[:app_id]>…：產生 check-runs 罐頭 JSON，id 依序遞增（越後面越新）；conclusion 寫 null 即 JSON null；
# app_id 省略＝15368（GitHub Actions）
runs() {
  local id=100 items= spec n rest s c app
  for spec in "$@"; do
    n=${spec%%:*}; rest=${spec#*:}
    s=${rest%%:*}; rest=${rest#*:}
    c=${rest%%:*}
    case "$rest" in *:*) app=${rest#*:} ;; *) app=15368 ;; esac
    if [ "$c" = null ]; then c=null; else c="\"${c}\""; fi
    items="${items:+${items},}{\"id\":${id},\"name\":\"${n}\",\"status\":\"${s}\",\"conclusion\":${c},\"html_url\":\"https://x/${id}\",\"app\":{\"id\":${app}}}"
    id=$((id + 1))
  done
  printf '{"total_count":%s,"check_runs":[%s]}' "$#" "$items" > "$GH_STUB_JSON"
}
ALL_GREEN="ci:completed:success db:completed:success lint:completed:success rules:completed:success"
# statuses <context:state[:description]>…：產生 combined status 罐頭 JSON（GitHub 每個 context 只回最新一筆；不給參數＝沒人貼過）
statuses() {
  local items= spec c st d
  for spec in "$@"; do
    c=${spec%%:*}; d=${spec#*:}; st=${d%%:*}
    case "$d" in *:*) d=${d#*:} ;; *) d="${c} ${st}" ;; esac
    items="${items:+${items},}{\"context\":\"${c}\",\"state\":\"${st}\",\"description\":\"${d}\",\"target_url\":\"https://linear/${c}\"}"
  done
  printf '{"state":"%s","total_count":%s,"statuses":[%s]}' "$([ $# -eq 0 ] && echo pending || echo success)" "$#" "$items" > "$GH_STUB_STATUS_JSON"
}

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
pushed_sha() { awk 'NR == 2 { print $2 }' "$PREPUSH_LOG" 2>/dev/null; }   # pre-push stdin 第 2 欄＝實際推出去的 local sha
no_push() { if [ -f "$PREPUSH_LOG" ]; then echo "✗ ${1}（不該嘗試 push，但 pre-push 被觸發）" >&2; fail=1; else echo "✓ $1"; fi; }

# ---- ① 方向：只准 development→test、test→main；其餘 exit 2、不碰 gh、不推 ----
runs $ALL_GREEN
statuses merge-review:success qa:success   # ①～⑭ 的 status 一律齊全；⑮⑯⑰ 才動它
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
has   '⑧ 摘要：merge-review status 綠' "$out" 'status merge-review: ✓ success'
hasnt '⑧ dev→test 不要求 qa status' "$out" 'status qa'
has   '⑧ 查的是 origin/development 的 combined status' "$(cat "$GH_STUB_LOG")" "commits/${dev1}/status"
has   '⑧ 晉升摘要列 status' "$out" 'status merge-review success'
hasnt '⑧ dev→test 不印 tag 提醒' "$out" 'tag'
has   '⑧ pre-push 收到 PROMOTE_VIA_SCRIPT=1' "$(cat "$PREPUSH_LOG" 2>/dev/null)" 'PROMOTE_VIA_SCRIPT=1'
has   '⑧ pre-push stdin：目標 refs/heads/test、remote sha＝舊 test' "$(cat "$PREPUSH_LOG" 2>/dev/null)" " refs/heads/test ${base}"
is    '⑧ pre-push 收到的 local sha＝(c)(d) 驗過的 origin/development sha（推 SHA 不推 ref，R1 F1）' "$(pushed_sha)" "$dev1"

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
has   '⑫ test→main 驗 qa status' "$out" 'status qa: ✓ success'
has   '⑫ 晉升摘要列 merge-review／qa' "$out" 'status merge-review／qa success'
has   '⑫ 查的是 origin/test 的 SHA' "$(cat "$GH_STUB_LOG")" "commits/${dev1}/check-runs"
has   '⑫ pre-push stdin：目標 refs/heads/main、remote sha＝舊 main' "$(cat "$PREPUSH_LOG" 2>/dev/null)" " refs/heads/main ${base}"
is    '⑫ pre-push 收到的 local sha＝驗過的 origin/test sha（R1 F1）' "$(pushed_sha)" "$dev1"
is    '⑫ remote test 未動（dev2 仍待晉升）' "$(rsha test)" "$dev1"
is    '⑫ development 未動' "$(rsha development)" "$dev2"

# ---- ⑬ 不在 git repo → exit 2 ----
out="$(cd "$work" && bash "$promote" development test 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '不在 git repo'; then echo "✓ ⑬ 不在 git repo → exit 2"; else echo "✗ ⑬ 不在 git repo 應 exit 2（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ---- ⑭ 只認 GitHub Actions（app 15368）的 check-run（R1 F5）：development（dev2）仍領先 test（dev1）----
runs "ci:completed:success:999" "db:completed:success" "lint:completed:success" "rules:completed:success"
reset_logs
expect 1 '⑭ ci 只有別的 app（999）的 success → 視為缺 → exit 1' 'check ci: 缺' development test
no_push '⑭ 別 app 的綠不推'
runs "ci:completed:failure" "db:completed:success" "lint:completed:success" "rules:completed:success" "ci:completed:success:999"
reset_logs
expect 1 '⑭ Actions 的 ci 紅、別 app 同名綠且更新 → 只看 Actions → exit 1' 'check ci: ✗ completed/failure' development test
no_push '⑭ 仍不推'
is    '⑭ remote test 未動' "$(rsha test)" "$dev1"

# ---- ⑮ commit status merge-review（LS-87）：development（dev2）領先 test（dev1），四 check 全綠，只動 status ----
runs $ALL_GREEN
statuses qa:success                       # 沒人貼 merge-review
reset_logs
expect 1 '⑮ merge-review 缺 → exit 1' 'status merge-review: 缺' development test
has   '⑮ 缺的指示：orchestrator 依 §2 貼 promote: no content diff' "$out" 'promote: no content diff'
has   '⑮ 缺的指示含 post-status.sh 與該 SHA' "$out" "post-status.sh ${dev2} merge-review success"
has   '⑮ 四個 check 仍印綠（一次列完）' "$out" 'check rules: ✓ success'
no_push '⑮ merge-review 缺不推'
is    '⑮ remote test 未動' "$(rsha test)" "$dev1"
statuses merge-review:failure:REQUEST_CHANGES\ R1 qa:success
reset_logs
expect 1 '⑮ merge-review failure → exit 1' 'status merge-review: ✗ failure（REQUEST_CHANGES R1）' development test
has   '⑮ 拒絕訊息說明不得改貼 success 繞過' "$out" '不得改貼 success'
no_push '⑮ merge-review failure 不推'
statuses merge-review:pending:審查中 qa:success
reset_logs
expect 1 '⑮ merge-review pending → exit 1' 'status merge-review: ✗ pending' development test
no_push '⑮ merge-review pending 不推'
# check 紅＋status 缺：兩者都列（一次看完，不逐項重跑）
runs "ci:completed:failure" "db:completed:success" "lint:completed:success" "rules:completed:success"
statuses
reset_logs
expect 1 '⑮ check 紅＋status 缺 → exit 1 且兩者都列' 'check ci: ✗ completed/failure' development test
has   '⑮ 同時列 status 缺' "$out" 'status merge-review: 缺'
no_push '⑮ 都紅不推'
# 放行：merge-review success（qa 缺也無妨——dev→test 不要求）→ test 前進到 dev2
runs $ALL_GREEN
statuses "merge-review:success:promote: no content diff（PR #1）"
reset_logs
expect 0 '⑮ merge-review success、qa 缺 → dev→test 仍 exit 0' '已晉升 test' development test
has   '⑮ 印 description' "$out" 'promote: no content diff（PR #1）'
is    '⑮ remote test 前進到 dev2' "$(rsha test)" "$dev2"
is    '⑮ 推的仍是驗過的 SHA' "$(pushed_sha)" "$dev2"

# ---- ⑯ commit status qa（LS-87）：test（dev2）領先 main（dev1），merge-review success，只動 qa ----
statuses merge-review:success
reset_logs
expect 1 '⑯ test→main qa 缺 → exit 1' 'status qa: 缺' test main
has   '⑯ 缺的指示：qa agent 貼、orchestrator 不得代貼' "$out" 'orchestrator 不得代貼'
has   '⑯ merge-review 仍印綠' "$out" 'status merge-review: ✓ success'
no_push '⑯ qa 缺不推'
is    '⑯ remote main 未動' "$(rsha main)" "$dev1"
statuses merge-review:success "qa:failure:BLOCKED: 缺實機 R1"
reset_logs
expect 1 '⑯ qa failure（BLOCKED）→ exit 1 並印 description' 'status qa: ✗ failure（BLOCKED: 缺實機 R1）' test main
no_push '⑯ qa failure 不推'
statuses qa:success                       # merge-review 缺、qa 有 → 仍拒（main 也要 merge-review）
reset_logs
expect 1 '⑯ test→main merge-review 缺（qa 有）→ exit 1' 'status merge-review: 缺' test main
no_push '⑯ merge-review 缺不推'
statuses merge-review:success "qa:success:PASS R2 · linear:abc"
reset_logs
expect 0 '⑯ merge-review＋qa success → exit 0' '已晉升 main' test main
has   '⑯ 印 qa description' "$out" 'PASS R2 · linear:abc'
has   '⑯ 查的是 origin/test 的 combined status' "$(cat "$GH_STUB_LOG")" "commits/${dev2}/status"
is    '⑯ remote main 前進到 dev2' "$(rsha main)" "$dev2"

# ---- ⑰ status 端點失敗 → exit 2（fail closed）、不推；check-runs 端點正常也一樣 ----
g -C "$seed" checkout -q development; echo d3 > "$seed/d3.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'feat: LS-3 dev third'
g -C "$seed" push -q origin development
dev3=$(g -C "$seed" rev-parse development)
runs $ALL_GREEN
statuses merge-review:success qa:success
reset_logs
out="$(cd "$repo" && GH_STUB_FAIL_STATUS=1 bash "$promote" development test 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'commits/<sha>/status 失敗'; then echo "✓ ⑰ status 端點失敗 → exit 2"; else echo "✗ ⑰ status 端點失敗應 exit 2 並說明（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has   '⑰ check-runs 已查過（失敗在 status 那一步）' "$out" 'check rules: ✓ success'
no_push '⑰ status 端點失敗不推'
is    '⑰ remote test 未動' "$(rsha test)" "$dev2"
is    '⑰ development 已是 dev3（待晉升）' "$(rsha development)" "$dev3"

if [ "$fail" -ne 0 ]; then
  echo "✗ promote 自測失敗" >&2
  exit 1
fi
echo "✓ promote 自測通過（17 組樣本）"
