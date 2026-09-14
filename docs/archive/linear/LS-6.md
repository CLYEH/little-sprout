# LS-6 Phase 0-2：Supabase 專案＋schema migration＋RLS policies

| 欄位 | 值 |
|---|---|
| 狀態 | Done（completed） |
| 優先序 | High |
| 標籤 | — |
| Cycle | — |
| Project | Phase 0 — 開發地基 |
| Milestone | — |
| 估點 | — |
| 建立 | 2026-08-22T05:59:50.130Z |
| 開始 | 2026-08-22T06:21:54.138Z |
| 完成 | 2026-08-22T09:07:51.125Z |
| 建票者 | Chih-Lin Yeh |
| 指派 | Chih-Lin Yeh |
| URL | https://linear.app/little-sprout-app/issue/LS-6/phase-0-2supabase-專案schema-migrationrls-policies |
| 關係 | related←LS-217, related←LS-206, related←LS-198, related←LS-200, related←LS-155, related←LS-151, related←LS-149, related←LS-143, related←LS-107, related←LS-63, related←LS-56, related←LS-40, related←LS-34, related←LS-36, related←LS-33, related←LS-24, related←LS-23, related←LS-21, related←LS-20, related←LS-18, related←LS-16, related←LS-14, related←LS-11 |

## 描述

依 docs/PLAN.md Phase 0 第 2 步與 §5 資料模型。建立 Supabase 專案，寫全套 schema migration 與 RLS policies（含 `content_reports`、`blocked_users`、`families.storage_*` 等第一天就要有的表與欄位）。

## 驗收條件

- [ ] SQL 測試證明跨 family 查不到資料（RLS 隔離）
- [ ] 灌數萬列假資料後 `EXPLAIN` 證明 policy 沒有 per-row 子查詢（用 STABLE SECURITY DEFINER 函式或 JWT claim）
- [ ] 每個 family 恆有 ≥1 位 owner 的約束有測試
- [ ] migration 檔納入 `supabase/migrations`（DB migration gate 自此生效）

備註：純後端票，跳過 Design 狀態。

## 留言（6）

### 2026-08-22T07:12:51.290Z · Chih-Lin Yeh · `6bbc5d7c`

**Handoff（ios-dev/opus，orchestrator 轉錄摘要）**

已完成：3 個 migration（16 張表——§5 實列 16 非 ticket 寫的 14，以 §5 為準）：schema＋索引＋column grant、triggers（owner 不變量／feed_items／storage_used_bytes＋額度硬防線）、RLS（private.* STABLE SECURITY DEFINER 集合函式，無內嵌 per-row 子查詢）。測試六檔＋run.sh＋EXPLAIN 證據檔。

已驗證：run.sh 全綠×2（含全新 DB 重建）——(a) 三角色跨家庭 14 表全 0 列（附正向對照防「全擋光假通過」）、寫入方向 42501；(b) 最後一位 owner 刪／降級噴 LS001，交接成功；(c) 5 萬列 media EXPLAIN 無 correlated SubPlan（最嚴苛查詢 10.1ms），另做了偵測器自我驗證與 policy mutation test。PR #4 CI 三 job 綠。

BLOCKED（誠實標記）：`supabase start` 因本機 Docker 無法拉映像（proxy 卡死）未跑成——改用拋棄式 PG16 容器補 Supabase 最小前提完成驗證；未涵蓋 PG17／真實 auth schema／db reset 流程。**Docker 恢復後補跑** `supabase start && supabase db reset && bash supabase/tests/run.sh`（已列入 QA gate 檢查項）。重啟 Docker Desktop 會動到使用者在跑的 projectx 容器，agent 未擅動，待使用者決定。

風險（交 merge-reviewer 特別看）：storage_used_bytes 為刻意的序列化點（statement-level trigger 已壓成每語句一鎖）；UPDATE trigger 無欄位過濾（transition table 限制）。

Gate 缺口 → LS-11：CI 只驗 tests/ 有動，未真跑 run.sh。

產出：PR #4、branch feature/LS-6-supabase-schema-rls、supabase/{config.toml,migrations×3,tests×6+run.sh,evidence}。

### 2026-08-22T07:32:45.119Z · Chih-Lin Yeh · `3452f6f8`

**Merge review（PR #4）：REQUEST_CHANGES**（merge-reviewer/opus，全項實測）

Blocker：B1 owner 不變量可被兩個併發降級繞過→家庭 0 owner 永久磚化（修法已由 reviewer 實測：families 列鎖 FOR UPDATE 序列化）；B2 families INSERT 全欄位 grant→任何人建家庭可自帶 1TiB 額度。
Major：M1 INSERT families+RETURNING 必 42501（PostgREST return=representation 路徑，§9-C5 壞）；M2 media.byte_size 可 UPDATE 歸零繞額度；M3 device_tokens 換帳號無法重綁→跨家庭推播外洩；M4 default privileges 未收斂→未來新表對 anon 全開且 RLS 預設關。
Minor：m1 被檢舉 owner 可自我駁回檢舉；m2 owner 可繞過邀請直塞成員（延到 Phase 1-2 加入 RPC 時收斂）；m3 entry_date 時區口徑；m4 private.* 函式 PUBLIC EXECUTE；m5 檔名/數據不一致；m6 config PG17 vs 驗證 PG16、seed.sql 缺。
覆核自報風險：storage 序列化點**判斷正確**（無 TOCTOU、無死鎖，3200 列併發實測對齊）；平行化無效益不改；scope 乾淨。

修復輪已派工（opus）。共通要求：每個修復附對應方向的測試（INSERT 面、併發面），不能只靠註解宣稱。

### 2026-08-22T08:27:00.457Z · Chih-Lin Yeh · `141f5935`

**Merge gate 通過，已併入 development（PR #4）**

- 複驗 **APPROVE**：reviewer 獨立重跑自己的重現腳本，B1/B2/M1-M4/m1/m3-m6 全數確認修妥；對三個新 gate 自做 mutation test（無鎖版本→併發測試紅、漏 revoke 函式→60_ 紅、default privileges 開回→60_ 紅）。實作者對 reviewer 兩個處方的修正（schema 範圍 function default privileges 是 no-op、REVOKE FROM PUBLIC 帶不走 anon）經覆核**皆正確**，後者修掉了 reviewer 自己處方會留下的洞。
- 複驗新發現（minor）：FOR UPDATE 與 FK 的 FOR KEY SHARE 互斥形成新死鎖邊——已依 reviewer 實測處方改 `FOR NO KEY UPDATE`（2f1ca24，一詞修補，orchestrator 依小型修補條款執行），死鎖消失且序列化保持。
- 部署檢查項 → **LS-14**：真實 Supabase 的 `\ddp` 覆核（唯一「本地綠、正式環境可能 no-op」的修復）、雲端授權斷言、security advisors。
- 待 QA gate：test branch 重跑測試套件（Docker 不可用時走 PG16 stub 備援路徑，腳本在 scratchpad）；`supabase start` 正式路徑仍 BLOCKED 於 Docker 映像拉取。

### 2026-08-22T09:01:33.627Z · Chih-Lin Yeh · `30804943`

**QA gate：PASS＋收尾 gate 完成**

QA（qa/sonnet）：`supabase start` 正式路徑仍 BLOCKED（Docker 拉取未恢復，實測 docker pull 掛起）——走 PG16 stub 備援：拋棄式容器套三個 migration＋`run.sh` **全綠**（8 個測試檔＋2 併發場景，含 RLS plan 偵測器自我驗證），容器已移除。證據：/tmp/qa-phase0/ls6-run-output.log。雲端唯讀斷言見 LS-14。
收尾 gate：dead-code 巡檢零 finding（12 支 SQL 函式皆 ≥3 處引用；config.toml seed 殘留已在 8697437 修掉獲確認）；PG17 覆核事項維持在 config 註解追蹤。retro 見 LS-16。
待 promote test→main 後進 Done。

### 2026-08-22T10:22:41.125Z · Chih-Lin Yeh · `6d54db57`

**積欠項結案：`supabase start` 正式路徑＋PG17 覆核——由 CI 證據補齊**

LS-11 的 CI `db` job 即正式路徑：官方 supabase CLI（鎖 2.115.0）→ `supabase db start`（依 config.toml `major_version = 17` 拉 **PG17** 映像）→ `supabase db reset` 套全部 migration → `supabase/tests/run.sh` 全套。已於多個 run 綠燈實證（32564495806、32566764597 等），且紅燈探針證明會攔真問題。原積欠的兩個疑慮（官方 stack 可套用性、PG17 相容性）皆解。

**本機環境遺留（需使用者處理，非專案阻塞）**：Docker Desktop 重啟後 image pull 仍卡死（60 秒拉不動 alpine；`docker info` 曾顯示走 `http.docker.internal:3128` proxy）。請檢查 Docker Desktop → Settings → Resources → Proxies 的設定。影響範圍：本機首次拉新映像的工作（既有快取映像的容器運作正常，QA/驗證的 PG16 備援路徑不受影響）。

### 2026-08-22T14:16:00.963Z · Chih-Lin Yeh · `93883b0b`

**本機環境遺留結案**：Docker proxy 已修（Docker Desktop proxy 模式改 manual 直連，設定已備份）。修復後本機跑完官方正式路徑：`supabase db start`（PG17 映像實際拉取成功）→ `supabase db reset`（4 個 migration 全套）→ `run.sh` **全綠**（含 owner 併發場景與 EXPLAIN 證據）。PG17 相容性至此有本機＋CI 雙重佐證。所有環境積欠項清零。

