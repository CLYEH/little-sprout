-- 併發場景（方向 B：軟刪先動）的最終狀態斷言：軟刪先贏，編輯必須完全沒有生效。
--
-- 只斷言「有軟刪」是不夠的——若 update_child 的鎖沒生效，name 有可能已經被改成
-- member 的新內容，只是「剛好」deleted_at 也還在（兩個 UPDATE 各自只碰各自的欄位，
-- 不會互相覆蓋掉對方寫的值），這種「表面一致、內容卻被動過」的結果一樣違反驗收條件。

\set ON_ERROR_STOP on

do $$
declare
  v_name text;
  v_deleted timestamptz;
begin
  select c.name, c.deleted_at into v_name, v_deleted from public.children c
   where c.id = '29000000-0000-4000-8000-000000000001';

  if v_deleted is null then
    raise exception 'FAIL 併發：先 commit 的軟刪被推翻了（deleted_at 竟然是 NULL）';
  end if;
  if v_name <> '原始名字' then
    raise exception
      'FAIL 併發：孩子檔案已被軟刪，name 卻被改成「%」—— 編輯的 UPDATE 沒有被真的擋下，只是恰好也軟刪成功了',
      v_name;
  end if;

  raise notice 'ok 併發：軟刪先動時最終 deleted_at 已設定，name 維持原始內容（編輯完全沒有生效）';
end;
$$;
