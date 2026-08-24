-- 雙 toggle 併發場景的最終狀態斷言：兩次 toggle（一次加入、一次收回）的淨效果必須
-- 正確歸零——沒有殘留列，也沒有因為序列化失敗而留下重複列。

\set ON_ERROR_STOP on

do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.reactions
   where target_type = 'album'
     and target_id = '6c000000-0000-4000-8000-000000000001'
     and user_id = 'a1000000-0000-4000-8000-000000000001';

  if v_count <> 0 then
    raise exception
      'FAIL 併發：雙 toggle 後淨效果應該歸零（先加入後收回），實際剩下 % 筆——序列化沒有正確生效',
      v_count;
  end if;

  raise notice 'ok 併發：雙 toggle 的淨效果正確歸零，沒有殘留或重複列';
end;
$$;
