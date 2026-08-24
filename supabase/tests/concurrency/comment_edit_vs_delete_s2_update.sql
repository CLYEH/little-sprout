-- 併發場景（方向 B：軟刪先動）的 session 2：作者在 owner 還沒 commit 軟刪的時候
-- 直接 UPDATE body。與 diaries 不同（comments_update 同樣沒有「已軟刪除不能
-- 編輯」的規則），解除阻塞後應該成功，理由同 album_edit_vs_delete_s2_update.sql。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  update public.comments set body = '軟刪之後還想改'
   where id = '69000000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，影響 % 列', round(v_elapsed::numeric, 2), v_n;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：作者的直接 UPDATE 沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— set_comment_deleted 尾端的 UPDATE 沒有真的鎖住這一列',
      round(v_elapsed::numeric, 2);
  end if;

  if v_n <> 1 then
    raise exception
      'FAIL 併發：作者編輯自己的留言（仍是該家庭成員）解除阻塞後應該成功，實際影響 % 列',
      v_n;
  end if;

  raise notice 'ok 併發：作者的直接 UPDATE 被 owner 的軟刪阻塞，解除阻塞後正常成功';
end;
$$;
