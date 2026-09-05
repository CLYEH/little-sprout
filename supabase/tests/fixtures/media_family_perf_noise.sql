-- 共用 fixture（LS-204，來源 LS-200 R1 i3 `ca99c6ae`）
--
-- 灌 5 萬列同家庭「背景雜訊」media，讓效能測試對 index 選擇有鑑別力——只灌少量
-- 列時 media 表本身很小，Seq Scan 在小表上成本低，規劃器會直接選它，測不出
-- 「表大了會怎樣」；灌到 5 萬+ 列後 EXPLAIN 才有鑑別力。原本
-- 107_album_summaries.sql §6 與 50_rls_plan_no_percall_subquery.sql 各自維護一份
-- 幾乎一樣的 insert（欄位、規模、目的完全相同，只有 storage_path 前綴與少數
-- 無關斷言的欄位值不同），抽成這份共用原始碼，兩邊改用同一份，不再各自維護。
--
-- 用 \ir（相對於呼叫端腳本所在目錄的 include，psql 9.6+ 內建語法）供兩支測試檔
-- 各自 include 一次——共用的是「同一份 SQL 原始碼」，不是「同一次執行」：兩支
-- 測試檔本來就整檔各自包在自己的 begin/rollback 裡（互不影響、可獨立重跑），
-- 抽出這個 insert 只消除文字重複，執行次數與交易邊界都不變，run.sh 總時間因此
-- 不受影響。
--
-- 為什麼不改用 bash 層的檔案拼接（例如改寫 run.sh 現有的檔案載入迴圈去支援
-- include）：run.sh 有三種連線管道，其中 docker exec 那條是把整份檔案內容經
-- stdin 餵給容器內的 psql（DB container 只掛了資料卷，沒有掛載 host 上的這份
-- repo），這個管道下 \i／\ir 只認得 psql 執行檔自己那台機器（即容器內部）的
-- 檔案系統，找不到這個檔案時 psql 會直接報錯中止——是清楚的失敗（fail loud），
-- 不是靜默跳過或誤判通過；host psql 這兩條管道（走 SUPABASE_DB_URL 或離散
-- 參數）都是 CI 與已安裝 psql 的本機開發常態，\ir 在其下正常運作。要在 docker
-- exec 管道下驗證本檔案的改動，本機需另外安裝 psql（見 run.sh 檔頭「psql 不
-- 一定裝在 host 上」那段既有備援說明）。
--
-- 依賴：呼叫端在 include 這份檔案之前，必須已經（在同一個交易內）存在
-- fixture 家庭 fc000000-0000-4000-8000-000000000001 與其 owner
-- c0000000-0000-4000-8000-000000000001（00_fixtures.sql 的「效能家」）。
insert into public.media
  (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
select
  'fc000000-0000-4000-8000-000000000001',
  'fc000000-0000-4000-8000-000000000001/2026/' || lpad((1 + (i % 12))::text, 2, '0') || '/noise-' || i || '.jpg',
  'photo', 1024, now() - (i * interval '1 minute'), 3024, 4032,
  'c0000000-0000-4000-8000-000000000001', now() - (i * interval '1 minute')
  from generate_series(1, 50000) i;
