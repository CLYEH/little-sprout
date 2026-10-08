-- 鎖強度探針（LS-419）的 session 1：以 FOR KEY SHARE 鎖住這筆成長紀錄，壓住 3 秒不 commit。
--
-- 為什麼需要這一組（而不只是「軟刪先動、編輯後動」那組）：那組的阻塞來自 owner 軟刪交易
-- 「自己的 UPDATE」取得的列鎖，delete_growth_record 開頭的 `select … for update` 拿掉之後
-- 那組照樣綠（LS-419 實測 S2 一樣等 1.81 秒、一樣拿到 42501）——它守的是「軟刪之後內容不再
-- 被改動」，守不到「授權判斷讀到的列先鎖住」（LS-52 規則，delete_growth_record 上方註解）。
--
-- FOR KEY SHARE 只和 FOR UPDATE 衝突，不和一般 UPDATE（改非鍵欄位時取的 FOR NO KEY UPDATE）
-- 衝突。所以 session 2 的 delete_growth_record 只有在「真的先 `select … for update`」時才會
-- 被這把鎖擋住；拿掉 for update 就直接穿過去（實測等待 0.01 秒）。現實中持 FOR KEY SHARE 的是
-- 「新增一筆以 FK 參照這筆紀錄的子列」；目前沒有表參照 growth_records，所以這裡以 postgres
-- 身分直接下 FOR KEY SHARE，當成純粹的鎖強度探針，不模擬任何使用者操作。

\set ON_ERROR_STOP on

begin;

select 1 from public.growth_records
 where id = '77000000-0000-4000-8000-000000000001'
   for key share;

select pg_sleep(3);

commit;

\echo 'S1：FOR KEY SHARE 已釋放'
