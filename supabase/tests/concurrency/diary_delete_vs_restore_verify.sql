-- 併發場景（LS-57：owner 軟刪先動）的最終狀態斷言：owner 的軟刪先贏，作者的還原
-- 必須完全沒有生效——`deleted_at` 仍是非 NULL，且 `deleted_by` 仍是 owner。

\set ON_ERROR_STOP on

do $$
declare
  v_deleted timestamptz;
  v_deleted_by uuid;
begin
  select d.deleted_at, d.deleted_by into v_deleted, v_deleted_by from public.diaries d
   where d.id = '57000000-0000-4000-8000-000000000001';

  if v_deleted is null then
    raise exception 'FAIL 併發：先 commit 的軟刪被推翻了（deleted_at 竟然是 NULL）';
  end if;
  if v_deleted_by is distinct from 'd1000000-0000-4000-8000-000000000001'::uuid then
    raise exception
      'FAIL 併發：deleted_by 應該仍是 owner（a2...1），實際是 %——作者的被擋還原不該動到這一欄',
      v_deleted_by;
  end if;

  raise notice 'ok 併發：owner 軟刪先動時最終 deleted_at 已設定、deleted_by 仍是 owner（作者的還原完全沒有生效）';
end;
$$;
