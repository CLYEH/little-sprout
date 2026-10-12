#!/bin/bash
# report-cite-check.sh 的自測（LS-429；R2 補 m1／M1）。CI rules job 每個 PR 都跑。
# 若 gate 退化——清單列沒 id 仍綠、`LS-<n>` 單獨提到就算引據、`tagline`／`reopened` 被當狀態詞、純數字（日期／run id）被當 hex id、
# 表格資料列不檢查、同段第二張表的表頭誤紅、編號清單／縮排子彈／段落行不檢查、豁免段落擴到下一段、程式碼區塊／引文被當事實、
# 缺檔靜默放行、`--sample` 抽到豁免列或由固定順序取前 N 列——這裡會紅。
# mutation：把 `# MUT:state-word` 那行換成無條件放行 → ③ 負樣本（LS-<n> 無狀態詞）變綠，證明紅是那條規則造成。
# LS-495 mutation：拿掉段落標題白名單（`待你決策` 與 `# MUT:allowlist` 那行）→ ⑪ 的待你決策案與成果案變紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/report-cite-check.sh"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect() {  # expect <期望 rc> <名稱> <輸出必含|''> <md 內容> [<額外參數>…]
  local want=$1 name=$2 must=$3 body=$4 out got
  shift 4
  printf '%s\n' "$body" > "$work/r.md"
  out="$(bash "$check" "$work/r.md" "$@" 2>&1)"; got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}；應含「${must}」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
  fi
}

GOOD='# 晨報 2026-10-09

## 狀態表

| 項目 | 值 |
|---|---|
| main | a4cdce8 v0.27.29 |
| open PR | #596 → development |

## 今日 Done
- LS-416 Done（QA R2 PASS 665bfd3f）
- LS-411 Done，設計 PR #589 併 dev

## 在飛
- LS-425 In Progress，VR R1 ITERATE（dff84df8）

## 待使用者
- LS-148 名稱沿用或改名？
- LS-417 第 2 條 a／b／c

```
- 這行在程式碼區塊，沒 id 也不算
```
> - 引文行也不算'
expect 0 '① 合法：表格列、清單列皆有 id；待使用者段與 code／引文豁免' '✓ report-cite-check：5 條事實列皆有引據（豁免 2 條）' "$GOOD"

expect 1 '② 清單列沒任何 id → exit 1 並點出行號' '✗ 第 2 行缺引據' '# 在飛
- LS-425 的設計進行中
- 設計者今天畫了六態'

expect 1 '③ LS-<n> 單獨提到（無狀態詞）不算引據' '✗ 第 2 行缺引據' '# 在飛
- LS-425 設計者今天畫了六態'
expect 0 '③ LS-<n>＋狀態詞算引據' '✓' '# 在飛
- LS-425 In Progress，設計者今天畫了六態'
expect 1 '③ R1 I1：tagline／reopened 不是整字狀態詞' '✗ 第 2 行缺引據' '# 在飛
- LS-425 的 tagline 改了，票已 reopened'

expect 1 '④ 純數字 token（日期 20261009／run id）不算 hex id' '✗ 第 2 行缺引據' '# 在飛
- 20261009 跑了 run 37874656901，全綠'

expect 1 '⑤ 表格資料列沒 id → 紅；表頭與分隔列不算' '✗ 第 5 行缺引據' '# 狀態表
| 項目 | 值 |
|---|---|
| main | a4cdce8 |
| test | 跟 main 一樣 |'
expect 0 '⑤ R1 I6：同一段落第二張表的表頭不誤紅' '✓ report-cite-check：2 條事實列' '# 狀態表
| 項目 | 值 |
|---|---|
| main | a4cdce8 |

| PR | 狀態 |
|---|---|
| #596 | merged |'

expect 1 '⑥ 豁免只限標題含待使用者／待裁決／建議的段落，下一段恢復檢查' '✗ 第 4 行缺引據' '## 待使用者
- 要不要改名？
## 風險
- 分類器擋 docker pause，QA 第 2 條沒驗
- 另一條有 id 1a2b3c4d'

expect 1 '⑦ R1 m1：編號清單沒 id → 紅' '✗ 第 2 行缺引據' '# 在飛
1. 設計者今天畫了六態
2. LS-425 In Progress'
expect 1 '⑦ R1 m1：縮排子彈／+ 子彈沒 id → 紅' '✗ 第 3 行缺引據' '# 在飛
- LS-425 In Progress
  - 子項：VR 還沒審
+ 另一條 #596'
expect 1 '⑦ R1 m1：段落行也是事實列' '✗ 第 2 行缺引據' '# 在飛
今天設計者把六態畫完了。'
expect 1 '⑦ R2 m2：標題「含」關鍵字（## 在飛（含查無））不豁免' '✗ 第 2 行缺引據' '## 在飛（含查無）
- LS-425 的設計進行中'
expect 1 '⑦ R3 M1：標題「開頭是」關鍵字（## 建議與在飛）不豁免——整行比對' '✗ 第 2 行缺引據' '## 建議與在飛
- 設計者今天畫了六態'
expect 0 '⑦ R3 M1：標題帶括號附註（## 建議（orchestrator 補））仍整段豁免' '0 條事實列皆有引據（豁免 1 條）' '## 建議（orchestrator 補）
- 下一步先把 LS-148 定案'
expect 1 '⑦ R2 m2：`#5 …` 開頭的行是事實列不是標題（本身缺 id 紅）' '✗ 第 2 行缺引據' '## 在飛
#5 這行不是標題，一位數也不是 PR 號'
expect 0 '⑦ R3 M1：豁免段內的 `#5 …` 行不是標題、不切換豁免狀態（後續列仍豁免）' '0 條事實列皆有引據（豁免 2 條）' '## 待使用者
#5 建議先裁名稱
- 設計者今天畫了六態'
expect 1 '⑦ R3 I3：「風險與查無」段裡只是「含」查無二字的句子不算缺席句（仍紅）' '✗ 第 2 行缺引據' '## 風險與查無
- 設計者查無法在兩天內畫完六態'
expect 1 '⑦ R2 m2：「風險與查無」段帶 id 的列照查（缺 id 且非缺席句型仍紅）' '✗ 第 4 行缺引據' '## 風險與查無
- lane:product：本 lane 無在飛票
- 收集員失敗：無
- 分類器擋 docker pause，QA 第 2 條沒驗'
expect 0 '⑦ R2 m2：「風險與查無」段帶 id 的列算已查（進抽樣池）' '1 條事實列皆有引據（豁免 1 條）' '## 風險與查無
- 收集員失敗：無
- LS-417 BLOCKED，第 2 條等 LS-427（512feab5）'
expect 1 '⑦ 「風險與查無」段的缺席陳述豁免（豁免 2）；「在飛」段同句仍紅' '已查 1 條、豁免 2 條' '## 在飛
- lane:product：本 lane 無在飛票
## 風險與查無
- lane:product：本 lane 無在飛票（Ready／In Progress 各查 0 張）
- 收集員失敗：無'
expect 0 '⑦ 豁免段內的編號清單與段落都不算' '✓ report-cite-check：0 條事實列皆有引據（豁免 3 條）' '## 待使用者裁決
1. C1 相機 a／b
2. C2 已刪照片 a／b
回覆格式：回「C1a C2b」。'

# ---- ⑪ LS-495 晨報改版：「待你決策」整段豁免、「成果」只豁免標籤句、事實列規則不放寬 ----
DECIDE='## 待你決策
1. 背景：LS-148 名稱要沿用或改名
   - 選項：a 沿用 Sprout Day／b 改名
   - 建議：a
   - 不裁的後果：卡住字標與 App Store 文案（LS-148）'
expect 0 '⑪ 豁免段：「待你決策」每題四要素的句子不計缺引據' '0 條事實列皆有引據（豁免 4 條）' "$DECIDE"

RESULT='## 成果
- v0.27.70 讓 TestFlight 版能用 Apple 登入（LS-498）
- 里程碑進度：M7 TestFlight 62%（5/8）
- Cycle 進度：cycle 7 完成 12/20 票
- 路線圖位置：Phase 1 第 9 步 TestFlight 發給家人實測
- 可看：截圖 .claude/evidence/LS-498/qa1/login.png、TestFlight build 3514'
expect 0 '⑪ 豁免段：「成果」的標籤句（無 id）豁免，版本句照查（tag＋票號）' '1 條事實列皆有引據（豁免 4 條）' "$RESULT"
expect 1 '⑪ 事實列不放寬：「成果」段的版本句沒 tag／Done 引據仍紅' '✗ 第 2 行缺引據' '## 成果
- 這版讓家人能用 Apple 登入
- 里程碑進度：M7 TestFlight 62%'
expect 0 '⑪ 「成果」標籤句帶 id 的列改算已查（進抽樣池，不計豁免）' '1 條事實列皆有引據（豁免 0 條）' '## 成果
- 可看：核可頁 artifact（LS-425 Done，e2d4fa02）'
expect 1 '⑪ 事實列不放寬：「事實列」底下的在飛列缺引據仍紅' '✗ 第 3 行缺引據' '## 事實列
### 在飛
- 設計者今天畫了六態'
expect 1 '⑪ 豁免不外溢：「成果」的下一段「正在做」恢復檢查，標籤句不豁免' '✗ 第 4 行缺引據' '## 成果
- 里程碑進度：M7 TestFlight 62%
## 正在做
- 里程碑進度：M8 Android 資料層 10%'

out8="$(bash "$check" "$work/none.md" 2>&1)"; got8=$?
if [ "$got8" -eq 2 ]; then echo "✓ ⑧ 檔案不存在 → exit 2"; else echo "✗ ⑧ 檔案不存在應 exit 2（實得 ${got8}）" >&2; fail=1; fi
out9="$(bash "$check" 2>&1)"; got9=$?
if [ "$got9" -eq 2 ]; then echo "✓ ⑨ 無參數 → exit 2"; else echo "✗ ⑨ 無參數應 exit 2（實得 ${got9}）" >&2; fail=1; fi
printf '%s\n' "$GOOD" > "$work/r.md"
out9b="$(bash "$check" "$work/r.md" --sample x 2>&1)"; got9b=$?
if [ "$got9b" -eq 2 ]; then echo "✓ ⑨ --sample 非整數 → exit 2"; else echo "✗ ⑨ --sample x 應 exit 2（實得 ${got9b}）" >&2; fail=1; fi

# ---- ⑩ R1 M1：--sample N 由腳本從已查事實列隨機抽，不抽豁免列；種子固定可重現、不同種子會變 ----
printf '%s\n' "$GOOD" > "$work/r.md"
outA="$(CITE_SAMPLE_SEED=7 bash "$check" "$work/r.md" --sample 2 2>&1)"; gotA=$?
nA=$(printf '%s\n' "$outA" | grep -c '^  第 [0-9]* 行：')
if [ "$gotA" -eq 0 ] && [ "$nA" -eq 2 ] && printf '%s' "$outA" | grep -qF '抽驗樣本（2 條'; then echo "✓ ⑩ --sample 2 印 2 條樣本且仍 exit 0"; else echo "✗ ⑩ --sample 2 應印 2 條（實得 ${nA}，rc ${gotA}）" >&2; printf '%s\n' "$outA" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s' "$outA" | grep -q '第 1[89] 行\|第 2[01] 行'; then echo "✗ ⑩ 樣本抽到豁免段（待使用者）的列" >&2; fail=1; else echo "✓ ⑩ 樣本不含豁免段的列"; fi
outB="$(CITE_SAMPLE_SEED=7 bash "$check" "$work/r.md" --sample 2 2>&1)"
if [ "$outA" = "$outB" ]; then echo "✓ ⑩ 同種子可重現"; else echo "✗ ⑩ 同種子輸出不同" >&2; fail=1; fi
diffseed=0
for s in 1 2 3 4 5 6 8 9 10 11 12 13; do
  outC="$(CITE_SAMPLE_SEED=$s bash "$check" "$work/r.md" --sample 2 2>&1 | grep '^  第')"
  [ "$outC" != "$(printf '%s\n' "$outA" | grep '^  第')" ] && diffseed=1 && break
done
if [ "$diffseed" -eq 1 ]; then echo "✓ ⑩ 不同種子會抽到不同列（不是固定取前 N 列）"; else echo "✗ ⑩ 12 個種子都抽到同樣的列——像是固定順序取前 N" >&2; fail=1; fi
printf '%s\n' '# 在飛
- 沒 id 的列' > "$work/r.md"
outD="$(bash "$check" "$work/r.md" --sample 2 2>&1)"; gotD=$?
if [ "$gotD" -eq 1 ] && ! printf '%s' "$outD" | grep -qF '抽驗樣本'; then echo "✓ ⑩ gate 紅時不印樣本"; else echo "✗ ⑩ gate 紅時仍印樣本或 rc≠1（rc ${gotD}）" >&2; fail=1; fi

# ---- R3 M1 負控：兩支 mutant 各自讓對應的自測案翻面 ----
mutE="$work/mutE.sh"   # 豁免退回「含關鍵字」→ 「## 建議與在飛」案必須變綠（證明整行比對是紅的原因）
sed "s/^EXEMPT_FULL_RE=.*/EXEMPT_FULL_RE='(待使用者|待裁決|建議)'/" "$check" > "$mutE"
if grep -q "^EXEMPT_FULL_RE='(待使用者|待裁決|建議)'$" "$mutE"; then
  printf '%s\n' '## 建議與在飛
- 設計者今天畫了六態' > "$work/r.md"
  outE="$(bash "$mutE" "$work/r.md" 2>&1)"; gotE=$?
  if [ "$gotE" -eq 0 ]; then echo "✓ mutant（豁免退回含關鍵字）：「建議與在飛」案變綠（整行比對確實是原因）"; else echo "✗ mutant 豁免退回後應 exit 0（實得 ${gotE}）" >&2; fail=1; fi
else
  echo "✗ mutant（豁免）的 sed 未命中（負控本身無效）" >&2; fail=1
fi
mutH="$work/mutH.sh"   # 標題判定退回「任何 # 開頭都算標題」→ 豁免段內 `#5 …` 案（期望 0）必須變紅
sed '/# MUT:heading-space/s/.*/      is_heading=1/' "$check" > "$mutH"
if ! grep -q 'MUT:heading-space' "$mutH" && grep -q 'MUT:heading-space' "$check"; then
  printf '%s\n' '## 待使用者
#5 建議先裁名稱
- 設計者今天畫了六態' > "$work/r.md"
  outH="$(bash "$mutH" "$work/r.md" 2>&1)"; gotH=$?
  if [ "$gotH" -eq 1 ]; then echo "✓ mutant（任何 # 都算標題）：豁免段內 #5 案變紅（標題判定確實是原因）"; else echo "✗ mutant 標題判定退回後應 exit 1（實得 ${gotH}）" >&2; printf '%s\n' "$outH" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ mutant（標題）的 sed 未命中（負控本身無效）" >&2; fail=1
fi

# mutation（LS-495）：拿掉段落標題白名單（「待你決策」從整段豁免移除＋「成果」標籤句豁免改成不命中）→ ⑪ 兩個豁免案必須變紅
mutA="$work/mutA.sh"
sed -e 's/|待你決策//' -e '/# MUT:allowlist/s/.*/EXEMPT_RESULT_RE="^(ZZZNOMATCH)$"/' "$check" > "$mutA"
if ! grep -q '^EXEMPT_FULL_RE=.*待你決策' "$mutA" && ! grep -q 'MUT:allowlist' "$mutA" && grep -q 'MUT:allowlist' "$check"; then
  printf '%s\n' "$DECIDE" > "$work/r.md"; bash "$mutA" "$work/r.md" >/dev/null 2>&1; gotA1=$?
  printf '%s\n' "$RESULT" > "$work/r.md"; bash "$mutA" "$work/r.md" >/dev/null 2>&1; gotA2=$?
  if [ "$gotA1" -eq 1 ] && [ "$gotA2" -eq 1 ]; then echo "✓ mutant（拿掉段落標題白名單）：⑪ 待你決策案與成果案皆變紅（白名單確實是豁免的原因）"; else echo "✗ mutant 拿掉白名單後兩案應皆 exit 1（實得 ${gotA1}／${gotA2}）" >&2; fail=1; fi
else
  echo "✗ mutant（白名單）的 sed 未命中（負控本身無效）" >&2; fail=1
fi

# mutation：`# MUT:state-word` 那行改成無條件 continue → ③ 負樣本必須變綠
mut="$work/mut.sh"
sed '/# MUT:state-word/s/.*/    continue/' "$check" > "$mut"
if ! grep -q 'MUT:state-word' "$mut" && grep -q 'MUT:state-word' "$check"; then
  echo "✓ mutant 已拿掉狀態詞條件"
  printf '%s\n' '# 在飛
- LS-425 設計者今天畫了六態' > "$work/r.md"
  outm="$(bash "$mut" "$work/r.md" 2>&1)"; gotm=$?
  if [ "$gotm" -eq 0 ]; then echo "✓ mutant：③ 負樣本變綠（狀態詞規則確實是原因）"; else echo "✗ mutant 應 exit 0（實得 ${gotm}）" >&2; printf '%s\n' "$outm" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ mutant 的 sed 未命中（負控本身無效）" >&2; fail=1
fi

[ "$fail" -eq 0 ] && echo "✓ report-cite-check 自測通過"
exit "$fail"
