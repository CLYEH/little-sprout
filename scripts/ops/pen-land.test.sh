#!/bin/bash
# pen-land.sh 的自測（LS-91；R2 補 merge-reviewer R1 F1/F2/F3/I2/I3）。CI 自測 step 每個 PR 都跑。
# 用合成 backup／worktree fixture（全部在 mktemp -d 底下），透過 $PEN_BACKUP_DIR 覆寫 backup 目錄——
# 絕不碰真正的 ~/.pencil/backup 或任何真實 design/littlesprout.pen。
# 「前饋必有反饋」對 gate 本身也適用：若結構 diff 漏放過 meta 變更、backup 缺卻誤 cp、dry-run 卻真的
# 寫了檔、--expect-nodes 沒傳給 landing gate、--after 沒真的擋住舊 backup、「結構無差異」沒有預設拒絕、
# 或 gate 紅時把半成品或殘缺內容留在原始檔，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/pen-land.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
wt="${work}/wt"
backup_dir="${work}/backup"

# pen-land.sh 用 `cd "$target" && pwd -P` 算絕對路徑（解 symlink）——macOS 的 $TMPDIR 常見
# /var/folders/... 是 /private/var/folders/... 的 symlink，這裡跟腳本用同一種方式解出「want」的
# 絕對路徑，sha1 才對得上腳本實際找的 backup 檔名。
want_path() { printf '%s/littlesprout.pen' "$(cd "${wt}/design" && pwd -P)"; }
sha_of() { printf '%s' "file://$(want_path)" | shasum | awk '{print $1}'; }

# reset：want＝2 節點（n1 > n2），backup 目錄清空
reset() {
  rm -rf "$wt" "$backup_dir"
  mkdir -p "${wt}/design" "$backup_dir"
  cat > "${wt}/design/littlesprout.pen" <<'JSON'
{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":1,"children":[{"id":"n2","y":2,"children":[]}]}]}
JSON
}

# write_backup <content>：把 $1 寫進 want 路徑對應的 backup 檔名
write_backup() {
  local sha
  sha="$(sha_of)"
  printf '%s' "$1" > "${backup_dir}/${sha}"
}

run() { PEN_BACKUP_DIR="$backup_dir" bash "$script" "$@"; }
tmp_leftovers() { find "${wt}/design" -name '*.pen-land.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }

BACKUP_3NODE='{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":99,"children":[{"id":"n2","y":2,"children":[]},{"id":"n3","z":3,"children":[]}]}]}'
WANT_2NODE='{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":1,"children":[{"id":"n2","y":2,"children":[]}]}]}'

# ---- ① 合法：結構 diff、cp、landing gate 都過（N 省略＝不帶 --expect-nodes 餵 gate，印警告） ----
reset; write_backup "$BACKUP_3NODE"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] \
  && printf '%s' "$out" | grep -qF '新增節點' \
  && printf '%s' "$out" | grep -qF '節點 n1 屬性變更' \
  && printf '%s' "$out" | grep -qF '✓ design-landing gate 通過' \
  && grep -qF '"x":99' "${wt}/design/littlesprout.pen"; then
  ok '① 合法落地：印變更清單＋cp＋landing gate 通過'
else
  bad "① 合法落地應 exit 0 且完成 cp（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ② --expect-nodes 顯式傳給 gate（R1 F2：給錯值 gate 紅時，原始檔完全不動、無殘留暫存檔） ----
reset; write_backup "$BACKUP_3NODE"
before="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" --expect-nodes 999 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF '節點數 3 ≠ 畫布預期 999' \
  && printf '%s' "$out" | grep -qF '原始檔' \
  && [ "$before" = "$after_content" ] && [ "$(tmp_leftovers)" = 0 ]; then
  ok '② --expect-nodes 給錯值：gate 紅、原始檔不動、無殘留暫存檔（R1 F2）'
else
  bad "② gate 紅時原始檔應完全不動且無殘留暫存檔（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ③ backup 缺 → exit 2，不 cp，訊息含路徑編碼提示（R1 I2） ----
reset
before="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到 backup' \
  && printf '%s' "$out" | grep -qF '非 ASCII' && [ "$before" = "$after_content" ]; then
  ok '③ backup 缺 → exit 2，不 cp，訊息提及路徑編碼（R1 I2）'
else
  bad "③ backup 缺應 exit 2、提及路徑編碼、且不動 want（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ④ meta 變更即拒（variables／themes／fileToken 各一組），不 cp ----
for key_desc_backup in \
  'variables:{"version":1,"fileToken":"tok1","variables":{"a":2},"themes":{"light":{}},"children":[{"id":"n1","x":1,"children":[{"id":"n2","y":2,"children":[]}]}]}' \
  'themes:{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"dark":{}},"children":[{"id":"n1","x":1,"children":[{"id":"n2","y":2,"children":[]}]}]}' \
  'fileToken:{"version":1,"fileToken":"tok2","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":1,"children":[{"id":"n2","y":2,"children":[]}]}]}'
do
  key="${key_desc_backup%%:*}"
  body="${key_desc_backup#*:}"
  reset; write_backup "$body"
  before="$(cat "${wt}/design/littlesprout.pen")"
  out="$(run "$wt" 2>&1)"; got=$?
  after_content="$(cat "${wt}/design/littlesprout.pen")"
  if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "meta 變更：${key} 不同" && [ "$before" = "$after_content" ]; then
    ok "④ meta 變更（${key}）即拒，不 cp"
  else
    bad "④ meta 變更（${key}）應 exit 1 且不動 want（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
done

# ---- ⑤ diff 失敗：backup 壞 JSON／backup 頂層非物件／want（落地檔）壞 JSON，皆不 cp（R1 I3 補 want 案例） ----
reset; printf '%s' '{not json' > "${backup_dir}/$(sha_of)"
before="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '解析失敗' && [ "$before" = "$after_content" ]; then
  ok '⑤ backup 壞 JSON → exit 1，不 cp'
else
  bad "⑤ backup 壞 JSON 應 exit 1 且不動 want（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

reset; printf '%s' '[1,2,3]' > "${backup_dir}/$(sha_of)"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '頂層不是物件'; then
  ok '⑤ backup 頂層非物件 → exit 1，不 cp'
else
  bad "⑤ backup 頂層非物件應 exit 1（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

reset; write_backup "$BACKUP_3NODE"; printf '%s' '{not json either' > "${wt}/design/littlesprout.pen"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '落地檔' && printf '%s' "$out" | grep -qF '解析失敗'; then
  ok '⑤ 落地檔（want）壞 JSON → exit 1，不 cp（R1 I3）'
else
  bad "⑤ want 壞 JSON 應 exit 1 且訊息點名落地檔（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑥ dry-run：印清單、exit 0、want 與 backup 目錄皆零副作用 ----
reset; write_backup "$BACKUP_3NODE"
before_want="$(cat "${wt}/design/littlesprout.pen")"
before_files="$(ls "$backup_dir")"
out="$(run "$wt" --dry-run 2>&1)"; got=$?
after_want="$(cat "${wt}/design/littlesprout.pen")"
after_files="$(ls "$backup_dir")"
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '新增節點' \
  && printf '%s' "$out" | grep -qF 'dry-run：未複製、未執行 landing gate' \
  && [ "$before_want" = "$after_want" ] && [ "$before_files" = "$after_files" ] \
  && [ "$(tmp_leftovers)" = 0 ]; then
  ok '⑥ dry-run：印清單＋exit 0＋零副作用（want／backup 皆未變，無殘留暫存檔）'
else
  bad "⑥ dry-run 應零副作用（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# dry-run 搭配 meta 變更：一樣要擋（訊息一致），且仍零副作用
reset; write_backup '{"version":1,"fileToken":"tok2","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":1,"children":[{"id":"n2","y":2,"children":[]}]}]}'
before_want="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" --dry-run 2>&1)"; got=$?
after_want="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'meta 變更：fileToken 不同' && [ "$before_want" = "$after_want" ]; then
  ok '⑥ dry-run＋meta 變更：仍擋、仍零副作用'
else
  bad "⑥ dry-run＋meta 變更應 exit 1 且零副作用（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑦ 目錄／檔案不存在 → exit 2 ----
out="$(run "${work}/nope" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到目錄'; then
  ok '⑦ worktree 目錄不存在 → exit 2'
else
  bad "⑦ 目錄不存在應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

reset; rm "${wt}/design/littlesprout.pen"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到'; then
  ok '⑦ design/littlesprout.pen 不存在 → exit 2'
else
  bad "⑦ .pen 不存在應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑧ 參數形狀 ----
out="$(bash "$script" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then
  ok '⑧ 無參數 → exit 2'
else
  bad "⑧ 無參數應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

reset; write_backup "$BACKUP_3NODE"
out="$(run "$wt" --expect-nodes abc 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '需要一個非負整數'; then
  ok '⑧ --expect-nodes 非數字 → exit 2'
else
  bad "⑧ --expect-nodes 非數字應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

out="$(run "$wt" --expect-nodes 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '需要一個非負整數'; then
  ok '⑧ --expect-nodes 缺值 → exit 2'
else
  bad "⑧ --expect-nodes 缺值應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

out="$(run "$wt" --after abc 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '需要一個非負整數（epoch 秒）'; then
  ok '⑧ --after 非數字 → exit 2'
else
  bad "⑧ --after 非數字應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

out="$(run "$wt" --bogus 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '不認得的參數'; then
  ok '⑧ 未知參數 → exit 2'
else
  bad "⑧ 未知參數應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑨ R1 F1：新鮮度（--after）與「結構無差異」預設拒絕 ----

# ⑨a 直接重現 review 的假落地情境：backup 與落地檔結構完全相同（autosave 還沒追上本輪屬性變更）
#     ——即使不給 --after，「結構無差異」也要預設拒絕，不得 exit 0。
reset; write_backup "$WANT_2NODE"
before="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" --expect-nodes 2 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF '本輪零變更或 autosave 還沒追上' && [ "$before" = "$after_content" ]; then
  ok '⑨a 重現 review 假落地情境：backup 與落地檔結構相同 → 預設拒絕（不再需要 --after 才擋得住）'
else
  bad "⑨a 結構無差異應預設 exit 非 0 且不 cp（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑨b --allow-unchanged：刻意確認本輪無變更時放行，且印顯著標記（R3 I3）
reset; write_backup "$WANT_2NODE"
out="$(run "$wt" --expect-nodes 2 --allow-unchanged 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '結構無差異' \
  && printf '%s' "$out" | grep -qF '⚠ allow-unchanged：本輪零變更，刻意放行'; then
  ok '⑨b --allow-unchanged：結構無差異時刻意放行 → exit 0，印顯著標記（R3 I3）'
else
  bad "⑨b --allow-unchanged 應 exit 0 且印顯著標記（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑨c --after：backup mtime 早於指定 epoch（未來時間戳）→ 拒，印兩邊時間，不 cp（backup 內容本身有差異，
#     證明 --after 是獨立於「結構無差異」之外的新鮮度檢查，不是靠結構比對頂替）
reset; write_backup "$BACKUP_3NODE"
before="$(cat "${wt}/design/littlesprout.pen")"
future=$(( $(date +%s) + 300 ))
out="$(run "$wt" --after "$future" 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF 'backup 太舊' \
  && printf '%s' "$out" | grep -qF "backup mtime=" && printf '%s' "$out" | grep -qF -- "--after=${future}" \
  && [ "$before" = "$after_content" ]; then
  ok '⑨c --after 未來時間戳：backup 太舊 → 拒，印兩邊時間，不 cp'
else
  bad "⑨c --after 應在 backup 太舊時 exit 非 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑨d --after：backup mtime 晚於指定 epoch（過去時間戳）→ 通過新鮮度檢查，正常落地
reset; write_backup "$BACKUP_3NODE"
past=$(( $(date +%s) - 300 ))
out="$(run "$wt" --expect-nodes 3 --after "$past" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF '"x":99' "${wt}/design/littlesprout.pen"; then
  ok '⑨d --after 過去時間戳：backup 夠新 → 正常落地'
else
  bad "⑨d --after 過去時間戳應正常落地（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑬ LS-44：--marker 內容證明覆蓋 mtime 快篩（mtime ~5 秒等級競態的機械解） ----

# ⑬a --marker 沒有 --after 陪同 → exit 2（單獨給不生效，fail loud 而非靜默忽略）
reset; write_backup "$BACKUP_3NODE"
out="$(run "$wt" --expect-nodes 3 --marker '"z":3' 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '須與 --after 搭配'; then
  ok '⑬a --marker 缺 --after → exit 2'
else
  bad "⑬a --marker 缺 --after 應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑬b --marker 缺值 → exit 2
out="$(run "$wt" --after "$(date +%s)" --marker 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '需要一個非空字串參數'; then
  ok '⑬b --marker 缺值 → exit 2'
else
  bad "⑬b --marker 缺值應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑬b2 LS-44 R2 F4（merge-review minor）：--marker '' 顯式空字串 → exit 2（⑬b 只驗完全沒帶值的
#     $# -lt 2 分支，:98 的 [ -z "${2:-}" ] 守衛本身零覆蓋——拿掉它自測仍全綠；沒有這組，
#     `grep -qF -- "" "$backup"` 會命中任何檔案，新鮮度把關被無條件關閉）
out="$(run "$wt" --after "$(date +%s)" --marker '' 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '需要一個非空字串參數'; then
  ok '⑬b2 --marker 顯式空字串 → exit 2（釘住 :98 的 -z 守衛）'
else
  bad "⑬b2 --marker 顯式空字串應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑬c mtime 快篩判定「落後」（未來 --after），但 --marker 命中 backup 原始內容、且不在落地檔（want）
#     中出現（本輪新內容，具鑑別力）→ 視為內容證明，覆蓋 mtime 判斷、繼續往下正常落地並印
#     ⚠ marker-override 到 stdout（LS-44 R2 F3：比照 --allow-unchanged 稽核慣例）
reset; write_backup "$BACKUP_3NODE"
future=$(( $(date +%s) + 300 ))
out="$(run "$wt" --expect-nodes 3 --after "$future" --marker '"z":3' 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '⚠ marker-override' \
  && printf '%s' "$out" | grep -qF '內容證明覆蓋 mtime 判斷' \
  && grep -qF '"x":99' "${wt}/design/littlesprout.pen"; then
  ok '⑬c --marker 命中且具鑑別力：mtime 顯示落後仍以內容證明覆蓋，正常落地，印 ⚠ marker-override'
else
  bad "⑬c --marker 命中應覆蓋 mtime 快篩並正常落地（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑬d mtime 快篩判定「落後」，--marker 有給但沒有命中 backup 內容 → 維持原本拒絕（不得被無關字串誤放行）
reset; write_backup "$BACKUP_3NODE"
before="$(cat "${wt}/design/littlesprout.pen")"
future=$(( $(date +%s) + 300 ))
out="$(run "$wt" --expect-nodes 3 --after "$future" --marker 'NOPE-NOT-PRESENT-IN-BACKUP' 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF '未在 backup 中命中' && [ "$before" = "$after_content" ]; then
  ok '⑬d --marker 未命中：維持拒絕，不 cp'
else
  bad "⑬d --marker 未命中應維持拒絕（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑬e LS-44 R2 F1（merge-review major）：--marker 命中 backup，但同一字串在落地檔（want，代表上一輪
#     內容）中也存在——對「backup 是否含本輪最後一筆編輯」零證明力，必須拒絕，不得放行覆蓋 mtime。
#     重現 reviewer 合成 fixture 的情境 A：n1.content 沿用舊字串「萌芽日記」未變，本輪只改了
#     n1.fill（尚未 autosave）；backup 另外把 n2.x 從 1 改成 5（已 autosave）。若把「萌芽日記」當
#     marker，它在 want／backup 都找得到——不能證明 backup 已經追上 fill 的那一筆。
reset
cat > "${wt}/design/littlesprout.pen" <<'JSON'
{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","content":"萌芽日記","fill":"#AAAAAA","children":[{"id":"n2","x":1,"children":[]}]}]}
JSON
write_backup '{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","content":"萌芽日記","fill":"#AAAAAA","children":[{"id":"n2","x":5,"children":[]}]}]}'
before="$(cat "${wt}/design/littlesprout.pen")"
future=$(( $(date +%s) + 300 ))
out="$(run "$wt" --expect-nodes 2 --after "$future" --marker '萌芽日記' 2>&1)"; got=$?
after_content="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '在落地檔（上一輪內容）中也存在' \
  && printf '%s' "$out" | grep -qF '沒有鑑別力' && [ "$before" = "$after_content" ]; then
  ok '⑬e --marker 命中 backup 但也在落地檔中存在（無鑑別力）→ 拒絕，不 cp（reviewer F1 合成情境 A）'
else
  bad "⑬e 無鑑別力的 marker 應拒絕、不 cp（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑪ LS-117：僅白名單屬性（placeholder）差異的診斷訊息 ----

# ⑪a 單一節點僅 placeholder 差異、節點總數不變 → 印「僅偵測到白名單屬性」，仍是 exit 0（dry-run 對真實
#     diff 一律 exit 0，這裡只驗訊息有沒有印對，不是驗 exit code 本身變了）
reset; write_backup '{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":1,"placeholder":true,"children":[{"id":"n2","y":2,"children":[]}]}]}'
out="$(run "$wt" --dry-run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '僅偵測到白名單屬性' \
  && printf '%s' "$out" | grep -qF "節點 n1 屬性變更：['placeholder']"; then
  ok '⑪a 僅 placeholder 差異、節點總數不變 → 印「僅偵測到白名單屬性」診斷訊息'
else
  bad "⑪a 應印僅白名單屬性訊息（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑪b 同一節點除了 placeholder 還有別的屬性變了（如 x）→ 不是「僅白名單」，不印該訊息
reset; write_backup '{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":99,"placeholder":true,"children":[{"id":"n2","y":2,"children":[]}]}]}'
out="$(run "$wt" --dry-run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF '僅偵測到白名單屬性' \
  && printf '%s' "$out" | grep -qF "節點 n1 屬性變更"; then
  ok '⑪b 同節點混雜非白名單屬性變更 → 不印「僅偵測到白名單屬性」'
else
  bad "⑪b 不應印僅白名單屬性訊息（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑪c 節點總數改變（新增節點），即使既有節點只有 placeholder 差異 → 不是「僅白名單」，不印該訊息
reset; write_backup '{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":1,"placeholder":true,"children":[{"id":"n2","y":2,"children":[]},{"id":"n3","z":3,"children":[]}]}]}'
out="$(run "$wt" --dry-run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF '僅偵測到白名單屬性' \
  && printf '%s' "$out" | grep -qF '新增節點'; then
  ok '⑪c 節點總數改變（新增節點）→ 即使既有節點僅 placeholder 差異，也不印「僅偵測到白名單屬性」'
else
  bad "⑪c 節點增減時不應印僅白名單屬性訊息（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑪d 完全無差異（既有的 UNCHANGED 案例）不應該同時印「僅偵測到白名單屬性」——兩種訊息互斥
reset; write_backup "$WANT_2NODE"
out="$(run "$wt" --expect-nodes 2 2>&1)"
if ! printf '%s' "$out" | grep -qF '僅偵測到白名單屬性'; then
  ok '⑪d 結構完全無差異時不印「僅偵測到白名單屬性」（與 UNCHANGED 訊息互斥）'
else
  bad "⑪d 零變更案例不應印僅白名單屬性訊息"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑫ LS-118 R1 F2（merge-review）：backup mtime 早於落地檔的方向訊號，供 pen-open.sh 的
#      check_root_safe 判斷「backup 落後落地檔（陳舊快取）」vs「backup 領先（真實未落地編輯）」----

# ⑫a 落地檔 mtime 晚於 backup（backup 陳舊，本票要治的場景：git pull／merge 後 Pen 那份 renderer 還沒
#     追上）→ 印方向訊號診斷行
reset; write_backup "$BACKUP_3NODE"
touch -t 202501010000 "${backup_dir}/$(sha_of)"
out="$(run "$wt" --dry-run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '落地檔 mtime 晚於 backup'; then
  ok '⑫a 落地檔 mtime 晚於 backup（陳舊快取方向）→ 印方向訊號診斷行（LS-118 R1 F2）'
else
  bad "⑫a 應印方向訊號診斷行（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑫b backup mtime 晚於落地檔（backup 較新＝真實未落地編輯情境）→ 不印方向訊號，維持保守
reset; write_backup "$BACKUP_3NODE"
touch -t 203001010000 "${backup_dir}/$(sha_of)"
out="$(run "$wt" --dry-run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF '落地檔 mtime 晚於 backup'; then
  ok '⑫b backup mtime 晚於落地檔（真實未落地編輯情境）→ 不印方向訊號（LS-118 R1 F2）'
else
  bad "⑫b 不應印方向訊號（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑩ R1 F3：省略 --expect-nodes 時印明確警告，且 gate 輸出不得宣稱「與畫布一致」 ----
reset; write_backup "$BACKUP_3NODE"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '未指定期望節點數，僅與 backup 自身對帳' \
  && ! printf '%s' "$out" | grep -qF '節點數與畫布一致'; then
  ok '⑩ 省略 --expect-nodes：印警告、不宣稱「與畫布一致」'
else
  bad "⑩ 省略 --expect-nodes 的訊息不符預期（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-land-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-land 自測通過（${n} 組樣本）"
