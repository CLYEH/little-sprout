-- 併發場景（方向 A：編輯先動）的 session 2：owner 在作者還沒 commit 編輯的時候用
-- set_comment_deleted 軟刪。技術結論同 album_edit_vs_delete_s2_delete.sql（不
-- 重複展開）：這裡會被阻塞，但阻塞來源是 `set_comment_deleted` 尾端的 UPDATE
-- 本身的隱含列鎖，不是開頭 `select ... for update` 的 `for update` 特有效果——
-- 本機實測驗證過拿掉 for update 這個場景的阻塞時間與最終狀態不變。

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
