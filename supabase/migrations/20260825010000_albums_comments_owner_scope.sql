-- LS-52 — albums_update／comments_update owner 分支不限欄位收斂
--
-- 來源：PR #60（LS-48）merge review 指出，LS-48 修的 diaries_update 同形狀洞，
-- albums_update（20260822120200_rls_policies.sql:232-240）與 comments_update
-- （同檔案 comments 段，300-308 行）同樣存在：owner 分支的 USING/WITH CHECK
-- 完全沒有限制「能改哪些欄位」，owner 因此可以直接改寫別人相簿的
-- title／child_id／cover_media_id，或別人留言的 body——超出 PLAN §10
-- 「Owner 移除內容」授權的範圍（§10 給 owner 的權力止於「移除」，不含「改寫別人
-- 寫的東西」）。這個 migration 不改動 20260822120200_rls_policies.sql 本身（規約
-- 禁止改舊 migration），舊檔案裡 albums_update／comments_update 的原始文字（含
-- 「owner 可移除任何留言」那句註解）已被本檔的 ALTER POLICY 取代，以本檔說明為準。
--
-- ---------------------------------------------------------------------------
-- 修法裁量：欄位級 grant（選項 a）vs RPC（選項 b，本檔採用）——過程附實測證據
--
-- 這個 codebase 已有三個用 column-level grant 收斂 owner 可寫欄位的先例
-- （families_update 只給 name、family_members_update 只給 role/can_upload、
-- content_reports_update 只給 status，見 20260822120000_init_schema.sql 與
-- 20260823010000_join_approval.sql）。這三個先例能用 column-level grant，是因為
-- 它們的 UPDATE policy 只有「一個分支」——不管判準是什麼，能通過 policy 的每一列，
-- 允許改的欄位集合都相同，column grant（對整個 authenticated 角色一視同仁、不分
-- 是哪一列）剛好對得上。media_update 雖然有兩個分支（owner／uploader），但兩分支
-- 允許的欄位集合是同一組（taken_at/deleted_at/width/height），一樣不需要「依列
-- 而異」的欄位限制。
--
-- albums_update／comments_update 不是這個形狀：兩個分支允許的欄位集合本來就該
-- 不同——作者改自己的內容應該能動 title／body 等所有欄位，owner 改別人的應該
-- 只能動 deleted_at。這兩個分支套用在同一個角色（authenticated）身上，
-- column-level grant 是角色層級的靜態設定，物理上表達不出「依這一列是不是我自己
-- 建立的，給不同欄位集合」這種依列而異的限制，這條路本來就走不通，不必再展開。
--
-- 剩下的問題是：RLS 的 WITH CHECK 能不能直接表達「這個分支只准改 deleted_at，
-- 其他欄位必須跟改之前一樣」？WITH CHECK 只看得到「這一列改完之後」的新值，
-- 沒有語法直接引用「改之前」的舊值；本機用 Supabase CLI 本機開發映像
-- （PostgreSQL 17.6）實測兩種寫法：
--   1. WITH CHECK 裡直接對同一張表寫自我 join 子查詢取舊值
--      （`title is not distinct from (select t2.title from albums t2 where t2.id = albums.id)`）
--      ——**Postgres 直接拒絕**：`42P17 infinite recursion detected in policy for
--      relation`（評估這張表自己的 policy 需要再查一次這張表，遞迴偵測擋下，
--      不分改的是不是合法欄位，連合法的 deleted_at-only 更新也一起被擋）。
--   2. 把同一段自我查詢包成 `private.` 的 SECURITY DEFINER 函式（跟本檔開頭
--      family_ids() 那五支函式破遞迴的手法一模一樣）——**這個技巧實測真的有效**：
--      owner 改別人相簿的 title 會被 WITH CHECK 擋下、噴出貨真價實的
--      `42501 new row violates row-level security policy`；owner 改別人相簿的
--      deleted_at（不動 title）則正常放行。
--
-- 換句話說，「(a) 在 RLS 無法表達」這個前提對**純 RLS**成立（寫法 1 直接遞迴
-- 擋下），但工程上其實有解——寫法 2 是可行的。決定不用寫法 2、仍然選 RPC
-- （選項 b），理由不是「做不到」而是「這樣做對未來的 schema 演進不安全」：
-- 寫法 2 要求 WITH CHECK 逐欄列舉「除了 deleted_at 以外，其他每一欄都要跟舊值
-- 一樣」——albums 有 title／child_id／cover_media_id 三欄要列，日後這張表若加
-- 新欄位（例如未來加 description），這份列舉不會自動涵蓋新欄位，除非有人記得
-- 回頭補一行 IS NOT DISTINCT FROM；忘記補的後果就是新欄位悄悄變成 owner
-- 可寫——跟這張票要修的洞是同一種錯，只是換一個欄位、晚一點發生，而且不會有
-- 任何測試或 gate 告訴你這件事發生了。RPC 的寫法是「函式裡的 UPDATE 語句只
-- SET deleted_at 一欄」，這件事由程式碼的形狀保證，不是靠列舉維護，日後加欄位
-- 不需要回頭改這支函式、也不可能因為忘了改而悄悄多開一個洞。這與 LS-48 對
-- diaries 選 RPC 是同一個理由（該檔案的等價說明段，這裡不重複整段展開）。
--
-- 因此比照 LS-48：owner 對別人內容的操作收斂成 SECURITY DEFINER RPC
-- （`set_album_deleted`／`set_comment_deleted`），函式內部只 SET deleted_at
-- 一欄，物理上不可能被拿來竄改內容。
--
-- 與 diaries 收斂的差異（刻意保留、不是漏做）：diaries 把 INSERT／UPDATE整個
-- 收斂成 RPC-only（三支 RPC，直接 INSERT/UPDATE 對所有角色都被 revoke）。這裡
-- 的洞只在「owner 分支」，作者改自己內容的那個分支本來就沒有問題——不擴大變更
-- 範圍，albums_update／comments_update 的作者分支維持直接 UPDATE、grant 也
-- 原封不動（不 revoke），只把 owner 分支從 policy 移除、改走新增的兩支 RPC。
-- albums／comments 的 INSERT policy、albums_delete／comments_delete（硬刪，
-- owner-only）都不在本票範圍內，未受影響。
--
-- 這個選擇也帶來一個要交代清楚的副作用：owner 直接對別人的相簿／留言下
-- `UPDATE ... SET title = ...`（不透過 RPC）不會拿到 42501——USING 子句的
-- 兩個分支都比對不上那一列（他不是作者也走不到 owner 分支了），Postgres 對
-- UPDATE 的標準行為是把比對不上 USING 的列直接排除在外，**影響 0 列，不噴
-- 任何錯誤**（本機同一次實測連帶驗證：拿掉 owner 分支後對別人的列下 UPDATE，
-- `GET DIAGNOSTICS row_count` 是 0，內容逐字不變，沒有 exception）。這不是
-- 沒修好，是 Postgres RLS 對「這列根本不在你能動的範圍」的標準反應，跟你對一個
-- 不存在的 id 下 UPDATE 一樣——不洩漏「這列存在但你不准動」與「這列不存在」的
-- 差異，反而是比噴錯更保守的資訊揭露（同一份考量，approve_join 的錯誤碼順序
-- 註解也討論過）。真正會噴出 42501 的是本檔新增的兩支 RPC（owner 走這裡才是
-- 「有意的」互動介面），下面的測試檔對兩種行為都各自驗證，不會拿 RPC 的斷言
-- 硬套到直接 UPDATE 的情境上。
-- ---------------------------------------------------------------------------

alter policy albums_update on public.albums
  using (
    created_by = (select auth.uid())
    and family_id in (select private.contributor_family_ids())
  )
  with check (
    created_by = (select auth.uid())
    and family_id in (select private.contributor_family_ids())
  );

alter policy comments_update on public.comments
  using (
    author_id = (select auth.uid())
    and family_id in (select private.family_ids())
  )
  with check (
    author_id = (select auth.uid())
    and family_id in (select private.family_ids())
  );

comment on table public.albums is
  '家庭相簿。直接 .update() 只對建立者本人、仍是該家庭 owner/member 時放行'
  '（albums_update policy，LS-52 收斂）——owner 對別人建立的相簿不再能透過直接'
  ' UPDATE 改寫任何欄位；owner 對別人相簿唯一剩下的操作是軟刪／還原，走'
  ' public.set_album_deleted() RPC（LS-52），只碰 deleted_at 一欄。硬刪'
  '（DELETE）仍是 20260822120200_rls_policies.sql 既有的 albums_delete'
  ' policy（僅 owner），未受本檔影響。';

comment on table public.comments is
  '家庭留言。直接 .update() 只對作者本人、仍是該家庭任一角色成員時放行'
  '（comments_update policy，LS-52 收斂）——owner 對別人留言不再能透過直接'
  ' UPDATE 改寫 body；owner 對別人留言唯一剩下的操作是軟刪／還原，走'
  ' public.set_comment_deleted() RPC（LS-52），只碰 deleted_at 一欄。硬刪'
  '（DELETE）仍是既有的 comments_delete policy（僅 owner），未受本檔影響。';

-- ---------------------------------------------------------------------------
-- set_album_deleted：owner 對別人相簿唯一剩下的操作——軟刪／還原。
--
-- 作者分支的判準逐字沿用收斂前 albums_update 作者分支的判準
-- （created_by = 我 and family_id in contributor_family_ids()）：這支 RPC
-- 對作者而言是「多一條路徑」而不是唯一路徑（作者仍可直接 UPDATE 軟刪自己的
-- 相簿），刻意讓兩條路徑的授權範圍一致，不夾帶擴權或縮權。
--
-- 錯誤碼延續 LS022（get_family_timeline）之後的序號：LS023＝相簿不存在。
-- 授權失敗沿用既有慣例用裸 42501（不像 update_diary_entry 那樣另開專屬碼），
-- 因為這支 RPC 只做一件事（切換 deleted_at），不像 update_diary_entry 需要
-- 用錯誤碼區分「不是作者」與「作者但已離開家庭」給呼叫端不同語意——這裡兩種
-- 情況對 UI 而言都是同一句話：「你不能移除／還原這本相簿」。
-- ---------------------------------------------------------------------------
create or replace function public.set_album_deleted(
  p_album_id uuid,
  p_deleted boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_album public.albums%rowtype;
  v_is_owner boolean;
  v_is_author_contributor boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除或還原相簿' using errcode = '42501';
  end if;

  select a.* into v_album from public.albums a where a.id = p_album_id for update;

  if not found then
    raise exception '相簿不存在' using errcode = 'LS023';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_album.family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_album.family_id and m.user_id = v_uid and m.role in ('owner', 'member')
  ) into v_is_author_contributor;

  if not v_is_owner
     and (v_album.created_by is distinct from v_uid or not v_is_author_contributor) then
    raise exception '只有建立者本人（且仍是該家庭 owner/member）或該家庭的 owner 能移除／還原這本相簿'
      using errcode = '42501';
  end if;

  update public.albums a
     set deleted_at = case when p_deleted then now() else null end
   where a.id = p_album_id;
end;
$$;

revoke execute on function public.set_album_deleted(uuid, boolean) from public, anon;
grant execute on function public.set_album_deleted(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- set_comment_deleted：同上，comments 版本。作者分支比照既有 comments_update
-- 的作者分支判準——只要求仍是該家庭「任何角色」的成員（family_ids()，不是
-- contributor_family_ids()）。這不是新放寬，是沿用收斂前 comments_update
-- 作者分支本來就有的判準：Viewer 也能留言（PLAN §3），留言的作者分支從一開始
-- 就沒有排除 viewer，這裡原樣保留，不在本票夾帶擴權或縮權。
--
-- 錯誤碼：LS024＝留言不存在。
-- ---------------------------------------------------------------------------
create or replace function public.set_comment_deleted(
  p_comment_id uuid,
  p_deleted boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_comment public.comments%rowtype;
  v_is_owner boolean;
  v_is_current_member boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除或還原留言' using errcode = '42501';
  end if;

  select c.* into v_comment from public.comments c where c.id = p_comment_id for update;

  if not found then
    raise exception '留言不存在' using errcode = 'LS024';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_comment.family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_comment.family_id and m.user_id = v_uid
  ) into v_is_current_member;

  if not v_is_owner
     and (v_comment.author_id is distinct from v_uid or not v_is_current_member) then
    raise exception '只有作者本人（且仍是該家庭成員）或該家庭的 owner 能移除／還原這則留言'
      using errcode = '42501';
  end if;

  update public.comments c
     set deleted_at = case when p_deleted then now() else null end
   where c.id = p_comment_id;
end;
$$;

revoke execute on function public.set_comment_deleted(uuid, boolean) from public, anon;
grant execute on function public.set_comment_deleted(uuid, boolean) to authenticated;
