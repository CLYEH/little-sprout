# scripts/hooks — Claude Code hook 撰寫慣例（LS-256）

本目錄放 `.claude/settings.json` 掛的 PreToolUse hook（bash 殼＋同名 `*_engine.py`／`*_guard.py` 引擎）。規約層與每條 hook 的來龍去脈在 `docs/COLLABORATION.md` §7 對照表；本檔只講**寫 hook 前必須先決定、自測必須釘住**的一件事：deny 極性。來源：LS-96 池項 `e4155ed8`(2)（fork-guard 落地時「腳本 exit 2 才 deny、wiring 不接 `|| exit 2`＝fail-open」只在 fork-guard.sh 檔頭有寫，沒有一處判準寫給下一個要寫 hook 的人）。

## deny 極性：腳本自己 `exit 2` 才 deny；`|| exit 2` 決定「腳本壞掉」算不算 deny

Claude Code PreToolUse hook 的 exit code 語意：**exit 0＝允許**（stdout 可帶 `permissionDecision` JSON）、**exit 2＝deny**（stderr 回給 model）、**其他非 0＝non-blocking error**（stderr 給使用者看、工具照跑）。因此：

- **deny 一律由腳本自己 `exit 2`**——stdout 印 `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`＋stderr 同一句理由。判定在引擎 python，bash 殼只做「讀 stdin → 呼叫引擎 → 轉譯」。
- **settings.json 的 command 接不接 `|| exit 2`，決定「腳本壞掉」（bash 殼找不到、python3 缺席、引擎 traceback、意外 exit 1）時的極性**：
  - 接 `|| exit 2` → **fail-closed**：任何非 0 都變 deny，腳本壞掉＝擋。適用「漏擋會出事、後果不可逆」的 gate（force push 到保護分支、寫主 checkout、背景化長命令、orchestrator 讀大檔）。
  - 不接 → **fail-open**：只有腳本自己明確 `exit 2` 才 deny，腳本壞掉＝工具照跑。適用「擋錯會讓整條產線停擺、漏擋的後果可事後補救」的 gate（fork-guard 選這邊：若接了 `|| exit 2`，hook 一壞 orchestrator 自己的所有 Agent 呼叫全被擋死，派工完全停擺；漏擋一次 fork 則由 review 與規約層事後補救）。
- 腳本內部的 fail-closed（`RESPONDED` 旗標＋`trap on_exit EXIT`：stdin 空／python3 缺席／引擎異常 → 自己 deny）與 wiring 的 `|| exit 2` 是**兩層、必須同極性**：腳本 fail-closed 但 wiring 不接，「bash 殼本身找不到」那一層仍是 fail-open；腳本 fail-open 但 wiring 接了，腳本刻意的 exit 0 之外任何意外仍被 wiring 轉成 deny，票文明示的 fail-open 就被推翻。
- **自測必須釘住 wiring 極性**（前饋必有反饋）：`fork-guard.test.sh` ⑤②（command **不得**接 `|| exit 2`）、`large-file-read-guard.test.sh` ⑭②（command **必須**接 `|| exit 2`）——新 hook 照抄其中一種；改極性要同時改自測，否則 CI 紅。

## 現有 hook 逐條（以 `.claude/settings.json` 為準；改接線時同步本表）

| 事件／matcher | 腳本 | wiring 接 `\|\| exit 2` | 極性 | 自測釘住處 |
|---|---|---|---|---|
| SessionStart | `scripts/ops/session-start.sh` | 否 | 不是 deny hook：fail-soft——任何內部錯誤仍輸出合法 JSON、exit 0（巡檢壞了不能擋 session，錯誤寫進 context） | ci.yml「Ops 腳本自測」step |
| PreToolUse `Bash\|Read\|Grep` | `pretool.sh`（＋`pretool_engine.py`，H1–H3） | 是 | fail-closed（腳本內亦 fail-closed） | `pretool.test.sh` |
| PreToolUse `Bash\|Write\|Edit\|MultiEdit\|NotebookEdit` | `main-checkout-guard.sh`（＋`main_checkout_guard.py`，W0–W5） | 是 | fail-closed（腳本內亦 fail-closed） | `main-checkout-guard.test.sh` |
| PreToolUse `Bash` | `background-bash-guard.sh`（＋`background_bash_guard.py`，H-BG） | 是 | fail-closed（腳本內亦 fail-closed；「找不到 agent 身分 → allow」是規則層的判定，不是極性） | `background-bash-guard.test.sh` |
| PreToolUse `Bash\|Read` | `large-file-read-guard.sh`（＋`large_file_read_guard.py`，H-LF） | 是 | fail-closed（腳本內亦 fail-closed） | `large-file-read-guard.test.sh` ⑭② |
| PreToolUse `Agent` | `fork-guard.sh`（＋`fork_guard.py`，LS-254） | **否** | **fail-open**（腳本內亦 fail-open：stdin 空／python3 缺席／JSON 壞 → exit 0＋stderr 註明） | `fork-guard.test.sh` ⑤② |
| PreToolUse `mcp__linear__save_issue` | `scripts/gates/linear-issue-check.sh`（規則 A–E） | 是 | fail-closed | `scripts/gates/linear-issue-check.test.sh` |

## 新增 hook 檢查表

1. 決定極性，寫在檔頭第一句（`PreToolUse fail-closed gate` ／ `fail-open gate`）＋理由。
2. bash 殼只做「讀 stdin → 呼叫引擎 → 轉譯」；規則表、盲區、身分信號來源寫在引擎 python 檔頭。
3. `.claude/settings.json` 只加不刪、獨立一條 matcher；`|| exit 2` 與檔頭極性一致。
4. 自測 `<name>.test.sh`：規則正負樣本＋mutation 負控＋**wiring 極性斷言**＋既有條目仍在（只加不刪）；`jq` 缺席時印 `SKIP <n> 組（無 jq）` 並計數，不得靜默少跑（LS-256）；掛進 `.github/workflows/ci.yml` rules job 的「Gate 腳本自測」step。
5. `docs/COLLABORATION.md` §7 對照表加一列；本表加一列。
