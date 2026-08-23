-- 併發場景一的 session 2：申請人乙在甲還沒 commit 的時候搶同一個名額。
--
-- 三條斷言，缺一不可：
--   1. 必須「被阻塞」——request_join 先取 invites 的列鎖，同一支碼的申請才會排隊。
--      沒有鎖的話乙會立刻讀到 used_count = 0 並往下走（等待 ≈ 0 秒）。
--   2. 解除阻塞後必須噴 **LS012**（次數用罄），因為 READ COMMITTED 下
--      SELECT ... FOR NO KEY UPDATE 等到鎖之後會重讀最新列版本，看到 used_count 已經是 1。
--   3. 乙不能留下任何申請列（另見 join_race_verify.sql 的最終狀態斷言）。
--
-- 為什麼第 2 條一定要驗「錯誤碼是 LS012」而不只是「有失敗」：
-- 拿掉那把鎖之後，乙的申請仍然會失敗——但失敗的地方變成 invites_uses_within_max 這條
-- CHECK（23514），時間點在 used_count 加一的時候。結果同樣是「只有一個人成立」，
-- 但 UI 拿到的是一個 DB 約束違反，沒辦法對使用者說「這支碼的名額用完了」。
-- 這就是本檔案對「拿掉 for no key update」這個 mutation 的紅燈依據。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls012 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"ea000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 request_join（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.request_join('RACE2345');
  exception
    when sqlstate 'LS012' then v_ls012 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先把 S2 的結果定案再斷言：萬一乙的申請沒被擋下，那一列要真的留在資料庫裡，
  -- join_race_verify.sql 才看得到「一支 max_uses=1 的碼產生了兩筆申請」這個實際後果。
  commit;

  raise notice 'S2：等待 % 秒後結束，LS012=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_ls012, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：乙的申請沒有被甲阻塞（僅等待 % 秒）—— request_join 沒有序列化同一支邀請碼的申請',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_ls012 then
    raise exception
      'FAIL 併發：乙搶最後一個名額沒有拿到 LS012（實際錯誤碼 %）—— UI 無法對使用者說「這支碼用完了」',
      coalesce(v_other, '沒有任何錯誤，申請竟然成立');
  end if;

  raise notice 'ok 併發：乙被阻塞後拿到 LS012（次數用罄）';
end;
$$;
