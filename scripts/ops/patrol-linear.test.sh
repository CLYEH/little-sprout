#!/bin/bash
# patrol-linear.sh／patrol_linear.py 的自測（LS-103）。CI rules job 跑（CI 沒有 LINEAR_API_KEY，跑的就是
# 這支自測本身，不是打真 API）。bash 3.2；不打真的 Linear——curl 用 PATH 前置的假身攔截，依 GraphQL
# body 裡的關鍵字（issues(／cycles(／documents(／"after": null／CURSOR1）回固定 fixture JSON，同
# post-status.test.sh／promote.test.sh 的 stub 慣例（記錄呼叫參數到 log，供斷言呼叫次數與分頁）。
#
# 覆蓋：候補排序（priority 同分取 size S→M→L 再 createdAt）、blockedBy 未 Done → 跳過、Canceled 視為
# 已解、缺 size 的 lane:harness 票列結構 (e)、cycle 外（非本 cycle）的 active 票列 cycle 對帳 (a)、
# LS-96 永遠不列為候補、分頁（兩頁 issues 合併）、無 LINEAR_API_KEY → 略過且不呼叫 curl。
# ⑩（LS-144 開票責任）：lane 空＋無候補 → 印「→ 開票」並列來源；lane 空＋候補全 hold:user → 印開票行且註明
# 「使用者裁決」；lane 有在飛 → 不印；第二輪升 ⚠（.claude/patrol-state.json 計數）；「需 Design gate」票歸
# 待Design 不進候補；設計票（open 或已 Done）已承接的 Story 不列；LS-96 池項 P1／P2 才列、被票引用或池內銷除
# 不列；附加查詢失敗 fail-soft（JSON 仍合法、行內註明）。R1 負樣本：「不需 Design gate」／「另票，需 Design gate」
# 票不得進待Design（F1）；銷除公告自身引述「P1 ·」不列、P3 池項文中引用「P1 ·」不升級（F2）；Canceled 設計票不算承接（F3）。
# R2 負樣本：混級 comment（`- P3 ·` 後接 `- P2 ·`）以最小級 P2 列出（N1）；「**UI 票：需先過 Design gate**」變體歸待Design、
# 「**UI 票：不需 Design gate**」不歸（N2）；公告不以「銷除」開頭（日期／票號起頭）仍被跳過（N3）。
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

# R1 F1：cycle 5 底下的票 state（不受 ISSUES_QUERY 的 nin completed/canceled 限制）——2 completed、
# 1 started、1 backlog，總數 4、完成 2，供「票數 完成/總數」斷言用。
cat > "$fx/cycle_issues.json" <<'EOF'
{"data":{"cycle":{"issues":{"nodes":[
  {"state":{"type":"completed"}},
  {"state":{"type":"completed"}},
  {"state":{"type":"started"}},
  {"state":{"type":"backlog"}}
]}}}}
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
# R1 I1 起結構 (e) 豁免它——它自己也缺 size 但不該再被列出）、LS-210（lane:backend、In Progress、
# cycle=4≠目前 cycle 5 → cycle 對帳 (a) 命中）、LS-206（缺「## 驗收」→ R1 F1 待 Spec）、
# LS-207（缺 project → R1 F1 待結構）、LS-211（R1 I2：lane:backend、Backlog、cycle=4≠目前 cycle 5，
# 是該 lane 唯一候補但在 cycle 外 → needs_scope_plus，human/brief 應標「cycle 外，取第一張需 scope+」）。
# hasNextPage=false。
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
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-206","title":"harness 缺驗收段","description":"沒有驗收段落","priority":2,"createdAt":"2026-01-06T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:S"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-207","title":"harness 缺 project","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-07T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:S"}]},
   "cycle":{"id":"cyc-5","number":5},"project":null,"projectMilestone":null,"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-211","title":"backend cycle 外候補","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-08T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:backend"}]},
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
  *'comments('*) echo '{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
  *'documents('*) cat "\$fx/documents.json" ;;
  *'cycle(id:'*) cat "\$fx/cycle_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'type: { in: ['*) echo '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
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

# ---- ②b R1 F3：token 不進 curl argv（stub curl 把完整 argv 記進 log，token 只能走 stdin config）----
if grep -qF 'test-token-not-real' "$CURL_STUB_LOG"; then
  echo "✗ ②b token 出現在 curl argv（應只走 stdin --config，見 R1 F3）" >&2
  sed 's/^/    /' "$CURL_STUB_LOG" >&2
  fail=1
else
  echo "✓ ②b token 沒有出現在 curl argv"
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
check("② 缺 size 的 lane:harness 票列結構 (e)（LS-205 命中）", "LS-205" in structure_e)
check("② R1 I1：LS-96 常駐待辦池結構檢查豁免，不列 (e)（否則永遠清不掉、訓練出忽略習慣）",
      "LS-96" not in structure_e)

check("② R1 F1：current_cycle 附帶剩餘天數／票數 完成-總數",
      isinstance((d.get("current_cycle") or {}).get("remaining_days"), (int, float))
      and (d["current_cycle"]["tickets_done"], d["current_cycle"]["tickets_total"]) == (2, 4))

check("② R1 F1：LS-206 缺「## 驗收」→ pending_spec 命中", "LS-206" in harness.get("pending_spec", []))
check("② R1 F1：LS-207 缺 project → pending_structure 命中", "LS-207" in harness.get("pending_structure", []))
check("② R1 F1：LS-206／LS-207 分類被排除，不進候補清單",
      "LS-206" not in harness["candidates"] and "LS-207" not in harness["candidates"])

check("② cycle 外 active 票（LS-210，cycle=4≠目前 cycle 5）列 cycle 對帳 (a)",
      "LS-210" in d["cycle_check"]["a"])
check("② cycle 對帳 (a) 動作含 save_issue LS-210 cycle=5",
      any("save_issue LS-210 cycle=5" in a for a in d["actions"]))

check("② R1 F5：cycle 對帳 (b)（LS-203 在目前 cycle 內、Backlog、blockedBy 未解）命中",
      "LS-203" in d["cycle_check"]["b"])

backend = d["lanes"]["lane:backend"]
check("② R1 I2：lane:backend 唯一候補 LS-211 在 cycle 外 → needs_scope_plus",
      backend["candidates"] == ["LS-211"] and backend["needs_scope_plus"] is True)
check("② R1 I2：lane:backend 選中 LS-211，動作含 scope+ 與 Ready 兩行",
      backend["chosen"] == "LS-211"
      and any("save_issue LS-211 cycle=5（scope+，取自 cycle 外）" in a for a in backend["actions"])
      and any("save_issue LS-211 state=Ready cycle=5" in a for a in backend["actions"]))

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

# ---- ④b R1 F1：human／--brief 的 lane 表五欄（上限／在飛／候補／待Spec／待結構）與 cycle 一行
#        （編號／剩餘天數／票數 完成/總數）都要印出來——不是只在 --json 才有 ----
has_in() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
has_in '④b human：cycle 一行含編號與票數 完成/總數' "$out_human" 'current cycle：5（剩'
has_in '④b human：cycle 一行含票數 2/4 完成' "$out_human" '票數 2/4 完成'
has_in '④b human：lane:harness 行含待 Spec（LS-206）' "$out_human" '待Spec：LS-206'
has_in '④b human：lane:harness 行含待結構（LS-207）' "$out_human" '待結構：LS-207'
has_in '④b --brief：也印 Lane 狀態表與待 Spec／待結構' "$out_brief" '待Spec：LS-206'
has_in '④b --brief：cycle 一行同樣在（不是只有 --json 才有）' "$out_brief" 'current cycle：5（剩'
has_in '④b R1 I2：human lane:backend 候補標示 cycle 外需 scope+' "$out_human" 'LS-211（cycle 外，取第一張需 scope+）'
has_in '④b R1 I2：--brief 同樣標示 cycle 外 scope+' "$out_brief" 'LS-211（cycle 外，取第一張需 scope+）'

# ---- ⑤ 參數錯誤 fail closed ----
out="$(bash "$plsh" --repo 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF -- '--repo 缺值'; then echo "✓ ⑤ --repo 缺值 → exit 2"; else echo "✗ ⑤ --repo 缺值應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out="$(bash "$plsh" --bogus 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '未知參數'; then echo "✓ ⑤ 未知參數 → exit 2"; else echo "✗ ⑤ 未知參數應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out="$(bash "$plsh" --repo "$work/nope" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then echo "✓ ⑤ --repo 不存在 → exit 2"; else echo "✗ ⑤ --repo 不存在應 exit 2（實得 ${rc}）" >&2; fail=1; fi

# ---- ⑥ R1 F5：fail-loud 負向控制（GraphQL errors／curl 非 0 exit／非法 JSON／缺 data 物件）----
# 用一支獨立的假 curl（依 CURL_FAIL_MODE 決定回應），只在單一指令前綴 PATH 蓋過 $work/bin，不影響
# 其他測項；重用 $repo（已有 .env token）即可，這幾種失敗都在 gql() 第一次呼叫（issues 查詢）就會炸。
mkdir -p "$work/bin_fail"
cat > "$work/bin_fail/curl" <<'EOF'
#!/bin/bash
mode="${CURL_FAIL_MODE:?}"
case "$mode" in
  errors) echo '{"errors":[{"message":"stub：模擬 GraphQL 錯誤"}]}' ;;
  badjson) echo '不是 JSON' ;;
  nulldata) echo '{"data":null}' ;;
  exit7) exit 7 ;;
esac
EOF
chmod +x "$work/bin_fail/curl"

# R2 m3：只驗 rc -eq 1 沒有鑑別力——fetch_issues() 對 None 取 subscript 也會拋 TypeError、Python
# 同樣 exit 1（把 R2 新加的 gql() 缺 data 檢查那 5 行整段移除後重跑，這四組原本仍全綠）。改成每組
# 都額外驗訊息內容含各自的 fail-loud 字樣（且不是原始 Traceback），才能真的守住各自的錯誤路徑。
check_fail_mode() {
  local label="$1" mode="$2" want_substr="$3" out rc
  out="$(CURL_FAIL_MODE="$mode" PATH="$work/bin_fail:$PATH" bash "$plsh" --repo "$repo" --json 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "✓ ⑥ ${label} → exit 1（fail loud）"
  else
    echo "✗ ⑥ ${label} 應 exit 1（實得 ${rc}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
  if printf '%s' "$out" | grep -qF "$want_substr"; then
    echo "✓ ⑥ ${label} 訊息含「${want_substr}」（非 Traceback，斷言有鑑別力）"
  else
    echo "✗ ⑥ ${label} 訊息應含「${want_substr}」（可能只是巧合 exit 1，非預期的 fail-loud 路徑）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
check_fail_mode 'GraphQL errors 欄位' errors 'GraphQL 錯誤'
check_fail_mode 'curl 非 0 exit（連線失敗）' exit7 'curl 失敗'
check_fail_mode '回應不是合法 JSON' badjson '不是合法 JSON'
check_fail_mode 'R1 F5：合法 JSON 但缺 data 物件（{"data":null}）' nulldata '缺少可用的 data 物件'

# ---- ⑥b --closed（LS-187：patrol.sh 專屬模擬器段問「這些票號哪些已 Done／Canceled」）：獨立假 curl 回 number in [...] 查詢的
#        fixture（LS-90 Done／LS-3 In Progress——後者伺服器端本該被 state filter 濾掉，這裡故意回來驗 python 仍只印
#        completed／canceled）；stdout 每行「LS-<n>\t<state.name>」；token 不進 argv；body 帶排序去重後的票號；只打一次 curl；
#        無 key → exit 3、stdout 空；票號格式錯／空值 → exit 2。（不回頭呼叫 patrol.sh 這點靠 patrol.test.sh ㉓ 的 --linear
#        路徑整條跑通來守：若遞迴，那裡的假身呼叫次數就不會是 1。）----
mkdir -p "$work/bin_closed"
cat > "$work/bin_closed/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_STUB_LOG:?}"
cat >/dev/null
data=""
while [ $# -gt 0 ]; do case "$1" in --data) data=$2; shift ;; esac; shift; done
case "$data" in
  *'number: { in: $numbers }'*) echo '{"data":{"issues":{"nodes":[{"identifier":"LS-90","state":{"name":"Done","type":"completed"}},{"identifier":"LS-3","state":{"name":"In Progress","type":"started"}},{"identifier":"LS-7","state":{"name":"Canceled","type":"canceled"}}]}}}' ;;
  *) echo '{"errors":[{"message":"stub curl：--closed 不該打別的查詢"}]}' ;;
esac
EOF
chmod +x "$work/bin_closed/curl"
: > "$CURL_STUB_LOG"
out_closed="$(PATH="$work/bin_closed:$PATH" bash "$plsh" --closed 90,3,90,7 --repo "$repo" 2>"$work/stderr_closed.log")"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑥b --closed exit 0"; else echo "✗ ⑥b --closed 應 exit 0（實得 ${rc}）" >&2; sed 's/^/    /' "$work/stderr_closed.log" >&2; fail=1; fi
if [ "$out_closed" = "$(printf 'LS-7\tCanceled\nLS-90\tDone')" ]; then echo "✓ ⑥b stdout 只含 completed／canceled、每行 LS-<n>\\t<state.name>、依票號排序"; else echo "✗ ⑥b stdout 不符：$(printf '%s' "$out_closed" | od -c | head -3)" >&2; fail=1; fi
n_curl=$(grep -c . "$CURL_STUB_LOG" 2>/dev/null || true); [ "${n_curl:-0}" -eq 1 ] && echo "✓ ⑥b 只打一次 curl（批次）" || { echo "✗ ⑥b 應只打一次 curl（實得 ${n_curl:-0}）" >&2; fail=1; }
grep -qF '"numbers": [3, 7, 90]' "$CURL_STUB_LOG" && echo "✓ ⑥b body 帶排序去重後的票號 [3, 7, 90]" || { echo "✗ ⑥b body 應帶 [3, 7, 90]：$(cat "$CURL_STUB_LOG")" >&2; fail=1; }
grep -qF 'test-token-not-real' "$CURL_STUB_LOG" && { echo "✗ ⑥b token 出現在 curl argv" >&2; fail=1; } || echo "✓ ⑥b token 不進 curl argv"
out_closed_nokey="$(bash "$plsh" --closed 90 --repo "$repo_no_token" 2>"$work/stderr_closed_nokey.log")"; rc=$?
if [ "$rc" -eq 3 ] && [ -z "$out_closed_nokey" ] && grep -qF '略過（無 LINEAR_API_KEY）' "$work/stderr_closed_nokey.log"; then echo "✓ ⑥b 無 key → exit 3、stdout 空、stderr 說略過"; else echo "✗ ⑥b 無 key 應 exit 3 且 stdout 空（實得 rc=${rc}、stdout=${out_closed_nokey}）" >&2; fail=1; fi
out_closed_bad="$(bash "$plsh" --closed '90,abc' --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out_closed_bad" | grep -qF '票號數字'; then echo "✓ ⑥b 票號格式錯 → exit 2"; else echo "✗ ⑥b 票號格式錯應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out_closed_empty="$(bash "$plsh" --closed '' --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then echo "✓ ⑥b --closed 空值 → exit 2"; else echo "✗ ⑥b --closed 空值應 exit 2（實得 ${rc}）" >&2; fail=1; fi

# ---- ⑦ R1 F5：cycle 對帳 (d)（剩餘時間 <24h）——用執行當下算出的動態時間戳，不寫死日期，
#        避免測試在特定日期之後失效；獨立 repo／fixture，不與 ② 的固定 2099 endsAt 互相干擾 ----
repo_d="$work/repo_d"
git init -q -b main "$repo_d"
git -C "$repo_d" config user.email test@example.com
git -C "$repo_d" config user.name Test
: > "$repo_d/.gitkeep"; git -C "$repo_d" add .gitkeep; git -C "$repo_d" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_d/.env"

fx_d="$work/fixtures_d"
mkdir -p "$fx_d"
now_epoch=$(date -u +%s)
end_epoch=$((now_epoch + 36000))     # 10 小時後 → remaining_h ≈10 <24，應觸發 (d)
start_epoch=$((now_epoch - 259200))  # 3 天前，只是避免 age_days 判定跑到非預期分支
# R2 B2：`date -u -r <epoch>` 是 BSD/macOS 語法；ubuntu CI 的 GNU coreutils 把 `-r` 當「讀檔案
# mtime」，epoch 數字被當檔名找不到檔案 → 印 iso 空字串，fixture 的 endsAt 跟著空、(d) 測項在 CI
# 上永遠不命中。改用同 repo patrol.test.sh:336 已有的可攜寫法：BSD 語法失敗（GNU 環境）就 fallback
# GNU 的 `date -u -d "@<epoch>"`。
end_iso=$(date -u -r "$end_epoch" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "@${end_epoch}" +"%Y-%m-%dT%H:%M:%S.000Z")
start_iso=$(date -u -r "$start_epoch" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "@${start_epoch}" +"%Y-%m-%dT%H:%M:%S.000Z")
cat > "$fx_d/cycles.json" <<EOF
{"data":{"team":{"cycles":{"nodes":[
  {"id":"cyc-9","number":9,"startsAt":"${start_iso}","endsAt":"${end_iso}","isActive":true}
]}}}}
EOF
cat > "$fx_d/documents.json" <<'EOF'
{"data":{"documents":{"nodes":[{"id":"doc-9","title":"Cycle 9 規劃"}]}}}
EOF
cat > "$fx_d/cycle_issues.json" <<'EOF'
{"data":{"cycle":{"issues":{"nodes":[]}}}}
EOF
cat > "$fx_d/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}
EOF
mkdir -p "$work/bin_d"
cat > "$work/bin_d/curl" <<EOF
#!/bin/bash
fx="${fx_d}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'documents('*) cat "\$fx/documents.json" ;;
  *'cycle(id:'*) cat "\$fx/cycle_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin_d/curl"

out_d="$(PATH="$work/bin_d:$PATH" bash "$plsh" --repo "$repo_d" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "✓ ⑦ cycle (d) fixture 跑一輪 exit 0"
else
  echo "✗ ⑦ cycle (d) fixture 應 exit 0（實得 ${rc}）" >&2
  printf '%s\n' "$out_d" | sed 's/^/    /' >&2
  fail=1
fi
if printf '%s' "$out_d" | grep -qF 'Cycle 9 剩'; then
  echo "✓ ⑦ R1 F5：cycle 對帳 (d) 命中（剩 <24h）"
else
  echo "✗ ⑦ cycle 對帳 (d) 應命中（剩 <24h）" >&2
  printf '%s\n' "$out_d" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ⑧ R1 F2：design_forced_full()／pen_open_status()——ui 票 In Progress 讀取 Pen 時
#        design lane 視為滿（wip=limit），不會誤補派 design 票。獨立 repo／worktree／fixture。----
repo_pen="$work/repo_pen"
git init -q -b main "$repo_pen"
git -C "$repo_pen" config user.email test@example.com
git -C "$repo_pen" config user.name Test
: > "$repo_pen/.gitkeep"; git -C "$repo_pen" add .gitkeep; git -C "$repo_pen" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_pen/.env"

# LS-950 這張 ui 票的 worktree：worktree_tickets() 靠資料夾名稱 LS-<n> 辨識；want_path 取
# git 實際回報的路徑（不用 bash cd/pwd 自算，避免 macOS /tmp↔/private/tmp 之類的 symlink
# 正規化落差讓 os.path.realpath() 比對不到）。
git -C "$repo_pen" worktree add -q "$work/wt/LS-950" -b ls950-branch
mkdir -p "$work/wt/LS-950/design"
: > "$work/wt/LS-950/design/littlesprout.pen"
wt_reported=$(git -C "$repo_pen" worktree list --porcelain | awk '/^worktree /{print $2}' | grep '/LS-950$')
want_path="${wt_reported}/design/littlesprout.pen"

fx_pen="$work/fixtures_pen"
mkdir -p "$fx_pen"
cat > "$fx_pen/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[
  {"id":"cyc-5","number":5,"startsAt":"2020-01-01T00:00:00.000Z","endsAt":"2099-01-01T00:00:00.000Z","isActive":true}
]}}}}
EOF
cat > "$fx_pen/documents.json" <<'EOF'
{"data":{"documents":{"nodes":[{"id":"doc-1","title":"Cycle 5 規劃"}]}}}
EOF
cat > "$fx_pen/cycle_issues.json" <<'EOF'
{"data":{"cycle":{"issues":{"nodes":[]}}}}
EOF
# LS-950：lane:ui、In Progress（design_forced_full 的觸發條件）。LS-951：lane:design、Backlog，
# 票文完整（有效候補）——用來檢驗「design lane 被判定為滿時不會選中它」。
cat > "$fx_pen/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-950","title":"ui 讀稿中","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"In Progress","type":"started"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-951","title":"design 候補","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-02T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:design"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF
mkdir -p "$work/bin_pen"
cat > "$work/bin_pen/curl" <<EOF
#!/bin/bash
fx="${fx_pen}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'documents('*) cat "\$fx/documents.json" ;;
  *'cycle(id:'*) cat "\$fx/cycle_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin_pen/curl"

assert_design_lane() {
  local label="$1" out_var="$2" want_wip_forced="$3" out
  out="$(eval "printf '%s' \"\$$out_var\"")"
  export ASSERT_DESIGN_OUT="$out"
  local py
  py="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["ASSERT_DESIGN_OUT"])
design = d["lanes"]["lane:design"]
print("%s\t%s\t%s" % (design["wip"], design["limit"], design["chosen"]))
PYEOF
)"
  local wip limit chosen
  wip=$(printf '%s' "$py" | cut -f1)
  limit=$(printf '%s' "$py" | cut -f2)
  chosen=$(printf '%s' "$py" | cut -f3)
  if [ "$want_wip_forced" = yes ]; then
    if [ "$wip" = "$limit" ] && [ "$chosen" = None ]; then
      echo "✓ ${label}（wip=${wip}=limit，未選中 LS-951）"
    else
      echo "✗ ${label} 失敗（wip=${wip} limit=${limit} chosen=${chosen}）" >&2
      fail=1
    fi
  else
    if [ "$wip" = 0 ] && [ "$chosen" = LS-951 ]; then
      echo "✓ ${label}（wip=0，正常選中 LS-951）"
    else
      echo "✗ ${label} 失敗（wip=${wip} limit=${limit} chosen=${chosen}）" >&2
      fail=1
    fi
  fi
}

# ⑧a：pen-open.sh --status 回傳的路徑就是這張 ui 票 worktree 的 .pen → design lane 視為滿
mkdir -p "$work/bin_pen_status_hit"
cat > "$work/bin_pen_status_hit/pen-open.sh" <<EOF
#!/bin/bash
echo "${want_path}"
EOF
chmod +x "$work/bin_pen_status_hit/pen-open.sh"
out_pen_a="$(PEN_OPEN_SH="$work/bin_pen_status_hit/pen-open.sh" PATH="$work/bin_pen:$PATH" bash "$plsh" --repo "$repo_pen" --json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "✗ ⑧a 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_pen_a" | sed 's/^/    /' >&2; fail=1; fi
assert_design_lane '⑧a R1 F2：pen-open.sh --status 命中 → design lane 視為滿' out_pen_a yes

# ⑧b：pen-open.sh --status 查不到（exit 非 0）、也沒有近期 backup → design lane 不視為滿
mkdir -p "$work/bin_pen_status_miss"
cat > "$work/bin_pen_status_miss/pen-open.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$work/bin_pen_status_miss/pen-open.sh"
backup_dir_empty="$work/pen-backup-empty"
mkdir -p "$backup_dir_empty"
out_pen_b="$(PEN_OPEN_SH="$work/bin_pen_status_miss/pen-open.sh" PEN_BACKUP_DIR="$backup_dir_empty" PATH="$work/bin_pen:$PATH" bash "$plsh" --repo "$repo_pen" --json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "✗ ⑧b 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_pen_b" | sed 's/^/    /' >&2; fail=1; fi
assert_design_lane '⑧b R1 F2：查不到 active 路徑也無近期 backup → design lane 不視為滿' out_pen_b no

# ⑧c：active 路徑查不到，但該 .pen 的 autosave backup mtime 在 30 分鐘內 → 也視為滿
backup_dir_hit="$work/pen-backup-hit"
mkdir -p "$backup_dir_hit"
sha=$(python3 -c "import hashlib,sys; print(hashlib.sha1(('file://'+sys.argv[1]).encode('utf-8')).hexdigest())" "$want_path")
: > "$backup_dir_hit/$sha"
out_pen_c="$(PEN_OPEN_SH="$work/bin_pen_status_miss/pen-open.sh" PEN_BACKUP_DIR="$backup_dir_hit" PATH="$work/bin_pen:$PATH" bash "$plsh" --repo "$repo_pen" --json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "✗ ⑧c 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_pen_c" | sed 's/^/    /' >&2; fail=1; fi
assert_design_lane '⑧c R1 F2：active 路徑查不到但 autosave backup mtime 30 分鐘內 → design lane 仍視為滿' out_pen_c yes

# ---- ⑨ R2 m1：current cycle 無法判定（cycles 查詢為空，沒有 active 也沒有 upcoming）時，
#        lane 補位不應選中候補、不應印出 "cycle=?"（之前 lane_candidates() 的 current_cycle_number
#        為 None 時，會把 cycle 也是 null 的候補誤判成「在目前 cycle 內」而選中並印不可執行的動作行）----
repo_none="$work/repo_none"
git init -q -b main "$repo_none"
git -C "$repo_none" config user.email test@example.com
git -C "$repo_none" config user.name Test
: > "$repo_none/.gitkeep"; git -C "$repo_none" add .gitkeep; git -C "$repo_none" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_none/.env"

fx_none="$work/fixtures_none"
mkdir -p "$fx_none"
cat > "$fx_none/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[]}}}}
EOF
# LS-960：lane:harness、Backlog、cycle=null（尚未排 cycle）、票文完整（classify_candidate 應為 ok）。
cat > "$fx_none/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-960","title":"harness 尚未排 cycle","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"},{"name":"size:S"}]},
   "cycle":null,"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF
mkdir -p "$work/bin_none"
cat > "$work/bin_none/curl" <<EOF
#!/bin/bash
fx="${fx_none}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：不應被呼叫（current 為 None 時不查 documents／cycle issues）"}]}' ;;
esac
EOF
chmod +x "$work/bin_none/curl"

out_none_json="$(PATH="$work/bin_none:$PATH" bash "$plsh" --repo "$repo_none" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑨ current 為 None 的 fixture 跑一輪 exit 0"; else echo "✗ ⑨ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_none_json" | sed 's/^/    /' >&2; fail=1; fi

export OUT_NONE_JSON="$out_none_json"
py_none="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT_NONE_JSON"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False

check("⑨ current_cycle 為 null", d.get("current_cycle") is None)
harness = d["lanes"]["lane:harness"]
check("⑨ current 為 None 時不選中候補（chosen 仍是 None）", harness["chosen"] is None)
check("⑨ current 為 None 時不產生動作（actions 為空）", harness["actions"] == [])
# LS-144：design／ui／backend 三 lane 在這個 fixture 裡都是空的，會印「→ 開票」提醒行——那是提醒、不是派工，
# 本項守的是「current 未知時不派」，所以只驗沒有任何 save_issue 動作。
check("⑨ 全部動作清單不含任何派工動作（current 未知，跨 lane 皆不派；「→ 開票」提醒不算派工）",
      not any("save_issue" in a for a in d["actions"]))
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py_none"
if printf '%s' "$py_none" | tail -1 | grep -qx OK; then :; else fail=1; fi
if printf '%s' "$out_none_json" | grep -qF 'cycle=?'; then
  echo "✗ ⑨ JSON 輸出不應出現 cycle=?（不可執行的動作字面）" >&2; fail=1
else
  echo "✓ ⑨ JSON 輸出不含 cycle=?"
fi

out_none_human="$(PATH="$work/bin_none:$PATH" bash "$plsh" --repo "$repo_none" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out_none_human" | grep -qF 'current cycle：無法判定'; then
  echo "✓ ⑨ human 模式印「current cycle：無法判定」"
else
  echo "✗ ⑨ human 模式應印「current cycle：無法判定」（exit ${rc}）" >&2
  printf '%s\n' "$out_none_human" | sed 's/^/    /' >&2
  fail=1
fi
if printf '%s' "$out_none_human" | grep -qF 'cycle=?'; then
  echo "✗ ⑨ human 輸出不應出現 cycle=?" >&2; fail=1
else
  echo "✓ ⑨ human 輸出不含 cycle=?"
fi

# ---- ⑩ LS-144 開票責任：lane 空＋無候補／候補全 hold:user → 印「→ 開票」並列來源；lane 有在飛 → 不印；
#        連續空第二輪升 ⚠；「需 Design gate」歸待Design；設計票已承接的 Story 不列；池項 P1／P2 才列、
#        被票引用或池內銷除不列；附加查詢（已結案票／LS-96 comments）失敗 fail-soft ----
repo_ot="$work/repo_ot"
git init -q -b main "$repo_ot"
git -C "$repo_ot" config user.email test@example.com
git -C "$repo_ot" config user.name Test
: > "$repo_ot/.gitkeep"; git -C "$repo_ot" add .gitkeep; git -C "$repo_ot" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_ot/.env"

fx_ot="$work/fixtures_ot"
mkdir -p "$fx_ot"
cat > "$fx_ot/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[
  {"id":"cyc-5","number":5,"startsAt":"2020-01-01T00:00:00.000Z","endsAt":"2099-01-01T00:00:00.000Z","isActive":true}
]}}}}
EOF
cat > "$fx_ot/documents.json" <<'EOF'
{"data":{"documents":{"nodes":[{"id":"doc-1","title":"Cycle 5 規劃"}]}}}
EOF
cat > "$fx_ot/cycle_issues.json" <<'EOF'
{"data":{"cycle":{"issues":{"nodes":[]}}}}
EOF
# open 票：
#   LS-970 lane:ui Backlog Story「需 Design gate」、票文完整、無設計票 → 待Design、design／ui 開票來源
#   LS-971 同上，但 LS-972（lane:design、In Progress、parent=LS-971）已承接 → 不列來源；design lane 在飛 1 → 不印開票
#   LS-973 lane:backend Backlog、票文完整、hold:user → 不進候補；backend lane 候補全被擋 → 印開票並註明使用者裁決
#   LS-974 lane:ui Backlog Story「需 Design gate」＋票文含「RPC」、無 backend 子票 → design／ui 來源＋backend 來源
#   LS-975 lane:ui Backlog Story「需 Design gate」，已結案設計票 LS-981 標題整字提到它 → 不列來源
#   LS-976 lane:product Story 含「RLS」關鍵字，已結案 backend 子票 LS-977（parent=LS-976）→ 不列 backend 來源
#   LS-96  常駐待辦池（skip）→ harness lane 無候補 → 印開票並列池項來源
cat > "$fx_ot/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-970","title":"Story：孩子檔案 CRUD","description":"PLAN。**UI 票：需 Design gate**（孩子卡片）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-971","title":"Story：相簿與上傳","description":"**UI 票：需 Design gate**\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-02T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-972","title":"設計：相簿頁（LS-971 畫面群）","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-03T00:00:00.000Z",
   "state":{"name":"In Progress","type":"started"},"labels":{"nodes":[{"name":"lane:design"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":{"identifier":"LS-971"},
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-973","title":"backend 使用者裁決中","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-04T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:backend"},{"name":"hold:user"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-974","title":"Story：帳號刪除","description":"**UI 票：需 Design gate**。刪除帳號 RPC（service_role）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-05T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-975","title":"Story：登入","description":"**UI 票：需 Design gate**\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-06T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-976","title":"Story：家庭","description":"家庭 RLS policy。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-07T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:product"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-96","title":"Harness 待辦池","description":"常駐","priority":1,"createdAt":"2020-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"}]},
   "cycle":null,"project":null,"projectMilestone":null,"parent":null,"inverseRelations":{"nodes":[]}}
]}}}
EOF
# 已結案票（輕量查詢）：LS-980 票文引用池項 bbbbbbbb → 該池項已升票；LS-981 lane:design Done 標題提到 LS-975；
# LS-977 lane:backend Done、parent=LS-976；LS-982 lane:design **Canceled** 標題提到 LS-970 → 不算承接（R1 F3），
# LS-970 仍列來源。
cat > "$fx_ot/closed_issues.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-980","title":"Harness：已升票的池項","description":"來源 LS-96 池項 `bbbbbbbb`。","state":{"name":"Done","type":"completed"},"labels":{"nodes":[{"name":"lane:harness"}]},"parent":null},
  {"identifier":"LS-981","title":"設計：登入頁（LS-975 畫面群）","description":"已核可","state":{"name":"Done","type":"completed"},"labels":{"nodes":[{"name":"lane:design"}]},"parent":null},
  {"identifier":"LS-977","title":"Task：LS-976 後端 RLS","description":"done","state":{"name":"Done","type":"completed"},"labels":{"nodes":[{"name":"lane:backend"}]},"parent":{"identifier":"LS-976"}},
  {"identifier":"LS-982","title":"設計：孩子卡片（LS-970 畫面群）","description":"取消","state":{"name":"Canceled","type":"canceled"},"labels":{"nodes":[{"name":"lane:design"}]},"parent":null}
]}}}
EOF
# LS-96 comments：aaaa P1（有效）、bbbb P2（被 LS-980 引用 → 不列）、cccc P3（不列）、eeee P1 但 dddd「銷除…已升為」
# 提到它（不列）、dddd 本身是銷除公告且引述「P1 ·」——且**不以「銷除」開頭**（日期／票號起頭，R2 N3：前 2 行含字樣即公告，不列）、
# ffff P2 較早建立（有效，排在 P1 之後）、abababab P3 池項文中引用「P1 ·」（既非首個 match 也不在行首 → 不升級、不列）、
# cdcdcdcd 混級：首項 `- P3 ·`、次項 `- P2 ·`（R2 N1：取行首各項最小級 → 以 P2 列出，摘要取 P2 那項）。
# efefefef 非公告池項（P3）在第 3 行提到 `aaaaaaaa` 並帶「銷案」字樣——前 2 行無公告字樣所以不是公告（R3：只有公告能銷除
# 別則 → aaaa 仍列；live bcb97555 第 3 行更正文提到 ca993eba／d8634a08 的誤藏實例）。
cat > "$fx_ot/pool_comments.json" <<'EOF'
{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"aaaaaaaa-0000-4000-8000-000000000001","createdAt":"2026-09-02T00:00:00.000Z","body":"入池 2026-09-02（orchestrator）：P1 · **候補不驗 Design gate** · 觸發事故（有）· 估 size:S"},
  {"id":"bbbbbbbb-0000-4000-8000-000000000002","createdAt":"2026-09-02T01:00:00.000Z","body":"入池：P2 · 已升票的池項 · 估 size:S"},
  {"id":"cccccccc-0000-4000-8000-000000000003","createdAt":"2026-09-02T02:00:00.000Z","body":"入池：P3 · 純效率項 · 估 size:S"},
  {"id":"dddddddd-0000-4000-8000-000000000004","createdAt":"2026-09-02T03:00:00.000Z","body":"2026-09-03 LS-999 已落地——**銷除**待辦池 comment `eeeeeeee`（P1 · 已銷除的池項），本筆不再是池項"},
  {"id":"eeeeeeee-0000-4000-8000-000000000005","createdAt":"2026-09-02T04:00:00.000Z","body":"入池：P1 · 已銷除的池項"},
  {"id":"ffffffff-0000-4000-8000-000000000006","createdAt":"2026-09-01T00:00:00.000Z","body":"入池 2026-09-01：\n- P2 · 第二個有效池項 · 估 size:M"},
  {"id":"abababab-0000-4000-8000-000000000007","createdAt":"2026-09-02T05:00:00.000Z","body":"入池：P3 · 純效率項——文中引用他則「P1 · 某某」只是舉例，不是升級"},
  {"id":"cdcdcdcd-0000-4000-8000-000000000008","createdAt":"2026-09-02T06:00:00.000Z","body":"入池 2026-09-02（LS-121 收尾）：\n- P3 · docs 錯誤碼表範例過時 · 估 size:S\n- P2 · **mutation 自證機械化** · 再發生一次即升獨立票 · 估 size:M"},
  {"id":"efefefef-0000-4000-8000-000000000009","createdAt":"2026-09-02T07:00:00.000Z","body":"入池：P3 · 純效率項\n- 細節：只是效率\n- 對照：同型 `aaaaaaaa` 尚未銷案，僅提及、不是公告"}
]}}}}
EOF
mkdir -p "$work/bin_ot"
cat > "$work/bin_ot/curl" <<EOF
#!/bin/bash
fx="${fx_ot}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'comments('*) cat "\$fx/pool_comments.json" ;;
  *'documents('*) cat "\$fx/documents.json" ;;
  *'cycle(id:'*) cat "\$fx/cycle_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'type: { in: ['*) cat "\$fx/closed_issues.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin_ot/curl"

out_ot1="$(PATH="$work/bin_ot:$PATH" bash "$plsh" --repo "$repo_ot" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑩ 開票 fixture 第一輪 exit 0"; else echo "✗ ⑩ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_ot1" | sed 's/^/    /' >&2; fail=1; fi
export OUT_OT1="$out_ot1"
py_ot1="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT_OT1"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False

ui = d["lanes"]["lane:ui"]; design = d["lanes"]["lane:design"]; backend = d["lanes"]["lane:backend"]; harness = d["lanes"]["lane:harness"]
ids = lambda srcs: [s["id"] for s in srcs]

check("⑩ 「需 Design gate」票不進候補、歸待Design（LS-970／971／974／975）",
      ui["candidates"] == [] and ui["chosen"] is None and ui["pending_design"] == ["LS-970", "LS-971", "LS-974", "LS-975"])
check("⑩ ui lane 空＋候補全被擋（待Design）→ open_ticket 第 1 輪",
      ui["open_ticket"] is not None and ui["open_ticket"]["empty_rounds"] == 1)
check("⑩ ui 開票行理由列「待Design …（需 Design gate 無核可稿）」",
      any("待Design LS-970, LS-971, LS-974, LS-975（需 Design gate 無核可稿）" in b for b in ui["open_ticket"]["blocked"]))
check("⑩ ui 來源候選＝尚無設計票的 Story（LS-970／974）；open 設計票 LS-972 承接的 LS-971 與 Done 設計票 LS-981 承接的 LS-975 不列；Canceled 設計票 LS-982 不算承接、LS-970 仍列（R1 F3）",
      ids(ui["open_ticket"]["sources"]) == ["LS-970", "LS-974"])
check("⑩ 動作清單含「→ 開票：lane:ui 空 1 輪」且列 LS-970 標題與理由",
      any(a.startswith("→ 開票：lane:ui 空 1 輪（候補全被擋：") and "LS-970「Story：孩子檔案 CRUD」（需 Design gate、尚無設計票（先開 lane:design））" in a for a in d["actions"]))

check("⑩ design lane 有在飛（LS-972）→ 不印開票、open_ticket 為 null",
      design["wip"] == 1 and design["open_ticket"] is None and not any("開票：lane:design" in a for a in d["actions"]))

check("⑩ hold:user 票（LS-973）不進候補、不被選中、列在 hold 欄",
      backend["candidates"] == [] and backend["chosen"] is None and backend["hold"] == ["LS-973"])
check("⑩ backend lane 候補全 hold:user → 開票行註明「使用者裁決」",
      any(a.startswith("→ 開票：lane:backend 空 1 輪（候補全被擋：hold:user LS-973（使用者裁決））") for a in d["actions"]))
check("⑩ backend 來源候選＝含後端關鍵字且無 backend 子票的 Story（LS-974）；LS-976 已有已結案 backend 子票 LS-977 → 不列",
      ids(backend["open_ticket"]["sources"]) == ["LS-974"] and "RPC" in backend["open_ticket"]["sources"][0]["why"])

check("⑩ harness lane 無候補（只有 LS-96）→ 開票行理由「無候補」",
      harness["open_ticket"] is not None and harness["open_ticket"]["blocked"] == []
      and any(a.startswith("→ 開票：lane:harness 空 1 輪（無候補）") for a in d["actions"]))
check("⑩ 池項來源：P1 aaaa、P2 ffff、P2 cdcdcdcd（P1 先、同級依建立時間）；bbbb 被 LS-980 引用、cccc 是 P3、eeee 被池內公告銷除、dddd 是公告（非「銷除」開頭，前 2 行含字樣）、abababab 是 P3 只在文中引用 P1 ·、efefefef 非公告提到 aaaa＋「銷案」不能銷除 aaaa → 皆不列／aaaa 仍列",
      ids(harness["open_ticket"]["sources"]) == ["LS-96#aaaaaaaa", "LS-96#ffffffff", "LS-96#cdcdcdcd"]
      and harness["open_ticket"]["sources"][0]["why"] == "P1 池項尚未升票"
      and harness["open_ticket"]["sources"][0]["title"].startswith("**候補不驗 Design gate**"))
mixed = [s for s in harness["open_ticket"]["sources"] if s["id"] == "LS-96#cdcdcdcd"]
check("⑩ R2 N1 混級 comment（首項 - P3 ·、次項 - P2 ·）以最小級 P2 列出，摘要取 P2 那項",
      len(mixed) == 1 and mixed[0]["why"] == "P2 池項尚未升票" and mixed[0]["title"].startswith("**mutation 自證機械化**"))
check("⑩ 第一輪不升 ⚠", not any("⚠ 開票" in a for a in d["actions"]))
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py_ot1"
if printf '%s' "$py_ot1" | tail -1 | grep -qx OK; then :; else fail=1; fi

state_file="$repo_ot/.claude/patrol-state.json"
if [ -f "$state_file" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["open_ticket_empty_rounds"]; sys.exit(0 if s["lane:ui"]==1 and s["lane:design"]==0 else 1)' "$state_file"; then
  echo "✓ ⑩ 連續空輪計數寫進 .claude/patrol-state.json（ui=1、design=0）"
else
  echo "✗ ⑩ .claude/patrol-state.json 缺或計數不對" >&2; [ -f "$state_file" ] && sed 's/^/    /' "$state_file" >&2; fail=1
fi

# 第二輪：同 repo 再跑 → ui 連續空 2 輪升 ⚠；design 仍 0
out_ot2="$(PATH="$work/bin_ot:$PATH" bash "$plsh" --repo "$repo_ot" --json 2>&1)"; rc=$?
export OUT_OT2="$out_ot2"
if [ "$rc" -eq 0 ] && python3 -c 'import json,os; d=json.loads(os.environ["OUT_OT2"]); ui=d["lanes"]["lane:ui"]["open_ticket"]; assert ui["empty_rounds"]==2; assert any(a.startswith("→ ⚠ 開票：lane:ui 連續空 2 輪（") for a in d["actions"]); assert d["lanes"]["lane:design"]["open_ticket"] is None'; then
  echo "✓ ⑩ 第二輪：ui 連續空 2 輪 → 動作行升「→ ⚠ 開票：lane:ui 連續空 2 輪」"
else
  echo "✗ ⑩ 第二輪應升 ⚠（exit ${rc}）" >&2; printf '%s\n' "$out_ot2" | sed 's/^/    /' >&2; fail=1
fi

# human 模式：lane 表多兩欄（待Design／hold:user 註明使用者裁決）、第 3 段與動作清單都印開票行
out_ot_h="$(PATH="$work/bin_ot:$PATH" bash "$plsh" --repo "$repo_ot" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "✗ ⑩ human 模式應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_ot_h" | sed 's/^/    /' >&2; fail=1; fi
has_in '⑩ human：lane 表 hold:user 欄註明使用者裁決' "$out_ot_h" 'hold:user：LS-973（使用者裁決）'
has_in '⑩ human：lane 表待Design 欄' "$out_ot_h" '待Design：LS-970, LS-971, LS-974, LS-975'
has_in '⑩ human：動作清單含 ui 開票行' "$out_ot_h" '開票：lane:ui'
if printf '%s' "$out_ot_h" | grep -qF '開票：lane:design'; then echo "✗ ⑩ human：design lane 有在飛不應印開票" >&2; fail=1; else echo "✓ ⑩ human：design lane 有在飛不印開票"; fi

# 附加查詢失敗 fail-soft：comments 查詢回 GraphQL errors → 報表仍 exit 0、--json 仍是合法 JSON（stderr 不外漏）、
# harness 開票行註明查詢失敗、其他 lane 不受影響
mkdir -p "$work/bin_ot_fail"
cat > "$work/bin_ot_fail/curl" <<EOF
#!/bin/bash
fx="${fx_ot}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'comments('*) echo '{"errors":[{"message":"stub：模擬 comments 查詢失敗"}]}' ;;
  *'documents('*) cat "\$fx/documents.json" ;;
  *'cycle(id:'*) cat "\$fx/cycle_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'type: { in: ['*) cat "\$fx/closed_issues.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin_ot_fail/curl"
out_ot_f="$(PATH="$work/bin_ot_fail:$PATH" bash "$plsh" --repo "$repo_ot" --json 2>&1)"; rc=$?
export OUT_OTF="$out_ot_f"
if [ "$rc" -eq 0 ] && python3 -c 'import json,os; d=json.loads(os.environ["OUT_OTF"]); h=d["lanes"]["lane:harness"]["open_ticket"]; assert h["sources"]==[]; assert any("查詢失敗" in n and "模擬 comments 查詢失敗" in n for n in h["notes"]); assert [s["id"] for s in d["lanes"]["lane:ui"]["open_ticket"]["sources"]]==["LS-970","LS-974"]'; then
  echo "✓ ⑩ 附加查詢失敗 fail-soft：exit 0、JSON 合法、harness 開票行註明查詢失敗、ui 來源不受影響"
else
  echo "✗ ⑩ 附加查詢失敗應 fail-soft（exit ${rc}）" >&2; printf '%s\n' "$out_ot_f" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑩d R1 F1 負樣本：裸子字串「需 Design gate」對否定句無感——「非畫面票（不需 Design gate）」（LS-145 實例）與
#        「拆後端先行（不需 Design gate）；UI 端（另票，需 Design gate）」（LS-143／149 用語）都不得進待Design，
#        必須照常列為候補並被選中；只有正典粗體 **UI 票：需 Design gate** 才歸待Design。獨立 repo（不動 ⑩ 的計數）。----
repo_neg="$work/repo_neg"
git init -q -b main "$repo_neg"
git -C "$repo_neg" config user.email test@example.com
git -C "$repo_neg" config user.name Test
: > "$repo_neg/.gitkeep"; git -C "$repo_neg" add .gitkeep; git -C "$repo_neg" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_neg/.env"
fx_neg="$work/fixtures_neg"
cp -R "$fx_ot" "$fx_neg"
cat > "$fx_neg/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-970","title":"Story：孩子檔案 CRUD","description":"PLAN。**UI 票：需 Design gate**（孩子卡片）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-978","title":"Phase 2-2：PrivacyInfo.xcprivacy","description":"TestFlight／送審前置，非畫面票（不需 Design gate）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-02T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-979","title":"Task：LS-976 後端先行","description":"拆後端先行（不需 Design gate）；UI 端（另票，需 Design gate）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-03T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:backend"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":{"identifier":"LS-976"},
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-983","title":"Story：登入（LS-17 式措辭）","description":"PLAN。**UI 票：需先過 Design gate**（登入頁）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-04T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-984","title":"設定頁小改","description":"**UI 票：不需 Design gate**（沿用既有元件）。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-05T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF
mkdir -p "$work/bin_neg"
sed "s#^fx=.*#fx=\"${fx_neg}\"#" "$work/bin_ot/curl" > "$work/bin_neg/curl"
chmod +x "$work/bin_neg/curl"
out_neg="$(PATH="$work/bin_neg:$PATH" bash "$plsh" --repo "$repo_neg" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑩d 負樣本 fixture exit 0"; else echo "✗ ⑩d 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out_neg" | sed 's/^/    /' >&2; fail=1; fi
export OUT_NEG="$out_neg"
py_neg="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT_NEG"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False
ui = d["lanes"]["lane:ui"]; backend = d["lanes"]["lane:backend"]; design = d["lanes"]["lane:design"]
check("⑩d 「非畫面票（不需 Design gate）」（LS-978）與粗體「**UI 票：不需 Design gate**」（LS-984）不進待Design、照常列為 ui 候補，LS-978 被選中",
      ui["candidates"] == ["LS-978", "LS-984"] and ui["chosen"] == "LS-978"
      and any("save_issue LS-978 state=Ready cycle=5" in a for a in ui["actions"]))
check("⑩d R2 N2 「**UI 票：需先過 Design gate**」（LS-983，LS-17 式變體）與正典 LS-970 一樣歸待Design",
      ui["pending_design"] == ["LS-970", "LS-983"])
check("⑩d ui lane 有候補 → 不印開票（open_ticket 為 null）", ui["open_ticket"] is None and not any("開票：lane:ui" in a for a in d["actions"]))
check("⑩d 「拆後端先行（不需 Design gate）；UI 端（另票，需 Design gate）」（LS-979）不進待Design、列為 backend 候補並被選中",
      backend["pending_design"] == [] and backend["candidates"] == ["LS-979"] and backend["chosen"] == "LS-979")
check("⑩d design lane 空 → 開票來源只列粗體標記的 LS-970／983，不列 LS-978／979／984",
      design["open_ticket"] is not None and [s["id"] for s in design["open_ticket"]["sources"]] == ["LS-970", "LS-983"])
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py_neg"
if printf '%s' "$py_neg" | tail -1 | grep -qx OK; then :; else fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ patrol-linear 自測失敗" >&2
  exit 1
fi
echo "✓ patrol-linear 自測通過"
