#!/bin/bash
# linear-post.sh／linear_post.py 的自測（LS-308 B1）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支備援腳本也適用：若 key 意外被印出、GraphQL errors 沒有讓腳本 exit 1、HTTP 層失敗
# （連線拒絕／4xx／5xx）被吞成假成功、或三個子命令中有一個查詢／變數組錯——這裡會紅。
#
# 手法：起一支本機的假 GraphQL 伺服器（純 Python `http.server`，不需要額外套件），$LINEAR_API_URL 指過去，
# 不打正式 Linear API。伺服器依序從 $STUB_QUEUE（JSONL，每行 `{"status":<int>,"body":<obj>}`）吐出回應——
# linear_post.py 每個子命令會依序發出 1～3 次 GraphQL 呼叫（get／state 各查兩次、comment 查兩次、state 查
# 三次），queue 用完後重複最後一行（測試只在乎前幾次呼叫，之後的呼叫在正常路徑下不會發生）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sh_wrap="${root}/scripts/ops/linear-post.sh"
fail=0
fail() { echo "✗ $1" >&2; fail=1; }
source "${root}/scripts/gates/lib/selftest-helpers.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP linear-post 自測（無 python3）"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

# ---- 假 GraphQL 伺服器：依序吐出 $STUB_QUEUE 的每一行；啟動後把實際 port 寫進 $STUB_PORT_FILE ----
SRV_PY="${work}/stub_server.py"
export STUB_QUEUE="${work}/queue.jsonl"
export STUB_SERVED="${work}/served.log"
STUB_PORT_FILE="${work}/port"
cat > "$SRV_PY" <<'PYEOF'
import http.server, json, os, sys

QUEUE = os.environ["STUB_QUEUE"]
SERVED = os.environ["STUB_SERVED"]
PORT_FILE = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        with open(QUEUE) as f:
            lines = [l for l in f.read().splitlines() if l.strip()]
        idx = 0
        if os.path.exists(SERVED):
            with open(SERVED) as f:
                idx = sum(1 for _ in f)
        if idx >= len(lines):
            idx = len(lines) - 1
        resp = json.loads(lines[idx])
        with open(SERVED, "a") as f:
            f.write("x\n")
        body = json.dumps(resp["body"]).encode()
        self.send_response(resp.get("status", 200))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
python3 "$SRV_PY" "$STUB_PORT_FILE" &
SRV_PID=$!
port=
for _ in $(seq 1 50); do
  [ -s "$STUB_PORT_FILE" ] && { port=$(cat "$STUB_PORT_FILE"); break; }
  sleep 0.1
done
if [ -z "$port" ]; then
  echo "✗ linear-post 自測：假伺服器 50 次輪詢後仍未寫出 port，放棄" >&2
  exit 1
fi
export LINEAR_API_URL="http://127.0.0.1:${port}/graphql"
export LINEAR_API_KEY="fake-test-key-should-never-be-printed"

queue() { : > "$STUB_QUEUE"; : > "$STUB_SERVED"; for l in "$@"; do printf '%s\n' "$l" >> "$STUB_QUEUE"; done; }
run() { bash "$sh_wrap" "$@"; }

ISSUE_OK='{"status":200,"body":{"data":{"issue":{"id":"uuid-1","team":{"id":"team-1"}}}}}'

# ---- ① get：成功路徑，印 title／state／labels／description ----
queue '{"status":200,"body":{"data":{"issue":{"identifier":"LS-308","title":"harness debt 8","description":"desc body","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"lane:harness"}]},"cycle":{"number":3},"parent":null,"comments":{"nodes":[]}}}}}'
out="$(run get LS-308 2>&1)"; got=$?
expect_exit 0 "$got" '① get：成功路徑 exit 0'
expect_has "$out" '# LS-308 harness debt 8' '① get：印標題'
expect_has "$out" 'state=In Progress' '① get：印狀態'
expect_has "$out" 'desc body' '① get：印描述'
expect_not_has "$out" 'fake-test-key-should-never-be-printed' '① get：stdout 不含 key'

# ---- ② get --comments：另列留言 ----
queue '{"status":200,"body":{"data":{"issue":{"identifier":"LS-308","title":"t","description":"","state":{"name":"QA"},"labels":{"nodes":[]},"cycle":null,"parent":null,"comments":{"nodes":[{"id":"c1234567890","createdAt":"2026-09-16T10:00:00Z","body":"hello from comment"}]}}}}}'
out="$(run get LS-308 --comments 2>&1)"; got=$?
expect_exit 0 "$got" '② get --comments：exit 0'
expect_has "$out" 'comment c1234567' '② get --comments：印 comment id 前八碼'
expect_has "$out" 'hello from comment' '② get --comments：印 comment body'

# ---- ③ get：查無此票（issue 為 null）→ exit 1 ----
queue '{"status":200,"body":{"data":{"issue":null}}}'
out="$(run get LS-9999 2>&1)"; got=$?
expect_exit 1 "$got" '③ get：issue 為 null → exit 1'
expect_has "$out" 'not found' '③ get：印查無此票'

# ---- ④ comment：成功路徑，印新 comment id ----
body_file="${work}/body.md"
printf 'test comment body\n' > "$body_file"
queue "$ISSUE_OK" '{"status":200,"body":{"data":{"commentCreate":{"success":true,"comment":{"id":"new-comment-id-1"}}}}}'
out="$(run comment LS-308 "$body_file" 2>&1)"; got=$?
expect_exit 0 "$got" '④ comment：成功路徑 exit 0'
expect_has "$out" 'new-comment-id-1' '④ comment：印新 comment id'
expect_not_has "$out" 'fake-test-key-should-never-be-printed' '④ comment：stdout 不含 key'

# ---- ⑤ comment：commentCreate success=false → exit 1 ----
queue "$ISSUE_OK" '{"status":200,"body":{"data":{"commentCreate":{"success":false,"comment":null}}}}'
out="$(run comment LS-308 "$body_file" 2>&1)"; got=$?
expect_exit 1 "$got" '⑤ comment：success=false → exit 1'

# ---- ⑥ state：成功路徑，印新狀態 ----
queue "$ISSUE_OK" \
  '{"status":200,"body":{"data":{"workflowStates":{"nodes":[{"id":"state-qa","name":"QA"},{"id":"state-done","name":"Done"}]}}}}' \
  '{"status":200,"body":{"data":{"issueUpdate":{"success":true,"issue":{"identifier":"LS-308","state":{"name":"QA"}}}}}}'
out="$(run state LS-308 QA 2>&1)"; got=$?
expect_exit 0 "$got" '⑥ state：成功路徑 exit 0'
expect_has "$out" 'LS-308 QA' '⑥ state：印票號與新狀態'

# ---- ⑦ state：目標狀態名不在 team 的 workflow states 內 → exit 1，列出可用狀態 ----
queue "$ISSUE_OK" '{"status":200,"body":{"data":{"workflowStates":{"nodes":[{"id":"state-qa","name":"QA"}]}}}}'
out="$(run state LS-308 NoSuchState 2>&1)"; got=$?
expect_exit 1 "$got" '⑦ state：狀態名不存在 → exit 1'
expect_has "$out" 'state not found' '⑦ state：印查無此狀態'

# ---- ⑧ GraphQL errors（HTTP 200 但 body 同時帶 "errors" 與看起來合法的 "data"）→ exit 1、印 errors 內容、
#      key 不外洩——"data" 故意也給合法形狀，讓下面 ⑫ 的 mutation 在拿掉判斷後能走到「照舊回傳成功」而不是
#      直接 KeyError 崩潰，兩者都會是非 0 exit code、崩潰不能拿來冒充「判斷式在擋」的證據。
ERR_BODY='{"status":200,"body":{"errors":[{"message":"Authentication required, not authenticated"}],"data":{"issue":{"identifier":"LS-308","title":"t","description":"","state":{"name":"QA"},"labels":{"nodes":[]},"cycle":null,"parent":null,"comments":{"nodes":[]}}}}}'
queue "$ERR_BODY"
out="$(run get LS-308 2>&1)"; got=$?
expect_exit 1 "$got" '⑧ GraphQL errors → exit 1'
expect_has "$out" 'Authentication required' '⑧ 印 GraphQL errors 內容'
expect_not_has "$out" 'fake-test-key-should-never-be-printed' '⑧ 不外洩 key'

# ---- ⑨ HTTP 層錯誤（500）→ exit 1，不假裝成功 ----
queue '{"status":500,"body":{"error":"internal server error"}}'
out="$(run get LS-308 2>&1)"; got=$?
expect_exit 1 "$got" '⑨ HTTP 500 → exit 1（不假裝成功）'

# ---- ⑩ 連線失敗（endpoint 指到沒人聽的 port）→ exit 1，不掛住 ----
out="$(LINEAR_API_URL="http://127.0.0.1:1/graphql" run get LS-308 2>&1)"; got=$?
expect_exit 1 "$got" '⑩ 連線被拒 → exit 1（不掛住）'
expect_not_has "$out" 'fake-test-key-should-never-be-printed' '⑩ 不外洩 key'

# ---- ⑪ 用法錯誤：缺子命令／未知子命令 → exit 2 ----
out="$(run 2>&1)"; got=$?
expect_exit 2 "$got" '⑪a 無參數 → exit 2'
out="$(run bogus 2>&1)"; got=$?
expect_exit 2 "$got" '⑪b 未知子命令 → exit 2'
out="$(run comment LS-308 2>&1)"; got=$?
expect_exit 2 "$got" '⑪c comment 缺 body-file 參數 → exit 2'
out="$(run state LS-308 2>&1)"; got=$?
expect_exit 2 "$got" '⑪d state 缺 state-name 參數 → exit 2'

# ---- ⑫ mutation：把 gql() 裡「errors in out → exit 1」判斷拿掉，驗證 ⑧ 這個負樣本會變成「照舊回傳成功」
#      （exit 0），證明原本是這段判斷在擋（mutant 檔獨立目錄，需連 linear-archive.py 一起複製過去，否則
#      import 找不到檔案、連 mutation 本身要不要生效都測不出來）----
mut_dir="${work}/mutant"
mkdir -p "$mut_dir"
mut_py="${mut_dir}/linear_post.py"
sed '/if "errors" in out:/,+2 s/^/#/' "${root}/scripts/ops/linear_post.py" > "$mut_py"
cp "${root}/scripts/ops/linear-archive.py" "${mut_dir}/linear-archive.py"
if grep -qF '#    if "errors" in out:' "$mut_py"; then
  ok '⑫ mutant 已把 errors 判斷整段註解掉'
else
  fail '⑫ mutant 合成失敗（sed 樣式對不上 linear_post.py 現在的形狀）'
fi
queue "$ERR_BODY"
out="$(python3 "$mut_py" get LS-308 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '# LS-308 t'; then
  ok '⑫ mutant：拿掉 errors 判斷後 ⑧ 的負樣本改回 exit 0、照 data 印出（證明原本是這段判斷在擋，mutation 有效）'
else
  fail "⑫ mutant 應 exit 0 並印出 issue（實得 exit ${got}，mutation 沒有如預期改變行為，斷言本身可能失效）"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ linear-post 自測失敗" >&2
  exit 1
fi
echo "✓ linear-post 自測通過（${selftest_helpers_n} 組樣本）"
