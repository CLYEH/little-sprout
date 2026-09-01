#!/bin/bash
# LS-91：.pen 落地腳本——把 Pen app 的 autosave 備份（~/.pencil/backup/<sha1("file://<abs path>")>）複製回
# worktree 的 design/littlesprout.pen，複製前做結構 diff 把關，複製後跑 design-landing-check.sh 收尾。
# 取代 LS-26 手動 SOP 的機械版本（LS-91 comment 0fb5f855；R2 補 F1/F2/F3——merge-reviewer R1 指出機械化
# 過程中弄丟了 LS-26 步驟 2「backup mtime 晚於最後一次 execute」這道新鮮度把關，只留節點數比對偵測不到
# 純屬性變更的假落地）。
#
# backup 目錄與命名格式（本票實測確認，2026-08-25）：`~/.pencil/backup/<sha1>`，檔名＝
# `printf '%s' "file://<絕對路徑>" | shasum` 的十六進位摘要（40 hex、無副檔名）——對主 checkout
# `design/littlesprout.pen` 算出的 sha1，與該目錄下一份既有備份檔名完全相符（mtime 也對得上最近一次
# `open -a Pen` 之後）。路徑含空白／非 ASCII 時 sha1 可能對不上（R1 I2；本票對含空白路徑實測引號處理
# 正確，只是若真的對不上，找不到 backup 的錯誤訊息要能提示往這個方向查）。
#
# 用法：pen-land.sh <worktree-or-repo-root> [--expect-nodes N] [--after EPOCH [--marker STRING]] [--allow-unchanged] [--dry-run]
#
# 流程：
#   1. 算 want = <root>/design/littlesprout.pen 的絕對路徑；sha1(file://want) 找 backup。
#   2. --after EPOCH（R1 F1，LS-26 步驟 2 的機械版）：backup mtime 早於 EPOCH 即拒、印兩邊時間、exit 1，
#      不往下跑——ui-designer 在最後一次 execute 之後立刻 `t=$(date +%s)`，用 `--after $t` 呼叫，擋住
#      「autosave 還沒追上最新編輯」這種假落地。省略則不做新鮮度檢查（相容舊呼叫，但 ui-designer 的收工
#      程序一律要傳）。
#      **LS-44**：這道 mtime 比對本身有 ~5 秒等級的競態——`date +%s` 只有整秒精度、autosave 是非同步寫入，
#      backup mtime 落在 EPOCH 前一兩秒不代表 backup 內容真的落後最後一次 execute，也可能只是寫入時間點被
#      秒級精度或排程延遲誤判成「早於」。mtime 因此只適合當**快篩**（明顯落後太多——例如落後幾分鐘——直接
#      擋掉多半是對的），不該是唯一的**決斷**依據。`--marker STRING`（與 `--after` 搭配、單獨給不生效）：
#      mtime 快篩判定「落後」時，若給了 `--marker` 且 backup 檔案原始內容（純文字 grep，非 JSON 解析）含有
#      這個字串，視為內容證明——backup 確實已包含本輪最後一筆編輯——覆蓋 mtime 的判斷，繼續往下跑結構 diff
#      （印出信任內容證明的稽核訊息）；沒給 `--marker` 或給了但沒命中，維持原本行為：印訊息、exit 1。
#      ui-designer 在最後一次 execute 之後，除了記 `t=$(date +%s)`，也應記下那次編輯裡的一個獨特字串（例如
#      剛設定的 content／name／新 id），落地時一併傳 `--marker`；沒有獨特字串可用（例如純屬性數值變更、
#      沒有可搜文字）就不傳，退回純 mtime 快篩＋等待重跑。
#   3. python3 結構 diff：want（落地檔／舊）vs backup（Pen 記憶體／新）——節點總數（含巢狀 children）、
#      id 集合（新增／刪除）、meta（variables／themes／fileToken）是否不變、逐 (id, prop) 差異
#      （排除 children，避免整棵子樹洗版）。印出變更清單。LS-117：節點總數／id 集合不變、且所有屬性差異都
#      落在白名單內（目前僅 `placeholder`，pen-dev skill 定義的「工作中」UI 態旗標）時，額外印一行「僅偵測到
#      白名單屬性…」的訊息——供 `pen-open.sh` 的 `check_root_safe` 辨識為可安全捨棄的 autosave 漂移，不影響
#      本腳本自身的 exit code／是否落地（純資訊性，不改變既有行為）。
#   4. meta 變了，或 diff 本身失敗（JSON 壞掉、頂層非物件等）→ 不 cp，exit 1。
#   5. 結構完全無差異（R1 F1）→ 預設也視為失敗（本輪零變更或 autosave 沒追上，兩者從結構上分不出來，
#      寧可誤擋不誤放）、印訊息、exit 1；刻意確認本輪真的沒有變更就加 `--allow-unchanged` 放行（R3 I3：
#      放行時印顯著標記 `⚠ allow-unchanged：本輪零變更，刻意放行`，這是這道把關唯一的逃生口，讓 handoff／
#      PR review 一眼看得到它被用掉了）。
#   6. --expect-nodes 省略時（R1 F3）**不會**帶去餵 design-landing-check.sh，避免它印出「節點數與畫布
#      一致」這種其實只是「backup 跟自己比」的誤導訊息；改印明確警告「僅與 backup 自身對帳」。
#   7. --dry-run：印完清單就結束，不 cp、不跑 landing gate（零副作用）。
#   8. 否則：cp backup → 暫存檔 → 跑 design-landing-check.sh 驗暫存檔 → 過了才 `mv -f` 覆蓋 want，
#      沒過就（trap 自動）清暫存檔、原始檔完全不動（R1 F2：避免 gate 紅時留下半成品或用殘缺 backup 蓋掉
#      合法舊稿）。暫存檔一律掛 `trap 'rm -f "$tmp"' EXIT`（R3 I2：Ctrl-C／外部 kill 這種異常中斷也不留下
#      未追蹤的殘留檔；`mv` 本身失敗這種需要人工檢查暫存檔的情況會先 `trap - EXIT` 關掉再退出，暫存檔才
#      真的留得住）。
#
# 測試用可覆寫 backup 目錄（$PEN_BACKUP_DIR，預設 ~/.pencil/backup）：自測用合成 fixture，不碰真正的
# ~/.pencil/backup 或 design/littlesprout.pen（真檔落地仍由 orchestrator 執行，auto-mode 分類器會擋 agent
# 直接覆寫）。mtime 一律用 python3（已是硬依賴）的 `os.path.getmtime` 讀取，不用 `stat -f`／`stat -c`——
# 兩種 stat 旗標語法在 macOS／Linux 不同，CI 的 rules job 跑在 ubuntu-latest，用 stat 會兩邊分裂。
#
# 自測：scripts/ops/pen-land.test.sh。
set -uo pipefail

usage() {
  echo "用法：pen-land.sh <worktree-or-repo-root> [--expect-nodes N] [--after EPOCH [--marker STRING]] [--allow-unchanged] [--dry-run]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

target=$1
shift
expect=""
after=""
after_given=0
marker=""
marker_given=0
allow_unchanged=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-nodes)
      if [ $# -lt 2 ] || ! printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then
        echo "✗ pen-land：--expect-nodes 需要一個非負整數參數" >&2
        exit 2
      fi
      expect=$2
      shift 2
      ;;
    --after)
      if [ $# -lt 2 ] || ! printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then
        echo "✗ pen-land：--after 需要一個非負整數（epoch 秒）參數" >&2
        exit 2
      fi
      after=$2
      after_given=1
      shift 2
      ;;
    --marker)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "✗ pen-land：--marker 需要一個非空字串參數" >&2
        exit 2
      fi
      marker=$2
      marker_given=1
      shift 2
      ;;
    --allow-unchanged)
      allow_unchanged=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *)
      echo "✗ pen-land：不認得的參數「$1」" >&2
      usage
      exit 2
      ;;
  esac
done

if [ "$marker_given" -eq 1 ] && [ "$after_given" -ne 1 ]; then
  echo "✗ pen-land：--marker 須與 --after 搭配（沒有 mtime 快篩就沒有需要覆蓋的判斷，單獨給不生效）" >&2
  exit 2
fi

root=$(cd "$target" 2>/dev/null && pwd -P) || {
  echo "✗ pen-land：找不到目錄「${target}」" >&2
  exit 2
}
want="${root}/design/littlesprout.pen"
[ -f "$want" ] || {
  echo "✗ pen-land：找不到「${want}」" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "✗ pen-land：需要 python3 解析 .pen 結構" >&2
  exit 2
}
command -v shasum >/dev/null 2>&1 || {
  echo "✗ pen-land：需要 shasum 計算 backup 檔名" >&2
  exit 2
}

backup_dir="${PEN_BACKUP_DIR:-$HOME/.pencil/backup}"
sha=$(printf '%s' "file://${want}" | shasum | awk '{print $1}')
backup="${backup_dir}/${sha}"
[ -f "$backup" ] || {
  echo "✗ pen-land：找不到 backup「${backup}」（Pen 可能沒開過這個路徑、autosave 還沒發生，或路徑含空白／非 ASCII 導致 sha1 對不上——先 pen-open.sh 切檔並等 autosave；仍找不到再檢查路徑編碼）" >&2
  exit 2
}

if [ "$after_given" -eq 1 ]; then
  backup_mtime=$(python3 -c 'import os, sys
print(int(os.path.getmtime(sys.argv[1])))' "$backup" 2>/dev/null) || {
    echo "✗ pen-land：無法讀取 backup「${backup}」的 mtime" >&2
    exit 2
  }
  if [ "$backup_mtime" -lt "$after" ]; then
    stale=$((after - backup_mtime))
    if [ "$marker_given" -eq 1 ] && grep -qF -- "$marker" "$backup" 2>/dev/null; then
      # LS-44 R2 F1（merge-review major）：命中 backup 不足以證明鑑別力——若同一字串在「落地檔」
      # （上一輪內容）也存在，代表它可能只是沿用的舊字串，對「backup 是否含本輪最後一筆編輯」零
      # 證明力（reviewer 合成 fixture 實證：舊字串命中會讓未 autosave 的最後一筆屬性變更靜默消
      # 失，正是 --after 要擋的競態）。必須再驗一次：字串同時出現在 want 就拒絕、要求換一個。
      if grep -qF -- "$marker" "$want" 2>/dev/null; then
        echo "✗ pen-land：--marker「${marker}」在落地檔（上一輪內容）中也存在——這個字串無法證明 backup 含本輪最後一筆編輯（可能只是沿用的舊內容），沒有鑑別力，不接受。換一個本輪新出現的獨特字串（新 content／name／新節點 id 皆可），或等 autosave 後重跑" >&2
        exit 2
      fi
      # LS-44 R2 F3（merge-review minor）：逃生口稽核標記比照 --allow-unchanged 慣例——stdout＋
      # `⚠` 開頭的顯著標記，讓 handoff／PR review 一眼看得到新鮮度把關被 marker 覆蓋掉。
      echo "⚠ marker-override：mtime 快篩顯示 backup mtime=${backup_mtime}（epoch）落後 --after=${after}（epoch）共 ${stale} 秒，但 --marker 命中 backup 內容且未出現在落地檔中（本輪新內容的鑑別性證明），視為內容證明覆蓋 mtime 判斷，繼續（LS-44：mtime 只是快篩，內容證明才是決斷）"
    else
      if [ "$marker_given" -eq 1 ]; then
        echo "✗ pen-land：backup 太舊——backup mtime=${backup_mtime}（epoch），--after=${after}（epoch），backup 落後 ${stale} 秒，且 --marker「${marker}」未在 backup 中命中——autosave 還沒追上最後一次 execute，等 autosave 後重跑（不得改用 cp 手動繞過）" >&2
      else
        echo "✗ pen-land：backup 太舊——backup mtime=${backup_mtime}（epoch），--after=${after}（epoch），backup 落後 ${stale} 秒——autosave 還沒追上最後一次 execute，等 autosave 後重跑（不得改用 cp 手動繞過；若能找出這次編輯的獨特字串，可加 --marker 用內容證明取代 mtime 快篩）" >&2
      fi
      exit 1
    fi
  fi
fi

# python 結構 diff：清單印到 stdout，最後三行印 `NODES=<N>`／`META_OK=0|1`／`UNCHANGED=0|1` 供 shell
# 解析，事後濾掉。
diff_out=$(PYTHONIOENCODING=utf-8 python3 - "$want" "$backup" <<'PY'
import json, os, sys

old_path, new_path = sys.argv[1], sys.argv[2]


def load(p):
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


try:
    old = load(old_path)
except Exception as e:
    print(f"✗ pen-land：落地檔「{old_path}」解析失敗（{type(e).__name__}: {e}）", file=sys.stderr)
    print("META_OK=0")
    sys.exit(1)
try:
    new = load(new_path)
except Exception as e:
    print(f"✗ pen-land：backup「{new_path}」解析失敗（{type(e).__name__}: {e}）", file=sys.stderr)
    print("META_OK=0")
    sys.exit(1)

if not isinstance(old, dict) or not isinstance(new, dict):
    print("✗ pen-land：頂層不是物件，不是 .pen 格式", file=sys.stderr)
    print("META_OK=0")
    sys.exit(1)


def collect(d):
    """回傳 {id: node} 與節點總數（含巢狀 children）。"""
    nodes = {}
    count = 0
    stack = list(d.get("children") or [])
    while stack:
        n = stack.pop()
        if isinstance(n, dict):
            count += 1
            nid = n.get("id")
            if nid is not None:
                nodes[nid] = n
            stack.extend(n.get("children") or [])
    return nodes, count


old_nodes, old_count = collect(old)
new_nodes, new_count = collect(new)

meta_ok = True
for key in ("variables", "themes", "fileToken"):
    if old.get(key) != new.get(key):
        meta_ok = False
        print(f"meta 變更：{key} 不同（落地檔 → backup）")

added = sorted(set(new_nodes) - set(old_nodes), key=str)
removed = sorted(set(old_nodes) - set(new_nodes), key=str)
if added:
    print(f"新增節點（{len(added)}）：{added}")
if removed:
    print(f"刪除節點（{len(removed)}）：{removed}")

# LS-117：僅變更這些屬性視為「UI 態」漂移（例如 ui-designer 收工前的 placeholder 開關），不是實質內容——
# 供 pen-open.sh 的 check_root_safe 判斷是否可安全捨棄自動 quit 前偵測到的 autosave 差異。單一集合，這裡與
# check_root_safe 各自認定同一份白名單（目前只有 placeholder），新增白名單鍵時兩處要一起改。
PLACEHOLDER_SAFE_KEYS = {"placeholder"}

prop_changes = 0
non_whitelisted_prop_change = False
for nid in sorted(set(old_nodes) & set(new_nodes), key=str):
    o, n = old_nodes[nid], new_nodes[nid]
    keys = (set(o) | set(n)) - {"children"}
    diffs = sorted(k for k in keys if o.get(k) != n.get(k))
    if diffs:
        prop_changes += 1
        print(f"節點 {nid} 屬性變更：{diffs}")
        if not set(diffs) <= PLACEHOLDER_SAFE_KEYS:
            non_whitelisted_prop_change = True

# LS-118 R1 F2（merge-review）：純節點內容 diff 分不出「backup 落後落地檔」（Pen 快取陳舊——落地檔在 Pen
# 上次 autosave 之後被 git checkout／merge／pull 更新，例如 QA `git pull` 後第一次讀稿必踩）與「backup 領先
# 落地檔」（Pen 有真實未落地編輯）兩個方向，過去一律判「可能有未落地變更」，逼呼叫端在陳舊方向也去跑
# pen-land.sh——那會用舊快照覆蓋較新的落地檔。mtime 是現成的方向訊號：落地檔 mtime 晚於 backup ＝ backup
# 寫入之後落地檔又被別的東西（通常是 git）動過，是陳舊快取而非新編輯；只印一行讓 pen-open.sh 的
# check_root_safe 判斷（是否安全捨棄仍需另外核對 git-clean，見該檔），不影響本腳本自身的 exit code。
try:
    old_mtime = os.path.getmtime(old_path)
    new_mtime = os.path.getmtime(new_path)
    if old_mtime > new_mtime:
        print("（落地檔 mtime 晚於 backup——落地檔在 Pen 上次 autosave 之後被更新，backup 可能是陳舊快取而非未落地的新編輯）")
except OSError:
    pass

print(f"節點總數：落地檔 {old_count} → backup {new_count}")
unchanged = not added and not removed and prop_changes == 0 and old_count == new_count
if unchanged:
    print("（結構無差異——本輪零變更或 autosave 還沒追上，兩者從結構上分不出來）")

# LS-117 defect 1：節點總數／id 集合不變，且所有屬性差異都落在白名單內（目前僅 placeholder）——這類差異
# 印出獨立可稽核的訊息，供 check_root_safe 辨識為「UI 態漂移、可安全捨棄」，不是「有未落地變更」。
placeholder_only = (
    not added
    and not removed
    and old_count == new_count
    and prop_changes > 0
    and not non_whitelisted_prop_change
)
if placeholder_only:
    print(
        f"（僅偵測到白名單屬性（{sorted(PLACEHOLDER_SAFE_KEYS)}）差異，節點總數與 id 集合不變——"
        "視為可安全捨棄的 UI 態 autosave 漂移，非實質內容變更）"
    )

print(f"NODES={new_count}")
print(f"META_OK={1 if meta_ok else 0}")
print(f"UNCHANGED={1 if unchanged else 0}")
sys.exit(0 if meta_ok else 1)
PY
)
py_rc=$?
printf '%s\n' "$diff_out" | grep -v -E '^(NODES=|META_OK=|UNCHANGED=)'

if [ "$py_rc" -ne 0 ]; then
  echo "✗ pen-land：結構 diff 失敗或 meta 變更（見上方訊息）——不複製" >&2
  exit 1
fi

nodes=$(printf '%s\n' "$diff_out" | grep '^NODES=' | tail -1 | cut -d= -f2)
unchanged=$(printf '%s\n' "$diff_out" | grep '^UNCHANGED=' | tail -1 | cut -d= -f2)
if [ -z "$nodes" ] || [ -z "$unchanged" ]; then
  echo "✗ pen-land：無法取得 diff 摘要（NODES=／UNCHANGED= 缺失，diff 腳本異常）" >&2
  exit 1
fi

if [ "$unchanged" = 1 ]; then
  if [ "$allow_unchanged" -ne 1 ]; then
    echo "✗ pen-land：本輪零變更或 autosave 還沒追上（結構與落地檔完全相同）——刻意確認本輪真的沒有變更就加 --allow-unchanged" >&2
    exit 1
  fi
  # R3 I3：--allow-unchanged 是這道把關唯一的逃生口，印顯著標記讓 handoff／PR review 一眼看得到它被用掉了。
  echo "⚠ allow-unchanged：本輪零變更，刻意放行"
fi

if [ "$dry_run" -eq 1 ]; then
  echo "（dry-run：未複製、未執行 landing gate）"
  exit 0
fi

tmp="${want}.pen-land.tmp.$$"
# R3 I2：異常中斷（Ctrl-C／外部 kill）沒有這個 trap 會在 worktree 留下未追蹤的暫存檔；同目錄才能保證
# mv -f 是同檔案系統的原子操作，trap 對正常結束（含成功 mv 之後 tmp 已不存在）是無害的 no-op。
trap 'rm -f "$tmp"' EXIT
cp "$backup" "$tmp" || {
  echo "✗ pen-land：cp「${backup}」→「${tmp}」失敗" >&2
  exit 1
}

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${script_root}/scripts/gates/design-landing-check.sh"
if [ -n "$expect" ]; then
  bash "$gate" "$tmp" --expect-nodes "$expect"
  gate_rc=$?
else
  echo "未指定期望節點數，僅與 backup 自身對帳（無法偵測 backup 是否落後畫布）"
  bash "$gate" "$tmp"
  gate_rc=$?
fi

if [ "$gate_rc" -ne 0 ]; then
  echo "✗ pen-land：landing gate 未過（見上方訊息）——原始檔「${want}」未動" >&2
  exit "$gate_rc"
fi

mv -f "$tmp" "$want" || {
  # mv 失敗是異常狀況（同目錄理論上不該跨檔案系統）：關掉 EXIT trap，保留暫存檔供人工檢查——
  # 訊息說「留在」就真的要留在，不能被 trap 悄悄清掉。
  trap - EXIT
  echo "✗ pen-land：mv「${tmp}」→「${want}」失敗——暫存檔留在「${tmp}」，原始檔「${want}」未動" >&2
  exit 1
}
echo "✓ pen-land：已落地到「${want}」"
