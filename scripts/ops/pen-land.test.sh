#!/bin/bash
# pen-land.sh 的自測（LS-91）。CI 自測 step 每個 PR 都跑。
# 用合成 backup／worktree fixture（全部在 mktemp -d 底下），透過 $PEN_BACKUP_DIR 覆寫 backup 目錄——
# 絕不碰真正的 ~/.pencil/backup 或任何真實 design/littlesprout.pen。
# 「前饋必有反饋」對 gate 本身也適用：若結構 diff 漏放過 meta 變更、backup 缺卻誤 cp、dry-run 卻真的
# 寫了檔、或 --expect-nodes 沒傳給 landing gate，這裡會紅。
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

BACKUP_3NODE='{"version":1,"fileToken":"tok1","variables":{"a":1},"themes":{"light":{}},"children":[{"id":"n1","x":99,"children":[{"id":"n2","y":2,"children":[]},{"id":"n3","z":3,"children":[]}]}]}'

# ---- ① 合法：結構 diff、cp、landing gate 都過（N 省略＝用 backup 節點數） ----
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

# ---- ② --expect-nodes 顯式傳給 gate（給錯值應該讓 gate 之後失敗，但 cp 仍完成——diff 本身沒理由擋） ----
reset; write_backup "$BACKUP_3NODE"
out="$(run "$wt" --expect-nodes 999 2>&1)"; got=$?
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF '節點數 3 ≠ 畫布預期 999' \
  && grep -qF '"x":99' "${wt}/design/littlesprout.pen"; then
  ok '② --expect-nodes 值傳給 landing gate（給錯值 gate 紅，但 cp 已完成）'
else
  bad "② --expect-nodes 應傳給 gate 並反映在錯誤訊息（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ③ backup 缺 → exit 2，不 cp ----
reset
before="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" 2>&1)"; got=$?
after="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到 backup' && [ "$before" = "$after" ]; then
  ok '③ backup 缺 → exit 2，不 cp'
else
  bad "③ backup 缺應 exit 2 且不動 want（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
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
  after="$(cat "${wt}/design/littlesprout.pen")"
  if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "meta 變更：${key} 不同" && [ "$before" = "$after" ]; then
    ok "④ meta 變更（${key}）即拒，不 cp"
  else
    bad "④ meta 變更（${key}）應 exit 1 且不動 want（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
done

# ---- ⑤ diff 失敗：backup 壞 JSON／want 壞 JSON／backup 頂層非物件，皆不 cp ----
reset; printf '%s' '{not json' > "${backup_dir}/$(sha_of)"
before="$(cat "${wt}/design/littlesprout.pen")"
out="$(run "$wt" 2>&1)"; got=$?
after="$(cat "${wt}/design/littlesprout.pen")"
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '解析失敗' && [ "$before" = "$after" ]; then
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

# ---- ⑥ dry-run：印清單、exit 0、want 與 backup 目錄皆零副作用 ----
reset; write_backup "$BACKUP_3NODE"
before_want="$(cat "${wt}/design/littlesprout.pen")"
before_files="$(ls "$backup_dir")"
out="$(run "$wt" --dry-run 2>&1)"; got=$?
after_want="$(cat "${wt}/design/littlesprout.pen")"
after_files="$(ls "$backup_dir")"
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '新增節點' \
  && printf '%s' "$out" | grep -qF 'dry-run：未複製、未執行 landing gate' \
  && [ "$before_want" = "$after_want" ] && [ "$before_files" = "$after_files" ]; then
  ok '⑥ dry-run：印清單＋exit 0＋零副作用（want／backup 皆未變）'
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

out="$(run "$wt" --bogus 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '不認得的參數'; then
  ok '⑧ 未知參數 → exit 2'
else
  bad "⑧ 未知參數應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-land-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-land 自測通過（${n} 組樣本）"
