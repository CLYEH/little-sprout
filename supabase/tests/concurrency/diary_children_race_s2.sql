-- LS-121 併發場景 session 2：等 S1 先取到鎖之後，才把孩子標記整組換成 {D}——必須
-- 被 S1 阻塞，解除阻塞後才真正執行，讀到的是 S1 已經 commit 之後的狀態，寫出的是
-- 自己完整、覆蓋後的集合。
--
-- R2 訂正（merge-reviewer PR #218 review M2）：R1 版本的錯誤訊息誤把這裡的阻塞
-- 歸因成 `update_diary_entry` 開頭那句 `select ... for update`。reviewer 做了
-- mutation 實測：把 `for update` 拿掉重跑完全相同的兩連線腳本，兩條斷言（阻塞
-- ≥0.5 秒、終態＝S2 的完整集合）照樣通過——真正提供序列化的是 RPC 本體那句
-- `update public.diaries d set body = ...`，READ COMMITTED 下任何 UPDATE 語句本身
-- 就會鎖住目標列，`for update` 對這個測試場景沒有增益（這把鎖真正必要之處是保護
-- 「日記是否已軟刪除」那個讀-判斷不吃到過期快照，不是這裡）。這條測試因此測不出
-- `for update` 被拿掉，但它仍然是有意義的斷言：它證明 `update_diary_entry` 這支
-- RPC 整體會把「內容覆蓋」與「孩子標記覆蓋」序列化成同一個不可分割的單位，兩個
-- 連線同時覆蓋同一篇日記時終態不會混合——只是序列化的施力點是 `UPDATE diaries`
-- 本身，不是那句 `for update`。要真的分辨得出 `for update` 被拿掉，見
-- `album_children_race_*`（`set_album_children` 沒有其他 UPDATE 語句，`for update`
-- 是唯一的序列化點）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 update_diary_entry（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  perform public.update_diary_entry(
    '58000000-0000-4000-8000-000000000001', 'S2 改的內容', current_date,
    array['28000000-0000-4000-8000-000000000004']::uuid[]);
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後完成，孩子標記整組換成 {D}', round(v_elapsed::numeric, 2);

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的 update_diary_entry 沒有被 S1 阻塞（僅等待 % 秒）—— update_diary_entry 對同一篇日記的兩次覆蓋沒有序列化（見檔頭 R2 訂正：施力點是 UPDATE diaries 本身，不是 for update）',
      round(v_elapsed::numeric, 2);
  end if;
end;
$$;
