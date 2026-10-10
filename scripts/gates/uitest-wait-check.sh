#!/bin/bash
# UITest 等待紀律 gate（LS-458，來源 LS-413 池 P1 `e0f65a8f`／`f608d582`／`def25a8f`）：
# 掃 `LittleSproutUITests/**/*.swift`，抓「慢 runner 才紅」的兩型斷言，exit 1 並逐處點名。
# 規範全文在 docs/COLLABORATION.md §7「UITest 等待紀律」一節；merge-reviewer 判準同源（.claude/agents/merge-reviewer.md）。
#
# 背景：每例 flaky 耗一輪 rerun 17–25 分（LS-385／LS-355／LS-391／LS-214 四例＋f608d582 第 4 次＋def25a8f）。
# 根因同型——UI 斷言前沒有等就緒，或「消失」寫成等待方向相反的 `XCTAssertFalse(x.waitForExistence(...))`：
# sheet 還在關閉動畫時元素仍存在，`waitForExistence` 立刻回 true → 斷言立刻紅，根本沒等到它消失。
#
# 口徑（純文字、逐行、不理解語意；字串字面值與 `//` 行尾註解先剔除再比對）：
#   「一則斷言」＝以 `XCTAssert…(` 起頭的那一行，括號展開到配平為止（最多 8 行）。
#   規則 i  `XCTAssertFalse(` 的斷言內含 `waitForExistence` → 紅。
#           消失一律 `XCTAssertTrue(x.waitForNonExistence(timeout:))`（或 `waitUntilGone`）。
#   規則 ii `XCTAssertTrue`／`XCTAssertEqual`／`XCTAssertNotNil` 的斷言內讀了元素的 `.exists`／`.label`／`.value`，
#           而「同一個 func 內、往前最多 N 行（預設 25，`--lookback` 可調；不跨過上一個 `func` 宣告）到斷言結尾」
#           這段文字沒有出現 `waitFor`／`waitUntilGone`／`XCTWaiter`／`XCTNSPredicateExpectation`／`expectation(` → 紅。
#           （取樣當下元素可能還沒就緒；先 wait 再讀。）
#   豁免兩種，皆須具名：
#     - 行內標記 `// uitest-wait-ok: <理由>`：寫在該斷言的任一行，或緊鄰斷言上一行；理由不可空。
#       用於「同步點在 helper 內（例如 entryRow(in:) 內已 waitForExistence）」或「反向斷言刻意在視窗期內不得出現」。
#     - 規則 ii 的檔案層級 allowlist（`scripts/gates/uitest-wait-allowlist.txt`，一行一個
#       `LittleSproutUITests/<相對路徑>`，`#` 後寫理由）：LS-458 落地時既有 46 處、12 檔的歷史債，
#       只擋新增、不要求一次清完。**棘輪**：allowlist 內的檔案若已沒有規則 ii 命中、或檔案不存在，gate 也紅
#       （請把條目刪掉）——債只能減、不會靜默留著。規則 i 沒有檔案層級豁免（落地時已全數修完或行內標記）。
#
# 靜態判斷看不到：tap 前是否等 `isHittable`、`.count` 型斷言、split view 是否就緒——這類（LS-458 修的
# ChildrenManagementViewIPadTests／AlbumsViewIPadTests／UploadQueueSheetRemovalUITests 三案）靠規範＋
# merge-review 判準，不假裝 gate 抓得到。
#
# 用法：bash uitest-wait-check.sh [--scan-dir <dir>] [--allowlist <file>] [--lookback <N>]
#   --scan-dir   預設 <repo>/LittleSproutUITests；--allowlist 預設 <repo>/scripts/gates/uitest-wait-allowlist.txt
#                （檔案不存在＝空 allowlist）。兩者與 --lookback 只給自測餵夾具用。
#   allowlist 條目以「<scan-dir 的目錄名>/<相對路徑>」比對。
# exit：0＝乾淨；1＝有命中（或 allowlist 過期）；2＝參數錯（fail closed）。
# 自測：scripts/gates/uitest-wait-check.test.sh（CI rules job：正負樣本＋三組 mutation）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
scan_dir=
allowlist=
lookback=25

usage="用法：uitest-wait-check.sh [--scan-dir <dir>] [--allowlist <file>] [--lookback <N>]"
while [ $# -gt 0 ]; do
  case "$1" in
    --scan-dir)  [ -n "${2:-}" ] || { echo "✗ uitest-wait-check：--scan-dir 缺值" >&2; exit 2; }; scan_dir=$2; shift 2 ;;
    --allowlist) [ -n "${2:-}" ] || { echo "✗ uitest-wait-check：--allowlist 缺值" >&2; exit 2; }; allowlist=$2; shift 2 ;;
    --lookback)  [ -n "${2:-}" ] || { echo "✗ uitest-wait-check：--lookback 缺值" >&2; exit 2; }; lookback=$2; shift 2 ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *) echo "✗ uitest-wait-check：未知參數「$1」。${usage}" >&2; exit 2 ;;
  esac
done
case "$lookback" in ''|*[!0-9]*) echo "✗ uitest-wait-check：--lookback 須為非負整數（${lookback}）" >&2; exit 2 ;; esac

scan_dir=${scan_dir:-${root}/LittleSproutUITests}
allowlist=${allowlist:-${root}/scripts/gates/uitest-wait-allowlist.txt}
[ -d "$scan_dir" ] || { echo "✗ uitest-wait-check：找不到掃描目錄 ${scan_dir}" >&2; exit 2; }
scan_dir=${scan_dir%/}
base_name=$(basename "$scan_dir")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 一個檔一次 awk；輸出 `規則<TAB>行號<TAB>原文`（原文去頭空白）。
scan_file() {
  awk -v lookback="$lookback" '
function strip(s) {
  gsub(/"[^"]*"/, "\"\"", s)   # 字串字面值 → 空字串（訊息文案裡的「.exists」「(」不算）
  sub(/\/\/.*$/, "", s)        # 行尾註解
  return s
}
function count(s, ch,   t) { t = s; return gsub(ch, "&", t) }
{ L[NR] = $0 }
END {
  fstart = 1
  for (i = 1; i <= NR; i++) {
    raw = L[i]
    bare = raw; sub(/^[ \t]+/, "", bare)
    if (bare ~ /^\/\//) continue
    code = strip(raw)
    if (code ~ /(^|[^A-Za-z0-9_])func[ \t]+[A-Za-z_]/) fstart = i
    if (code !~ /XCTAssert(False|True|Equal|NotNil)\(/) continue

    # 展開成一則斷言：括號配平為止（最多 8 行）
    stmt = code
    depth = count(code, "\\(") - count(code, "\\)")
    j = i
    while (depth > 0 && j < NR && j - i < 8) {
      j++
      c = strip(L[j])
      stmt = stmt " " c
      depth += count(c, "\\(") - count(c, "\\)")
    }

    # 行內豁免：斷言任一行或緊鄰上一行有 `uitest-wait-ok: <非空理由>`
    ok = 0
    from = (i > 1) ? i - 1 : i
    for (k = from; k <= j; k++) if (L[k] ~ /uitest-wait-ok:[ \t]*[^ \t]/) { ok = 1; break }
    if (ok) continue

    if (code ~ /XCTAssertFalse\(/ && stmt ~ /waitForExistence/) {
      printf "i\t%d\t%s\n", i, bare
      continue
    }
    if (code ~ /XCTAssert(True|Equal|NotNil)\(/ && stmt ~ /\.(exists|label|value)([^A-Za-z0-9_]|$)/) {
      lo = i - lookback; if (lo < fstart) lo = fstart; if (lo < 1) lo = 1
      win = ""
      for (k = lo; k <= j; k++) {
        b = L[k]; sub(/^[ \t]+/, "", b)
        if (b ~ /^\/\//) continue
        win = win " " strip(L[k])
      }
      if (win !~ /waitFor|waitUntilGone|XCTWaiter|XCTNSPredicateExpectation|expectation\(/) {
        printf "ii\t%d\t%s\n", i, bare
      }
    }
  }
}
' "$1"
}

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$scan_dir" -name '*.swift' -type f | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "✗ uitest-wait-check：${scan_dir} 下找不到任何 *.swift（掃描範圍空＝gate 形同虛設，fail closed）" >&2
  exit 1
fi

: > "$work/allow.txt"
if [ -f "$allowlist" ]; then
  sed 's/#.*//' "$allowlist" | tr -d '[:blank:]' | grep -v '^$' | sort -u > "$work/allow.txt" || true
fi

: > "$work/hits.txt"        # 真命中（已扣豁免）
: > "$work/ii_files.txt"    # 規則 ii 有命中的檔（含被 allowlist 吃掉的），供棘輪檢查
for f in "${files[@]}"; do
  rel="${base_name}/${f#"${scan_dir}"/}"
  out=$(scan_file "$f")
  [ -n "$out" ] || continue
  while IFS=$'\t' read -r rule line text; do
    if [ "$rule" = ii ]; then
      echo "$rel" >> "$work/ii_files.txt"
      if grep -qxF -- "$rel" "$work/allow.txt"; then continue; fi
    fi
    printf '%s:%s [規則 %s] %s\n' "$rel" "$line" "$rule" "$text" >> "$work/hits.txt"
  done <<<"$out"
done
sort -u -o "$work/ii_files.txt" "$work/ii_files.txt"

stale=$(comm -23 "$work/allow.txt" "$work/ii_files.txt")

fail=0
if [ -s "$work/hits.txt" ]; then
  fail=1
  n=$(wc -l < "$work/hits.txt" | tr -d ' ')
  echo "✗ uitest-wait-check：${n} 處 UITest 斷言缺等待（慢 runner 才紅；規範見 docs/COLLABORATION.md §7「UITest 等待紀律」）" >&2
  sed 's/^/    /' "$work/hits.txt" >&2
  echo "  規則 i ：消失斷言改 XCTAssertTrue(x.waitForNonExistence(timeout: UITestTimeouts.…))；XCTAssertFalse(waitForExistence) 在元素尚在消失動畫時立刻紅。" >&2
  echo "  規則 ii：讀 .exists／.label／.value 之前先 waitForExistence／waitForHittable／waitUntilGone（同 func 內往前 ${lookback} 行）。" >&2
  echo "  確屬例外：斷言旁加 // uitest-wait-ok: <理由>（同步點在 helper 內／反向斷言刻意視窗期內不得出現）。" >&2
fi
if [ -n "$stale" ]; then
  fail=1
  echo "✗ uitest-wait-check：allowlist 過期——下列條目已無規則 ii 命中（或檔案不存在），請從 ${allowlist#"${root}"/} 刪掉（債只減不留）：" >&2
  sed 's/^/    /' <<<"$stale" >&2
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ uitest-wait-check：${#files[@]} 個 UITest 檔無缺等待的斷言（規則 i 0 處；規則 ii 另有 $(wc -l < "$work/allow.txt" | tr -d ' ') 檔在 allowlist 的歷史債）"
fi
exit "$fail"
