-- 鎖強度探針（LS-435）的 session 1：以 FOR KEY SHARE 鎖住這筆日記，壓住 3 秒不 commit。
--
-- 為什麼需要這一組（而不只是 diary_edit_vs_delete 那兩個方向）：那兩個方向的阻塞來自先動一方
-- 「自己的 UPDATE」取得的列鎖；set_diary_deleted 開頭的 `select … for update` 拿掉之後，
-- 軟刪先動／編輯先動兩個方向照樣綠（LS-435 mutation 實測，原文見 handoff）——它們守的是
-- 「後動那一邊排隊、終態一致」，守不到「授權判斷讀到的列先鎖住」（LS-52 規則）。
--
-- FOR KEY SHARE 只和 FOR UPDATE 衝突，不和一般 UPDATE（改非鍵欄位時取的 FOR NO KEY UPDATE）
-- 衝突。所以 session 2 的 set_diary_deleted 只有在「真的先 `select … for update`」時才會被這把鎖
-- 擋住；拿掉 for update 就直接穿過去。現實中持 FOR KEY SHARE 的是「新增一筆以 FK 參照這筆
-- 日記的子列」；這裡以 postgres 身分直接下 FOR KEY SHARE，當成純粹的鎖強度探針，不模擬
-- 任何使用者操作（做法同 growth_record_delete_vs_edit_s1_keyshare.sql，LS-419）。
--
-- run.sh 的 race_case 在每個方向開始前都會重跑一次 diary_edit_vs_delete_setup.sql，
-- 所以這裡不必假設日記處於哪個既有狀態。

\set ON_ERROR_STOP on

begin;

select 1 from public.diaries
 where id = '59000000-0000-4000-8000-000000000001'
   for key share;

select pg_sleep(3);

commit;

\echo 'S1：FOR KEY SHARE 已釋放'
