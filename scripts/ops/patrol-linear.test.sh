#!/bin/bash
# patrol-linear.sh／patrol_linear.py 的自測（LS-103）。CI rules job 跑（CI 沒有 LINEAR_API_KEY，跑的就是
# 這支自測本身，不是打真 API）。bash 3.2；不打真的 Linear——curl 用 PATH 前置的假身攔截，依 GraphQL
# body 裡的關鍵字（issues(／cycles(／documents(／"after": null／CURSOR1）回固定 fixture JSON，同
# post-status.test.sh／promote.test.sh 的 stub 慣例（記錄呼叫參數到 log，供斷言呼叫次數與分頁）。
#
# 覆蓋：候補排序（priority 同分取 size S→M→L 再 createdAt）、blockedBy 未 Done → 跳過、Canceled 視為
# 已解、缺 size 的 lane:harness 票列結構 (e)、cycle 外（非本 cycle）的 active 票列 cycle 對帳 (a)、
# LS-96 永遠不列為候補、分頁（兩頁 issues 合併）、無 LINEAR_API_KEY → 略過且不呼叫 curl。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plsh="${root}/scripts/ops/patrol-linear.sh"
fail=0
command -v python3 >/dev/null 2>&1 || { echo "✗ patrol-linear 自測需要 python3" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ---- 合成 repo（.env 放 LINEAR_API_KEY；patrol-linear.sh 的 ROOT 解到這裡）----
repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
: > "$repo/.gitkeep"; git -C "$repo" add .gitkeep; git -C "$repo" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo/.env"

# ---- 沒有 .env／沒有 LINEAR_API_KEY 的合成 repo（略過案例用）----
repo_no_token="$work/repo_no_token"
git init -q -b main "$repo_no_token"
git -C "$repo_no_token" config user.email test@example.com
git -C "$repo_no_token" config user.name Test
: > "$repo_no_token/.gitkeep"; git -C "$repo_no_token" add .gitkeep; git -C "$repo_no_token" -c commit.gpgsign=false commit -q -m 'chore: init'

# ---- fixtures：GraphQL 回應（stub curl 依 body 關鍵字挑一個回）----
fx="$work/fixtures"
mkdir -p "$fx"

# cycle 5＝目前 cycle（isActive true）；startsAt 故意設在很久以前（保證 age>=2 天，不看真實跑測時間）、
# endsAt 設在很久以後（保證不會被判成「剩 <24h」）——這兩個判定不看牆鐘、看固定字面值，測試才不會隨執行時間 flaky。
cat > "$fx/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[
  {"id":"cyc-5","number":5,"startsAt":"2020-01-01T00:00:00.000Z","endsAt":"2099-01-01T00:00:00.000Z","isActive":true},
  {"id":"cyc-4","number":4,"startsAt":"2019-01-01T00:00:00.000Z","endsAt":"2019-01-08T00:00:00.000Z","isActive":false}
]}}}}
EOF

cat > "$fx/documents.json" <<'EOF'
{"data":{"documents":{"nodes":[{"id":"doc-1","title":"Cycle 5 規劃"}]}}}
EOF

# page1：LS-201（size:M）、LS-202（size:S，priority 同分但 size 較小，排序應排 202 在 201 之前）、
# LS-203（blockedBy 未解——阻擋票 state.type=started）。hasNextPage=true，endCursor=CURSOR1。
cat > "$fx/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR1"},"nodes":[
  {"identifier":"LS-201","title":"harness A","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-02T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:M"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-202","title":"harness B","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-03T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:S"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-203","title":"harness blocked","description":"## 驗收\n過","priority":1,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:S"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[{"type":"blocks","issue":{"identifier":"LS-999","state":{"type":"started"}}}]}}
]}}}
EOF

# page2（after=CURSOR1）：LS-204（blockedBy 已 Canceled——視為已解，priority Urgent 應排第一）、
# LS-205（缺 size：候補排最後＋結構 (e) 命中）、LS-96（常駐待辦池，priority 故意設最高也永不列為候補，
# 但結構 (e) 一樣命中——它本身也是 lane:harness 缺 size）、LS-210（lane:backend、In Progress、
# cycle=4≠目前 cycle 5 → cycle 對帳 (a) 命中）。hasNextPage=false。
cat > "$fx/issues_page2.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-204","title":"harness C","description":"## 驗收\n過","priority":1,"createdAt":"2026-01-04T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:M"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[{"type":"blocks","issue":{"identifier":"LS-998","state":{"type":"canceled"}}}]}},
  {"identifier":"LS-205","title":"harness D 缺 size","description":"## 驗收\n過","priority":3,"createdAt":"2026-01-05T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-96","title":"Harness 待辦池","description":"常駐","priority":1,"createdAt":"2020-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"}]},
   "cycle":null,"project":null,"projectMilestone":null,"parent":null,"inverseRelations":{"nodes":[]}},
  {"identifier":"LS-210","title":"backend in progress","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"In Progress","type":"started"},"labels":{"nodes":[{"name":"lane:backend"}]},
   "cycle":{"id":"cyc-4","number":4},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF

# ---- stub curl：記錄 argv 到 log，依 --data 內容判斷回哪個 fixture 檔 ----
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<EOF
#!/bin/bash
log="\${CURL_STUB_LOG:?}"
fx="${fx}"
printf '%s\n' "\$*" >> "\$log"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'documents('*) cat "\$fx/documents.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'issues('*)
    case "\$data" in
      *'CURSOR1'*) cat "\$fx/issues_page2.json" ;;
      *'"after": null'*) cat "\$fx/issues_page1.json" ;;
      *) echo '{"errors":[{"message":"stub curl：認不出的 after cursor"}]}' ;;
    esac ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
export CURL_STUB_LOG="$work/curl.log"
export SIMCTL_LIST_JSON='{"devices":{}}'   # Booted 模擬器段沿用 patrol.sh，這裡不碰真 xcrun（同 patrol.test.sh 慣例）

# ---- ① 無 LINEAR_API_KEY → 略過、exit 0、不呼叫 curl ----
: > "$CURL_STUB_LOG"
out="$(bash "$plsh" --repo "$repo_no_token" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '略過（無 LINEAR_API_KEY）'; then
  echo "✓ ① 無 LINEAR_API_KEY → exit 0 且印略過"
else
  echo "✗ ① 應 exit 0 且印略過（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
if [ -s "$CURL_STUB_LOG" ]; then
  echo "✗ ① 不應呼叫 curl" >&2; sed 's/^/    /' "$CURL_STUB_LOG" >&2; fail=1
else
  echo "✓ ① 略過時不呼叫 curl"
fi
out_json="$(bash "$plsh" --repo "$repo_no_token" --json 2>&1)"
if printf '%s' "$out_json" | grep -qF '"skipped":true'; then echo "✓ ① --json 模式印 skipped:true"; else echo "✗ ① --json 應印 skipped:true（實得：${out_json}）" >&2; fail=1; fi

# ---- ② 正常跑一輪（有 token）：--json 拿完整結構，逐項斷言 ----
: > "$CURL_STUB_LOG"
out_json="$(bash "$plsh" --repo "$repo" --json 2>"$work/stderr2.log")"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "✗ ② 正常跑一輪應 exit 0（實得 ${rc}）" >&2
  sed 's/^/    stderr: /' "$work/stderr2.log" >&2
  printf '%s\n' "$out_json" | sed 's/^/    stdout: /' >&2
  fail=1
else
  echo "✓ ② 正常跑一輪 exit 0"
fi

export OUT_JSON="$out_json"
py_out="$(python3 - <<'PYEOF'
import json, os, sys
d = json.loads(os.environ["OUT_JSON"])
ok = True

def check(name, cond):
    global ok
    if cond:
        print("✓ " + name)
    else:
        print("✗ " + name)
        ok = False

check("② skipped=false", d.get("skipped") is False)
check("② current_cycle number=5", (d.get("current_cycle") or {}).get("number") == 5)

harness = d["lanes"]["lane:harness"]
check("② 候補排序（Canceled 視為已解，priority Urgent 排第一）",
      harness["candidates"][:1] == ["LS-204"])
check("② 候補排序（priority 同分，size S 排在 size M 之前：202 先於 201）",
      harness["candidates"].index("LS-202") < harness["candidates"].index("LS-201"))
check("② 候補排序（缺 size 排最後）", harness["candidates"][-1] == "LS-205")
check("② blockedBy 未 Done → 跳過（LS-203 不在候補）", "LS-203" not in harness["candidates"])
check("② LS-96 永不列為候補", "LS-96" not in harness["candidates"])
check("② lane:harness WIP=0、選中 LS-204、動作含 save_issue Ready",
      harness["wip"] == 0 and harness["chosen"] == "LS-204"
      and any("save_issue LS-204 state=Ready cycle=5" in a for a in harness["actions"]))

structure_e = set(d["structure"]["e"])
check("② 缺 size 的 lane:harness 票列結構 (e)（LS-205、LS-96 皆命中）",
      {"LS-205", "LS-96"} <= structure_e)

check("② cycle 外 active 票（LS-210，cycle=4≠目前 cycle 5）列 cycle 對帳 (a)",
      "LS-210" in d["cycle_check"]["a"])
check("② cycle 對帳 (a) 動作含 save_issue LS-210 cycle=5",
      any("save_issue LS-210 cycle=5" in a for a in d["actions"]))

print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py_out"
if printf '%s' "$py_out" | tail -1 | grep -qx OK; then :; else fail=1; fi

# ---- ③ 分頁：兩頁 issues 都被呼叫（after=null 與 after=CURSOR1 各一次）、cycles／documents 各呼叫過 ----
n_after_null=$(grep -cF '"after": null' "$CURL_STUB_LOG")
n_cursor1=$(grep -cF 'CURSOR1' "$CURL_STUB_LOG")
n_cycles=$(grep -cF 'cycles(' "$CURL_STUB_LOG")
n_docs=$(grep -cF 'documents(' "$CURL_STUB_LOG")
if [ "$n_after_null" -ge 1 ] && [ "$n_cursor1" -ge 1 ]; then echo "✓ ③ 分頁：after=null 與 CURSOR1 都被呼叫"; else echo "✗ ③ 分頁未涵蓋兩頁（after=null ${n_after_null} 次、CURSOR1 ${n_cursor1} 次）" >&2; fail=1; fi
if [ "$n_cycles" -ge 1 ]; then echo "✓ ③ cycles 查詢有呼叫"; else echo "✗ ③ cycles 查詢沒被呼叫" >&2; fail=1; fi
if [ "$n_docs" -ge 1 ]; then echo "✓ ③ documents 查詢有呼叫（cycle 對帳 (c)）"; else echo "✗ ③ documents 查詢沒被呼叫" >&2; fail=1; fi

# ---- ④ human／--brief 模式跑得動、不炸（格式細節已由 --json 斷言涵蓋，這裡只驗不crash＋含動作清單）----
out_human="$(bash "$plsh" --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out_human" | grep -qF '動作清單'; then echo "✓ ④ human 模式 exit 0 且含動作清單段"; else echo "✗ ④ human 模式異常（exit ${rc}）" >&2; printf '%s\n' "$out_human" | sed 's/^/    /' >&2; fail=1; fi
out_brief="$(bash "$plsh" --repo "$repo" --brief 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out_brief" | grep -qF 'save_issue LS-204 state=Ready cycle=5'; then echo "✓ ④ --brief 模式印動作清單（含 save_issue LS-204）"; else echo "✗ ④ --brief 模式異常（exit ${rc}）" >&2; printf '%s\n' "$out_brief" | sed 's/^/    /' >&2; fail=1; fi

# ---- ⑤ 參數錯誤 fail closed ----
out="$(bash "$plsh" --repo 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF -- '--repo 缺值'; then echo "✓ ⑤ --repo 缺值 → exit 2"; else echo "✗ ⑤ --repo 缺值應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out="$(bash "$plsh" --bogus 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '未知參數'; then echo "✓ ⑤ 未知參數 → exit 2"; else echo "✗ ⑤ 未知參數應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out="$(bash "$plsh" --repo "$work/nope" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then echo "✓ ⑤ --repo 不存在 → exit 2"; else echo "✗ ⑤ --repo 不存在應 exit 2（實得 ${rc}）" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ patrol-linear 自測失敗" >&2
  exit 1
fi
echo "✓ patrol-linear 自測通過"
