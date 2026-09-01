#!/bin/bash
# scripts/gates/linear-issue-check.test.sh（LS-77）
#
# 自測 scripts/gates/linear-issue-check.sh：六情境（建票缺 project／Phase 缺 milestone／
# Task 缺 parent／無 lane／合規／更新票一律放行）＋ labels 多於一個 lane:* ＋ fail-closed
# 三態（空 stdin／JSON 壞掉／jq 與 python3 皆缺）＋ jq 缺時 python3 備援＋四條 deny 規則各一個
# mutant（拿掉該規則區塊後，原本會 deny 的同一份 payload 必須改判 allow，證明測試真的測到
# 那個區塊、不是同一份 payload 湊巧一直 allow——同 scripts/hooks/pretool.test.sh 的 F5 慣例）。
# CI rules job 每個 PR 都跑。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${root}/scripts/gates/linear-issue-check.sh"
fail=0

# ---- payload 建構：只需要 tool_input，不需要 tool_name（matcher 本身已限定工具）----
payload() {  # $1=JSON 字串（tool_input 的內容）
  printf '{"tool_input":%s}' "$1"
}

# expect <label> <want_exit> <payload>：deny（!=0，本檔案只用 2）驗輸出含 deny JSON；
# allow（0）驗無輸出。
expect() {
  local label=$1 want=$2 payload=$3 out got
  out=$(printf '%s' "$payload" | bash "$gate" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ ${label}（期望 exit ${want}，實得 ${got}；輸出：${out}）" >&2
    fail=1
    return
  fi
  if [ "$want" -eq 0 ]; then
    if [ -n "$out" ]; then
      echo "✗ ${label}（allow 應無輸出，實得：${out}）" >&2
      fail=1
      return
    fi
  else
    case "$out" in
      *'"permissionDecision":"deny"'*) ;;
      *) echo "✗ ${label}（exit=${want} 但輸出缺 deny JSON：${out}）" >&2; fail=1; return ;;
    esac
  fi
  echo "✓ ${label}"
}

# ============================================================
# 六情境（票文／派工 prompt 列的清單）
# ============================================================
expect '① 建票缺 project（deny）' 2 "$(payload '{"title":"Foo","labels":["lane:harness"]}')"
expect '② Phase 專案缺 milestone（deny）' 2 "$(payload '{"project":"Phase 1","title":"Foo","labels":["lane:harness"]}')"
expect '③ Task 標題缺 parentId（deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Task：LS-1 foo","labels":["lane:harness"]}')"
expect '③b Task: 半形冒號同樣算（deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Task: LS-1 foo","labels":["lane:harness"]}')"
expect '④ 無 lane 標籤（labels 空陣列，deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":[]}')"
expect '④b 無 lane 標籤（labels 整個省略，deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo"}')"
expect '⑤ 合規建票（allow）' 0 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness","size:M"]}')"
expect '⑤b 合規建票：Phase 專案帶 milestone（allow）' 0 "$(payload '{"project":"Phase 1","milestone":"M1","title":"Foo","labels":["lane:harness"]}')"
expect '⑤c 合規建票：Task 標題帶 parentId（allow）' 0 "$(payload '{"project":"Harness 與協作基建","title":"Task：LS-1 foo","parentId":"LS-9","labels":["lane:harness"]}')"
expect '⑥ 更新票（有 id）一律放行——即使其餘欄位全缺（allow）' 0 "$(payload '{"id":"LS-77","labels":[]}')"
expect '⑥b 更新票：id 為空字串不算「有 id」（視同建票，仍套規則，deny）' 2 "$(payload '{"id":"","title":"Foo","labels":["lane:harness"]}')"

# labels 多於一個 lane:*（票文「或多於一個」半句）
expect '⑦ labels 多於一個 lane:*（deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness","lane:ui"]}')"

# ============================================================
# fail-closed：空 stdin／JSON 壞掉／頂層非物件
# ============================================================
expect 'fail-closed：空 stdin（deny）' 2 ''
expect 'fail-closed：JSON 語法壞掉（deny）' 2 '{"tool_input":'
expect 'fail-closed：JSON 頂層不是物件（deny）' 2 '[1,2,3]'
expect 'fail-closed：labels 不是陣列（deny，型別異常視同解析失敗）' 2 "$(payload '{"project":"P","title":"Foo","labels":"lane:harness"}')"

# ============================================================
# 解析工具缺席：jq 缺退 python3；jq／python3 皆缺 → deny（同 pretool.test.sh 慣例）
# ============================================================
bash_bin=$(bash -c 'type -P bash' 2>/dev/null || echo /bin/bash)
real_python3=$(bash -c 'type -P python3' 2>/dev/null || true)
work=$(mktemp -d)
mkdir -p "$work/empty" "$work/py-only"
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/py-only/python3"

out=$(printf '%s' "$(payload '{"title":"Foo","labels":["lane:harness"]}')" | env PATH="$work/empty" "$bash_bin" "$gate" 2>&1)
got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ fail-closed：jq／python3 皆缺（PATH 清空，deny）'
else
  echo "✗ fail-closed：jq／python3 皆缺（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
  fail=1
fi

if [ -n "$real_python3" ]; then
  out=$(printf '%s' "$(payload '{"title":"Foo","labels":["lane:harness"]}')" | env PATH="$work/py-only" "$bash_bin" "$gate" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（建票缺 project 仍判定為 deny）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness","size:M"]}')" | env PATH="$work/py-only" "$bash_bin" "$gate" 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（合規建票仍 allow）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（合規建票期望 exit 0 allow，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(payload '{"id":"LS-77"}')" | env PATH="$work/py-only" "$bash_bin" "$gate" 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（更新票仍一律放行）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（更新票期望 exit 0 allow，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
else
  echo '⚠ 略過 jq-缺-python3-備援 測試（本機找不到 python3）'
fi
rm -rf "$work"

# ============================================================
# mutation 負控：四條 deny 規則各拿掉一個，同一份原本會 deny 的 payload 必須改判 allow——
# 證明「該規則的判斷式」是真正造成 deny 的原因，不是這份測試湊巧沒踩到別的規則
# （同 scripts/hooks/pretool.test.sh 的 F5 trap-mutation 慣例）。
# ============================================================
mut_dir=$(mktemp -d)

build_mutant() {  # $1=規則字母（A/B/C/D） $2=輸出路徑
  awk -v tag="RULE-${1}-START" -v endtag="RULE-${1}-END" '
    index($0, tag) > 0 { skip = 1 }
    skip != 1 { print }
    index($0, endtag) > 0 { skip = 0 }
  ' "$gate" > "$2"
  chmod +x "$2"
}

run_mutant() {  # $1=mutant 路徑 $2=payload $3=label
  local out got
  out=$(printf '%s' "$3" | bash "$1" 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo "✓ mutant $2：拿掉規則後，原本會 deny 的 payload 改判 allow（證明規則區塊確實是原因）"
  else
    echo "✗ mutant $2：拿掉規則後仍非 allow——規則區塊可能沒被正確移除，或另一條規則也命中同一份 payload（實得 exit ${got}：${out}）" >&2
    fail=1
  fi
}

build_mutant A "$mut_dir/mutant-a.sh"
run_mutant "$mut_dir/mutant-a.sh" "A（缺 project）" "$(payload '{"title":"Foo","labels":["lane:harness"]}')"

build_mutant B "$mut_dir/mutant-b.sh"
run_mutant "$mut_dir/mutant-b.sh" "B（Phase 缺 milestone）" "$(payload '{"project":"Phase 1","title":"Foo","labels":["lane:harness"]}')"

build_mutant C "$mut_dir/mutant-c.sh"
run_mutant "$mut_dir/mutant-c.sh" "C（Task 缺 parentId）" "$(payload '{"project":"Harness 與協作基建","title":"Task：LS-1 foo","labels":["lane:harness"]}')"

build_mutant D "$mut_dir/mutant-d.sh"
run_mutant "$mut_dir/mutant-d.sh" "D（無 lane 標籤）" "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":[]}')"

# 反向確認：mutant 腳本裡真的看不到被拿掉的那段文字（避免 awk pattern 打錯字、其實整份原封不動
# 複製過去，讓上面「改判 allow」是因為別的原因湊巧 allow，而非規則真的被移除）。
for pair in "A:${mut_dir}/mutant-a.sh" "B:${mut_dir}/mutant-b.sh" "C:${mut_dir}/mutant-c.sh" "D:${mut_dir}/mutant-d.sh"; do
  letter=${pair%%:*}
  path=${pair#*:}
  if grep -q "RULE-${letter}-START" "$path"; then
    echo "✗ mutant ${letter}：規則區塊竟然還在（awk 拿掉失敗，mutation 負控本身無效）" >&2
    fail=1
  else
    echo "✓ mutant ${letter}：規則區塊確實已從 mutant 腳本移除"
  fi
done

rm -rf "$mut_dir"

if [ "$fail" -ne 0 ]; then
  echo "FAIL：linear-issue-check.test.sh 有斷言未通過" >&2
  exit 1
fi
echo "PASS：linear-issue-check.test.sh 全數通過"
