-- LS-342：sort_order deferrable unique 反面探針（預期失敗，run.sh 的呼叫端反轉判定）。
--
-- 蓄意在交易內留下一筆真正的重複 sort_order 到 COMMIT——deferred 檢查延到 COMMIT
-- 才做，這裡就是要證明「延到 COMMIT」不等於「COMMIT 時不檢查」：COMMIT 必須拿到
-- 23505。COMMIT 失敗時 PostgreSQL 會自動捨棄整個未提交的交易（這裡從未執行過
-- COMMIT 以外的交易控制語句），這個探針本身不會在資料庫留下任何痕跡；呼叫端
-- （run.sh）另外用 select 驗證過一次未受污染。
\set ON_ERROR_STOP on

begin;

insert into public.food_catalog (id, name_zh, category, sort_order)
values ('ls342_probe_dup', 'LS342 重複探針', 'grain_root', 1);  -- 蓄意與 rice_cereal(1) 重複到 commit

commit;
