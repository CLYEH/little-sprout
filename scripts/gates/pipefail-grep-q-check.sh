#!/bin/bash
# `pipefail` ＋ `| grep -q` 偵測（LS-270，來源 LS-96 池項 `d4c1add5`／`e850cb7f`(3)）：
# 掃 `scripts/**/*.sh`（**含 gate／hook／ops 本體，不只自測**），檔內開了 `pipefail`
# （`set -o`／`-uo`／`-euo pipefail`）**且**出現 `<上游> | grep -q…` 的，印一行 ⚠ 摘要。
#
# R2 B2：初版只掃 `*.test.sh`，因此看不見 `scripts/gates/agent-tools-check.sh` 那處——它不是自測，
# 是掛在 rules job 上**會擋 PR 的 gate 本體**，body 最大 36 KB，merge-review R1 在 ubuntu 容器實測
# 30 次紅 2 次。最該被這支照到的就是這一型，掃描範圍因此擴到全部 `*.sh`。
#
# 背景（LS-267 R2 B1）：`printf '%s' "$big" | grep -qF -- pat` 在 `set -o pipefail` 下，GNU grep
# 命中即 `exit 0`，上游還在寫就收 SIGPIPE、以 141 結束，`pipefail` 把整條管線判成 141 ＝紅；
# macOS 的 BSD grep 會把輸入讀完才退出，**本機永遠綠**。LS-267 head `c360589` 的 `rules` job
# 因此 20 次跑紅 14 次，同一份自測在開發機 6/6 綠——正是「本機綠 CI 紅」這個最貴的類別。
#
# **不是硬門檻，是機率（R2 B2 訂正）**：初版寫「≈64 KB 以下安全」，那是把 LS-267 R3 的取樣
# （60 KB 10 次紅 1 次、72 KB 10 次紅 7 次、128 KB 10 次全紅）誤讀成門檻。merge-review R1 在
# ubuntu:24.04 容器對 `agent-tools-check.sh` 實測：body 20–36 KB，30 次紅 2 次；改成 here-string
# 後同樣 30 次紅 0 次。**紅的機率隨上游輸出大小上升，小輸入只是機率低、不是安全**——一律改
# here-string／讀檔，別再用大小當理由放過。
#
# **informational：一律 exit 0、不擋**（同 `uitest-dup-helper-check.sh` 的既有取捨）。理由是這支
# 靜態看得到「有沒有用這個構造」，看不到「上游會吐多少位元組」，四百多處一次全擋等於逼所有人
# 在同一個 PR 內改寫。它的用途是：寫／改腳本的人在 CI log 裡看得到這條，知道新寫的要用讀檔或
# here-string（`grep -qF -- "$pat" <<<"$big"`），順手經過的舊處也一併換掉。
#
# 判準：
#   - pipefail＝檔內任一行出現 `set -<旗標>o<空白>pipefail`（`-o`／`-uo`／`-euo` 都算）。不追蹤
#     `set +o pipefail` 之後是否關掉——那是執行期狀態，靜態文字判不了，寧可多提醒。
#   - 命中行＝`| grep -q…`（`-q`／`-qF`／`-qE`／`-F -q` 這類拆開寫的旗標組合都算）。
#   - 整行去頭空白後以 `#` 起手的**純註解行不算**（本檔與 COLLABORATION.md 自己就會在註解裡寫這個
#     構造當反例；行尾註解仍會被算進去，那是可接受的少數誤報）。
#
# 用法：bash pipefail-grep-q-check.sh [--scan-dir <dir>] [--list]
#   --scan-dir  掃描根目錄（預設 <repo>/scripts）；只給自測餵夾具用。
#   --list      逐處列出 `檔:行號` 與該行原文（預設只印摘要，避免四百多行灌爆 CI log）。
# exit：一律 0（informational）；參數錯 exit 2（fail closed）。
# 自測：scripts/gates/pipefail-grep-q-check.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
scan_dir=
list=0

while [ $# -gt 0 ]; do
  case "$1" in
    --scan-dir)
      [ -n "${2:-}" ] || { echo "✗ pipefail-grep-q-check：--scan-dir 缺值" >&2; exit 2; }
      scan_dir=$2; shift 2 ;;
    --list) list=1; shift ;;
    -h|--help)
      echo "用法：pipefail-grep-q-check.sh [--scan-dir <dir>] [--list]"
      exit 0 ;;
    *) echo "✗ pipefail-grep-q-check：未知參數「$1」。用法：pipefail-grep-q-check.sh [--scan-dir <dir>] [--list]" >&2; exit 2 ;;
  esac
done

scan_dir=${scan_dir:-${root}/scripts}
if [ ! -d "$scan_dir" ]; then
  echo "→ pipefail-grep-q-check：找不到 ${scan_dir}，略過"
  exit 0
fi

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$scan_dir" -name '*.sh' -type f | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "→ pipefail-grep-q-check：${scan_dir} 下沒有 *.sh，略過"
  exit 0
fi

# awk 一次掃完（BSD／GNU 的 awk 都吃這組 ERE）：`FNR == 1` 時先把整檔讀一遍找 pipefail，命中才記命中行。
# 輸出兩種行：`HIT<TAB>檔<TAB>行號<TAB>原文` 與 `FILE<TAB>檔<TAB>處數`。
hits=$(awk '
function has_pipefail(path,   line, found) {
  found = 0
  while ((getline line < path) > 0) {
    if (line ~ /set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail/) { found = 1; break }
  }
  close(path)
  return found
}
FNR == 1 { active = has_pipefail(FILENAME); count = 0 }
!active { next }
{
  line = $0
  bare = line
  sub(/^[[:space:]]+/, "", bare)
  if (substr(bare, 1, 1) == "#") next
  if (line !~ /\|[[:space:]]*grep([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*q/) next
  count++
  file_count[FILENAME] = count
  printf "HIT\t%s\t%d\t%s\n", FILENAME, FNR, bare
}
END { for (f in file_count) printf "FILE\t%s\t%d\n", f, file_count[f] }
' "${files[@]}" | sed "s#${root}/##g")

total=$(printf '%s\n' "$hits" | awk -F'\t' '$1 == "HIT" { n++ } END { print n + 0 }')
nfiles=$(printf '%s\n' "$hits" | awk -F'\t' '$1 == "FILE" { n++ } END { print n + 0 }')

if [ "$total" -eq 0 ]; then
  echo "✓ pipefail-grep-q-check：${#files[@]} 支腳本都沒有「pipefail ＋ | grep -q」的構造"
  exit 0
fi

echo "⚠ pipefail-grep-q-check：${total} 處 \`| grep -q\` 落在 ${nfiles} 支開了 pipefail 的腳本裡（掃 ${scan_dir##*/}/**/*.sh，共 ${#files[@]} 支）"
echo "  GNU grep 命中即退出 → 上游還在寫就收 SIGPIPE、以 141 結束，pipefail 把管線判成紅；macOS 的 BSD grep 讀完才退出，本機看不到（LS-267 head \`c360589\` 的 rules job 20 次紅 14 次）。"
echo "  **沒有安全大小**：紅的機率隨上游輸出上升，小輸入只是機率低——LS-270 R2 B2 實測 20–36 KB 的 agent-tools-check.sh 在 ubuntu 30 次紅 2 次，改 here-string 後 30 次 0 紅。一律改讀檔或 here-string：grep -qF -- \"\$pat\" <<<\"\$big\"。"
if [ "$list" -eq 1 ]; then
  printf '%s\n' "$hits" | awk -F'\t' '$1 == "HIT" { printf "    %s:%s  %s\n", $2, $3, $4 }'
else
  echo "  逐處清單：bash scripts/gates/pipefail-grep-q-check.sh --list"
fi
echo "→ pipefail-grep-q-check：informational，一律 exit 0 不擋（docs/COLLABORATION.md §7 BSD-GNU 列第三型）。"
exit 0
