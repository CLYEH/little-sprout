-- 併發場景（軟刪先動）的最終狀態斷言：軟刪先贏，編輯必須完全沒有生效，deleted_by 歸屬 owner。
--
-- 只斷言「有軟刪」不夠——若編輯沒被真的擋下，量測值／備註可能已被改成作者的新內容，
-- 只是 deleted_at 也還在（兩個 UPDATE 各寫各的欄位，不會互相蓋掉），這種「表面一致、
-- 內容卻被動過」的結果一樣違反「軟刪之後內容不再被改動」。

\set ON_ERROR_STOP on

do $$
declare
  v_note text;
  v_height numeric;
  v_deleted timestamptz;
  v_deleted_by uuid;
begin
  select g.note, g.height_cm, g.deleted_at, g.deleted_by
    into v_note, v_height, v_deleted, v_deleted_by
    from public.growth_records g
   where g.id = '77000000-0000-4000-8000-000000000001';

  if v_deleted is null then
    raise exception 'FAIL 併發：先 commit 的軟刪被推翻了（deleted_at 竟然是 NULL）';
  end if;
  if v_deleted_by is distinct from '75000000-0000-4000-8000-000000000001' then
    raise exception 'FAIL 併發：deleted_by 應為 owner，實際 %', v_deleted_by;
  end if;
  if v_note is distinct from '原始備註' or v_height is distinct from 70.0 then
    raise exception
      'FAIL 併發：紀錄已被軟刪，內容卻被改成 note=「%」height_cm=% —— 編輯的 UPDATE 沒有被真的擋下',
      v_note, v_height;
  end if;

  raise notice 'ok 併發：軟刪先動時最終 deleted_at 已設定、deleted_by＝owner，內容維持原狀（編輯完全沒有生效）';
end;
$$;
