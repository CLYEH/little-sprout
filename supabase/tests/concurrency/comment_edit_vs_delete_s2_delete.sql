-- 併發場景（方向 A：編輯先動）的 session 2：owner 在作者還沒 commit 編輯的時候用
-- set_comment_deleted 軟刪。
--
-- LS-58 更新：原本「作者搬家 vs owner 軟刪」的方向 C（
-- comment_edit_vs_delete_s1_move_family.sql／s2_delete_after_move.sql，merge-
-- reviewer PR #70 review N1 加的、真正驗到 for update 必要性的那組)已隨 LS-58
-- 收斂 comments 成 RPC-only 一起退役——update_comment 的參數只有 body，comments
-- 的 UPDATE grant 也整個被收回，authenticated 已經沒有任何路徑能把一則留言的
-- family_id 搬到別的家庭，這裡要重現的跨家庭越權場景在前提上就不成立了（不是靠
-- 鎖擋住，是連「搬家」這個動作本身都做不到）。set_comment_deleted 的 `for update`
-- 沒有被拿掉（migration 是歷史紀錄不回頭改），下面這組（方向 A／B）繼續驗它與
-- update_comment 之間序列化正確、沒有互相覆蓋對方寫的欄位——但同 album_edit_vs_
-- delete_s2_delete.sql 的既有說明：這證明的是「序列化正確」，不是「for update 本身
-- 必要」，兩件事不能混為一談，comments 這裡目前沒有能重現「拿掉 for update 會實際
-- 壞掉」的場景。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_comment_deleted('69000000-0000-4000-8000-000000000001', true);
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：owner 的 set_comment_deleted 沒有被作者的直接 UPDATE 阻塞（僅等待 % 秒）——序列化沒有生效',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：owner 軟刪這則留言竟然出錯（%）—— set_comment_deleted 不該因為內容正在被編輯而失敗',
      v_error;
  end if;

  raise notice 'ok 併發：owner 的軟刪被作者的直接 UPDATE 阻塞，解除阻塞後正常成功';
end;
$$;
