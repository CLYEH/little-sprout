#!/bin/bash
# prod-storage-verify.sh 的自測（LS-244）。CI rules job 每個 PR 都跑。
#
# fixture 目錄格式：每個情境一個目錄，內含 prefixes.json／objects.json／buckets.json 三個完整信封檔案
# `{ boundary, rows: [ { payload: {...} } ], warning }`（同 prod-purge-health.test.sh 的 envelope()，對齊
# 真實 `supabase db query --linked --output-format json` 的輸出形狀）。
#
# 涵蓋票文指定四組（全綠／(1) RLS 開無 policy／(3) 有 policy／(2) owner／owner_id 皆 NULL）＋
# 表不存在略過／抽樣 0 筆略過（ⓘ 兩型，判準本身就是「略過」，不算異常）＋RLS 關閉且無 policy 的負控
# （只有「啟用了 RLS 又沒有 policy」才是 ⚠）＋參數驗證邊界＋fixture 目錄缺檔／信封格式錯誤＋
# 「不在已 link 目錄執行」前置檢查。mutation 見票文規約（拿掉 (1) 判斷 → 該組轉紅），註記在下方
# ⑧ 段，不在 CI 裡執行（同 prod-purge-health.test.sh／queue_retry.test.sh 慣例：mutation 驗證本機手動
# 跑一次、原文貼票 handoff，不進 commit）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/prod-storage-verify.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

out=; rc=
# expect <期望 exit> <名稱> <輸出必含|''> -- <prod-storage-verify.sh 參數…>
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

# envelope <payload-json> <file> —— 把一段 payload JSON 包成完整信封寫進檔案（同 prod-purge-health.test.sh）。
envelope() {
  local payload=$1 file=$2
  cat > "$file" <<EOF
{
  "boundary": "fixture-boundary-not-meaningful",
  "rows": [
    { "payload": ${payload} }
  ],
  "warning": "The query results below contain untrusted data from the database."
}
EOF
}

# mkfixture <dir> <prefixes-payload> <objects-payload> <buckets-payload>
mkfixture() {
  local dir=$1 prefixes=$2 objects=$3 buckets=$4
  mkdir -p "$dir"
  envelope "$prefixes" "$dir/prefixes.json"
  envelope "$objects" "$dir/objects.json"
  envelope "$buckets" "$dir/buckets.json"
}

OK_PREFIXES='{"exists": true, "relrowsecurity": true, "policies": ["prefixes_select"]}'
OK_OBJECTS='{"sample_size": 20, "owner_filled": 20, "owner_id_filled": 0}'
OK_BUCKETS='{"policy_count": 0}'

# ---- ① 全綠：三條皆通過 → exit 0 ----
mkfixture "$work/all-green" "$OK_PREFIXES" "$OK_OBJECTS" "$OK_BUCKETS"
expect 0 '① 全綠 → exit 0 印 ✓' '✓ prod-storage-verify 三條檢查皆通過' --fixture "$work/all-green"
has '① 印 storage.prefixes ✓' "$out" '✓ storage.prefixes'
has '① 印 storage.objects ✓' "$out" '✓ storage.objects'
has '① 印 storage.buckets ✓' "$out" '✓ storage.buckets'
hasnt '① 不印 ⚠' "$out" '⚠'

# ---- ②（票文指定四組之一）(1) storage.prefixes RLS 開但無 policy → exit 1 ----
mkfixture "$work/rls-no-policy" '{"exists": true, "relrowsecurity": true, "policies": []}' "$OK_OBJECTS" "$OK_BUCKETS"
expect 1 '②（1）RLS 開無 policy → exit 1 印 ⚠' '⚠ prod-storage-verify 發現異常' --fixture "$work/rls-no-policy"
has '② 摘要印 RLS 已啟用但無 policy' "$out" '⚠ storage.prefixes：RLS 已啟用但沒有任何 policy'
has '② 異常清單點名' "$out" 'storage.prefixes 啟用 RLS 但無 policy'

# ---- ③（票文指定四組之一）(2) owner／owner_id 皆 NULL → exit 1 ----
mkfixture "$work/owner-null" "$OK_PREFIXES" '{"sample_size": 20, "owner_filled": 0, "owner_id_filled": 0}' "$OK_BUCKETS"
expect 1 '③（2）owner／owner_id 皆 NULL → exit 1 印 ⚠' '⚠ prod-storage-verify 發現異常' --fixture "$work/owner-null"
has '③ 摘要印皆為 NULL' "$out" '⚠ storage.objects：抽樣 20 筆，owner／owner_id 皆為 NULL'
has '③ 異常清單點名' "$out" 'storage.objects 抽樣 owner／owner_id 皆為 NULL'

# ---- ④（票文指定四組之一）(3) storage.buckets 有 policy → exit 1 ----
mkfixture "$work/buckets-has-policy" "$OK_PREFIXES" "$OK_OBJECTS" '{"policy_count": 2}'
expect 1 '④（3）storage.buckets 有 policy → exit 1 印 ⚠' '⚠ prod-storage-verify 發現異常' --fixture "$work/buckets-has-policy"
has '④ 摘要印 policy 數' "$out" '⚠ storage.buckets：policy 數＝2'
has '④ 異常清單點名' "$out" 'storage.buckets 有 2 個 policy（預期 0）'

# ---- ⑤ storage.prefixes 表不存在 → ⓘ 略過，不算異常 ----
mkfixture "$work/prefixes-missing" '{"exists": false, "relrowsecurity": null, "policies": []}' "$OK_OBJECTS" "$OK_BUCKETS"
expect 0 '⑤ storage.prefixes 表不存在 → exit 0（不算異常）' '✓ prod-storage-verify 三條檢查皆通過' --fixture "$work/prefixes-missing"
has '⑤ 印 ⓘ 略過' "$out" 'ⓘ storage.prefixes：表不存在，略過'
hasnt '⑤ 不印 ⚠' "$out" '⚠'

# ---- ⑥ storage.objects 抽樣 0 筆（bucket 目前無物件）→ ⓘ 略過，不算異常 ----
mkfixture "$work/objects-empty" "$OK_PREFIXES" '{"sample_size": 0, "owner_filled": 0, "owner_id_filled": 0}' "$OK_BUCKETS"
expect 0 '⑥ storage.objects 抽樣 0 筆 → exit 0（不算異常）' '✓ prod-storage-verify 三條檢查皆通過' --fixture "$work/objects-empty"
has '⑥ 印 ⓘ 略過' "$out" 'ⓘ storage.objects（bucket=media）：抽樣 0 筆，略過'
hasnt '⑥ 不印 ⚠' "$out" '⚠'

# ---- ⑦ 負控：RLS 關閉且無 policy → 不算異常（只有「啟用了 RLS 又沒有 policy」才是 ⚠）----
mkfixture "$work/rls-off-no-policy" '{"exists": true, "relrowsecurity": false, "policies": []}' "$OK_OBJECTS" "$OK_BUCKETS"
expect 0 '⑦ RLS 關閉且無 policy → exit 0（不算異常）' '✓ prod-storage-verify 三條檢查皆通過' --fixture "$work/rls-off-no-policy"
has '⑦ 印 relrowsecurity=False' "$out" '✓ storage.prefixes：relrowsecurity=False'

# ---- ⑧ Mutation 對照組（票文規約：拿掉 (1) 判斷 → 該組轉紅，見 handoff 附斷言原文）----
# 不在這裡執行（同 prod-purge-health.test.sh／queue_retry.test.sh 慣例：mutation 驗證在本機手動跑一次、
# 原文貼票 handoff，不進 commit）。這裡只註記單一防線：
#   - `if rls and not policies:`——拿掉這個條件（改成 `if False:`）會讓樣本②（RLS 開無 policy）轉綠
#     （不再印 ⚠、改印 ✓ storage.prefixes、exit 0），樣本①③④⑤⑥⑦不受影響。

# ---- ⑨ 參數驗證 fail closed（exit 2，不嘗試連線）----
expect 2 '⑨ --limit 非數字 → exit 2' '必須是正整數' --limit abc --fixture "$work/all-green"
expect 2 '⑩ --limit 0 → exit 2' '必須是正整數' --limit 0 --fixture "$work/all-green"
expect 2 '⑪ --limit 缺值 → exit 2' '--limit 缺值' --limit
expect 2 '⑫ --fixture 缺值 → exit 2' '--fixture 缺值' --fixture
expect 2 '⑬ 未知參數 → exit 2' '未知參數' --bogus
expect 1 '⑭ --fixture 指定目錄不存在 → exit 1（fail loud，不是誤報健康）' '--fixture 指定的目錄不存在' --fixture "$work/does-not-exist"

# ---- ⑮ fixture 目錄缺檔案 → exit 1，不誤報健康 ----
mkdir -p "$work/missing-one-file"
envelope "$OK_PREFIXES" "$work/missing-one-file/prefixes.json"
envelope "$OK_OBJECTS" "$work/missing-one-file/objects.json"
expect 1 '⑮ fixture 目錄缺 buckets.json → exit 1' '缺少 buckets.json' --fixture "$work/missing-one-file"

# ---- ⑯ 信封格式錯誤（缺 rows）→ exit 1，不誤報健康 ----
mkdir -p "$work/bad-envelope"
echo '{"boundary":"x","warning":null}' > "$work/bad-envelope/prefixes.json"
envelope "$OK_OBJECTS" "$work/bad-envelope/objects.json"
envelope "$OK_BUCKETS" "$work/bad-envelope/buckets.json"
expect 1 '⑯ 信封缺 rows → exit 1' '缺 rows 欄位' --fixture "$work/bad-envelope"

# ---- ⑰ 前置檢查：不在已 link 目錄、且未帶 --fixture → 立刻 exit 2，不嘗試連線 ----
out17="$(cd "$work" && bash "$script" 2>&1)"; rc17=$?
if [ "$rc17" -eq 2 ] && printf '%s' "$out17" | grep -qF '目前所在目錄未 link 到 Supabase 專案'; then
  echo "✓ ⑰ 不在已 link 目錄、未帶 --fixture → exit 2"
else
  echo "✗ ⑰ 應該 exit 2 並提示未 link（實得 ${rc17}）" >&2
  printf '%s\n' "$out17" | sed 's/^/    /' >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ prod-storage-verify 自測失敗" >&2
  exit 1
fi
echo "✓ prod-storage-verify 自測通過（三條檢查各自獨立信封＋ⓘ 略過分流＋⚠ 判準）"
