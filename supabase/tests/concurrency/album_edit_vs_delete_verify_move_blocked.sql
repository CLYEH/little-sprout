-- 併發場景（方向 C：作者搬家先動）的最終狀態斷言：相簿必須真的搬到 f8，且
-- deleted_at 必須維持 NULL——f3 的 owner 被 for update 正確擋下，完全沒有機會
-- 寫到這一欄（不是「寫了又被復原」，是壓根沒執行到那句 UPDATE）。

\set ON_ERROR_STOP on

do $$
declare
  v_family uuid;
  v_deleted timestamptz;
begin
  select a.family_id, a.deleted_at into v_family, v_deleted from public.albums a
   where a.id = '49000000-0000-4000-8000-000000000001';

  if v_family <> 'f8000000-0000-4000-8000-000000000001' then
    raise exception 'FAIL 併發：作者的搬家最終沒有生效（family_id=%）', v_family;
  end if;
  if v_deleted is not null then
    raise exception 'FAIL 併發：相簿的 deleted_at 竟然被設定了（%）——f3 owner 對已搬到 f8 的相簿完成了軟刪，跨家庭越權', v_deleted;
  end if;

  raise notice 'ok 併發：相簿已搬到 f8，deleted_at 維持 NULL（f3 owner 的軟刪被正確擋下，沒有跨家庭越權）';
end;
$$;
