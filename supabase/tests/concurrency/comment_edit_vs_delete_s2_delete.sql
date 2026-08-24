-- 併發場景（方向 A：編輯先動）的 session 2：owner 在作者還沒 commit 編輯的時候用
-- set_comment_deleted 軟刪。
--
-- 更正（merge-reviewer PR #70 review N1，第 2 輪）：先前的檔頭宣稱「for update
-- 不是行為必要的」是錯的，理由同 album_edit_vs_delete_s2_delete.sql（不重複
-- 展開）。真正驗 for update 必要性的是
-- comment_edit_vs_delete_s1_move_family.sql／s2_delete_after_move.sql（作者
-- 搬家 vs owner 軟刪），comments 的作者分支門檻比 albums 更低（family_ids()，
-- 任一角色皆可搬家），同一種跨家庭越權更容易觸發。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_comment_deleted('69000000-0000-4000-8000-000000000001', true);
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：owner 的 set_comment_deleted 沒有被作者的直接 UPDATE 阻塞（僅等待 % 秒）——序列化沒有生效',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：owner 軟刪這則留言竟然出錯（%）—— set_comment_deleted 不該因為內容正在被編輯而失敗',
      v_error;
  end if;

  raise notice 'ok 併發：owner 的軟刪被作者的直接 UPDATE 阻塞，解除阻塞後正常成功';
end;
$$;
