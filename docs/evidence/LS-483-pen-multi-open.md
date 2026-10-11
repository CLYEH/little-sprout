# LS-483 .pen 多開可行性探針評估

- 探針時間：2026-10-12 01:03–01:10（Asia/Taipei）
- 環境：Pen.app（desktop）、pen CLI 0.3.4（`/opt/homebrew/bin/pen`，有新版 0.3.11 提示，依票文不升級）、Pencil MCP（本 session）
- **全程螢幕鎖定**：`ioreg -n Root -d1 -a` 的 `IOConsoleLocked` 一直是 `true`（使用者離開座位）。所以 (A)(B) 的結果都是「鎖屏狀態下」量到的；「鎖屏前後比對」做不到，見 A-5。
- 副本：`mktemp -d` 開在 scratchpad（`…/scratchpad/LS-483-probe.HhCY/`），內容如下：`probe-main.pen`＝`design/littlesprout.pen`（development d129811，version 2.21，21,632 節點）；`probe-proposal.pen`＝`git show origin/feature/LS-455-soft-social-proposal:docs/design-proposals/soft-social-20261009/littlesprout-soft-social.pen`（version 2.18，632 節點）；另有 `probe-third.pen`（proposal 的複本），以及 C-6 自建的 `probe-lib.pen`／`probe-consumer.pen`。repo 內 .pen 全程沒有寫入（主 checkout `git status --porcelain design/` 前後都是空的）。
- 起手清場：`bash scripts/ops/pen-open.sh /Users/clyeh/little-sprout --kill` → rc=0。清場前 ps 顯示同一個 Pen 主行程底下已經同時開著兩份文件（LS-471 提案檔與主稿），這也是同行程多文件的一筆現成證據。

## (A) 桌面 Pen 多開

### A-1 `open -a Pen probe-main.pen` 之後再 `open -a Pen probe-proposal.pen` → **同一行程開新視窗（多一個 renderer）**

```
open -a Pen $D/probe-main.pen      → status: …/probe-main.pen
open -a Pen $D/probe-proposal.pen  → status: …/probe-proposal.pen
Pen pids: 33576            （只有一個主行程）
33599 file:///Users/clyeh/little-sprout/design/littlesprout.pen
34015 file:///…/LS-483-probe.HhCY/probe-main.pen
34325 file:///…/LS-483-probe.HhCY/probe-proposal.pen   （每份文件各一支 Pen Helper (Renderer)）
```

`mcp__pencil__get_app_state` 原文摘錄（只回 active 一份，**沒有文件清單**欄位）：

```
- Currently active canvas editor: `/private/tmp/…/LS-483-probe.HhCY/probe-proposal.pen`
- Top-level nodes: `ev2Pc` (frame): C / Visual language · 一起長大 [user visible], `rsm56` (frame): C / 01 家庭動態 …, ... +3 others
- Reusable components: `q8jPVU`: Button · 分享給家人, `NuMx0`: Button · 小禾
```

**用 filePath 定址非 active 文件（這是本票最重要的正面結果）**：`mcp__pencil__execute` 帶 `filePath=probe-main.pen`（已載入、但不是 active）時，回的確實是 probe-main 的內容（`OeXop cmp/Status Bar 0 0`…，頂層 395 個）；帶 `filePath=probe-proposal.pen` 回的是 proposal 的內容（`ev2Pc … 0 0`，頂層 13 個）。這和 LS-118 的結論一致：filePath 只對「某個 renderer 已經載入的文件」有效（從沒開過的路徑會默默改服務 active，本票沒有重測）。

### A-2 兩份各改一個節點（不存檔），檢查有沒有互相汙染 → **沒有汙染**

```
[filePath=probe-main]     Update("OeXop",{name:"PROBE-A-main"})       → PROBE-A-main
[filePath=probe-proposal] Update("ev2Pc",{name:"PROBE-B-proposal"})   → PROBE-B-proposal
[filePath=probe-main]     main OeXop: PROBE-A-main / PROBE top-level in main: OeXop=PROBE-A-main / ev2Pc in main: 0
[filePath=probe-proposal] proposal ev2Pc: PROBE-B-proposal / PROBE top-level in proposal: ev2Pc=PROBE-B-proposal / OeXop in proposal: 0
```

- 寫入之後 active document 沒有變（`get_app_state` 仍然回 probe-proposal，頂層第一個已經是 `PROBE-B-proposal`）。
- autosave backup 各寫各的：`~/.pencil/backup/b28014f3…`＝sha1(`file://…/probe-main.pen`)，裡面只有 `"PROBE-A-main"`；`99889efc…`＝sha1(`file://…/probe-proposal.pen`)，裡面只有 `"PROBE-B-proposal"`。磁碟上的副本 mtime 沒變，`grep -c PROBE-` 兩份都是 0，也就是說 Pen 沒有自動寫回原檔。
- 匯出：`Export(["rsm56"],"png",…)`（proposal）→ 390×844；`Export(["W6qTyS"],"png",…)`（main）→ 393×44。兩份都是各自文件的正確板（目視 rsm56＝「家庭動態」板）。照片格顯示為棋盤格，原因是副本目錄裡沒有相對路徑的圖片資產，跟多開無關。

### A-3 `open -n -a Pen probe-third.pen`（試圖開第二個行程）→ **被忽略**

```
before Pen pids: 33576 → open -n rc=0 → 8s 後、18s 後 Pen pids: 33576（仍然只有一個）
renderer 裡沒有 probe-third（計數 0）；active 仍是 probe-proposal
```

推測原因是 Electron 的單一實例鎖：第二個實例啟動後立刻退出，而且沒有把檔案轉給第一個實例。這是 **PLAUSIBLE**，`log show` 沒抓到相關紀錄。

### A-4 pen CLI 的多文件選項：`pen interactive --app desktop --in probe-third.pen` → **被忽略**

`pen interactive --help` 列出的連線模式只有 `--app <name> [--in <file.pen>]`，沒有多文件或切檔的旗標。實跑 `get_app_state()` 的回覆：`Currently active canvas editor: …/probe-proposal.pen`（不是 probe-third），renderer 也沒有多出 probe-third。LS-91 記載「`--in` 會讓那一次呼叫回報該檔」，那是針對已開過的檔；對沒開過的檔，連 session-local 的覆寫都沒有發生。

### A-4b `open -a Pen probe-main.pen`（該檔已經在背景視窗開著）→ **不會奪回 active**

連續 7 次、每次間隔 2s 輪詢，結果都是 `probe-proposal.pen`。這重現了 pen-open.sh 檔頭記載的「已知坑」。補充：對沒開過的新檔，`open -a` 會立刻變成 active（C-6 的 `probe-consumer.pen` 就是這樣）。

### A-5 鎖屏前後 bounds → **PLAUSIBLE（量不到）**

- `pen-bounds-probe.sh --pen <probe-proposal|probe-main>` 兩次都是 rc=3：`原因：ioreg IOConsoleLocked＝true`。這是第 1 道檢查直接攔下，所以第 2 道 bounds 比對根本沒跑。
- 補充手動量測（鎖屏中）：proposal `rsm56` 的 x/y＝bounds（0,300）；main 頂層前 8 個節點的 x/y 也全部等於 bounds。只是頂層節點本來就有明確的 x/y，對 LS-471 那種「新節點 y+50」的偏移不敏感，所以**無法區分多開和鎖屏各自的影響**。
- 第二儀器 `pen-status.sh --pen`：probe-main 回 rc=1（`≠--pen 期望 ✗`，因為不是 active），probe-proposal 回 rc=0。這說明現行的對帳儀器都只看 active 一份。

### (A) 結論：**可並存（同一行程、多視窗），但切換只能序列**

- 同一個 Pen 行程可以同時載入多份 .pen。用 MCP `execute` 帶 `filePath` 定址，讀、寫、匯出都會命中各自的文件，未存狀態與 autosave backup 也互不汙染（實測）。
- 不支援的部分有三項：第二個行程（`open -n` 被忽略）、CLI 切檔、用 `open -a` 奪回背景文件的 active。`get_app_state` 只回 active 一份，沒有文件清單。
- 以上全部是在鎖屏中量到的。解鎖狀態下 `open -a` 的焦點行為是否相同，屬於 **PLAUSIBLE**。

## (B) headless `pen interactive` 和桌面並存（#648 Q2）

`pen --help` 原文（節錄，完整的 help 在 handoff 指令紀錄裡）：

```
pen interactive           Start interactive shell (see: pen interactive --help). Agents should use this mode to design with pen.dev.
  pen --in <input.pen> --out <output.pen> --prompt "Add a button" --agent gemini
  --preview-output <path> Path to save the preview PNG (default: ~/.pencil/latest-preview.png)
```

`pen interactive --help`：

```
pen interactive --app <name> [--in <file.pen>]     Connect to a running pen.dev app
pen interactive --out <file.pen> [--in <file.pen>]  Run in headless mode
```

實跑（桌面 Pen 這時開著 probe-main／probe-proposal，active＝probe-proposal）：

```
pen interactive --in $D/probe-headless-in.pen --out $D/probe-headless-out.pen --preview-output $D/headless-preview.png  < get_app_state / execute(Update ev2Pc + Export) / save / exit
[ERROR] Document is not valid:
- /version - expected "2.17", got "2.18"
[ERROR] Unsupported file format: 2.18
- Currently active canvas editor: `…/probe-headless-in.pen`
- Top-level nodes: The document is empty (no top-level nodes)
Error: Node 'ev2Pc' not found!
Saved …/probe-headless-out.pen          → 1,028 bytes：{"version":"2.17","children":[],"variables":{…}}
```

主稿副本也一樣：`pen interactive --in probe-main.pen --out …`（只送 `exit()`，不存檔）→ `expected "2.17", got "2.21"`／`Unsupported file format: 2.21`。

對照票文的四項：
- (a) active 是否被搶：沒有。headless 跑完後桌面 `pen-open.sh --status` 仍是 probe-proposal。
- (b) 未存狀態汙染：headless 的 in 檔和原本逐位元相同（`cmp` 通過），沒有汙染桌面。
- (c) 鎖屏 bounds：無從量起，因為 headless 載入的是空文件。
- (d) 匯出：沒產出，Export 所在的 block 因為找不到節點整段 rollback。

**資料遺失陷阱**：版本不符時，CLI 只印 ERROR，然後照樣用「空 children＋保留 variables」繼續跑，`save()` 也照寫。如果 `--out` 和 `--in` 是同一個路徑，整份稿會被清空（PLAUSIBLE：未實跑同路徑，由「save() 照寫 1,028 bytes 空稿」推論）。

### (B) 結論：**不支援（Mac 上 pen CLI 0.3.4 讀不了本專案的 .pen 2.18／2.21）**

升級到 CLI 0.3.11 之後能不能讀、能不能並存，屬於 **PLAUSIBLE（未驗）**；依票文不安裝套件，這要另票做。#648 提到的「Windows headless 成功」所用的 CLI 版本與檔案版本，需要拿來對照。

## (C) 拆檔的 gate 相容性（唯讀評估）

分類共四種：已支援多檔／只需加路徑參數／假設 base 有檔（新檔會紅）／需重設計。

| 腳本 | 現況分類 | 引據檔:行 |
|---|---|---|
| `scripts/ops/pen-land.sh` | 只需加路徑參數（已加 `--pen`，LS-480） | pen-land.sh:14,16 |
| `scripts/ops/pen-open.sh` | 只需加路徑參數（已加 `--pen`）。但清場候選只認主稿和 `docs/design-proposals/**`，其他路徑的 .pen 會不經檢查直接被殺 | pen-open.sh:22–32,85 |
| `scripts/ops/pen-read.sh` | 只需加路徑參數（已加 `--pen`） | pen-read.sh:14 |
| `scripts/ops/pen-status.sh` | 只需加路徑參數（已加 `--pen`）。只比對 active 一份，多文件並存時看不到背景文件（A-5 實測 rc=1） | pen-status.sh:30–32,86–88 |
| `scripts/ops/lib/pen-path.sh` | 已支援多檔（共用的解析；省略時＝主稿） | pen-path.sh:12,25 |
| `scripts/design/overflow-scan.js` | 已支援多檔（路徑不寫死；送進 `execute` 時由 filePath 或 active 決定目標，A-1 證實 filePath 能定址已載入的文件） | overflow-scan.js:10–13 |
| `scripts/design/pen-snapshot-dump.js` | 已支援多檔（同上，dump「目前定址的文件」全稿） | pen-snapshot-dump.js:9–11 |
| `scripts/design/pen-bounds-probe.sh` | 只需加路徑參數（已加 `--pen`）。但它要求「active＝該 .pen」才跑，否則 exit 2，所以多文件並存時一次只能探 active 那份 | pen-bounds-probe.sh:12,17 |
| `scripts/gates/design_tree_hash.py` | 已支援多檔（純函式，吃任何一份 JSON；不認 `imports`，見 C-6） | design_tree_hash.py:2–3 |
| `scripts/gates/design-landing-check.sh` | 已支援多檔（`<path.pen>` 參數） | design-landing-check.sh:7 |
| `scripts/gates/design-evidence-check.sh` | 需重設計：base 沒有檔時可以容忍（`base_roots={}`），但收據命名 `design/evidence/<票號>-r<n>-overflow.json` 沒有 .pen 這個維度。同一個 PR 動兩份 .pen 時，每一份 .pen 都會拿該票全部收據來驗 head_sha 和 total_nodes，不可能兩份同時通過（**由程式碼推得，未實跑 → PLAUSIBLE**） | design-evidence-check.sh:193,240–255,454–455 |
| `scripts/gates/design-notes-check.sh`＋`design_notes_check.py` | 假設 base 有檔（新檔會紅）：`load_snapshot` 對 base 做 `git show` 失敗就 `die` | design_notes_check.py:143–145；design-notes-check.sh:113 |
| `scripts/gates/design-identity-header-check.sh`＋`.py` | 假設 base 有檔（新檔會紅）：借用 `dnc.load_snapshot(base, pen)` | design_identity_header_check.py:139；design-identity-header-check.sh:64 |
| `scripts/gates/design-ref-check.sh` | 只需加路徑參數：CI 寫死 `design/littlesprout.pen`；只讀 head，沒有讀 base | ci.yml:640；design_ref_check.py:31–33 |
| `scripts/ops/patrol.sh` 的 Pencil 段 | 只需加路徑參數（只看 active 一條路徑；主 checkout 寫回偵測寫死主稿） | patrol.sh:358,1044–1046 |
| CI `rules` job 的 .pen 段（落地／收據／Notes／Identity） | job 層已支援多檔（對 `git diff --diff-filter=ACM -- '*.pen'` 的每一份逐檔呼叫）；能不能過，要看上面各腳本 | ci.yml:648–653,672–684,692–700,708–716 |

**現成實例 #626**（`feature/LS-455-soft-social-proposal`，run 38023669238）：`rules` 紅了四條：evidence-path、收據缺件，以及 `.pen Notes 節點 id gate（LS-168）` 和 `.pen Identity Header 年齡 NBSP gate（LS-309）`——後兩條訊息都是 `✗ design_notes_check：git show 9f68ffa:docs/design-proposals/soft-social-20261009/littlesprout-soft-social.pen 失敗（fatal: path … exists on disk, but not in '9f68ffa6…`。這和上表「假設 base 有檔」兩列完全對上。

### C-6 元件和變數能不能跨檔引用 → **格式層有跨檔 import，而且桌面 Pen 實測可以解析**

- 兩份實稿（`python3 -I` 唯讀解析，指令在 handoff）：
  - probe-main：頂層鍵是 `children/fileToken/themes/variables/version`。3,222 個 `ref` 節點只指向 30 個目標，全部在同一檔內（缺 0），也沒有任何 `ref` 值含 `/`、`.pen` 或 `:`。variables 有 74 個，形狀一律是 `{type,value}`。
  - probe-proposal：0 個 `ref`，自帶 2 個 reusable（`q8jPVU`、`NuMx0`）。也就是說提案檔是複製一套，不是引用主稿的 `cmp/*`。
  - 兩份都沒有 `imports` 鍵。`library`＝icon 庫名（`lucide`），`link`＝unsplash 署名網址，都不是跨檔引用。
- 但 Pen 自己的 schema（`mcp__pencil__read_skill pen-schema.md`）寫的是 `Document { version: "2.21"; … imports?: { [key: string]: string /** Value: relative URI of imported .pen file. Key: short alias. */ }; variables?: { [key: string /** RegEx: [^:]+ */] … }`。
- 自建的 scratch 對照組：`probe-lib.pen` 裡有一個 reusable `LibBtn` 和變數 `accent`；`probe-consumer.pen` 設 `imports:{lib:"./probe-lib.pen"}`、`ref:"lib:LibBtn"`、`fill:"$lib:accent"`。用 `open -a` 只開 consumer 之後的 `execute` 結果：

```
1 InstA frame  "#FF0000"  120 40
2 InstA/lib:LibLbl text  "#FFFFFF" from-lib 53 17
1 VarRect rectangle  "#FF0000"  50 20
vars {"variables":{"lib:accent":{"type":"color","value":"#FF0000"}}}
```

  也就是說，跨檔的元件 instance 和變數都解析成功，而且 lib 不需要另外開著。lib 在磁碟上改了之後 consumer 會不會刷新，**未驗（PLAUSIBLE 有快取問題，同 LS-118 renderer 快照）**。
- 對 gate 的影響：`scripts/` 底下沒有任何腳本認得 `imports`（`grep -n imports scripts/gates/*.py scripts/design/*.js scripts/ops/*.sh` 零命中）。拆檔改用 import 後，下列幾個都會在 consumer 端看不到 lib 的節點和變數：磁碟 JSON 系的 gate（tree_hash、landing 節點數、Notes 死 id 候選集、Identity NBSP 只掃 `cmp/Card *`）、`overflow-scan.js --from-snapshot`，以及 design-ref-check 對元件 id 的查找。這些腳本要改成「需重設計」。

### (C) 結論：**只能序列（拆檔在格式上可行，但現行 gate 只撐得住「一個 PR 動一份 .pen、而且 base 已有該檔」）**

## 建議（只是建議，規則改動另外開票）

1. **design lane WIP＝1：維持**。理由有三：
   - 桌面 Pen 雖然能同行程多文件，但對帳儀器（`get_app_state`、`pen-status.sh`、`pen-bounds-probe.sh`、`pen-open.sh` 輪詢）全部只認 active 一份，`open -a` 又奪不回背景文件，兩個 ui-designer 會互相改掉對方的 active（PLAUSIBLE：未實跑雙 agent 情境，由單 agent 切換實測推論）。
   - `--kill` 清場會一次殺掉全部文件。
   - headless 在 Mac 上根本讀不了本專案的檔。

   如果要放寬，前置條件有兩個：(i) agent 一律帶 filePath 定址、不依賴 active（A-1、A-2 證明讀、寫、匯出都可行），並把 pen-status／bounds-probe 改成驗「該檔已載入」而不是「該檔是 active」；(ii) 升級 CLI 後重跑 (B)。
2. **拆檔**：先開 harness 票修兩件事，修完拆檔或新增提案檔的 PR 才會綠：
   - 「假設 base 有檔」兩支（`design_notes_check.load_snapshot` 對 base 缺檔改當空文件）；
   - 收據加上 .pen 維度（例如 `<票號>-<pen-slug>-r<n>-overflow.json`，或在收據裡加 `pen` 欄位）。

   若要用 `imports` 共用 `cmp/*`／variables，需要另一張「需重設計」級的票，讓 tree_hash、Notes、Identity、overflow-scan 學會解析 import。在那之前，拆檔只建議「各檔自足（複製元件）」，也就是 proposal 現在的做法。

## 我跑過、看過的東西

- 命令：`pen --help`、`pen interactive --help`、`pen version`；`open -a Pen` ×4、`open -n -a Pen` ×1；`pen interactive --app desktop --in …`；`pen interactive --in … --out … --preview-output …` ×2；`bash scripts/ops/pen-open.sh --kill`／`--status`；`bash scripts/ops/pen-status.sh --pen` ×2；`bash scripts/design/pen-bounds-probe.sh --pen` ×2；`ioreg -n Root -d1 -a`；`ps -Ao pid,ppid,command | grep 'Pen Helper (Renderer)'`；`gh pr checks 626`、`gh run view 38023669238 --log-failed`；`python3 -I` 唯讀解析兩份副本。
- MCP 呼叫：`get_app_state` ×3；`execute` ×10（含 2 次 cross-lookup 失敗後改寫）；`read_skill execute.md`、`read_skill pen-schema.md`。
- 檔案：上表引據列出的每一支腳本（檔頭＋grep 命中行）、`.github/workflows/ci.yml:640–716`、`docs/COLLABORATION.md:68,296`。
