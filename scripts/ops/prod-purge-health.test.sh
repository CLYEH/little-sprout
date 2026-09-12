#!/bin/bash
# prod-purge-health.sh 的自測（LS-235）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對正式站健康度巡檢也適用：若退化成——全 2xx 卻印 ⚠、有一筆
# 非 2xx 卻沒偵測到、缺對應回應（http_status_code 為 null）卻沒偵測到、exit code
# 與訊息不一致——這裡會紅。全程用 `--fixture` 餵事先準備好的 JSON，不打真的
# `supabase db query --linked`（唯讀查正式站的部分只在真的部署後由票 handoff 的
# 「已驗證」欄記錄，見票文驗收第 2 條）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/prod-purge-health.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

out=; rc=
# expect <期望 exit> <名稱> <輸出必含|''> -- <prod-purge-health.sh 參數…>
expect() {
  local want=$1 name=$2 must=$3; shift 3
  out="$(bash "$script" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${rc}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
has()    { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt()  { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }

# ---- ① 三組必要 fixture（票文驗收）----

# (a) 全 2xx → ✓、exit 0
cat > "$work/all-2xx.json" <<'EOF'
[
  {"run_date":"2026-09-12","purge_run_id":"a1","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-12T19:05:00Z"},
  {"run_date":"2026-09-11","purge_run_id":"a2","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-11T19:05:00Z"},
  {"run_date":"2026-09-10","purge_run_id":"a3","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-10T19:05:00Z"}
]
EOF
expect 0 '① 全 2xx → exit 0 印 ✓' '✓ purge-storage 最近 3 次呼叫皆為 2xx' --fixture "$work/all-2xx.json"
has '① 全 2xx 訊息附最新一筆日期與狀態' "$out" '2026-09-12 HTTP 200'
hasnt '① 全 2xx 不印 ⚠' "$out" '⚠'

# (b) 一筆 500（09-11 Gateway Timeout 那次事故的重現）→ ⚠、exit 1
cat > "$work/one-500.json" <<'EOF'
[
  {"run_date":"2026-09-12","purge_run_id":"b1","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-12T19:05:00Z"},
  {"run_date":"2026-09-11","purge_run_id":"b2","http_status_code":500,"http_error_msg":"Gateway Timeout","http_created":"2026-09-11T19:05:03Z"},
  {"run_date":"2026-09-10","purge_run_id":"b3","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-10T19:05:00Z"}
]
EOF
expect 1 '② 一筆 500 → exit 1 印 ⚠' '⚠ purge-storage 健康度異常' --fixture "$work/one-500.json"
has '② 訊息點名異常日期與狀態碼' "$out" '2026-09-11：HTTP 500（Gateway Timeout）'

# (c) 缺列（http_status_code 為 null，代表這天找不到對應的 HTTP 回應）→ ⚠、exit 1
cat > "$work/missing-row.json" <<'EOF'
[
  {"run_date":"2026-09-12","purge_run_id":"c1","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-12T19:05:00Z"},
  {"run_date":"2026-09-11","purge_run_id":"c2","http_status_code":null,"http_error_msg":null,"http_created":null},
  {"run_date":"2026-09-10","purge_run_id":"c3","http_status_code":200,"http_error_msg":null,"http_created":"2026-09-10T19:05:00Z"}
]
EOF
expect 1 '③ 缺列 → exit 1 印 ⚠' '⚠ purge-storage 健康度異常' --fixture "$work/missing-row.json"
has '③ 訊息點名缺少對應回應' "$out" '2026-09-11：缺少對應的 purge-storage HTTP 回應'

# ---- ② 邊界／參數驗證（fail closed，不落到「查無資料」那一種泛用訊息）----

echo '[]' > "$work/empty.json"
expect 1 '④ 空陣列 → exit 1（沒有任何紀錄可供比對）' '⚠ 沒有任何 purge_runs 紀錄可供比對' --fixture "$work/empty.json"
expect 2 '⑤ --limit 非數字 → exit 2' '必須是正整數' --limit abc --fixture "$work/all-2xx.json"
expect 2 '⑥ --limit 0 → exit 2' '必須是正整數' --limit 0 --fixture "$work/all-2xx.json"
expect 2 '⑦ --limit 缺值 → exit 2' '--limit 缺值' --limit
expect 2 '⑧ --fixture 缺值 → exit 2' '--fixture 缺值' --fixture
expect 2 '⑨ 未知參數 → exit 2' '未知參數' --bogus
expect 1 '⑩ --fixture 指定檔案不存在 → exit 1（fail loud，不是誤報健康）' '查無資料' --fixture "$work/does-not-exist.json"

# ---- ③ --limit N 真的接得到（不影響 fixture 內容本身，只驗參數有被解析）----
expect 0 '⑪ --limit 3 搭 fixture 仍正常運作' '✓ purge-storage 最近 3 次呼叫皆為 2xx' --limit 3 --fixture "$work/all-2xx.json"

# ---- ④ 混合案例：多筆異常一次列全，不是只列第一筆 ----
cat > "$work/two-problems.json" <<'EOF'
[
  {"run_date":"2026-09-12","purge_run_id":"d1","http_status_code":503,"http_error_msg":"Service Unavailable","http_created":"2026-09-12T19:05:00Z"},
  {"run_date":"2026-09-11","purge_run_id":"d2","http_status_code":null,"http_error_msg":null,"http_created":null}
]
EOF
expect 1 '⑫ 兩筆都異常 → 都列出' '' --fixture "$work/two-problems.json"
has '⑫ 列出 09-12 的 503' "$out" '2026-09-12：HTTP 503（Service Unavailable）'
has '⑫ 列出 09-11 缺列' "$out" '2026-09-11：缺少對應的 purge-storage HTTP 回應'

if [ "$fail" -ne 0 ]; then
  echo "✗ prod-purge-health 自測失敗" >&2
  exit 1
fi
echo "✓ prod-purge-health 自測通過（12 組樣本）"
