-- 併發場景（方向 B：軟刪先動）的 session 2：作者在 owner 還沒 commit 軟刪的時候
-- 呼叫 update_comment 改 body。與 diaries 不同（comments 同樣沒有「已軟刪除不能
-- 編輯」的規則——update_comment 檢查的是「呼叫當下」的 deleted_at，owner 的軟刪
-- 這時還沒 commit，作者看到的仍是未刪狀態），解除阻塞後應該成功，理由同
-- album_edit_vs_delete_s2_update.sql。
--
-- LS-58：改呼叫 update_comment（RPC-only），不再是直接 UPDATE。update_comment
-- 找不到／已被軟刪除的目標會 raise LS024，不是「影響 0 列」——所以這裡改成跟
-- diary_edit_vs_delete_s2_delete.sql 一樣，用 exception 捕捉來判斷成功與否，不是
-- get diagnostics row_count（update_comment 對呼叫端而言是「要嘛整支成功、要嘛
-- raise」的語意，沒有靜默 0 列這種中間狀態）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.update_comment('69000000-0000-4000-8000-000000000001', '軟刪之後還想改');
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：作者的 update_comment 沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— set_comment_deleted 尾端的 UPDATE 沒有真的鎖住這一列',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：作者編輯自己的留言（仍是該家庭成員）解除阻塞後應該成功，實際出錯（%）',
      v_error;
  end if;

  raise notice 'ok 併發：作者的 update_comment 被 owner 的軟刪阻塞，解除阻塞後正常成功';
end;
$$;
