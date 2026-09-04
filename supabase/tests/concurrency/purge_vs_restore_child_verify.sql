-- 最終狀態斷言：purge 先贏，孩子檔案必須真的物理消失（不是「還原剛好也失敗、但列
-- 其實還在」這種表面一致、內容卻不對的結果）。

\set ON_ERROR_STOP on

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.children where id = '2f000000-0000-4000-8000-000000000001';
  if v_n <> 0 then
    raise exception 'FAIL 併發：purge_expired() 已 commit，競態孩子卻還在（% 列）', v_n;
  end if;

  raise notice 'ok 併發：purge_expired() 先動時最終孩子檔案已物理消失，還原完全沒有生效';
end;
$$;
