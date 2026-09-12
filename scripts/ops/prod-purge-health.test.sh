#!/bin/bash
# prod-purge-health.sh 的自測（LS-235；R2 重做，merge-review R1 comment
# da96a7d0）。CI rules job 每個 PR 都跑。
#
# R1 版本的 fixture 直接餵「已經整理好的裸陣列」，完全繞過真通道下唯一真正在
# 做事的那層解析（CLI --output-format json 的信封萃取）——12 組全綠、真通道
# 卻永遠印「查無資料」（M1 major）。R2 起所有 fixture 一律是**完整信封**
# `{ boundary, rows: [ { payload: {...} } ], warning }`，跟 2026-09-13 從主
# checkout 對正式站實跑 `supabase db query --linked --output-format json` 取得
# 的真實形狀逐欄位一致（見 envelope() helper；job_triggered_days／
# purge_run_days／missing_*_dates／latest_http_* 八個欄位，boundary／warning
# 兩個信封本身的欄位值不影響解析，用固定占位字串）——自測跟真通道走同一條
# `fetch_raw_output()`／python3 解析路徑，不會再出現「自測全綠、真通道全滅」
# 的落差。
#
# 涵蓋票文指定四組（全綠／缺一日／最新 HTTP 500／保留期外無回應不算異常）＋
# 對稱補上「排程未觸發缺一日」（M2 修法：job 觸發與 purge_runs 兩個主訊號各自
# 獨立判定，不應該只有其中一邊有測試覆蓋）＋參數驗證邊界＋「不在已 link 目錄
# 執行」的前置檢查（i3）。
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
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }

# envelope <payload-json> <file> —— 把一段 payload JSON 包成完整信封寫進檔案，
# 對齊真實 `supabase db query --linked --output-format json` 的輸出形狀
# （2026-09-13 從主 checkout 對正式站實跑取得，見票 handoff 附的原文）。
envelope() {
  local payload=$1 file=$2
  cat > "$file" <<EOF
{
  "boundary": "fixture-boundary-not-meaningful",
  "rows": [
    {
      "payload": ${payload}
    }
  ],
  "warning": "The query results below contain untrusted data from the database."
}
EOF
}

# ---- ① 全綠：排程觸發 7/7、purge_runs 7/7、最新 HTTP 200 → exit 0 印 ✓ ----
envelope '{
  "window_days": 7,
  "job_triggered_days": 7,
  "missing_job_trigger_dates": [],
  "purge_run_days": 7,
  "missing_purge_run_dates": [],
  "latest_http_status_code": 200,
  "latest_http_error_msg": null,
  "latest_http_created": "2026-09-12T19:15:00.000000+00:00"
}' "$work/all-green.json"
expect 0 '① 全綠 → exit 0 印 ✓' '✓ purge-storage 最近 7 天排程與 purge_runs 皆完整' --fixture "$work/all-green.json"
has '① 印排程觸發 7/7' "$out" '排程觸發：7/7（ls153-purge-storage-daily）'
has '① 印 purge_runs 7/7' "$out" 'purge_runs：7/7'
has '① 印最新 HTTP 200' "$out" '最新 HTTP 回應：200'
hasnt '① 不印 ⚠' "$out" '⚠'

# ---- ② purge_runs 缺一日 → exit 1 印 ⚠（票文指定四組之一）----
envelope '{
  "window_days": 7,
  "job_triggered_days": 7,
  "missing_job_trigger_dates": [],
  "purge_run_days": 6,
  "missing_purge_run_dates": ["2026-09-08"],
  "latest_http_status_code": 200,
  "latest_http_error_msg": null,
  "latest_http_created": "2026-09-12T19:15:00.000000+00:00"
}' "$work/missing-purge-run-day.json"
expect 1 '② purge_runs 缺一日 → exit 1 印 ⚠' '⚠ purge-storage 健康度異常' --fixture "$work/missing-purge-run-day.json"
has '② 摘要列出缺 6/7' "$out" 'purge_runs：6/7，缺：2026-09-08'
has '② 異常清單點名缺列日期' "$out" 'purge_runs 有 1 天缺列：2026-09-08'

# ---- ②b 排程觸發缺一日（對稱補測：M2 兩個主訊號各自獨立判定，不能只測其中一邊）----
envelope '{
  "window_days": 7,
  "job_triggered_days": 6,
  "missing_job_trigger_dates": ["2026-09-09"],
  "purge_run_days": 7,
  "missing_purge_run_dates": [],
  "latest_http_status_code": 200,
  "latest_http_error_msg": null,
  "latest_http_created": "2026-09-12T19:15:00.000000+00:00"
}' "$work/missing-job-trigger-day.json"
expect 1 '②b 排程觸發缺一日 → exit 1 印 ⚠（與 purge_runs 缺日獨立判定）' '⚠ purge-storage 健康度異常' --fixture "$work/missing-job-trigger-day.json"
has '②b 摘要列出缺 6/7' "$out" '排程觸發：6/7（ls153-purge-storage-daily），缺：2026-09-09'
has '②b 異常清單點名未觸發日期' "$out" '排程有 1 天未觸發：2026-09-09'

# ---- ③ 最新 HTTP 500（09-11 Gateway Timeout 事故重現，票文指定四組之一）----
# 直接採用 2026-09-13 從主 checkout 對正式站實跑取得的真實信封形狀（僅 boundary
# 占位字串換掉，其餘欄位與真實回應逐字一致）。
envelope '{
  "job_triggered_days": 7,
  "latest_http_created": "2026-09-11T19:15:00.157621+00:00",
  "latest_http_error_msg": null,
  "latest_http_status_code": 500,
  "missing_job_trigger_dates": [],
  "missing_purge_run_dates": [],
  "purge_run_days": 7,
  "window_days": 7
}' "$work/latest-500.json"
expect 1 '③ 最新 HTTP 500 → exit 1 印 ⚠' '⚠ purge-storage 健康度異常' --fixture "$work/latest-500.json"
has '③ 摘要印出 500' "$out" '最新 HTTP 回應：500（2026-09-11T19:15:00.157621+00:00）'
has '③ 異常清單點名非 2xx' "$out" '最新 HTTP 回應非 2xx：500'

# ---- ④ 保留期外無回應（net._http_response 查不到任何列）→ 不算異常，仍是 exit 0（票文指定四組之一）----
envelope '{
  "window_days": 7,
  "job_triggered_days": 7,
  "missing_job_trigger_dates": [],
  "purge_run_days": 7,
  "missing_purge_run_dates": [],
  "latest_http_status_code": null,
  "latest_http_error_msg": null,
  "latest_http_created": null
}' "$work/retention-expired.json"
expect 0 '④ 保留期外無回應 → exit 0（不算異常）' '✓ purge-storage 最近 7 天排程與 purge_runs 皆完整' --fixture "$work/retention-expired.json"
has '④ 摘要印「保留期外，無法核對」' "$out" '最新 HTTP 回應：保留期外，無法核對（net._http_response 僅保留約 6 小時）'
hasnt '④ 不印 ⚠' "$out" '⚠'

# ---- ⑤ Mutation 對照組（票文規約：拿掉某個判斷 → 對應樣本轉紅，見 handoff 附斷言原文）----
# 不在這裡執行 mutation（同 queue_retry.test.sh 慣例：mutation 驗證在本機手動
# 跑一次、原文貼票 handoff，不進 commit）。這裡只註記哪一行是「非 2xx」判斷的
# 單一防線：prod-purge-health.sh 的
# `if not (200 <= int(latest_status) < 300):`——拿掉這個條件（改成 `if False:`）
# 會讓樣本 ③ 轉紅（不再印 ⚠、exit 0），而樣本 ①④ 不受影響（它們的
# latest_http_status_code 本來就是 200／null）。

# ---- ⑥ 參數驗證 fail closed（exit 2，不嘗試連線）----
expect 2 '⑥ --limit 非數字 → exit 2' '必須是正整數' --limit abc --fixture "$work/all-green.json"
expect 2 '⑦ --limit 0 → exit 2' '必須是正整數' --limit 0 --fixture "$work/all-green.json"
expect 2 '⑧ --limit 缺值 → exit 2' '--limit 缺值' --limit
expect 2 '⑨ --fixture 缺值 → exit 2' '--fixture 缺值' --fixture
expect 2 '⑩ 未知參數 → exit 2' '未知參數' --bogus
expect 1 '⑪ --fixture 指定檔案不存在 → exit 1（fail loud，不是誤報健康）' '--fixture 指定的檔案不存在' --fixture "$work/does-not-exist.json"

# ---- ⑫ 信封格式錯誤（缺 rows／rows 為空／payload 不是物件）→ exit 1，不誤報健康 ----
echo '{"boundary":"x","warning":null}' > "$work/no-rows.json"
expect 1 '⑫a 信封缺 rows → exit 1' '缺 rows 欄位' --fixture "$work/no-rows.json"
echo '{"boundary":"x","rows":[],"warning":null}' > "$work/empty-rows.json"
expect 1 '⑫b rows 為空 → exit 1' 'rows 為空' --fixture "$work/empty-rows.json"
echo 'not json at all' > "$work/not-json.json"
expect 1 '⑫c 不是合法 JSON → exit 1' '不是合法 JSON' --fixture "$work/not-json.json"

# ---- ⑬ 前置檢查（i3）：不在已 link 目錄、且未帶 --fixture → 立刻 exit 2，不嘗試連線 ----
out13="$(cd "$work" && bash "$script" 2>&1)"; rc13=$?
if [ "$rc13" -eq 2 ] && printf '%s' "$out13" | grep -qF '目前所在目錄未 link 到 Supabase 專案'; then
  echo "✓ ⑬ 不在已 link 目錄、未帶 --fixture → exit 2"
else
  echo "✗ ⑬ 應該 exit 2 並提示未 link（實得 ${rc13}）" >&2
  printf '%s\n' "$out13" | sed 's/^/    /' >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ prod-purge-health 自測失敗" >&2
  exit 1
fi
echo "✓ prod-purge-health 自測通過（信封格式解析＋雙訊號設計，17 組樣本）"
