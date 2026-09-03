-- LS-143（LS-24 拆票之一，backend lane 先行）— app 內帳號刪除 RPC：delete_my_account()
--
-- 背景：PLAN §9-A2／App Store Guideline 5.1.1(v)。§5「每個 family 必須恆有 ≥1 位
-- owner...這條約束是帳號刪除流程能成立的基礎」——本票是這句話第一次真正派上用場：
-- 呼叫者若是某家庭唯一 owner、且家庭還有其他成員，必須先走既有的 owner 交接路徑
-- （直接 UPDATE family_members.role，本票不重做，見 API.md §3 family_members）才能
-- 刪除帳號。
--
-- 範圍（票文 1-4，本 migration 只做「資料面」）：
--   1. 唯一 owner 且家庭還有其他成員 → 拒絕，新錯誤碼 LS050，DETAIL 帶 JSON 陣列
--      列出需要轉移的家庭（[{family_id, family_name}, ...]）。
--   2. 呼叫者是某家庭的唯一成員（因此也是唯一 owner——不可能同時滿足情況 1 的
--      擋門條件，情況 1 要求「家庭還有其他成員」）→ 整個家庭連同底下資料一併
--      刪除（cascade；families 是 albums／diaries／media／album_media／diary_media／
--      comments／reactions／invites／join_requests／content_reports／blocked_users／
--      feed_items／family_members 的共同上游，全部 on delete cascade，見
--      20260822120000_init_schema.sql）。Storage 物件的清理契約見下方與
--      docs/API.md §6：本 migration 只確保 media 列被清乾淨，bucket 裡對應的實體
--      檔案會依既有的孤兒物件對帳定義（PLAN §5「離線對帳」）變成孤兒，實際清除
--      批次是另一張票（LS-143 票文「不做」段落）。
--   3. 其餘家庭（呼叫者不是唯一成員——可能是 owner-with-co-owner／member／viewer）
--      → 自己的 diaries／albums／comments 依既有 soft delete 策略處理
--      （deleted_at=now()、deleted_by=自己，語意等同作者自己呼叫
--      set_diary_deleted／set_album_deleted／set_comment_deleted 自刪——
--      private.enforce_deletion_attribution() trigger 會再次推導/覆寫同一個值，
--      見 20260825040000_deletion_attribution.sql 檔頭「三支 set_*_deleted RPC
--      的函式本體因此完全不需要修改」那段，這裡援用同一個機制），然後離開家庭
--      （DELETE family_members）；家庭本身與其他成員的內容完全不受影響。
--      media／reactions／device_tokens 刻意不在本 RPC 觸碰的範圍，理由見下方
--      「規格分歧與取捨 b)」。
--   4. 標記 profiles.deletion_requested_at；auth.users 的實際刪除是另一支以
--      service_role 執行的流程（Edge Function，另票——見下方「規格分歧與取捨 a)」），
--      不在本 migration 範圍。
--
-- 規格分歧與取捨（handoff 已列，這裡留一份供之後改動的人對照）：
--   a) 票文給了「RPC 只標記 deletion_requested_at，實際刪除交 Edge Function」與
--      「本票直接做完 Edge Function」兩個選項，要求擇一並說明。選前者（最保守、
--      最容易回退）：repo 目前沒有任何 supabase/functions/ 部署單元（本票是第一個
--      需要它的功能），把「新增一種部署基礎設施」跟「這支 RPC 的資料面邏輯」綁在
--      同一張票會讓 review 面同時扛兩種完全不同性質的風險（SQL migration vs. Deno
--      Edge Function 的 service_role 金鑰使用），且票文本身允許「明確另票」。
--      `profiles.deletion_requested_at` 就是交接這兩張票的唯一契約欄位。
--   b) media／reactions／device_tokens 不比照 diaries/albums/comments 軟刪：
--      - media 沒有 deleted_by 欄位、也沒有「使用者自刪單張照片」的既有 RPC——沒有
--        「既有策略」可以「依循」，動它是本票沒有依據的新設計，留給後續 Storage
--        清理票（票文「不做」段落）一併考慮，不在此自行擴大範圍。
--      - reactions 沒有 soft delete 概念（toggle 語意，非二元存在／已刪），家庭
--        真正消失時（情況 2）跟著 cascade 刪掉；家庭存活時（情況 3）留著只是一個
--        不再對應活躍成員的 +1，跟「作者已離開但他的留言/日記仍看得到內容只是
--        deleted_by 指不到人」是同一種既有的殘影（FK on delete set null 本來就會
--        製造這種殘影），不構成新問題，也不是本票要解的問題。
--      - device_tokens 的 FK 是 on delete cascade，`auth.users` 真正被刪除時會
--        自動清掉；本 RPC 只標記 deletion_requested_at，profiles 這時還沒有真的
--        消失，沒有必要提前處理裝置 token。
--   c) 唯一 owner 守門用新錯誤碼 LS050（不重用既有的 LS001）：兩者是同一個不變量
--      的不同觸發路徑，但 LS001 的既有語意是「你剛剛送出的操作本身違反了不變量」
--      （直接 DELETE/UPDATE family_members），這裡是「你想刪帳號，但目前的家庭
--      狀態不允許」，且票文明確要求「回傳需轉移的家庭清單」——LS001 從未帶過
--      結構化 payload，也沒有理由現在才加，這裡用 DETAIL 帶 JSON 是本 RPC 獨有的
--      契約，記在 docs/API.md §4 對應段落，不影響 LS001 既有的呼叫端處理方式。
--
-- 併發設計（比照 supabase/tests/concurrency/owner_guard_*.sql 的 LS-6／LS-15 場景，
-- 見下方 delete_account_race_*.sql）：本 RPC 唯一新增的鎖需求是 family_members 的
-- DELETE 觸發既有的 private.enforce_family_has_owner() statement-level trigger
-- （FOR NO KEY UPDATE、family_id 遞增序，LS-6／LS-15 既有設計，本 RPC 沒有引入任何
-- 新的鎖或新的取鎖順序）。上面第 1 步的守門查詢刻意不額外加鎖：它只是提早給一個
-- 對使用者友善、附家庭清單的錯誤；真正防止「家庭剩 0 位 owner」的權威防線始終是
-- 上述既有 trigger。兩者之間存在一個極短的競態窗口（例如兩位共同 owner 幾乎同時
-- 呼叫本 RPC）——最壞結果是其中一邊的 DELETE 被 trigger 擋下、回 LS001 而不是
-- LS050，整個呼叫（含已執行的軟刪與情況 2 的家庭刪除）隨事務一起回滾，使用者需要
-- 重試；不會有資料損壞或死鎖，重試時上面的守門查詢會用最新狀態正確分流。
-- ---------------------------------------------------------------------------

alter table public.profiles add column deletion_requested_at timestamptz;

comment on column public.profiles.deletion_requested_at is
  '呼叫 delete_my_account() 成功後寫入（LS-143）。NULL＝未請求刪除。實際刪除'
  ' auth.users（cascade 掉這一列）是另一支以 service_role 執行的流程，這一欄'
  '只是資料面的請求標記，不是刪除本身；authenticated 對這一欄沒有 UPDATE 權限'
  '（見下方 REVOKE/GRANT），只能透過 delete_my_account() 寫入。';

-- authenticated 對 public.profiles 原本是整表 UPDATE grant（20260822120000_init_schema.sql
-- 的 `grant select, insert, update on public.profiles to authenticated;`）——對一個
-- 已經有整表 grant 的角色另外下欄位級 REVOKE 是 no-op（relacl 整表授權與 attacl 欄位
-- 授權是 OR 語意，REVOKE 欄位級只動得到 attacl，動不到 relacl；
-- 20260825040000_deletion_attribution.sql 檔頭「N1/N2 根治」段落已用 Supabase CLI
-- 映像實測記錄過同一個陷阱）：必須先收回整表、只重開允許直接編輯的欄位，
-- deletion_requested_at 才會真的擋下直接 UPDATE，不然任何登入者都能繞過下面
-- delete_my_account() 的全部檢查，直接把自己標成「已請求刪除」。這也讓 profiles
-- 跟上 families／media／albums／diaries／comments 等表既有的「先收回整表、只開放
-- 允許欄位」慣例（deletion_attribution.sql 同段註解：這不是新發明，是既有模式）。
revoke update on public.profiles from authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking jsonb;
begin
  if v_uid is null then
    raise exception '未登入，無法刪除帳號' using errcode = '42501';
  end if;

  -- 情況 1：呼叫者是某家庭的唯一 owner、且家庭還有其他成員 → 一次列出全部這樣的
  -- 家庭並拒絕（不是找到第一個就報，使用者一次看到所有要處理的家庭）。
  select jsonb_agg(
           jsonb_build_object('family_id', fm.family_id, 'family_name', f.name)
           order by f.name, fm.family_id
         )
    into v_blocking
    from public.family_members fm
    join public.families f on f.id = fm.family_id
   where fm.user_id = v_uid
     and fm.role = 'owner'
     and exists (
       select 1 from public.family_members other
        where other.family_id = fm.family_id and other.user_id <> v_uid
     )
     and not exists (
       select 1 from public.family_members co
        where co.family_id = fm.family_id and co.role = 'owner' and co.user_id <> v_uid
     );

  if v_blocking is not null then
    raise exception
      '你是家庭的唯一 owner，且家庭還有其他成員，請先把 owner 身份轉移給其他成員才能刪除帳號'
      using errcode = 'LS050', detail = v_blocking::text;
  end if;

  -- 情況 2：呼叫者是唯一成員的家庭 → 整個家庭連同資料一併刪除（cascade）。通過
  -- 上面的守門之後，這裡判斷到的「唯一成員」家庭不可能與情況 1 重疊。
  delete from public.families f
   where f.id in (
     select fm.family_id from public.family_members fm
      where fm.user_id = v_uid
        and not exists (
          select 1 from public.family_members other
           where other.family_id = fm.family_id and other.user_id <> v_uid
        )
   );

  -- 情況 3：其餘家庭——自己的內容依既有 soft delete 策略處理，家庭不受影響。上面
  -- 情況 2 的 DELETE 若已經處理過某個家庭，這裡三句 UPDATE 的 family_id 子查詢
  -- 自然不會再包含它（成員列隨家庭一起 cascade 掉了，下面子查詢查不到）。
  update public.diaries d
     set deleted_at = now(), deleted_by = v_uid
   where d.author_id = v_uid
     and d.deleted_at is null
     and d.family_id in (
       select fm.family_id from public.family_members fm where fm.user_id = v_uid
     );

  update public.albums a
     set deleted_at = now(), deleted_by = v_uid
   where a.created_by = v_uid
     and a.deleted_at is null
     and a.family_id in (
       select fm.family_id from public.family_members fm where fm.user_id = v_uid
     );

  update public.comments c
     set deleted_at = now(), deleted_by = v_uid
   where c.author_id = v_uid
     and c.deleted_at is null
     and c.family_id in (
       select fm.family_id from public.family_members fm where fm.user_id = v_uid
     );

  -- 離開剩餘家庭：一句 DELETE 涵蓋呼叫者在情況 2 之外的每個家庭。見上方「併發
  -- 設計」——這句話觸發的既有 trigger 才是「家庭必須恆有 ≥1 owner」的權威防線。
  delete from public.family_members where user_id = v_uid;

  -- 情況 4：標記已請求刪除。auth.users 的實際刪除由另一支以 service_role 執行的
  -- 流程完成（另票，不在本 migration 範圍——見檔頭「規格分歧與取捨 a)」）。
  update public.profiles set deletion_requested_at = now() where id = v_uid;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
