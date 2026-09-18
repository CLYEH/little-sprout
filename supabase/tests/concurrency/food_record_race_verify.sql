-- LS-325 併發場景驗證：終態必須恰好一列（partial unique index 保護），內容是
-- S2（後 commit 的一方）寫入的值——不能是兩列（unique 保護失效），也不能是 S1
-- 的值（若 S2 真的被 S1 阻塞、且解除阻塞後正確轉為更新，最終一定是 S2 的內容）。

\set ON_ERROR_STOP on

do $$
declare
  v_n int;
  v_note text;
  v_reaction text;
  v_first_tried_on date;
begin
  select count(*) into v_n from public.child_food_records
   where child_id = '73000000-0000-4000-8000-000000000001' and food_id = 'banana';
  if v_n <> 1 then
    raise exception
      'FAIL 併發：終態應該恰好 1 列（partial unique index 保護），實際 % 列——ON CONFLICT 的併發仲裁沒有正確生效',
      v_n;
  end if;

  select note, reaction, first_tried_on into v_note, v_reaction, v_first_tried_on
    from public.child_food_records
   where child_id = '73000000-0000-4000-8000-000000000001' and food_id = 'banana';

  if v_note <> 'S2 記錄' or v_reaction <> 'disliked' or v_first_tried_on <> date '2026-01-02' then
    raise exception
      'FAIL 併發：終態內容應該是 S2 寫入的值（note=S2 記錄／reaction=disliked／first_tried_on=2026-01-02），實際 note=%／reaction=%／first_tried_on=%',
      v_note, v_reaction, v_first_tried_on;
  end if;

  raise notice 'ok 併發：兩個連線同時 upsert_child_food_record 同一寶貝同一食物，終態恰好一列、正確是後 commit 那一方（S2）的完整內容，沒有重複列也沒有混合';
end;
$$;
