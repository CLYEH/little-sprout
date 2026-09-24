-- LS-378 併發場景（共用照片的兩篇日記同時刪除）session 2：S1 還沒 commit 時軟刪 D2。
--
-- D2 是另一列日記，set_diary_deleted 本身的 UPDATE 不會被 S1 擋；會被擋的是
-- diaries_media_feed_visibility trigger 對共用照片 media 列取的 FOR NO KEY UPDATE 鎖。
-- 解除阻塞後下一句 SQL 取新快照、看得到 D1 已刪 → 判定照片隱藏。沒有這把鎖時 S2 不會
-- 等待，用舊快照看到 D1 還活著而保留照片（verify 會紅）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"d3780000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 S1 的軟刪（含 trigger 取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  perform public.set_diary_deleted('53780000-0000-4000-8000-000000000002', true);
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：D2 軟刪等待 % 秒後完成', round(v_elapsed::numeric, 2);

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：D2 的軟刪沒有被 S1 阻塞（僅等待 % 秒）——diaries_media_feed_visibility 沒有對共用照片的 media 列取鎖',
      round(v_elapsed::numeric, 2);
  end if;
end;
$$;
