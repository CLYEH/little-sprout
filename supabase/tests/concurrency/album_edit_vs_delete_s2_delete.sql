-- 併發場景（方向 A：編輯先動）的 session 2：owner 在作者還沒 commit 編輯的時候用
-- set_album_deleted 軟刪。
--
-- 更正（merge-reviewer PR #70 review N1，第 2 輪）：這個檔案先前的檔頭宣稱
-- 「for update 對這個情境不是行為必要的」是錯的，已由 reviewer 實測反例推翻，
-- 這裡不重複那段錯誤推論。真話是：**現有這組 race case（作者改 title、owner
-- 軟刪）測不出 for update 的必要性，但這把鎖本身不可移除**——授權判斷讀的
-- family_id 就是從這一列本身讀來的，會隨作者的另一種直接 UPDATE（改 family_id
-- 搬家）而變動。這組（title vs 軟刪）測到的是「序列化正確、不互相覆蓋對方寫的
-- 欄位」，真正驗 for update 必要性的是另一組
-- album_edit_vs_delete_s1_move_family.sql／s2_delete_after_move.sql（作者搬家
-- vs owner 軟刪），該組的檔頭有完整說明與 mutation 證據，這裡不重複展開。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的直接 UPDATE（含取隱含列鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_album_deleted('49000000-0000-4000-8000-000000000001', true);
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：owner 的 set_album_deleted 沒有被作者的直接 UPDATE 阻塞（僅等待 % 秒）——序列化沒有生效',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：owner 軟刪這本相簿竟然出錯（%）—— set_album_deleted 不該因為內容正在被編輯而失敗',
      v_error;
  end if;

  raise notice 'ok 併發：owner 的軟刪被作者的直接 UPDATE 阻塞，解除阻塞後正常成功';
end;
$$;
