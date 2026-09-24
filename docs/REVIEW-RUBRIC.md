# Merge-review 四維度 rubric（LS-352）

> **本檔是 ios-dev 自檢與 merge-reviewer 審查的單一來源，改條目請同步自測**（`bash scripts/gates/handoff-evidence-check.test.sh`）。
> 兩份 agent 定義（`.claude/agents/ios-dev.md`、`.claude/agents/merge-reviewer.md`）只引用本檔、不各自抄一份。

機器解析契約（`scripts/gates/handoff_evidence_check.py` 讀本檔、不寫死條目數）：

- 每個維度一個 `## R<n> <名稱>` 標題；每個檢查項一行 `- R<n>.<m> <內容>`（`R<n>.<m>` 編號全檔唯一）。
- 新增／刪除／改號一條＝ios-dev handoff「## 自檢」段必須跟著逐條對上（條目數或編號不符 → gate 紅，訊息點名缺哪一條）。
- 本檔其他行（引言、說明段）不算條目。

ios-dev handoff「## 自檢（依 docs/REVIEW-RUBRIC.md）」段每條一行：`- R<n>.<m>｜通過／不適用／已知未處理｜理由＋證據`——證據是測試名、`file:line`、路徑或指令（同「已驗證」段的證據規則）。merge-reviewer 對「通過」的項只抽驗、不重寫（見 merge-reviewer.md）。

## R1 Race condition

- R1.1 Swift Concurrency 正確性：actor 隔離、`@MainActor`、`Sendable`、Task 取消與生命週期。
- R1.2 背景上傳佇列與重試的資料競態。
- R1.3 快取一致性。
- R1.4 Supabase 寫入與本地狀態的同步。
- R1.5 對分頁結果做過濾的變更：確認測試涵蓋整頁被濾空、下一頁游標取自原始指標而非過濾後結果（LS-329）。

## R2 運算效能

- R2.1 RLS policy 是否退化成 per-row 子查詢（PLAN §5 明文禁止）。
- R2.2 N+1 查詢。
- R2.3 OFFSET 分頁（應 keyset）。
- R2.4 主執行緒上的圖片解碼／壓縮。
- R2.5 列表誤載原圖（應載縮圖）。

## R3 平行優化

- R3.1 可平行的工作被不必要地序列化（批次上傳、縮圖產生應併發且有並發上限）。
- R3.2 迴圈內逐一 await 的串行瓶頸。

## R4 Scope

判定規則：diff 超出 ticket 範圍——無關重構、順手改動、未被要求的功能一律列為 finding（手術式修改原則），不得歸 informational 記池後照樣 APPROVE。

- R4.1 diff 是否超出 ticket 範圍：無關重構、順手改動（手術式修改原則）。
- R4.2 未被要求的功能。
