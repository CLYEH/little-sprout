-- 併發場景（方向 C：作者搬家先動）的 session 2：f3（原家庭）owner 在作者還沒
-- commit 搬家的時候呼叫 set_album_deleted。
--
-- 這是 `FOR UPDATE` 真正必要的地方（merge-reviewer PR #70 review N1，第 2 輪）：
-- `set_album_deleted` 的授權判斷讀的是 `v_album.family_id`，用它去查
-- `family_members` 判斷呼叫者是不是這個家庭的 owner／仍是成員。若這支函式的初始
-- `select ... for update` 沒有鎖住這一列：
--   1. 這裡的 SELECT 會讀到搬家**之前**的 `family_id`（f3）——因為作者的 UPDATE
--      還沒 commit，READ COMMITTED 下這個 SELECT 看不到它。
--   2. 用這個過期的 f3 去查 family_members，f3 的 owner（呼叫者本人）通過授權。
--   3. 函式尾端的 `update public.albums a set deleted_at = ...`（SECURITY
--      DEFINER，不受 RLS 保護）在作者的搬家 commit 之後才真正執行——此時這本
--      相簿的 `family_id` 已經是 f8，但函式已經在步驟 2 判過權限，不會回頭重查。
--   結果：f3 的 owner 對一本此刻已經屬於 f8 的相簿完成了軟刪——跨家庭越權。
-- 有 `for update`：初始 SELECT 會等作者的搬家 commit 之後才讀到列，讀到的
-- `family_id` 已經是 f8，f3 的 owner 對 f8 沒有任何身分，授權判斷正確地噴 42501，
-- `deleted_at` 完全沒被動過（見 verify 檔）。
--
-- Mutation 證據（本機用 Supabase CLI 映像實測，套用於這個檔案／這個場景）：把
-- `set_album_deleted` 開頭 `select a.* into v_album from public.albums a where
-- a.id = p_album_id for update;` 的 `for update` 拿掉，重跑這個場景：
-- 授權判斷通過（不噴 42501）、`deleted_at` 被寫入——這個檔案的兩條斷言（下面）
-- 與 verify 檔的斷言都會變紅，證實這把鎖確實是行為必要的，不是防禦性寫法。

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

  -- 讓 session 1 的搬家 UPDATE（含隱含列鎖）先跑完
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
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功——若看到這行，代表 for update 沒有真的擋住跨家庭越權）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：f3 owner 的 set_album_deleted 沒有被作者的搬家 UPDATE 阻塞（僅等待 % 秒）——序列化沒有生效',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is distinct from '42501' then
    raise exception
      'FAIL 併發：相簿此刻已屬於 f8，f3 的 owner 竟然能對它呼叫 set_album_deleted 成功（錯誤碼=%）——跨家庭越權，for update 沒有擋住這個 race',
      coalesce(v_error, '（無，成功）');
  end if;

  raise notice 'ok 併發：f3 owner 被作者的搬家阻塞，解除阻塞後正確拿到 42501（相簿已不屬於 f3，沒有跨家庭越權）';
end;
$$;
