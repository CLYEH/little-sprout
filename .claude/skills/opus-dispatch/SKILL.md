---
name: opus-dispatch
description: Orchestrator 派任何 Opus 5.5 agent（ios-dev／qa／merge-reviewer／ui-designer／visual-reviewer，agent 定義皆 model opus）前必載——把 claude.dev「Getting the most out of Opus 5.5」八條建議翻成本專案派工單與 SendMessage 續派的固定寫法：明寫 finish line 與 Done 定義、刪掉 think-carefully 類句、stop/go 規則、未證實項標 PLAUSIBLE、設計退修用排除清單、大稽核拆 subagent 並核對證據、checklist 落檔、不索取內部推理、多輪續派鎖住已核銷項、safety flag 降級偵測。寫 Agent prompt 或 SendMessage 續派時對照本檔逐條自檢。
---

# Opus 5.5 派工寫法（本專案版）

來源：https://claude.dev/blog/getting-the-most-out-of-opus-5-5/ （2026-09-24 讀取）。適用對象：所有 `model: opus` 的 subagent（COLLABORATION §1 表：ios-dev／qa／merge-reviewer／ui-designer／visual-reviewer，effort 一律 frontmatter 明寫 high）。dead-code-sweeper 是 sonnet，本檔的「finish line」「未證實標記」兩條仍適用。

## Opus 5.5 與前代的差別（影響寫法的四點）

1. **長任務不會半路停**：多段工作一封派完即可，不必切成多次派工。
2. **每次回覆前都會自己思考，且自己決定想多久**：派工單裡任何「請仔細思考／逐步推理」都是噪音。
3. **回報比前代直白**：handoff 格式照規約要求即可，不必再加「請誠實回報」。
4. **讀圖、讀截圖、抓長文矛盾更準**：對稿、對截圖直接給路徑，不要把畫面轉述成文字。

## 八條寫法

### 1. 明寫 finish line

一封派工單裡把「做什麼」「Done 是什麼」「什麼情況才停下來問」三件寫齊。本專案的 Done 固定＝票文驗收條＋handoff 六段＋PR 開好（實作票）或 verdict comment＋status 貼上（審查票）。

- 寫法：`Done＝票文驗收三條全勾、handoff 六段齊、PR #… 開好且 pr-body-check rc=0。只有在測試紅而你解釋不了、或要動 supabase/ 以外的破壞性操作時才停下來問。`
- 反例：`先看一下這張票，做到哪回報到哪。`（沒有終點，agent 會提早交手）

### 2. 刪掉 think-carefully 類句

「仔細思考」「一步一步」「深呼吸」「think step by step」「think hard」一律不寫。要引導判斷，寫**判斷的材料**（要對哪些板、哪些測試、哪些邊界）而不是叫它想。

- 寫法：`race 維度請看 tracker 進行中集合與 RPC 回呼交錯：連點、RPC 失敗、換批、view 重建、登出。`
- 反例：`請仔細思考所有可能的 race condition。`

盤點（2026-09-24）：`.claude/agents/*.md`、`skills/*/SKILL.md`、CLAUDE.md、COLLABORATION、REVIEW-RUBRIC 以 `think carefully|step by step|仔細思考|一步一步|逐步思考|深呼吸|think hard|ultrathink` grep 皆零命中；新增文字維持零命中。

### 3. stop/go 規則寫在派工單，不是事後補

Opus 5.5 會一直往前做，所以「什麼時候該停」要事先講清楚。本專案固定三條：

- **繼續**：不需要 orchestrator 決定的步驟直接做，狀態寫在 handoff，不要中途回報。
- **停下問**：測試紅且無法解釋；票文與稿面／範圍補記矛盾；要做破壞性操作（刪資料、force-push、動 repo 以外）。
- **不准做**：`--no-verify`、手動 push `test`／`main`、跨 worktree 編輯、切 Pen active 檔（非設計票）。

### 4. 未證實的發現標 PLAUSIBLE，並說看過哪裡

審查與 QA 派工單固定帶：`凡無法自己重現或量到的結論一律標 PLAUSIBLE，並寫出你看過哪些檔案、跑過哪些命令。` reviewer 的 verdict 分級（blocker／major／minor／informational）與 PLAUSIBLE 標記同時存在。

- 反例：讓 reviewer 用「應該沒問題」帶過。

### 5. 設計退修用排除清單，不用形容詞

給 ui-designer／visual-reviewer 的退修不要寫「避免模板感」「更有靈魂」，要列**具體要排除的樣式**與**具體要保留的樣式**。本專案的排除清單來源＝`little-sprout-brand` skill 的 slop 禁例＋VR 十條；派工單直接引用條目編號並補本輪特有的排除項。

- 寫法：`不要：進度大卡、警告三角圖示、免責句擋在內容前、Baby Chip 放紙面。要保留：紙片＝吃過、灰空位＝未吃、日期章壓角托。`
- 反例：`請讓入口看起來不那麼 SaaS。`

### 6. 大範圍稽核拆 subagent，回報要核對證據

一次要看很多檔／很多板／很多票時，一件一個 subagent（Agent 工具可並行），回報進來先核對它附的證據（檔案:行、comment id、截圖路徑）再採信，最後彙整成一張表。ios-dev 派 Explore 子 agent 做研究同理。

### 7. checklist 落檔

長任務的進度要寫在檔案，不是留在對話：本專案＝scratchpad `LS-<n>-handoff.md`（六段）＋ Linear comment。派工單固定要求「每完成一項就更新 handoff 對應段」，設計票另加「每項落地即 commit＋push」。

### 8. 不索取內部推理

不要寫「把你的思考過程列出來」「解釋你每一步怎麼想」——這類要求會被拒。要理由就要**結論式說明**：

- 寫法：`用三句話說明為什麼選 (b) 而不是 (a)。`
- 反例：`請把推理過程完整寫出來。`

## 多輪續派（SendMessage）的兩條

- **鎖住已核銷項**：R2 以後的續派開頭列「R1 已核銷：…（不要回頭改）」，只列本輪要處理的 finding。Opus 5.5 會自動避免重做，但明寫可省它重驗的成本。
- **一次把裁決講完**：orchestrator 對每條 finding 的裁決（採用／不採用＋理由）在同一則訊息給齊，不要分兩次。

## Safety flag 降級偵測

Opus 5.5 帶 Fable 級的 bio／cyber 安全旗標；被 flag 的 session 會自動切到較舊模型繼續。subagent 的模型看不到，所以：

- 收到 handoff 後若品質異常（回報變短、少了規約要求的段落、判斷明顯退步），先跑 `bash scripts/ops/agent-model-check.sh <agent>` 查 transcript 實際 model／effort。
- 確認被降級 → 該輪結果視為 sonnet 級，重要判斷（VR verdict、merge-review blocker 判定）重派一輪。
- 誤 flag 用 `/feedback` 回報；orchestrator 自己的 session 被切走用 `/model` 切回。

## 派工單自檢（寫完再看一遍）

- [ ] 有 Done 定義、有「何時停下問」
- [ ] 沒有「仔細思考／step by step」類句
- [ ] 判斷材料（板 id、檔案:行、邊界情境）給齊，不是叫它想
- [ ] 審查／QA 帶 PLAUSIBLE 規則
- [ ] 設計退修是排除清單＋保留清單
- [ ] 要 handoff 落檔＋Linear comment
- [ ] 沒有索取內部推理
- [ ] 續派時列出已核銷項與本輪裁決
