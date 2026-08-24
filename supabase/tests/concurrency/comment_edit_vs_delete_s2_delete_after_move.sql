-- 併發場景（方向 C：作者搬家先動）的 session 2：f4（原家庭）owner 在作者還沒
-- commit 搬家的時候呼叫 set_comment_deleted。技術結論與 mutation 證據同
-- album_edit_vs_delete_s2_delete_after_move.sql（不重複展開）：`for update`
-- 拿掉會讓 f4 owner 對一則此刻已屬於 f9 的留言完成軟刪——跨家庭越權。

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
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功——若看到這行，代表 for update 沒有真的擋住跨家庭越權）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：f4 owner 的 set_comment_deleted 沒有被作者的搬家 UPDATE 阻塞（僅等待 % 秒）——序列化沒有生效',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is distinct from '42501' then
    raise exception
      'FAIL 併發：留言此刻已屬於 f9，f4 的 owner 竟然能對它呼叫 set_comment_deleted 成功（錯誤碼=%）——跨家庭越權，for update 沒有擋住這個 race',
      coalesce(v_error, '（無，成功）');
  end if;

  raise notice 'ok 併發：f4 owner 被作者的搬家阻塞，解除阻塞後正確拿到 42501（留言已不屬於 f4，沒有跨家庭越權）';
end;
$$;
