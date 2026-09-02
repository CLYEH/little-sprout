-- LS-121 R2 併發場景 session 2：等 S1 先取到鎖之後，才把相簿的孩子標記整組換成
-- {D}——真正要驗的是終態（見 album_children_race_verify.sql），不是這裡的等待
-- 秒數本身。
--
-- 誠實記錄一個 mutation 實測發現的細節（拿掉 `set_album_children` 開頭那句
-- `for update` 重跑同一組腳本）：S2 這裡量到的等待秒數**不會變**（拿掉鎖前後都
-- 是約 1.8 秒），不是因為 `for update` 沒有作用，是因為 S1／S2 的初始標記集合都
-- 含孩子 A（S1 覆蓋成 {B,C}、S2 覆蓋成 {D}，兩者都要把 A 刪掉）——`album_children`
-- 對這一列本身的 DELETE 是真正的 DML，兩個連線同時刪同一列一定會互相排隊，這是
-- Postgres 對任何並行 DML 的通用行為，跟 `set_album_children` 有沒有對 `albums`
-- 下 `for update` 無關，所以下面「等待 ≥0.5 秒」這條斷言**不足以**單獨證明
-- `for update` 有沒有生效。真正有鑑別力的是 `album_children_race_verify.sql`
-- 的終態檢查：拿掉 `for update` 之後，S2 對孩子 A 那列的 DELETE 解除阻塞時用
-- EvalPlanQual 重新確認到那一列已經被 S1 刪掉、不再對它做事，但 S2 這次
-- DELETE／INSERT 兩句各自的敘述級快照（READ COMMITTED）都停留在自己開始執行時
-- 的畫面，看不到 S1 同一個交易裡插入的 B／C——終態因此會是 {B,C,D} 混合，不是
-- 乾淨的 {D}，這才是 `for update` 缺席時唯一可觀察到的差異。這裡的等待秒數斷言
-- 保留作為「兩個連線確實有交疊」的前提檢查，不是判定鎖是否生效的依據。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 set_album_children（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  perform public.set_album_children(
    '4f000000-0000-4000-8000-000000000001',
    array['2e000000-0000-4000-8000-000000000004']::uuid[]);
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後完成，孩子標記整組換成 {D}', round(v_elapsed::numeric, 2);

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 完全沒有等待（僅 % 秒）—— 這組場景的兩個連線應該對孩子 A 那列的 DELETE 互相排隊，沒等到代表場景設計本身壞了（見檔頭說明：這條斷言驗的是「兩個連線有交疊」，不是 for update 本身，真正的判準在 verify.sql 的終態檢查）',
      round(v_elapsed::numeric, 2);
  end if;
end;
$$;
