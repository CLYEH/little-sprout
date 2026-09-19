-- LS-342（LS-310 M8 收尾）—— food_catalog.sort_order 唯一性下沉到 DB。
--
-- 背景：`20260919073805_food_catalog_expansion.sql` 檔頭已記載本表 sort_order 全域
-- 唯一「只是 CSV／seed 手動維護出來的慣例，不是 DB 強制的」；LS-339 merge-review R1
-- 的風險段與 LS-96 池項 `708422e5`（i1）明確點出：那支 migration 的交易中段
-- （INSERT 152 列在前、UPDATE 105 列既有值在後）會有 77 個暫時重複的 sort_order
-- 值——今天無害，但「日後若想替 sort_order 加 unique index，這支 migration 若被
-- 重放（新環境 bootstrap）會失敗」。本票把這個隱形地雷收掉，同時真的把唯一性下沉
-- 到 DB（票面驗收 2）。
--
-- 為什麼是 `deferrable initially deferred`（而不是 `deferrable initially immediate`
-- 或非 deferrable）：
--   - 非 deferrable 的 unique constraint：每一列寫入立刻檢查，`20260919073805` 那種
--     「先 INSERT 一批新列（新編號可能暫時撞到還沒被 UPDATE 移走的舊列），再用一支
--     UPDATE 把舊列移到新位置」的兩階段模式，會在 INSERT 那一步就被 23505 擋下——
--     這支既有 migration 不可改（immutable gate），代表 non-deferrable 選項會讓
--     `supabase db reset`／CI `db` job 在新環境套用既有 migration 序列時直接失敗。
--   - `deferrable initially immediate`：檢查時機是「每個陳述式結束時」而不是逐列，
--     可以讓單一陳述式內的重排（例如一支 UPDATE ... FROM (VALUES ...) 一次改很多列）
--     安全；但 `20260919073805` 的暫時重複是**跨陳述式**（INSERT 陳述式結束後，
--     UPDATE 陳述式還沒執行，此時已經有 77 個重複值存在），immediate 檢查時機在
--     INSERT 陳述式結束當下就會抓到、一樣會失敗。
--   - `deferrable initially deferred`：檢查時機延到 COMMIT，整支 migration（單一
--     交易）結束時 274 列已經是最終態、無重複，COMMIT 成功；且往後任何人的自訂
--     連線 session 想更精確控制檢查時機，仍可用 `set constraints
--     food_catalog_sort_order_unique immediate` 提前觸發。
--
-- 驗證：`supabase/tests/run.sh` 的「sort_order deferrable unique」段（見該檔）實跑
-- 兩件事：(a) 用同一種「INSERT 在前、UPDATE 在後」的跨陳述式暫時重複模式做一次
-- 探針，COMMIT 應該成功（證明既有 migration 的模式往後仍然可行）；(b) 蓄意在
-- COMMIT 時留下真正的重複，必須拿到 23505（且交易未提交，不會污染資料）。

alter table public.food_catalog
  add constraint food_catalog_sort_order_unique
  unique (sort_order) deferrable initially deferred;
