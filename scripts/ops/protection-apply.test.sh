#!/bin/bash
# protection-apply.sh 的自測（LS-478 新增；此前沒有自測）。假 gh（PATH shim）回罐頭 protection JSON，只跑 --dry-run，
# 不連 GitHub、不改任何設定。涵蓋 LS-478 範圍 6 的清單變更：
#   - test／main 的 request 含 android-lint／android-unit@15368，且「現況已等於目標」判定認得完整十一個 context；
#   - development 的 patch request 把 android-lint／android-unit 加進去（其餘 check 照 before、ci-ui-* 由 DEV_ADD 重建），
#     且重跑冪等（before 已含它們時不重複、不遺失）；
#   - 與 promote.sh REQUIRED_CHECKS 同步（兩處清單的差集為空）——LS-209 merge-review R1 M3 的事故形狀。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/protection-apply.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
command -v jq >/dev/null 2>&1 || { echo "⊘ protection-apply.test.sh：沒有 jq，SKIP"; exit 0; }

bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/gh" <<'STUB'
#!/bin/bash
# gh api <endpoint> [...]：protection GET 回 $FAKE_PROTECTION；collaborators 回空
case "$*" in
  *collaborators*) exit 0 ;;
  *"-X "*) echo "不該有寫入：$*" >> "$FAKE_WORK/WRITE"; exit 1 ;;
  *) cat "$FAKE_PROTECTION" ;;
esac
STUB
chmod +x "$bin/gh"
export FAKE_WORK="$work"
repo="$work/repo"; mkdir -p "$repo"; git -C "$repo" init -q

mkjson() {   # mkjson <out> <require_pr true|false> <context@app…>  （app: 數字或 any）
  local out=$1 pr=$2; shift 2
  local checks="" c ctx app
  for c in "$@"; do ctx=${c%@*}; app=${c#*@}; [ "$app" = any ] && app=null
    checks="${checks:+${checks},}{\"context\":\"${ctx}\",\"app_id\":${app}}"; done
  local prblock=null; [ "$pr" = true ] && prblock='{"required_approving_review_count":0}'
  cat > "$out" <<JSON
{"required_status_checks":{"strict":false,"checks":[${checks}]},"enforce_admins":{"enabled":true},
 "required_pull_request_reviews":${prblock},"restrictions":null,"required_linear_history":{"enabled":false},
 "allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}
JSON
}
dry() {   # dry <branch> <protection.json> → 輸出
  ( cd "$repo" && PATH="$bin:$PATH" FAKE_PROTECTION="$2" bash "$script" "$1" --dry-run --out "$work/out-$1" 2>&1 )
}
has() { grep -qF -- "$2" <<<"$1"; }

ALL10=(ci@15368 ci-ipad@15368 ci-ui-1@15368 ci-ui-2@15368 ci-ui-3@15368 db@15368 lint@15368 rules@15368 android-lint@15368 android-unit@15368 merge-review@any)
OLD8=(ci@15368 ci-ipad@15368 ci-ui-1@15368 ci-ui-2@15368 ci-ui-3@15368 db@15368 lint@15368 rules@15368 merge-review@any)

# ---- test／main（PUT 整份）----
mkjson "$work/tm-old.json" false "${OLD8[@]}"
out=$(dry main "$work/tm-old.json")
if has "$out" '"context": "android-lint"' && has "$out" '"context": "android-unit"'; then ok '① main request 含 android-lint／android-unit'; else bad '① main request 應含 android-lint／android-unit'; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
if has "$out" '現況已等於目標'; then bad '① 只有舊八個 check 時不該判「現況已等於目標」'; else ok '① 舊八個 check 的現況 → 判定需要套用（verify 認得新清單）'; fi
mkjson "$work/tm-new.json" false "${ALL10[@]}"
out=$(dry test "$work/tm-new.json")
if has "$out" '現況已等於目標'; then ok '② 十個 check＋merge-review 的現況 → 冪等（已等於目標）'; else bad '② 完整清單應判已等於目標'; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

# ---- development（PATCH required_status_checks）----
mkjson "$work/dev-old.json" true ci@15368 lint@any rules@any db@15368 ci-ui-1@15368 ci-ui-2@15368 ci-ui-3@15368 merge-review@any
out=$(dry development "$work/dev-old.json")
req="$work/out-development/protection-development-request.json"
got=$(jq -r '[.checks[].context] | sort | join(",")' "$req" 2>/dev/null)
want="android-lint,android-unit,ci,ci-ui-1,ci-ui-2,ci-ui-3,db,lint,merge-review,rules"
if [ "$got" = "$want" ]; then ok '③ development request：既有 check 保留＋加 android-lint／android-unit／merge-review'; else bad "③ development request contexts 不符：得「${got}」"; fi
if [ "$(jq -r '.checks[] | select(.context=="lint") | .app_id' "$req")" = "-1" ]; then ok '③ development 其餘 check 的 app_id 照現況（lint 的 null→-1，不順手收緊）'; else bad '③ lint 的 app_id 應維持 any(-1)'; fi
if [ "$(jq -r '.checks[] | select(.context=="android-lint") | .app_id' "$req")" = "15368" ]; then ok '③ android-lint@15368'; else bad '③ android-lint 應為 15368'; fi
mkjson "$work/dev-new.json" true ci@15368 lint@any rules@any db@15368 ci-ui-1@15368 ci-ui-2@15368 ci-ui-3@15368 android-lint@15368 android-unit@15368 merge-review@any
out=$(dry development "$work/dev-new.json")
req="$work/out-development/protection-development-request.json"
cnt=$(jq -r '[.checks[] | select(.context=="android-lint")] | length' "$req")
if [ "$cnt" = 1 ] && has "$out" '現況已等於目標'; then ok '④ development 已含 android check 時重跑冪等（不重複、判已等於目標）'; else bad "④ 冪等失敗（android-lint 出現 ${cnt} 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

# ---- 與 promote.sh 同步 ----
promote_set=$(sed -n 's/^REQUIRED_CHECKS="\(.*\)"/\1/p' "$root/scripts/ops/promote.sh" | tr ' ' '\n' | sort)
apply_set=$(sed -n '/^CHECKS_JSON=/,/^  }'"'"'/p' "$script" | grep -oE '"context": "[^"]+"' | sed 's/.*: "//;s/"//' | grep -vx merge-review | sort)
if [ -n "$promote_set" ] && [ "$promote_set" = "$apply_set" ]; then ok '⑤ promote.sh REQUIRED_CHECKS 與 protection-apply.sh CHECKS_JSON 同步'; else bad '⑤ 兩處 required 清單不同步'; diff <(echo "$promote_set") <(echo "$apply_set") >&2; fi
# ---- required 清單 ↔ ci.yml（LS-478 範圍 6）：每個 required check 在 ci.yml 都有對應 job；android-lint／android-unit 沒有 job 層 if ----
ci_yml="$root/.github/workflows/ci.yml"
job_block() { awk -v j="$1" '$0 ~ "^  "j":$" {f=1; next} f && /^  [A-Za-z0-9_-]+:/ {exit} f {print}' "$ci_yml"; }
missing=""
for c in $promote_set; do
  key=$c; case "$c" in ci-ui-[0-9]*) key=ci-ui ;; esac
  grep -qE "^  ${key}:" "$ci_yml" || missing="$missing $c"
done
if [ -z "$missing" ]; then ok '⑦ promote.sh REQUIRED_CHECKS 每一個在 ci.yml 都有對應 job（ci-ui-N 對 ci-ui matrix）'; else bad "⑦ ci.yml 缺 job：${missing}"; fi
for j in android-lint android-unit; do
  blk=$(job_block "$j")
  if [ -z "$blk" ]; then bad "⑦ 找不到 ${j} job 區塊"
  elif grep -qE '^    if:' <<<"$blk"; then bad "⑦ ${j} 不得有 job 層 if（required check 被 skipped 會讓 promote.sh 拒收；早退要放 step 層）"
  else ok "⑦ ${j} 無 job 層 if（永遠建立 check-run）"; fi
done
[ ! -e "$work/WRITE" ] && ok '⑥ 全程 --dry-run：沒有任何寫入呼叫' || bad '⑥ 出現寫入呼叫'

[ "$fail" -eq 0 ] || { echo "✗ protection-apply.test.sh：有失敗" >&2; exit 1; }
echo "✓ protection-apply.test.sh：${n} 項通過"
