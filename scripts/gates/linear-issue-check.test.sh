#!/bin/bash
# scripts/gates/linear-issue-check.test.sh（LS-77／LS-79）
#
# 自測 scripts/gates/linear-issue-check.sh：八情境（建票缺 project／Phase 缺 milestone／
# Task 缺 parent／無 lane／合規／更新票一律放行／id 型別防呆兩組）＋ labels 多於一個
# lane:* ＋ state／cycle 交界情境（規則 E**混合案**：Ready 建票／更新票皆驗；In Progress
# 只在建票時驗，更新票不驗——R1 merge-review 594 筆歷史流量回放實證後 orchestrator 拍板，
# 見 linear-issue-check.sh 檔頭與 docs/COLLABORATION.md §5-c 修訂理由；state 缺席／state
# 非 Ready/In Progress 皆不觸發；cycle 正規化：0／純空白視同未帶）＋ fail-closed 三態（空
# stdin／JSON 壞掉／jq 與 python3 皆缺）＋ jq 缺時 python3 備援＋ settings.json 接線斷言
# （LS-96 待辦池 F1）＋ trap 移除 mutation 負控（LS-96 待辦池 F2，同 pretool.test.sh F5
# 慣例）＋`-d ''` 修法負控（LS-79 R1 merge-review F4：title 含換行的合規建票，main 版會
# 誤擋、本版須放行）＋cycle 正規化 mutation 負控（LS-79 R1 F6）＋五條 deny 規則（A-E）
# 各一個 mutant（拿掉該規則區塊後，原本會 deny 的同一份 payload 必須改判 allow，證明測試
# 真的測到那個區塊、不是同一份 payload 湊巧一直 allow）。CI rules job 每個 PR 都跑。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${root}/scripts/gates/linear-issue-check.sh"
fail=0

# ---- 暫存目錄集中清理（LS-96 待辦池 F9：先前只在正常流程尾端 rm -rf，早退／中途失敗會
# 留殘留目錄；改用 trap 兜底，正常流程仍照舊清一次，trap 再清一次是 no-op）----
_tmp_dirs=()
_cleanup_tmp() {
  local d
  for d in "${_tmp_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap _cleanup_tmp EXIT

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
# 八情境（票文／派工 prompt 列的清單）
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
expect '⑧ id 為物件 {}（型別非字串，不算「有 id」，視同建票仍套規則，deny）' 2 "$(payload '{"id":{},"title":"Foo","labels":["lane:harness"]}')"
expect '⑧b id 為陣列 []（同上，deny）' 2 "$(payload '{"id":[],"title":"Foo","labels":["lane:harness"]}')"

# labels 多於一個 lane:*（票文「或多於一個」半句）
expect '⑦ labels 多於一個 lane:*（deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness","lane:ui"]}')"

# ============================================================
# state／cycle 交界情境（規則 E，LS-79 R1 混合案）——Ready：建票與更新票兩條路徑都要驗到；
# In Progress：只有建票要驗，更新票（歷史流量最常見的 {"id":..,"state":"In Progress"}
# 派工形狀）不驗；同時要證明「state 沒出現」「state 不是 Ready/In Progress」兩種情況都
# 不觸發（維持 LS-77 既有行為）。
# ============================================================
expect 'E1 建票 state=Ready 無 cycle（deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready"}')"
expect 'E2 建票 state=Ready 有 cycle（allow）' 0 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":"7"}')"
expect 'E3 建票 state=In Progress 無 cycle（deny——建票分支仍套用）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"In Progress"}')"
expect 'E4 建票 state=In Progress 有 cycle（allow）' 0 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"In Progress","cycle":"7"}')"
expect 'E5 建票 state=Backlog 無 cycle（不觸發規則 E，allow）' 0 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Backlog"}')"
expect 'E6 建票 state=Ready 但 cycle 為空字串（視同未帶，deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":""}')"
expect 'E7 更新票（有 id）state 改成 Ready 但無 cycle（deny——Ready 對更新票仍套用）' 2 "$(payload '{"id":"LS-79","state":"Ready"}')"
expect 'E8 更新票（有 id）state 改成 Ready 且帶 cycle（allow）' 0 "$(payload '{"id":"LS-79","state":"Ready","cycle":"7"}')"
expect 'E9 更新票（有 id）state 改成 In Progress 且無 cycle（allow——混合案核心：61 筆歷史流量的派工形狀，In Progress 對更新票不驗）' 0 "$(payload '{"id":"LS-79","state":"In Progress"}')"
expect 'E10 更新票（有 id）state 改成 In Progress 且帶 cycle（allow，同上，cycle 有無皆不影響）' 0 "$(payload '{"id":"LS-79","state":"In Progress","cycle":"7"}')"
expect 'E11 更新票（有 id）state 改成 Done 無 cycle（不觸發規則 E，allow）' 0 "$(payload '{"id":"LS-79","state":"Done"}')"
expect 'E12 更新票（有 id）沒有 state 欄位（不觸發規則 E，其餘欄位仍不驗，allow）' 0 "$(payload '{"id":"LS-79","labels":[]}')"

# ============================================================
# cycle 正規化交界情境（池項 F6，LS-79 R1）——JSON 數字 0／字面 "0"／純空白字串視同未帶
# cycle（jq／python3 兩路徑原本判決不一致，統一為 fail-closed：視同未帶）；含非空白字元的
# 值（即使前後有空白）仍維持原值、不誤清空。
# ============================================================
expect 'E13 state=Ready、cycle=0（JSON 數字，視同未帶，deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":0}')"
expect 'E14 state=Ready、cycle="0"（字面字串，視同未帶，deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":"0"}')"
expect 'E15 state=Ready、cycle="   "（純空白，視同未帶，deny）' 2 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":"   "}')"
expect 'E16 state=Ready、cycle=" 1 "（含非空白字元，維持原值，allow）' 0 "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":" 1 "}')"

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
work=$(mktemp -d); _tmp_dirs+=("$work")
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
  out=$(printf '%s' "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready"}')" | env PATH="$work/py-only" "$bash_bin" "$gate" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（規則 E：state=Ready 無 cycle 仍判定為 deny）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（規則 E 期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(payload '{"id":"LS-79","state":"In Progress"}')" | env PATH="$work/py-only" "$bash_bin" "$gate" 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（混合案：更新票 In Progress 無 cycle 仍 allow）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（混合案期望 exit 0 allow，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":0}')" | env PATH="$work/py-only" "$bash_bin" "$gate" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（cycle 正規化：0 仍視同未帶、判定為 deny——與 jq 路徑一致）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（cycle 正規化期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
else
  echo '⚠ 略過 jq-缺-python3-備援 測試（本機找不到 python3）'
fi
rm -rf "$work"

# ============================================================
# LS-96 待辦池 F1：settings.json 接線斷言（比照 pretool.test.sh I6）——把 PreToolUse 區塊
# 刪掉／matcher 打錯／忘了 || exit 2，此前 CI 全綠、hook 已死也不會被抓到。
# ============================================================
settings_json="${root}/.claude/settings.json"
wiring_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "mcp__linear__save_issue") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null)
if [ -n "$wiring_cmd" ]; then
  echo '✓ F1①：settings.json 的 PreToolUse matcher 含 mcp__linear__save_issue 且接著 command'
else
  echo "✗ F1①：settings.json 找不到 matcher=mcp__linear__save_issue 的 PreToolUse command" >&2
  fail=1
fi
case "$wiring_cmd" in
  *linear-issue-check.sh*) echo '✓ F1②：command 確實呼叫 linear-issue-check.sh' ;;
  *) echo "✗ F1②：command 沒有呼叫 linear-issue-check.sh（實得：${wiring_cmd}）" >&2; fail=1 ;;
esac
case "$wiring_cmd" in
  *'|| exit 2'*) echo '✓ F1③：command 帶 || exit 2（腳本缺席／執行失敗時 wiring 層仍 fail-closed）' ;;
  *) echo "✗ F1③：command 沒有 || exit 2（實得：${wiring_cmd}）" >&2; fail=1 ;;
esac

# ============================================================
# LS-96 待辦池 F2：trap 移除 mutation 負控（同 pretool.test.sh F5 慣例）——把 trap 那行拿掉
# 重跑，注入一個中途未被任何 if／&&／|| 包住的失敗（`exit 1`），若移除 trap 這件事不會改變
# 行為，代表這組測試沒測到 trap 的作用（假綠）；本測試斷言兩者行為確實不同。
# ============================================================
trap_mut_dir=$(mktemp -d); _tmp_dirs+=("$trap_mut_dir")
build_trap_mutant() {   # $1=輸出路徑 $2=yes/no（是否保留 trap）
  awk -v keep="$2" '
    $0 == "trap on_exit EXIT" && keep != "yes" { next }
    { print }
    $0 == "input=" { print "exit 1  # LS-79 mutation-test：模擬腳本中途未捕捉錯誤" }
  ' "$gate" > "$1"
  chmod +x "$1"
}
build_trap_mutant "$trap_mut_dir/with_trap.sh" yes
build_trap_mutant "$trap_mut_dir/no_trap.sh" no

out=$(printf '%s' "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"]}')" | bash "$trap_mut_dir/with_trap.sh" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：trap on_exit EXIT 在——腳本中途未捕捉錯誤（注入 exit 1）仍 deny（exit 2）'
else
  echo "✗ F2：trap 在時應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

out=$(printf '%s' "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"]}')" | bash "$trap_mut_dir/no_trap.sh" 2>&1); got=$?
if [ "$got" -ne 2 ] || ! case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：拿掉 trap 後同樣的中途錯誤不再變成 deny（證明 trap 是關鍵、不是巧合過關）'
else
  echo "✗ F2：拿掉 trap 後行為竟然沒變——這組測試沒測到 trap 的效果（實得 exit ${got}：${out}）" >&2
  fail=1
fi
rm -rf "$trap_mut_dir"

# ============================================================
# LS-79 R1 merge-review F4：池項 F3（`read -r -d ''`）修法本身無守門斷言——把兩處 `-d ''`
# 拿掉重跑，48 條既有斷言仍全綠（reviewer 實測），必須額外用「title 含換行的合規建票」這個
# 具體 payload 證明修法真的改變了行為：main 版（無 -d ''）誤判 deny（換行截斷欄位，讓後面
# 的 labels 欄位跑位、規則 D 誤擋合規建票），本版（有 -d ''）必須 allow。
# ============================================================
dflag_mut_dir=$(mktemp -d); _tmp_dirs+=("$dflag_mut_dir")
# 只精確命中池項 F3 改動的兩處欄位解析 read（"...-d '' idv..."），不動第 98 行既有、與
# F3 無關的 stdin 讀取（那行從 LS-77 就有 -d ''，不是本次修法範圍）。
sed "s/read -r -d '' idv/read -r idv/g" "$gate" > "$dflag_mut_dir/no-dflag.sh"
chmod +x "$dflag_mut_dir/no-dflag.sh"

newline_payload=$(payload '{"project":"Harness 與協作基建","title":"a\nb","labels":["lane:harness"]}')

out=$(printf '%s' "$newline_payload" | bash "$gate" 2>&1); got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ]; then
  echo "✓ F4：title 含換行的合規建票在本版（-d '' 修法）allow"
else
  echo "✗ F4：title 含換行的合規建票本應 allow（實得 exit ${got}：${out}）" >&2
  fail=1
fi

out=$(printf '%s' "$newline_payload" | bash "$dflag_mut_dir/no-dflag.sh" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo "✓ F4：拿掉 -d '' 後同一份 payload 改判 deny（證明池項 F3 修法確實改變了行為，不是巧合過關）"
else
  echo "✗ F4：拿掉 -d '' 後行為竟然沒變——這組測試沒測到 -d '' 的效果（實得 exit ${got}：${out}）" >&2
  fail=1
fi

if grep -q "read -r -d '' idv" "$dflag_mut_dir/no-dflag.sh"; then
  echo "✗ F4：mutant 腳本裡仍看得到 -d '' idv（sed 替換失敗，負控本身無效）" >&2
  fail=1
else
  echo "✓ F4：mutant 腳本確實已拿掉兩處欄位解析 read 的 -d ''（第 98 行 stdin 讀取不受影響）"
fi
rm -rf "$dflag_mut_dir"

# ============================================================
# LS-79 R1 F6：cycle 正規化 mutation 負控——拿掉 CYCLE-NORM 區塊後，cycle=0 必須改判 allow
# （證明正規化區塊確實是 cycle:0 被擋的原因）。
# ============================================================
norm_mut_dir=$(mktemp -d); _tmp_dirs+=("$norm_mut_dir")
awk '
  index($0, "CYCLE-NORM-START") > 0 { skip = 1 }
  skip != 1 { print }
  index($0, "CYCLE-NORM-END") > 0 { skip = 0 }
' "$gate" > "$norm_mut_dir/no-norm.sh"
chmod +x "$norm_mut_dir/no-norm.sh"

cycle_zero_payload=$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready","cycle":0}')
out=$(printf '%s' "$cycle_zero_payload" | bash "$norm_mut_dir/no-norm.sh" 2>&1); got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ]; then
  echo '✓ F6：拿掉 cycle 正規化區塊後，cycle=0 改判 allow（證明正規化區塊確實是原因）'
else
  echo "✗ F6：拿掉正規化區塊後仍非 allow（實得 exit ${got}：${out}）" >&2
  fail=1
fi
if grep -q "CYCLE-NORM-START" "$norm_mut_dir/no-norm.sh"; then
  echo "✗ F6：mutant 腳本裡仍看得到 CYCLE-NORM 區塊（awk 拿掉失敗，負控本身無效）" >&2
  fail=1
else
  echo '✓ F6：mutant 腳本確實已拿掉 CYCLE-NORM 區塊'
fi
rm -rf "$norm_mut_dir"

# ============================================================
# mutation 負控：五條 deny 規則（A-E）各拿掉一個，同一份原本會 deny 的 payload 必須改判
# allow——證明「該規則的判斷式」是真正造成 deny 的原因，不是這份測試湊巧沒踩到別的規則
# （同 scripts/hooks/pretool.test.sh 的 F5 trap-mutation 慣例）。
# ============================================================
mut_dir=$(mktemp -d); _tmp_dirs+=("$mut_dir")

build_mutant() {  # $1=規則字母（A/B/C/D/E） $2=輸出路徑
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

build_mutant E "$mut_dir/mutant-e.sh"
run_mutant "$mut_dir/mutant-e.sh" "E（state=Ready 無 cycle）" "$(payload '{"project":"Harness 與協作基建","title":"Foo","labels":["lane:harness"],"state":"Ready"}')"

# 反向確認：mutant 腳本裡真的看不到被拿掉的那段文字（避免 awk pattern 打錯字、其實整份原封不動
# 複製過去，讓上面「改判 allow」是因為別的原因湊巧 allow，而非規則真的被移除）。
for pair in "A:${mut_dir}/mutant-a.sh" "B:${mut_dir}/mutant-b.sh" "C:${mut_dir}/mutant-c.sh" "D:${mut_dir}/mutant-d.sh" "E:${mut_dir}/mutant-e.sh"; do
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
