-- 併發場景（方向 A：編輯先動）的 session 2：owner 在作者還沒 commit 編輯的時候用
-- set_album_deleted 軟刪。
--
-- 誠實的技術結論（merge-reviewer PR #70 review F2 要求「驗鎖等待」，這裡如實驗證、
-- 也如實記錄驗到了什麼）：這裡確實會被阻塞，但阻塞的來源是
-- `set_album_deleted` 函式尾端那句 `update public.albums a set deleted_at = ...`——
-- **任何** UPDATE 命中一個已被其他未 commit 交易鎖住的列都會等待，這是 Postgres
-- 的通用行為，不是 `select ... for update` 這句話特有的效果。本機用 Supabase CLI
-- 映像實測驗證過：把 `set_album_deleted` 開頭那句 `select ... for update` 的
-- `for update` 拿掉，重跑這個場景，阻塞時間與最終狀態**完全不變**——因為這支函式
-- 的授權判斷（v_is_owner／v_is_author_current_member）查的是 family_members，
-- 不是這本相簿自己的欄位，尾端的 UPDATE 又是把 deleted_at 設成常數（不是根據
-- 讀到的舊值算出新值），所以沒有「讀到舊資料做出錯誤決策」這個 for update 原本
-- 要防的風險。這與 diaries 的 update_diary_entry／set_diary_deleted 不同——那兩支
-- 函式的決策明確依賴讀到的 deleted_at／body 是不是最新的（判斷「這篇日記是否已被
-- 移除」），拿掉 for update 會讓決策讀到過期資料而做錯事，這裡沒有對應的風險。
-- 因此這個測試檔案能證明的是「作者的直接編輯與 owner 的軟刪會正確序列化、不會
-- 互相覆蓋掉對方寫的欄位」（見 verify 檔），**不能**當成「拿掉 for update 這個檔案
-- 會變紅」的證據——如果之後有人真的把 for update 拿掉，這個測試仍然會是綠的，
-- 這是函式本身的邏輯形狀決定的，不是測試漏寫。

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
