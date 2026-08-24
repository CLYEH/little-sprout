-- 雙 toggle 併發場景的 session 2：第二次呼叫 toggle_reaction（同一人、同一目標），
-- 在 session 1 commit 之前發出。
--
-- 兩條斷言：
--   1. 必須「被阻塞」——toggle_reaction 用 pg_advisory_xact_lock 序列化「同一人×
--      同一目標」的並發呼叫，session 2 要在鎖上排隊等 session 1 commit。
--   2. 解除阻塞後必須**成功且回傳 false**（收回）：session 1 已經把反應加進去，
--      session 2 看到的是「已經按過」，toggle 的另一面是刪除，不該噴錯（尤其不該
--      是 reactions_target_user_key 的 23505——那正是沒有鎖時兩個併發 INSERT 會
--      撞到的錯誤）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
  v_result boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 toggle_reaction（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    select public.toggle_reaction('f6000000-0000-4000-8000-000000000001', 'album',
      '6c000000-0000-4000-8000-000000000001') into v_result;
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%，回傳=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無）'), v_result;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：第二次 toggle_reaction 沒有被第一次阻塞（僅等待 % 秒）—— pg_advisory_xact_lock 沒有真的序列化',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：第二次 toggle_reaction 解除阻塞後竟然出錯（%）——序列化之後應該正常完成（收回反應），不該噴錯（例如 23505）',
      v_error;
  end if;

  if v_result is not false then
    raise exception
      'FAIL 併發：第二次 toggle_reaction 的回傳應為 false（收回，因為第一次已經加入），實際 %',
      coalesce(v_result::text, 'NULL');
  end if;

  raise notice 'ok 併發：第二次 toggle_reaction 被第一次阻塞，解除阻塞後正常完成並回傳 false（收回）';
end;
$$;
