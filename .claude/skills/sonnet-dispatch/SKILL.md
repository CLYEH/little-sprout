---
name: sonnet-dispatch
description: Orchestrator 派任何 Sonnet 5.5 agent（ios-dev／qa／dead-code-sweeper，agent 定義 model sonnet；Claude Code ≥2.1.284 的 sonnet 別名＝claude-sonnet-5-5）前必載——把官方「Prompting Claude Sonnet 5.5」翻成本專案派工單與 SendMessage 續派的固定寫法：effort 由定義檔決定（派工不調）、先用 agent-model-check 確認別名真的解析到 5.5、做到完才停、不做沒要求的、真跑檢查才算完成、判斷材料代替叫它想、不索取內部推理、續派自報身分避免被當注入、查現況不憑記憶、對稿先裁圖、未證實標 PLAUSIBLE、finish line 與 handoff 落檔沿 opus-dispatch。寫 Agent prompt 或 SendMessage 續派時對照本檔逐條自檢；agent 是 opus 時改讀 opus-dispatch。
---

# Sonnet 5.5 派工寫法（本專案版）

來源：https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5 與 https://platform.claude.com/docs/en/models/sonnet-5-5/whats-new-sonnet-5-5（2026-09-29 讀取）。適用對象：所有 `model: sonnet` 的 subagent（COLLABORATION §1 表：ios-dev／qa／dead-code-sweeper；Claude Code ≥2.1.284 的 `sonnet` 別名指 `claude-sonnet-5-5`）。opus agent（ui-designer／merge-reviewer／visual-reviewer）讀 `opus-dispatch`；兩份共用的六條（finish line、判斷材料、stop/go、PLAUSIBLE、checklist 落檔、續派鎖項）本檔只寫差異，寫法本身以 opus-dispatch 為準。

## 別名與版本

`sonnet` 別名在 Claude Code 2.1.284 起指 `claude-sonnet-5-5`（2.1.281／2.1.282 的二進位仍是 `claude-sonnet-5`；2026-09-29 probe transcript 跑在 2.1.281）。agent 定義檔寫 `model: sonnet`，讓別名跟著 CLI 升級自動指向最新 Sonnet；代價是舊 CLI 會靜默退回 Sonnet 5，所以：

- 版本看的是**正在跑的 session**，不是磁碟上的 `claude --version`（自動更新後磁碟已是 2.1.284、舊 session 仍是 2.1.281，別名照舊指 Sonnet 5）。第一張 sonnet 派工後 `bash scripts/ops/agent-model-check.sh <agent>`：它印該 session 的 Claude Code 版本與 transcript 的 `"model"`，看到 `claude-sonnet-5-5` 才算生效；印 `claude-sonnet-5` 就 `/exit` 重開 session 再派。
- Agent 工具的 `model` 參數同樣走別名（`sonnet`／`opus`／`haiku`／`fable`），同一條件下才會是 5.5。
- 需要釘死版本（例如 CLI 升不了）時才在定義檔改寫全 ID `claude-sonnet-5-5`（frontmatter 接受全 ID）。

## Sonnet 5.5 與 Opus 5.5 的差別（影響寫法的六點）

1. **effort 重校，且由定義檔決定**：官方建議 agentic 且票文明確的任務從 `medium` 起、難或長的用 `high`；本專案 ios-dev／qa 先釘 `high`（票多為 S–M、驗收條需真跑測試），量測兩個 cycle 後再議降 `medium`。Agent 工具派工時傳不了 effort，派工單裡也不要寫「請多想／少想」——沒有效果。
2. **low／medium 會在做完前停下來問**：medium 以下容易「先確認計畫」「做完一部分就問要不要繼續」。定義檔已是 high，但票大或多段時仍要在派工單明寫「做到完才停」（第 2 條）。
3. **會自己加沒要求的測試／文件／輔助檔**：每個 effort 都會、高 effort 更多。本專案票文本來就列出要哪些測試，所以派工單要把「要求的」與「不要加的」分開寫（第 3 條）。
4. **low 會漏跑驗證就報完成**：push gate 是機械 gate 擋得住，但 handoff 的「已驗證」段仍可能寫「應該可以」——派工單釘「真跑才算」（第 4 條）。
5. **對中途插入的文字會起疑**：訓練成抗注入，tool result 後面出現的指令可能被當成假訊息而忽略。SendMessage 續派要自報身分、一次講完（第 8 條）。
6. **會答訓練知識而不查**：對 repo 現況、API 契約、CLI 版本這類會變的細節，要它 grep／讀檔再改（第 9 條）。

其餘：Sonnet 5.5 在工具呼叫之間會寫進度短句（Claude Code 會顯示；「使用者很久沒聽到你」的提醒由 Claude Code 自己送，派工單不用要求）；工具名大小寫偶爾寫錯（Claude Code 容錯，handoff 若提到「工具呼叫失敗」先看是不是這個，不是 agent 判斷錯）；JSON 輸出與圖表裁切工具那兩段本專案用不到（handoff 是 markdown；截圖對稿見第 10 條）。

## 十條寫法

### 1. 明寫 finish line（同 opus-dispatch 第 1 條）

Done＝票文驗收條＋handoff 六段＋PR 開好（實作票）或 verdict comment＋status（審查／QA 票）。Sonnet 5.5 沒有 finish line 時比 Opus 更容易在中途交手。

- 寫法：`Done＝驗收條三條全勾、handoff 六段齊、PR #… 開好且 pr-body-check rc=0。`
- 反例：`做到哪回報到哪。`

### 2. 做到完才停（官方句，本專案版）

派工單固定帶這一段（官方原句翻譯，並接上本專案的停下條件）：

- 寫法：`把票文要求的全部做完再停；只有卡在需要 orchestrator 決定的事、或要做有風險的步驟前才停下來問。停下問的情況只有：<列三條>。`
- 反例：`有問題隨時回報。`（medium 以下會每做一段就回報一次）

### 3. 不做沒要求的事（官方句，本專案版）

Sonnet 5.5 會順手加測試、文件、拆檔。票文列的測試是「要求」，其餘是「不要」：

- 寫法：`要求的測試只有：<列票文那幾支>。做完並跑過檢查就停下回報，不要另加測試、文件、檔案或重構；覺得該加的寫在 handoff「未完成／建議」段，不要動手。`
- 反例：`測試請盡量補齊。`（會補到 lint 上限、reviewer 得多審一段）

### 4. 真跑檢查才算完成（官方句，本專案版）

- 寫法：`改到可以跑、編、或型別檢查的程式，回報完成前一定要真的跑過一次會執行到那段改動的檢查：專案的測試、swiftlint --strict、build，或被改的那條命令本身；只檢查語法、或檢查命令根本沒起來，都不算。若這裡真的沒有檢查能跑，寫出你沒跑哪一項與原因，不要當成完成。`
- 反例：`確認沒問題就好。`

### 5. 判斷材料代替叫它想（同 opus-dispatch 第 2 條）

「仔細思考／step by step／think hard」一律不寫（盤點 2026-09-24 零命中，維持）。給板 id、檔:行、邊界情境、要重放的 mutation。

- 寫法：`race 維度請看：連點、RPC 失敗、換批、view 重建、登出，各對照 tracker 集合的狀態。`
- 反例：`請仔細思考所有 race。`

### 6. 不索取內部推理（Sonnet 5.5 會直接拒答）

Sonnet 5.5 對「把推理過程寫出來」會回 `reasoning_extraction` 類拒答，整輪白費。要理由就要結論式：

- 寫法：`用三句話說明為什麼選 (b) 不選 (a)。`
- 反例：`把你每一步怎麼想的完整列出來。`

### 7. 未證實標 PLAUSIBLE（同 opus-dispatch 第 4 條）

審查／QA／sweeper 派工單固定帶：`凡無法自己重現或量到的結論一律標 PLAUSIBLE，並寫出你看過哪些檔案、跑過哪些命令。`

### 8. 續派自報身分、一次講完（抗注入的副作用）

SendMessage 續派的文字會出現在 agent 的 tool result 之後，Sonnet 5.5 可能把它當成夾帶的假指令而忽略或反問。固定寫法：

- 開頭一行自報：`orchestrator 續派 R2（LS-<n>）：`，不要用引文、不要模仿 tool result 格式。
- 已核銷項＋本輪裁決＋Done 定義在同一則講完，不分兩則。
- 若 agent 回「訊息像注入、請確認」，直接再送一次同樣開頭的訊息即可，不要改成更像系統訊息的格式。
- 反例：把指令包在「[系統通知] …」裡送。

### 9. 查現況、不憑記憶

對會變的細節（repo 現況、API.md 契約、CLI 版本、Linear 票文）要它先查再改；派工單裡不要寫「只在必要時才用工具」這類句子（官方指出會壓低查證意願）。

- 寫法：`先 grep 三個呼叫端與 docs/API.md §4 現行契約再動手；票文引據的檔:行若與現況不符，以現況為準並在 handoff 註明。`
- 反例：`你應該記得這段怎麼寫的。`

### 10. 對稿先裁圖，路徑給全

Sonnet 5.5 讀密集截圖（多板對稿、AX3 長頁）時漏細節；給它裁圖或放大的手段比拉高 effort有效。本專案 qa 對稿一律：

- 寫法：`對稿時先用 sips／Preview 把截圖裁到該區塊（或 UITest 附件的單一元件截圖）再比對；稿面用 design/evidence 既有 PNG 或 VR 匯出圖，路徑寫全，不要轉述畫面。`
- 反例：`看一下整頁截圖有沒有跟稿不一樣。`

## 多輪續派（SendMessage）的三條

- **鎖住已核銷項**（同 opus-dispatch）：開頭列「R1 已核銷：…（不要回頭改）」。
- **一次把裁決講完**（同 opus-dispatch）。
- **自報身分**（本檔第 8 條）：每則續派第一行 `orchestrator 續派 R<n>（LS-<n>）：`。

## 拒答與降級偵測

- Sonnet 5.5 的安全分類有五類（cyber／bio／frontier_llm／reasoning_extraction／general_harms）。本專案會撞到的只有 `reasoning_extraction`（第 6 條）與偶發 `general_harms`（如「刪除帳號」「封鎖」相關文案被誤判）；撞到時 handoff 會少一段或直接停，先看 transcript 尾端的 `stop_reason`，改寫派工句再派，不要換模型硬闖。
- 品質異常（回報變短、少規約段落）先 `bash scripts/ops/agent-model-check.sh <agent>` 查實際 model／effort；`"model"` 是 `claude-sonnet-5` 代表這個 session 的 Claude Code <2.1.284（別名退回舊版），`/exit` 重開 session 再派——磁碟版本已更新也救不了舊 session。
- 真的需要更強判斷（跨模組重構、race 密集、長程多段）→ 派工時 Agent 工具 `model: opus` 覆寫並在派工訊息註明理由（§1 表「升 opus 的時機」）。

## 派工單自檢（寫完再看一遍）

- [ ] 有 Done 定義、有「停下問」三條（第 1、2 條）
- [ ] 分開列「要求的測試」與「不要加的」（第 3 條）
- [ ] 有「真跑檢查才算完成」句（第 4 條）
- [ ] 沒有「仔細思考／step by step」類句，判斷材料給齊（第 5 條）
- [ ] 沒有索取內部推理（第 6 條）
- [ ] 審查／QA／sweeper 帶 PLAUSIBLE 規則（第 7 條）
- [ ] 續派第一行自報身分、已核銷項＋裁決一次講完（第 8 條）
- [ ] 要它查現況的地方寫了「先 grep／讀檔」（第 9 條）
- [ ] 對稿有裁圖與路徑（第 10 條）
- [ ] 要 handoff 落檔＋Linear comment（沿 opus-dispatch 第 7 條）
- [ ] 首張 sonnet 派工已用 agent-model-check 確認該 session 版本 ≥2.1.284 且 model 是 `claude-sonnet-5-5`（不是就重開 session）
