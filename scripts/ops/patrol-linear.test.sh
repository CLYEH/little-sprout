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
# ⑬（LS-287）：harness 池項來源候選再多一層排除——id 前 8 碼若已被 repo 腳本檔頭等引用（`git grep`）視為已落地，
# 從候選移除並在「→ 開票」行附註「已落地：…」；未命中維持現行；mutation 證明綠來自這段排除本身。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plsh="${root}/scripts/ops/patrol-linear.sh"
fail=0
command -v python3 >/dev/null 2>&1 || { echo "✗ patrol-linear 自測需要 python3" >&2; exit 1; }

# LS-301：本檔散落多處 `printf | grep -qF` 改用共用庫（scripts/gates/lib/selftest-helpers.sh）的
# has()（here-string，避免 pipefail 下的 SIGPIPE 誤判），語意不變。本檔沒有自己的 ok()／fail() 函式
# （只有 `fail=0` 旗標變數），這裡補一個同名 fail() 函式（bash 函式與變數不同命名空間，`fail=1` 賦值
# 與 `fail "msg"` 呼叫不衝突）讓共用庫的 expect_has 失敗時仍會設到這個旗標。
fail() { echo "✗ $1" >&2; fail=1; }
source "${root}/scripts/gates/lib/selftest-helpers.sh"

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
if [ "$rc" -eq 0 ] && has "$out" '略過（無 LINEAR_API_KEY）'; then
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
if has "$out_json" '"skipped":true'; then echo "✓ ① --json 模式印 skipped:true"; else echo "✗ ① --json 應印 skipped:true（實得：${out_json}）" >&2; fail=1; fi

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
if [ "$(tail -1 <<<"$py_out")" = OK ]; then :; else fail=1; fi

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
if [ "$rc" -eq 0 ] && has "$out_human" '動作清單'; then echo "✓ ④ human 模式 exit 0 且含動作清單段"; else echo "✗ ④ human 模式異常（exit ${rc}）" >&2; printf '%s\n' "$out_human" | sed 's/^/    /' >&2; fail=1; fi
out_brief="$(bash "$plsh" --repo "$repo" --brief 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out_brief" 'save_issue LS-204 state=Ready cycle=5'; then echo "✓ ④ --brief 模式印動作清單（含 save_issue LS-204）"; else echo "✗ ④ --brief 模式異常（exit ${rc}）" >&2; printf '%s\n' "$out_brief" | sed 's/^/    /' >&2; fail=1; fi

# ---- ④b R1 F1：human／--brief 的 lane 表五欄（上限／在飛／候補／待Spec／待結構）與 cycle 一行
#        （編號／剩餘天數／票數 完成/總數）都要印出來——不是只在 --json 才有 ----
# LS-301：has_in() 改用檔頭已 source 的共用庫 expect_has，語意不變。
expect_has "$out_human" 'current cycle：5（剩' '④b human：cycle 一行含編號與票數 完成/總數'
expect_has "$out_human" '票數 2/4 完成' '④b human：cycle 一行含票數 2/4 完成'
expect_has "$out_human" '待Spec：LS-206' '④b human：lane:harness 行含待 Spec（LS-206）'
expect_has "$out_human" '待結構：LS-207' '④b human：lane:harness 行含待結構（LS-207）'
expect_has "$out_brief" '待Spec：LS-206' '④b --brief：也印 Lane 狀態表與待 Spec／待結構'
expect_has "$out_brief" 'current cycle：5（剩' '④b --brief：cycle 一行同樣在（不是只有 --json 才有）'
expect_has "$out_human" 'LS-211（cycle 外，取第一張需 scope+）' '④b R1 I2：human lane:backend 候補標示 cycle 外需 scope+'
expect_has "$out_brief" 'LS-211（cycle 外，取第一張需 scope+）' '④b R1 I2：--brief 同樣標示 cycle 外 scope+'

# ---- ⑤ 參數錯誤 fail closed ----
out="$(bash "$plsh" --repo 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && has "$out" '--repo 缺值'; then echo "✓ ⑤ --repo 缺值 → exit 2"; else echo "✗ ⑤ --repo 缺值應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out="$(bash "$plsh" --bogus 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && has "$out" '未知參數'; then echo "✓ ⑤ 未知參數 → exit 2"; else echo "✗ ⑤ 未知參數應 exit 2（實得 ${rc}）" >&2; fail=1; fi
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
  if has "$out" "$want_substr"; then
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
if [ "$rc" -eq 2 ] && has "$out_closed_bad" '票號數字'; then echo "✓ ⑥b 票號格式錯 → exit 2"; else echo "✗ ⑥b 票號格式錯應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out_closed_empty="$(bash "$plsh" --closed '' --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then echo "✓ ⑥b --closed 空值 → exit 2"; else echo "✗ ⑥b --closed 空值應 exit 2（實得 ${rc}）" >&2; fail=1; fi

# ---- ⑥c --lane（LS-209：patrol.sh「Pen 開錯檔（實作票）」偵測問「這張票目前是哪個 lane」）：獨立假 curl 回
#        number: { eq: $number } 查詢的 fixture；stdout 恰一行（lane 名或空字串）；無 key → exit 3、stdout 空；
#        票號格式錯／空值／逗號分隔（--lane 只收單一票號，不像 --closed）→ exit 2 ----
mkdir -p "$work/bin_lane"
cat > "$work/bin_lane/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_STUB_LOG:?}"
cat >/dev/null
data=""
while [ $# -gt 0 ]; do case "$1" in --data) data=$2; shift ;; esac; shift; done
case "$data" in
  *'number: { eq: $number }'*)
    case "$data" in
      *'"number": 188.0'*) echo '{"data":{"issues":{"nodes":[{"identifier":"LS-188","labels":{"nodes":[{"name":"lane:backend"},{"name":"size:M"}]}}]}}}' ;;
      *'"number": 46.0'*) echo '{"data":{"issues":{"nodes":[{"identifier":"LS-46","labels":{"nodes":[{"name":"lane:design"}]}}]}}}' ;;
      *'"number": 999999.0'*) echo '{"data":{"issues":{"nodes":[]}}}' ;;
      *) echo '{"data":{"issues":{"nodes":[{"identifier":"LS-X","labels":{"nodes":[]}}]}}}' ;;
    esac ;;
  *) echo '{"errors":[{"message":"stub curl：--lane 不該打別的查詢"}]}' ;;
esac
EOF
chmod +x "$work/bin_lane/curl"
: > "$CURL_STUB_LOG"
out_lane="$(PATH="$work/bin_lane:$PATH" bash "$plsh" --lane 188 --repo "$repo" 2>"$work/stderr_lane.log")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out_lane" = "lane:backend" ]; then echo "✓ ⑥c --lane 188 → exit 0、印 lane:backend"; else echo "✗ ⑥c --lane 188 應 exit 0 印 lane:backend（實得 rc=${rc}、out=${out_lane}）" >&2; sed 's/^/    /' "$work/stderr_lane.log" >&2; fail=1; fi
out_lane_design="$(PATH="$work/bin_lane:$PATH" bash "$plsh" --lane 46 --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out_lane_design" = "lane:design" ]; then echo "✓ ⑥c --lane 46 → 印 lane:design（正常設計票，不該被巡檢標記）"; else echo "✗ ⑥c --lane 46 應印 lane:design（實得 ${out_lane_design}）" >&2; fail=1; fi
out_lane_none="$(PATH="$work/bin_lane:$PATH" bash "$plsh" --lane 999999 --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out_lane_none" ]; then echo "✓ ⑥c 查無此票 → exit 0、印空行（呼叫端當「非 design」處理，不是查詢失敗）"; else echo "✗ ⑥c 查無此票應 exit 0 印空（實得 rc=${rc}、out=${out_lane_none}）" >&2; fail=1; fi
n_curl_lane=$(grep -c . "$CURL_STUB_LOG" 2>/dev/null || true); [ "${n_curl_lane:-0}" -eq 3 ] && echo "✓ ⑥c 每次呼叫各打一次 curl" || { echo "✗ ⑥c curl 呼叫次數不符（實得 ${n_curl_lane:-0}）" >&2; fail=1; }
grep -qF 'test-token-not-real' "$CURL_STUB_LOG" && { echo "✗ ⑥c token 出現在 curl argv" >&2; fail=1; } || echo "✓ ⑥c token 不進 curl argv"
out_lane_nokey="$(bash "$plsh" --lane 188 --repo "$repo_no_token" 2>"$work/stderr_lane_nokey.log")"; rc=$?
if [ "$rc" -eq 3 ] && [ -z "$out_lane_nokey" ] && grep -qF '略過（無 LINEAR_API_KEY）' "$work/stderr_lane_nokey.log"; then echo "✓ ⑥c 無 key → exit 3、stdout 空、stderr 說略過"; else echo "✗ ⑥c 無 key 應 exit 3（實得 rc=${rc}）" >&2; fail=1; fi
out_lane_bad="$(bash "$plsh" --lane 188,3 --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && has "$out_lane_bad" '單一票號數字'; then echo "✓ ⑥c 逗號分隔（多票號）→ exit 2（--lane 只收單一票號）"; else echo "✗ ⑥c 多票號應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out_lane_bad2="$(bash "$plsh" --lane abc --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && has "$out_lane_bad2" '單一票號數字'; then echo "✓ ⑥c 非數字 → exit 2"; else echo "✗ ⑥c 非數字應 exit 2（實得 ${rc}）" >&2; fail=1; fi
out_lane_empty="$(bash "$plsh" --lane '' --repo "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then echo "✓ ⑥c --lane 空值 → exit 2"; else echo "✗ ⑥c --lane 空值應 exit 2（實得 ${rc}）" >&2; fail=1; fi

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
if has "$out_d" 'Cycle 9 剩'; then
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
if [ "$(tail -1 <<<"$py_none")" = OK ]; then :; else fail=1; fi
if has "$out_none_json" 'cycle=?'; then
  echo "✗ ⑨ JSON 輸出不應出現 cycle=?（不可執行的動作字面）" >&2; fail=1
else
  echo "✓ ⑨ JSON 輸出不含 cycle=?"
fi

out_none_human="$(PATH="$work/bin_none:$PATH" bash "$plsh" --repo "$repo_none" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out_none_human" 'current cycle：無法判定'; then
  echo "✓ ⑨ human 模式印「current cycle：無法判定」"
else
  echo "✗ ⑨ human 模式應印「current cycle：無法判定」（exit ${rc}）" >&2
  printf '%s\n' "$out_none_human" | sed 's/^/    /' >&2
  fail=1
fi
if has "$out_none_human" 'cycle=?'; then
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
if [ "$(tail -1 <<<"$py_ot1")" = OK ]; then :; else fail=1; fi

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
expect_has "$out_ot_h" 'hold:user：LS-973（使用者裁決）' '⑩ human：lane 表 hold:user 欄註明使用者裁決'
expect_has "$out_ot_h" '待Design：LS-970, LS-971, LS-974, LS-975' '⑩ human：lane 表待Design 欄'
expect_has "$out_ot_h" '開票：lane:ui' '⑩ human：動作清單含 ui 開票行'
if has "$out_ot_h" '開票：lane:design'; then echo "✗ ⑩ human：design lane 有在飛不應印開票" >&2; fail=1; else echo "✓ ⑩ human：design lane 有在飛不印開票"; fi

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
if [ "$(tail -1 <<<"$py_neg")" = OK ]; then :; else fail=1; fi

# ---- ⑪（LS-267／LS-239 R3）§4-b cron 模板的過濾式必須留得住動作清單／lane 表／cycle 一行 ----
# orchestrator 巡檢改成自己直接跑 `patrol.sh 40 --linear` 再過濾進 context；樣式**直接從
# docs/COLLABORATION.md 讀出來**餵給斷言，模板與實際輸出任一邊漂移這裡就紅。
pfilter11="${root}/scripts/ops/patrol-filter.sh"
filter11=$(bash "$pfilter11" --pattern)
if [ -z "$filter11" ]; then
  echo "✗ ⑪ 讀不到 patrol-filter.sh --pattern 的樣式（斷言失去意義，fail loud）" >&2; fail=1
else
  echo "✓ ⑪ 取得過濾樣式（patrol-filter.sh --pattern）：${filter11}"
fi
out11="$(bash "$plsh" --repo "$repo" 2>&1)"
keep11=$(printf '%s\n' "$out11" | bash "$pfilter11" 2>/dev/null)

# (a) 動作清單段的每一行都含 →（模板靠它留下整段；行首 → 是慣例，行中的也算）
act11=$(printf '%s\n' "$out11" | sed -n '/^== 動作清單/,$p' | sed '1d' | grep -v '^[[:space:]]*$')
if [ -z "$act11" ]; then
  act11=$(printf '%s\n' "$out11" | sed -n '/動作清單/,$p' | sed '1d' | grep -v '^[[:space:]]*$')
fi
if [ -z "$act11" ]; then
  echo "✗ ⑪(a) 找不到動作清單段，斷言會空跑" >&2; fail=1
else
  bad11=$(printf '%s\n' "$act11" | grep -vF '→' | grep -v '（無待執行動作）')
  if [ -z "$bad11" ]; then
    echo "✓ ⑪(a) 動作清單 $(printf '%s\n' "$act11" | wc -l | tr -d ' ') 行全部含 →（過濾式留得住）"
  else
    echo "✗ ⑪(a) 動作清單有行不含 →（會被 §4-b 過濾式丟掉）：" >&2; printf '%s\n' "$bad11" | sed 's/^/    /' >&2; fail=1
  fi
  miss11=$(printf '%s\n' "$act11" | while IFS= read -r l; do has "$keep11" "$l" || printf '%s\n' "$l"; done)
  if [ -z "$miss11" ]; then
    echo "✓ ⑪(a) 動作清單每一行實際通過過濾"
  else
    echo "✗ ⑪(a) 動作清單有行被過濾掉：" >&2; printf '%s\n' "$miss11" | sed 's/^/    /' >&2; fail=1
  fi
fi

# (b) lane 狀態表每一行含 `lane:`；(c) cycle 一行含 `current cycle`
lane11=$(printf '%s\n' "$out11" | grep -F '上限' | grep -F '在飛')
if [ -z "$lane11" ]; then
  echo "✗ ⑪(b) 找不到 lane 狀態表，斷言會空跑" >&2; fail=1
elif grep -qv 'lane:' <<<"$lane11"; then
  echo "✗ ⑪(b) lane 狀態表有行不含 lane:（會被過濾掉）：" >&2; printf '%s\n' "$lane11" | grep -v 'lane:' | sed 's/^/    /' >&2; fail=1
else
  echo "✓ ⑪(b) lane 狀態表 $(printf '%s\n' "$lane11" | wc -l | tr -d ' ') 行全部含 lane:，且過濾後仍在（$(printf '%s\n' "$keep11" | grep -cF '上限') 行）"
fi
if has "$keep11" 'current cycle'; then
  echo "✓ ⑪(c) cycle 一行含 current cycle、過濾後仍在"
else
  echo "✗ ⑪(c) cycle 一行沒通過過濾" >&2; printf '%s\n' "$out11" | grep -F 'cycle' | sed 's/^/    /' >&2; fail=1
fi

# (e) R2 M1 全稱：human 段的每一條**結論行**只要不是「：無」／「ok」／「（無…）」這種「沒事」的行，
#     就必須通過過濾——R1 只釘了動作行／lane 表／cycle 行三種，對「壓根沒有標記的異常行」（cycle 對帳
#     (a)(b)、開票結構 (a)-(e)、QA 讀不到…）在定義上無感，reviewer R1 M1 實跑抓到整段被吞。
lost11=$(printf '%s\n' "$out11" | grep -v '^== ' | grep -v '^[[:space:]]*$' \
  | grep -vE '：無$|：ok$|（無異常）|（無待執行動作）|（無候補）' \
  | while IFS= read -r l; do has "$keep11" "$l" || printf '%s\n' "$l"; done)
if [ -z "$lost11" ]; then
  echo "✓ ⑪(e) 全稱：human 段所有「非『無／ok』結論行」都通過過濾（$(printf '%s\n' "$out11" | grep -v '^== ' | grep -vE '：無$|：ok$|（無異常）|（無待執行動作）|（無候補）|^[[:space:]]*$' | wc -l | tr -d ' ') 行）"
else
  echo "✗ ⑪(e) 以下結論行會被 §4-b 過濾式吞掉（缺 ⚠／✗／→ 標記）：" >&2; printf '%s\n' "$lost11" | sed 's/^/    /' >&2; fail=1
fi

# (e2) R2 M1 mutation：拿掉 `mark()` 補的 ⚠（cycle 對帳 (a)(b)／開票結構 (a)-(e) 的異常行）→ (e) 轉紅
mutdir11e="$work/mut11e"
rm -rf "$mutdir11e"; mkdir -p "$mutdir11e"
cp -R "${root}/scripts" "$mutdir11e/scripts"
sed 's|return "%s%s%s" % (prefix, "⚠ " if items else "", text)|return "%s%s" % (prefix, text)|' \
  "${root}/scripts/ops/patrol_linear.py" > "$mutdir11e/scripts/ops/patrol_linear.py"
if ! grep -q 'return "%s%s" % (prefix, text)' "$mutdir11e/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑪(e2) mutant 沒被正確合成（mark() 形狀變了）" >&2; fail=1
else
  out11e="$(bash "$mutdir11e/scripts/ops/patrol-linear.sh" --repo "$repo" 2>&1)"
  keep11e=$(printf '%s\n' "$out11e" | bash "$pfilter11" 2>/dev/null)
  lost11e=$(printf '%s\n' "$out11e" | grep -v '^== ' | grep -v '^[[:space:]]*$' \
    | grep -vE '：無$|：ok$|（無異常）|（無待執行動作）|（無候補）' \
    | while IFS= read -r l; do has "$keep11e" "$l" || printf '%s\n' "$l"; done)
  if [ -n "$lost11e" ]; then
    echo "✓ ⑪(e2) mutant（mark() 不補 ⚠）：出現被過濾吞掉的結論行（如「$(printf '%s' "$lost11e" | head -1 | cut -c1-56)…」）——證明 (e) 的綠來自 mark()"
  else
    echo "✗ ⑪(e2) mutant 未如預期翻轉——(e) 可能零覆蓋（夾具沒有任何非空的對帳結果？）" >&2; fail=1
  fi
fi

# (f) R2 M1 逐分支夾具：無 LINEAR_API_KEY 時的「略過」結論行必須帶標記、通過過濾
#     （失敗情境：.env 過期／換機沒帶 → Linear 半段整段沒跑，orchestrator 卻只看到 git 半段，靜默停擺）
out11f="$(bash "$plsh" --repo "$repo_no_token" 2>&1)"
keep11f=$(printf '%s\n' "$out11f" | bash "$pfilter11" 2>/dev/null)
if has "$keep11f" '略過（無 LINEAR_API_KEY）'; then
  echo "✓ ⑪(f) 無 LINEAR_API_KEY 的略過行通過過濾（不會整段靜默消失）"
else
  echo "✗ ⑪(f) 無 LINEAR_API_KEY 的略過行被過濾掉了——Linear 半段沒跑卻沒有任何訊號" >&2
  printf '%s\n' "$out11f" | sed 's/^/    原始：/' >&2; fail=1
fi

# (g) R2 M1 mutation：把 (f) 那行的 ⚠ 拿掉 → (f) 轉紅（證明綠來自標記本身）
mutdir11g="$work/mut11g"
rm -rf "$mutdir11g"; mkdir -p "$mutdir11g"
cp -R "${root}/scripts" "$mutdir11g/scripts"
sed 's/echo "⚠ 巡檢（Linear 半段）：略過（無 LINEAR_API_KEY）/echo "巡檢（Linear 半段）：略過（無 LINEAR_API_KEY）/' \
  "${root}/scripts/ops/patrol-linear.sh" > "$mutdir11g/scripts/ops/patrol-linear.sh"
out11g="$(bash "$mutdir11g/scripts/ops/patrol-linear.sh" --repo "$repo_no_token" 2>&1)"
keep11g=$(printf '%s\n' "$out11g" | bash "$pfilter11" 2>/dev/null)
if has "$keep11g" '略過（無 LINEAR_API_KEY）'; then
  echo "✗ ⑪(g) mutant（拿掉略過行的 ⚠）仍通過過濾——(f) 的綠不是來自標記，斷言沒有牙" >&2; fail=1
else
  echo "✓ ⑪(g) mutant（拿掉略過行的 ⚠）：該行被過濾掉——證明 (f) 釘的正是那個標記"
fi

# (d) mutation：拿掉動作清單行首的 `→ ` → (a) 轉紅（證明 (a) 釘的正是這個標記）
mutdir11="$work/mut11"
rm -rf "$mutdir11"; mkdir -p "$mutdir11"
cp -R "${root}/scripts" "$mutdir11/scripts"
sed 's/"→ save_issue /"save_issue /' "${root}/scripts/ops/patrol_linear.py" > "$mutdir11/scripts/ops/patrol_linear.py"
if ! grep -q '"save_issue ' "$mutdir11/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑪(d) mutant 沒被正確合成（save_issue 動作字串形狀變了）" >&2; fail=1
else
  out11d="$(bash "$mutdir11/scripts/ops/patrol-linear.sh" --repo "$repo" 2>&1)"
  act11d=$(printf '%s\n' "$out11d" | sed -n '/動作清單/,$p' | sed '1d' | grep -v '^[[:space:]]*$')
  if grep -q '^save_issue ' <<<"$act11d"; then
    echo "✓ ⑪(d) mutant（動作行拿掉 →）：出現不含 → 的動作行——證明 (a) 的綠來自那個標記，過濾式會把它丟掉"
  else
    echo "✗ ⑪(d) mutant 未如預期翻轉——(a) 可能零覆蓋" >&2; printf '%s\n' "$act11d" | sed 's/^/    /' >&2; fail=1
  fi
fi

# ---- ⑫（R3 m1）狀態對照行**恰好一個 ⚠**：`format_human()` 已對每條 state_crosscheck 行前置 `  ⚠ `，
#      產生端（`state_crosscheck()`）不可以自己再加一個，否則渲染成 `⚠ ⚠ …`（R2 對 QA「讀不到」那條就多加了）。
py_qa="$(ROOT_DIR="$root" python3 - <<'PYEOF'
import importlib.util, os

spec = importlib.util.spec_from_file_location("pl", os.environ["ROOT_DIR"] + "/scripts/ops/patrol_linear.py")
pl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pl)

report = {
    "generated_at": "2026-09-14T00:00:00Z",
    "current_cycle": None,
    "state_crosscheck": ["LS-275 QA：origin/development 不存在或讀不到，略過對照"],
    "cycle_check": {"a": [], "b": [], "c": [], "d": []},
    "lanes": {},
    "structure": {k: [] for k in ("a", "b", "c", "d", "e")},
    "booted_simulator_flags": [],
    "actions": [],
}
for line in pl.format_human(report).split("\n"):
    if "QA：origin/development 不存在或讀不到" in line:
        print("%d|%s" % (line.count("⚠"), line))
PYEOF
)"
case "$py_qa" in
  1\|*)
    echo "✓ ⑫ 狀態對照行恰好一個 ⚠（不是雙標）：${py_qa#1|}"
    keep_qa12=$(printf '%s\n' "${py_qa#1|}" | bash "$pfilter11" 2>/dev/null)
    if has "$keep_qa12" 'QA：origin/development 不存在或讀不到'; then
      echo "✓ ⑫ 該行仍通過 §4-b 過濾（渲染端的 ⚠ 就夠）"
    else
      echo "✗ ⑫ 該行沒通過過濾" >&2; fail=1
    fi ;;
  '') echo "✗ ⑫ 渲染不出狀態對照行（format_human 形狀變了？）" >&2; fail=1 ;;
  *)  echo "✗ ⑫ 狀態對照行的 ⚠ 個數不是 1：${py_qa}" >&2; fail=1 ;;
esac

# ---- ⑬（LS-287）harness 池項來源候選：id 前 8 碼已被 repo 腳本檔頭等引用者視為已落地，從候選移除、
#      同段的「→ 開票」行附註「已落地：<id8> → <檔:行>」；未命中維持現行輸出 ----
repo_landed="$work/repo_landed"
git init -q -b main "$repo_landed"
git -C "$repo_landed" config user.email test@example.com
git -C "$repo_landed" config user.name Test
mkdir -p "$repo_landed/scripts/ops"
# 「11112222」已被這支腳本檔頭引用（模擬 cleanup-merged.sh／pen-read.sh 之類「來源 LS-96 池項 <id>」的慣例）；
# 「33334444」不出現在 repo 任何地方，應維持現行輸出（夾具 (b)）。
cat > "$repo_landed/scripts/ops/fake-landed-LS287.sh" <<'EOF'
#!/bin/bash
# 假腳本（LS-287 自測用）：來源 LS-96 池項 11112222
echo hi
EOF
git -C "$repo_landed" add scripts/ops/fake-landed-LS287.sh
git -C "$repo_landed" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_landed/.env"

fx_landed="$work/fixtures_landed"
mkdir -p "$fx_landed"
cat > "$fx_landed/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[]}}}}
EOF
cat > "$fx_landed/closed_issues.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}
EOF
cat > "$fx_landed/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-96","title":"Harness 待辦池","description":"常駐","priority":1,"createdAt":"2020-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"}]},
   "cycle":null,"project":null,"projectMilestone":null,"parent":null,"inverseRelations":{"nodes":[]}}
]}}}
EOF
# aaaa11112222…：P2 已落地（repo 已引用）；bbbb33334444…：P2 未落地（repo 無引用）——皆合法 P2 池項。
cat > "$fx_landed/pool_comments.json" <<'EOF'
{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"11112222-0000-4000-8000-000000000001","createdAt":"2026-09-01T00:00:00.000Z","body":"入池：P2 · 已落地的候選 · 估 size:S"},
  {"id":"33334444-0000-4000-8000-000000000002","createdAt":"2026-09-02T00:00:00.000Z","body":"入池：P2 · 尚未落地的候選 · 估 size:S"}
]}}}}
EOF
mkdir -p "$work/bin_landed"
cat > "$work/bin_landed/curl" <<EOF
#!/bin/bash
fx="${fx_landed}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'comments('*) cat "\$fx/pool_comments.json" ;;
  *'type: { in: ['*) cat "\$fx/closed_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：不應被呼叫（current 為 None 時不查 documents／cycle issues）"}]}' ;;
esac
EOF
chmod +x "$work/bin_landed/curl"

out13="$(PATH="$work/bin_landed:$PATH" bash "$plsh" --repo "$repo_landed" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑬ LS-287 fixture exit 0"; else echo "✗ ⑬ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out13" | sed 's/^/    /' >&2; fail=1; fi
export OUT13="$out13"
py13="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT13"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False

harness = d["lanes"]["lane:harness"]["open_ticket"]
ids = [s["id"] for s in harness["sources"]]
check("⑬(a) 已落地的池項（11112222）從候選移除，只剩未落地的（33334444）（夾具 b：未命中維持現行）",
      ids == ["LS-96#33334444"])
check("⑬(a) 開票行的 notes 印「已落地：11112222 → scripts/ops/fake-landed-LS287.sh:2」",
      any(n.startswith("已落地：11112222 → scripts/ops/fake-landed-LS287.sh:2") for n in harness["notes"]))
check("⑬(a) 動作清單的「→ 開票」行含已落地附註（同段一行，重用 notes［…］）",
      any(a.startswith("→ 開票：lane:harness 空 1 輪") and "已落地：11112222 → scripts/ops/fake-landed-LS287.sh:2" in a for a in d["actions"]))
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py13"
if [ "$(tail -1 <<<"$py13")" = OK ]; then :; else fail=1; fi

# ⑬(b) mutation：拿掉 repo-grep 排除（把 repo_landed_pool_items 硬短路回傳空字典）→ 已落地的池項也會被列出，
#      證明 ⑬(a) 的紅/綠來自這段機械排除，不是巧合
mutdir13="$work/mut13"
rm -rf "$mutdir13"; mkdir -p "$mutdir13"
cp -R "${root}/scripts" "$mutdir13/scripts"
sed 's/^def repo_landed_pool_items(root, prefixes):$/def repo_landed_pool_items(root, prefixes):\n    return {}  # LS-287 mutation test/' \
  "${root}/scripts/ops/patrol_linear.py" > "$mutdir13/scripts/ops/patrol_linear.py"
if ! grep -q '# LS-287 mutation test' "$mutdir13/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑬(b) mutant 沒被正確合成" >&2; fail=1
else
  out13m="$(PATH="$work/bin_landed:$PATH" bash "$mutdir13/scripts/ops/patrol-linear.sh" --repo "$repo_landed" --json 2>&1)"
  export OUT13M="$out13m"
  mut13err="$work/ls287-mut-err"
  if python3 -c 'import json,os; d=json.loads(os.environ["OUT13M"]); ids=[s["id"] for s in d["lanes"]["lane:harness"]["open_ticket"]["sources"]]; assert ids==["LS-96#11112222","LS-96#33334444"], ids' 2>"$mut13err"; then
    echo "✓ ⑬(b) mutant（拿掉 repo-grep 排除）：已落地的 11112222 也被列出——證明 ⑬(a) 的綠來自這段機械排除"
  else
    echo "✗ ⑬(b) mutant 未如預期翻轉" >&2; cat "$mut13err" >&2; printf '%s\n' "$out13m" | sed 's/^/    /' >&2; fail=1
  fi
fi

# ---- ⑭（LS-298 scope 1＋3）已結案票查詢失敗：design_gate_sources()／backend_sources() 的「尚無子票」
#      類候選改印「子票有無不可判（已結案查詢失敗）」且不列入來源候選（scope 1）；先退回讀
#      docs/archive/linear/*.md 反查，命中印「已落地／已有 Done 子票 LS-<n>」（scope 3）----
repo_degraded="$work/repo_degraded"
git init -q -b main "$repo_degraded"
git -C "$repo_degraded" config user.email test@example.com
git -C "$repo_degraded" config user.name Test
mkdir -p "$repo_degraded/docs/archive/linear"
cat > "$repo_degraded/docs/archive/linear/LS-995.md" <<'EOF'
# LS-995 Task：LS-994 後端先行——假子票（LS-298 自測用）

| 欄位 | 值 |
|---|---|
| 狀態 | Done（completed） |
| 標籤 | size:S, lane:backend |
| 父票 | LS-994 假 Story |
EOF
git -C "$repo_degraded" add docs/archive/linear/LS-995.md
: > "$repo_degraded/.gitkeep"; git -C "$repo_degraded" add .gitkeep
git -C "$repo_degraded" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_degraded/.env"

fx_degraded="$work/fixtures_degraded"
mkdir -p "$fx_degraded"
cat > "$fx_degraded/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[
  {"id":"cyc-5","number":5,"startsAt":"2020-01-01T00:00:00.000Z","endsAt":"2099-01-01T00:00:00.000Z","isActive":true}
]}}}}
EOF
cat > "$fx_degraded/documents.json" <<'EOF'
{"data":{"documents":{"nodes":[{"id":"doc-1","title":"Cycle 5 規劃"}]}}}
EOF
cat > "$fx_degraded/cycle_issues.json" <<'EOF'
{"data":{"cycle":{"issues":{"nodes":[]}}}}
EOF
# LS-993：Story、後端關鍵字 RPC、無 lane:backend 子票、封存索引也查無 → 應印「不可判」。
# LS-994：Story、後端關鍵字 RLS、無 lane:backend 子票，但 docs/archive/linear/LS-995.md 為其 Done
# 子票（父票欄＝LS-994、lane:backend）→ 應印「已落地」。
cat > "$fx_degraded/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-96","title":"Harness 待辦池","description":"常駐","priority":1,"createdAt":"2020-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"}]},
   "cycle":null,"project":null,"projectMilestone":null,"parent":null,"inverseRelations":{"nodes":[]}},
  {"identifier":"LS-993","title":"Story：無法判定的候選","description":"後端需要 RPC 支援。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-994","title":"Story：已落地的候選","description":"後端需要 RLS 政策。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-02T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF
mkdir -p "$work/bin_degraded"
cat > "$work/bin_degraded/curl" <<EOF
#!/bin/bash
fx="${fx_degraded}"
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
  *'type: { in: ['*) echo '{"errors":[{"message":"stub：模擬 closed issues 查詢失敗（curl 28 同型，LS-297 事故重現）"}]}' ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin_degraded/curl"

out14="$(PATH="$work/bin_degraded:$PATH" bash "$plsh" --repo "$repo_degraded" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑭ LS-298 scope1＋3 fixture exit 0"; else echo "✗ ⑭ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out14" | sed 's/^/    /' >&2; fail=1; fi
export OUT14="$out14"
py14="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT14"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False

backend = d["lanes"]["lane:backend"]["open_ticket"]
check("⑭ scope1：已結案查詢失敗時，「尚無子票」候選不列入來源候選（sources 空）", backend["sources"] == [])
check("⑭ scope1：LS-993（封存索引也查無）印「子票有無不可判（已結案查詢失敗）」",
      any(n == "LS-993：子票有無不可判（已結案查詢失敗）" for n in backend["notes"]))
check("⑭ scope3：LS-994（封存索引命中 LS-995）印「已落地／已有 Done 子票 LS-995」",
      any(n == "LS-994：已落地／已有 Done 子票 LS-995（本機封存索引）" for n in backend["notes"]))
check("⑭ 一般錯誤說明仍在（已結案票查詢失敗）", any("已結案票查詢失敗" in n for n in backend["notes"]))
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py14"
if [ "$(tail -1 <<<"$py14")" = OK ]; then :; else fail=1; fi

# ⑭a mutation（scope 1）：拿掉降級的早退（open_ticket_sources() 的 `return [], notes`）→ LS-993／LS-994
#      都會被誤列為候選（重現 LS-297 事故：closed 查詢失敗仍印「尚無子票」）
mutdir14a="$work/mut14a"
rm -rf "$mutdir14a"; mkdir -p "$mutdir14a"
cp -R "${root}/scripts" "$mutdir14a/scripts"
sed 's/^            return \[\], notes$/            pass  # LS-298 mutation test (scope 1 disabled)/' \
  "${root}/scripts/ops/patrol_linear.py" > "$mutdir14a/scripts/ops/patrol_linear.py"
if ! grep -q 'LS-298 mutation test (scope 1 disabled)' "$mutdir14a/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑭a mutant 沒被正確合成" >&2; fail=1
else
  out14a="$(PATH="$work/bin_degraded:$PATH" bash "$mutdir14a/scripts/ops/patrol-linear.sh" --repo "$repo_degraded" --json 2>&1)"
  export OUT14A="$out14a"
  if python3 -c 'import json,os; d=json.loads(os.environ["OUT14A"]); ids=set(s["id"] for s in d["lanes"]["lane:backend"]["open_ticket"]["sources"]); assert ids=={"LS-993","LS-994"}, ids' 2>"$work/mut14a-err"; then
    echo "✓ ⑭a mutant（拿掉降級的早退）：LS-993／LS-994 都被誤列為候選——證明 ⑭ scope1 的綠來自這段降級"
  else
    echo "✗ ⑭a mutant 未如預期翻轉" >&2; cat "$work/mut14a-err" >&2; printf '%s\n' "$out14a" | sed 's/^/    /' >&2; fail=1
  fi
fi

# ⑭c mutation（scope 3）：archive_done_child() 恆回 None → LS-994 也變成「不可判」（封存索引反查失效）
mutdir14c="$work/mut14c"
rm -rf "$mutdir14c"; mkdir -p "$mutdir14c"
cp -R "${root}/scripts" "$mutdir14c/scripts"
sed 's/^def archive_done_child(root, story_ident, lane_label, match_title=False):$/def archive_done_child(root, story_ident, lane_label, match_title=False):\n    return None  # LS-298 mutation test (scope 3 disabled)/' \
  "${root}/scripts/ops/patrol_linear.py" > "$mutdir14c/scripts/ops/patrol_linear.py"
if ! grep -q 'LS-298 mutation test (scope 3 disabled)' "$mutdir14c/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑭c mutant 沒被正確合成" >&2; fail=1
else
  out14c="$(PATH="$work/bin_degraded:$PATH" bash "$mutdir14c/scripts/ops/patrol-linear.sh" --repo "$repo_degraded" --json 2>&1)"
  export OUT14C="$out14c"
  if python3 -c 'import json,os; d=json.loads(os.environ["OUT14C"]); notes=d["lanes"]["lane:backend"]["open_ticket"]["notes"]; assert any(n=="LS-994：子票有無不可判（已結案查詢失敗）" for n in notes), notes; assert not any("已落地" in n for n in notes), notes' 2>"$work/mut14c-err"; then
    echo "✓ ⑭c mutant（拿掉封存讀取）：LS-994 也變成「不可判」——證明 ⑭ scope3 的「已落地」綠來自封存讀取本身"
  else
    echo "✗ ⑭c mutant 未如預期翻轉" >&2; cat "$work/mut14c-err" >&2; printf '%s\n' "$out14c" | sed 's/^/    /' >&2; fail=1
  fi
fi

# ---- ⑮（LS-298 scope 2）Story 候選附 repo 已落地提示：抽票文反引號 token 跑 git grep，命中附
#      「已落地：<token> → <檔:行>（疑已有子票）」；候選本身仍照列（closed 查詢正常成功，非降級路徑）----
repo_landed2="$work/repo_landed2"
git init -q -b main "$repo_landed2"
git -C "$repo_landed2" config user.email test@example.com
git -C "$repo_landed2" config user.name Test
mkdir -p "$repo_landed2/scripts/ops"
cat > "$repo_landed2/scripts/ops/fake-landed-LS298.sh" <<'EOF'
#!/bin/bash
# 假腳本（LS-298 自測用）：已經實作 fancy_measurement_table
echo hi
EOF
git -C "$repo_landed2" add scripts/ops/fake-landed-LS298.sh
git -C "$repo_landed2" -c commit.gpgsign=false commit -q -m 'chore: init'
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_landed2/.env"

fx_landed2="$work/fixtures_landed2"
mkdir -p "$fx_landed2"
cat > "$fx_landed2/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[]}}}}
EOF
cat > "$fx_landed2/closed_issues.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}
EOF
cat > "$fx_landed2/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-96","title":"Harness 待辦池","description":"常駐","priority":1,"createdAt":"2020-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:harness"}]},
   "cycle":null,"project":null,"projectMilestone":null,"parent":null,"inverseRelations":{"nodes":[]}},
  {"identifier":"LS-996","title":"Story：反引號 token 命中","description":"後端需要 RPC 支援 `fancy_measurement_table`。\n\n## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:ui"}]},
   "cycle":null,"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF
mkdir -p "$work/bin_landed2"
cat > "$work/bin_landed2/curl" <<EOF
#!/bin/bash
fx="${fx_landed2}"
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'comments('*) echo '{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
  *'type: { in: ['*) cat "\$fx/closed_issues.json" ;;
  *'cycles('*) cat "\$fx/cycles.json" ;;
  *'issues('*) cat "\$fx/issues_page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：不應被呼叫（current 為 None 時不查 documents／cycle issues）"}]}' ;;
esac
EOF
chmod +x "$work/bin_landed2/curl"

out15="$(PATH="$work/bin_landed2:$PATH" bash "$plsh" --repo "$repo_landed2" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑮ LS-298 scope2 fixture exit 0"; else echo "✗ ⑮ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out15" | sed 's/^/    /' >&2; fail=1; fi
export OUT15="$out15"
py15="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT15"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False
backend = d["lanes"]["lane:backend"]["open_ticket"]
srcs = {s["id"]: s for s in backend["sources"]}
check("⑮ scope2：LS-996 仍列為候選（未被排除，只是附註）", "LS-996" in srcs)
check("⑮ scope2：LS-996 的 why 附「已落地：fancy_measurement_table → scripts/ops/fake-landed-LS298.sh:<行>（疑已有子票）」",
      "LS-996" in srcs
      and "已落地：fancy_measurement_table → scripts/ops/fake-landed-LS298.sh:" in srcs["LS-996"]["why"]
      and srcs["LS-996"]["why"].endswith("（疑已有子票）"))
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py15"
if [ "$(tail -1 <<<"$py15")" = OK ]; then :; else fail=1; fi

# ⑮b mutation：repo_landed_tokens() 恆回空字典 → LS-996 的 why 不再附已落地提示
mutdir15="$work/mut15"
rm -rf "$mutdir15"; mkdir -p "$mutdir15"
cp -R "${root}/scripts" "$mutdir15/scripts"
sed 's/^def repo_landed_tokens(root, tokens):$/def repo_landed_tokens(root, tokens):\n    return {}  # LS-298 mutation test (scope 2 disabled)/' \
  "${root}/scripts/ops/patrol_linear.py" > "$mutdir15/scripts/ops/patrol_linear.py"
if ! grep -q 'LS-298 mutation test (scope 2 disabled)' "$mutdir15/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑮b mutant 沒被正確合成" >&2; fail=1
else
  out15b="$(PATH="$work/bin_landed2:$PATH" bash "$mutdir15/scripts/ops/patrol-linear.sh" --repo "$repo_landed2" --json 2>&1)"
  export OUT15B="$out15b"
  if python3 -c 'import json,os; d=json.loads(os.environ["OUT15B"]); srcs={s["id"]:s for s in d["lanes"]["lane:backend"]["open_ticket"]["sources"]}; assert "已落地" not in srcs["LS-996"]["why"], srcs["LS-996"]["why"]' 2>"$work/mut15-err"; then
    echo "✓ ⑮b mutant（拿掉 git grep 提示）：LS-996 的 why 不再附已落地——證明 ⑮ scope2 的綠來自這段提示本身"
  else
    echo "✗ ⑮b mutant 未如預期翻轉" >&2; cat "$work/mut15-err" >&2; printf '%s\n' "$out15b" | sed 's/^/    /' >&2; fail=1
  fi
fi

# ---- ⑯（LS-298 scope 4）Ready（本 cycle）且 `.claude/worktrees/LS-<n>` 已建的票——lane 候補首位標
#      「（worktree 已建，待派）」，不再往下拉第二張候補（LS-251 事故：連兩輪誤拉候補、超過 lane 上限）----
repo_ready="$work/repo_ready"
git init -q -b main "$repo_ready"
git -C "$repo_ready" config user.email test@example.com
git -C "$repo_ready" config user.name Test
: > "$repo_ready/.gitkeep"; git -C "$repo_ready" add .gitkeep; git -C "$repo_ready" -c commit.gpgsign=false commit -q -m 'chore: init'
git -C "$repo_ready" worktree add -q "$work/wt/LS-997" -b ls997-branch
printf 'LINEAR_API_KEY=test-token-not-real\n' > "$repo_ready/.env"

fx_ready="$work/fixtures_ready"
mkdir -p "$fx_ready"
cat > "$fx_ready/cycles.json" <<'EOF'
{"data":{"team":{"cycles":{"nodes":[
  {"id":"cyc-5","number":5,"startsAt":"2020-01-01T00:00:00.000Z","endsAt":"2099-01-01T00:00:00.000Z","isActive":true}
]}}}}
EOF
cat > "$fx_ready/documents.json" <<'EOF'
{"data":{"documents":{"nodes":[{"id":"doc-1","title":"Cycle 5 規劃"}]}}}
EOF
cat > "$fx_ready/cycle_issues.json" <<'EOF'
{"data":{"cycle":{"issues":{"nodes":[]}}}}
EOF
# LS-997：lane:design、Ready、cycle 5、已建 worktree（scope4 觸發條件）。LS-998：lane:design、Backlog、
# cycle 5，票文完整、有效候補——用來檢驗「候補首位被 LS-997 佔走後，不會再往下拉 LS-998」（lane:design 上限 1）。
cat > "$fx_ready/issues_page1.json" <<'EOF'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"identifier":"LS-997","title":"設計：已派工待推進","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-01T00:00:00.000Z",
   "state":{"name":"Ready","type":"unstarted"},"labels":{"nodes":[{"name":"lane:design"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}},
  {"identifier":"LS-998","title":"設計：下一張候補","description":"## 驗收\n過","priority":2,"createdAt":"2026-01-02T00:00:00.000Z",
   "state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"lane:design"}]},
   "cycle":{"id":"cyc-5","number":5},"project":{"name":"Phase 1 test"},"projectMilestone":{"name":"M1"},"parent":null,
   "inverseRelations":{"nodes":[]}}
]}}}
EOF
mkdir -p "$work/bin_ready"
cat > "$work/bin_ready/curl" <<EOF
#!/bin/bash
fx="${fx_ready}"
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
  *) echo '{"errors":[{"message":"stub curl：不應被呼叫（design lane 有候補不觸發開票來源查詢）"}]}' ;;
esac
EOF
chmod +x "$work/bin_ready/curl"

out16="$(PATH="$work/bin_ready:$PATH" bash "$plsh" --repo "$repo_ready" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑯ LS-298 scope4 fixture exit 0"; else echo "✗ ⑯ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out16" | sed 's/^/    /' >&2; fail=1; fi
export OUT16="$out16"
py16="$(python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["OUT16"])
ok = True
def check(name, cond):
    global ok
    print(("✓ " if cond else "✗ ") + name)
    if not cond:
        ok = False
design = d["lanes"]["lane:design"]
check("⑯ scope4：候補首位＝LS-997（Ready＋worktree 已建）", design["candidates"] == ["LS-997"])
check("⑯ scope4：ready_dispatch 記為 LS-997", design.get("ready_dispatch") == "LS-997")
check("⑯ scope4：不選中、不產生動作（不拉第二張 LS-998）", design["chosen"] is None and design["actions"] == [])
check("⑯ scope4：不觸發開票（open_ticket 為 null）", design["open_ticket"] is None)
print("OK" if ok else "FAIL")
PYEOF
)"
printf '%s\n' "$py16"
if [ "$(tail -1 <<<"$py16")" = OK ]; then :; else fail=1; fi

out16h="$(PATH="$work/bin_ready:$PATH" bash "$plsh" --repo "$repo_ready" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "✗ ⑯ human 模式應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out16h" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out16h" 'LS-997（worktree 已建，待派）' '⑯ human：lane:design 行標「LS-997（worktree 已建，待派）」'

# ⑯b mutation：ready_dispatch_candidate() 恆回 None（拿掉 worktree 判斷）→ LS-998 被誤拉為第二張候補並選中
#      （重現 LS-251 事故：連兩輪誤要求再拉一張、超過 lane 上限 1）
mutdir16="$work/mut16"
rm -rf "$mutdir16"; mkdir -p "$mutdir16"
cp -R "${root}/scripts" "$mutdir16/scripts"
sed 's/^def ready_dispatch_candidate(issues, lane, current_cycle_number, worktrees):$/def ready_dispatch_candidate(issues, lane, current_cycle_number, worktrees):\n    return None  # LS-298 mutation test (scope 4 disabled)/' \
  "${root}/scripts/ops/patrol_linear.py" > "$mutdir16/scripts/ops/patrol_linear.py"
if ! grep -q 'LS-298 mutation test (scope 4 disabled)' "$mutdir16/scripts/ops/patrol_linear.py"; then
  echo "✗ ⑯b mutant 沒被正確合成" >&2; fail=1
else
  out16m="$(PATH="$work/bin_ready:$PATH" bash "$mutdir16/scripts/ops/patrol-linear.sh" --repo "$repo_ready" --json 2>&1)"
  export OUT16M="$out16m"
  if python3 -c 'import json,os; d=json.loads(os.environ["OUT16M"]); design=d["lanes"]["lane:design"]; assert design["chosen"]=="LS-998", design; assert any("save_issue LS-998 state=Ready cycle=5" in a for a in design["actions"]), design["actions"]' 2>"$work/mut16-err"; then
    echo "✓ ⑯b mutant（拿掉 worktree 判斷）：LS-998 被誤拉為第二張候補並選中——證明 ⑯ scope4 的綠來自這段判斷（重現 LS-251 事故）"
  else
    echo "✗ ⑯b mutant 未如預期翻轉" >&2; cat "$work/mut16-err" >&2; printf '%s\n' "$out16m" | sed 's/^/    /' >&2; fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ patrol-linear 自測失敗" >&2
  exit 1
fi
echo "✓ patrol-linear 自測通過"
