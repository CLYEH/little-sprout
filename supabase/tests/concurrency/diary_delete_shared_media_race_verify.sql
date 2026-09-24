-- LS-378 併發場景（共用照片的兩篇日記同時刪除）最終狀態：兩篇都已軟刪，共用照片必須已
-- 自時間軸隱藏（media 列本身仍在、未軟刪）。

\set ON_ERROR_STOP on

do $$
declare
  v_live int;
begin
  select count(*) into v_live from public.diaries
   where id in ('53780000-0000-4000-8000-000000000001', '53780000-0000-4000-8000-000000000002')
     and deleted_at is null;
  if v_live <> 0 then
    raise exception 'FAIL 併發：兩篇日記應都已軟刪，仍有 % 篇未刪（場景前提不成立）', v_live;
  end if;

  if exists (select 1 from public.feed_items
              where kind = 'media' and ref_id = '33780000-0000-4000-8000-000000000001') then
    raise exception 'FAIL 併發：共用照片的兩篇日記同時被刪，照片仍在 feed_items（write skew：兩邊都用舊快照判定「另一篇還活著」）';
  end if;

  if not exists (select 1 from public.media
                  where id = '33780000-0000-4000-8000-000000000001' and deleted_at is null) then
    raise exception 'FAIL 併發：刪日記只該動 feed 層，共用照片的 media 列卻不見或被軟刪了';
  end if;

  raise notice 'ok 併發：共用照片的兩篇日記同時刪除後，照片已自時間軸隱藏、media 列仍在';
end;
$$;
