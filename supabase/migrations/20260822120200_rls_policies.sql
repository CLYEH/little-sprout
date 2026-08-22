-- LS-6 — Row Level Security
--
-- PLAN §5 的硬規定：
--   「policy 一律檢查 family_id IN (使用者所屬家庭)。但不要直接內嵌子查詢——
--     family_id IN (SELECT ... FROM family_members WHERE user_id = auth.uid()) 會對每一列重算。
--     包成 STABLE SECURITY DEFINER 函式。」
--
-- 為什麼包成函式就不會 per-row 重算：函式沒有參數、被標成 STABLE，
-- 規劃器可以把 `family_id IN (SELECT private.family_ids())` 收斂成一次性的 InitPlan／hashed SubPlan，
-- 整個查詢只算一次；直接內嵌的子查詢因為引用了外層列，會變成 correlated SubPlan，每列都跑一次。
-- 這條性質由 supabase/tests/50_rls_plan_no_percall_subquery.sql 用 5 萬列實測把關（不是靠相信註解）。
--
-- SECURITY DEFINER 也是必要的：policy 判斷需要讀 family_members，
-- 但 family_members 自己也有 RLS，直接查會遞迴。definer 以表擁有者身分執行、繞過 RLS，切斷遞迴。
-- 每個函式都 `set search_path = ''` 並全名限定，避免被呼叫端的 search_path 挾持（definer 的標準防護）。

-- ---------------------------------------------------------------------------
-- 輔助函式：使用者的四種 family 集合（對應 PLAN §3 的角色表）
-- ---------------------------------------------------------------------------

-- 讀取權：我所屬的所有家庭（任何角色）
create or replace function private.family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m where m.user_id = auth.uid();
$$;

-- 管理權：我是 owner 的家庭（成員管理、邀請、孩子檔案、硬刪內容、處理檢舉）
create or replace function private.owned_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid() and m.role = 'owner';
$$;

-- 產出內容權：owner 或 member（§3：Viewer 只能看與留言）
create or replace function private.contributor_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid() and m.role in ('owner', 'member');
$$;

-- 上傳權：owner 恆可；member 看 can_upload（§3：可由 Owner 逐人關閉）
create or replace function private.uploadable_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid()
     and (m.role = 'owner' or (m.role = 'member' and m.can_upload));
$$;

-- 我看得到的 profile：我自己，以及與我同家庭的人（留言／上傳者要顯示名字與頭像）。
-- 不開放全表：這是私密 app，陌生使用者的顯示名稱沒有理由對所有人可見。
create or replace function private.peer_profile_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid()
  union
  select m.user_id from public.family_members m
   where m.family_id in (
     select mine.family_id from public.family_members mine where mine.user_id = auth.uid()
   );
$$;

grant execute on function
  private.family_ids(),
  private.owned_family_ids(),
  private.contributor_family_ids(),
  private.uploadable_family_ids(),
  private.peer_profile_ids()
to authenticated;

-- ---------------------------------------------------------------------------
-- 啟用 RLS（16 張表無一例外）
-- ---------------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.families         enable row level security;
alter table public.family_members   enable row level security;
alter table public.invites          enable row level security;
alter table public.children         enable row level security;
alter table public.media            enable row level security;
alter table public.albums           enable row level security;
alter table public.album_media      enable row level security;
alter table public.diaries          enable row level security;
alter table public.diary_media      enable row level security;
alter table public.comments         enable row level security;
alter table public.reactions        enable row level security;
alter table public.device_tokens    enable row level security;
alter table public.feed_items       enable row level security;
alter table public.content_reports  enable row level security;
alter table public.blocked_users    enable row level security;

-- 註：auth.uid() 一律寫成 (select auth.uid())。auth.uid() 是 STABLE 不是 IMMUTABLE，
-- 直接寫在 qual 裡會逐列呼叫；包成純量子查詢才會被提成 InitPlan 算一次。

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (id in (select private.peer_profile_ids()));
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
-- 沒有 delete policy：帳號刪除（§9-A2）走 auth 側，由 service_role 刪 auth.users 後 cascade，
-- 不開放客戶端直接刪 profile（會留下沒有 profile 的 auth 帳號）。

-- ---------------------------------------------------------------------------
-- families
-- ---------------------------------------------------------------------------
create policy families_select on public.families for select to authenticated
  using (
    id in (select private.family_ids())
    -- created_by 這一支是為了 `insert ... returning`：成員列是 AFTER INSERT trigger 產生的，
    -- RETURNING 投影發生在 AFTER trigger 之前，那個瞬間建立者還不在 family_members 裡，
    -- 只靠 family_ids() 會讓「建立家庭」整條路徑噴 42501。supabase-swift 預設就是
    -- PostgREST 的 return=representation，§9-C5「新使用者必須能自己建立家庭」會直接壞掉。
    -- 代價：建立者離開家庭後仍看得到這一列（只有家庭名稱）。相對於建不了家庭，這個代價可以接受。
    or created_by = (select auth.uid())
  );
-- 任何登入者都能開新家庭（§9-C5：陌生人下載後必須能自己建立家庭，否則觸犯 Guideline 4.2）
create policy families_insert on public.families for insert to authenticated
  with check (created_by = (select auth.uid()));
-- 只有 owner 能改，且 column grant 只給了 name：額度與用量改不到（§10-A）
create policy families_update on public.families for update to authenticated
  using (id in (select private.owned_family_ids()))
  with check (id in (select private.owned_family_ids()));
-- 沒有 delete policy：刪家庭會連坐所有人的照片，Phase 1 不需要，先不開。

-- ---------------------------------------------------------------------------
-- family_members
-- ---------------------------------------------------------------------------
create policy family_members_select on public.family_members for select to authenticated
  using (true);
-- 已知的過寬之處：owner 可以直接把任何 user_id 塞進自家成員名單，不必經過邀請碼。
-- Phase 1-2 的「以邀請碼加入家庭」SECURITY DEFINER RPC 落地時要收斂這條 policy
-- （改成只有該 RPC 能寫入，owner 的直接 INSERT 關掉）。現階段沒有 RPC，關掉會讓家庭加不了人。
create policy family_members_insert on public.family_members for insert to authenticated
  with check (family_id in (select private.owned_family_ids()));
create policy family_members_update on public.family_members for update to authenticated
  using (family_id in (select private.owned_family_ids()))
  with check (family_id in (select private.owned_family_ids()));
-- owner 可移除成員；任何人都可以退出自己所在的家庭
-- （最後一位 owner 想退出會被 private.enforce_family_has_owner 擋下，policy 不必重複這個判斷）
create policy family_members_delete on public.family_members for delete to authenticated
  using (
    family_id in (select private.owned_family_ids())
    or user_id = (select auth.uid())
  );

-- ---------------------------------------------------------------------------
-- invites（只有 owner 能管理；以邀請碼加入家庭需要 SECURITY DEFINER RPC，見 Phase 1-2）
-- ---------------------------------------------------------------------------
create policy invites_select on public.invites for select to authenticated
  using (family_id in (select private.owned_family_ids()));
create policy invites_insert on public.invites for insert to authenticated
  with check (family_id in (select private.owned_family_ids()));
create policy invites_update on public.invites for update to authenticated
  using (family_id in (select private.owned_family_ids()))
  with check (family_id in (select private.owned_family_ids()));
create policy invites_delete on public.invites for delete to authenticated
  using (family_id in (select private.owned_family_ids()));

-- ---------------------------------------------------------------------------
-- children（§3：Owner 建立孩子檔案）
-- ---------------------------------------------------------------------------
create policy children_select on public.children for select to authenticated
  using (family_id in (select private.family_ids()));
create policy children_insert on public.children for insert to authenticated
  with check (family_id in (select private.owned_family_ids()));
create policy children_update on public.children for update to authenticated
  using (family_id in (select private.owned_family_ids()))
  with check (family_id in (select private.owned_family_ids()));
create policy children_delete on public.children for delete to authenticated
  using (family_id in (select private.owned_family_ids()));

-- ---------------------------------------------------------------------------
-- media
-- ---------------------------------------------------------------------------
create policy media_select on public.media for select to authenticated
  using (family_id in (select private.family_ids()));
create policy media_insert on public.media for insert to authenticated
  with check (
    family_id in (select private.uploadable_family_ids())
    and uploaded_by = (select auth.uid())
  );
-- soft delete 也是 UPDATE：上傳者可以收回自己的照片，owner 可以處理任何一張（§9-A1 移除內容）
create policy media_update on public.media for update to authenticated
  using (
    family_id in (select private.owned_family_ids())
    or (uploaded_by = (select auth.uid()) and family_id in (select private.uploadable_family_ids()))
  )
  with check (
    family_id in (select private.owned_family_ids())
    or (uploaded_by = (select auth.uid()) and family_id in (select private.uploadable_family_ids()))
  );
-- 硬刪只有 owner（一般刪除請走 deleted_at，§5：長輩誤刪要有救援路徑）
create policy media_delete on public.media for delete to authenticated
  using (family_id in (select private.owned_family_ids()));

-- ---------------------------------------------------------------------------
-- albums
-- ---------------------------------------------------------------------------
create policy albums_select on public.albums for select to authenticated
  using (family_id in (select private.family_ids()));
create policy albums_insert on public.albums for insert to authenticated
  with check (
    family_id in (select private.contributor_family_ids())
    and created_by = (select auth.uid())
  );
create policy albums_update on public.albums for update to authenticated
  using (
    family_id in (select private.owned_family_ids())
    or (created_by = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
  )
  with check (
    family_id in (select private.owned_family_ids())
    or (created_by = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
  );
create policy albums_delete on public.albums for delete to authenticated
  using (family_id in (select private.owned_family_ids()));

-- ---------------------------------------------------------------------------
-- album_media / diary_media（連結表自己帶 family_id，所以不必 join 回母表判斷歸屬）
-- ---------------------------------------------------------------------------
create policy album_media_select on public.album_media for select to authenticated
  using (family_id in (select private.family_ids()));
create policy album_media_insert on public.album_media for insert to authenticated
  with check (family_id in (select private.contributor_family_ids()));
create policy album_media_update on public.album_media for update to authenticated
  using (family_id in (select private.contributor_family_ids()))
  with check (family_id in (select private.contributor_family_ids()));
create policy album_media_delete on public.album_media for delete to authenticated
  using (family_id in (select private.contributor_family_ids()));

create policy diary_media_select on public.diary_media for select to authenticated
  using (family_id in (select private.family_ids()));
create policy diary_media_insert on public.diary_media for insert to authenticated
  with check (family_id in (select private.contributor_family_ids()));
create policy diary_media_update on public.diary_media for update to authenticated
  using (family_id in (select private.contributor_family_ids()))
  with check (family_id in (select private.contributor_family_ids()));
create policy diary_media_delete on public.diary_media for delete to authenticated
  using (family_id in (select private.contributor_family_ids()));

-- ---------------------------------------------------------------------------
-- diaries
-- ---------------------------------------------------------------------------
create policy diaries_select on public.diaries for select to authenticated
  using (family_id in (select private.family_ids()));
create policy diaries_insert on public.diaries for insert to authenticated
  with check (
    family_id in (select private.contributor_family_ids())
    and author_id = (select auth.uid())
  );
create policy diaries_update on public.diaries for update to authenticated
  using (
    family_id in (select private.owned_family_ids())
    or (author_id = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
  )
  with check (
    family_id in (select private.owned_family_ids())
    or (author_id = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
  );
create policy diaries_delete on public.diaries for delete to authenticated
  using (family_id in (select private.owned_family_ids()));

-- ---------------------------------------------------------------------------
-- comments / reactions（§3：Viewer 也能留言與按愛心）
-- ---------------------------------------------------------------------------
create policy comments_select on public.comments for select to authenticated
  using (family_id in (select private.family_ids()));
create policy comments_insert on public.comments for insert to authenticated
  with check (
    family_id in (select private.family_ids())
    and author_id = (select auth.uid())
  );
-- 作者可編輯／收回自己的留言；owner 可移除任何留言（§9-A1）
create policy comments_update on public.comments for update to authenticated
  using (
    family_id in (select private.owned_family_ids())
    or (author_id = (select auth.uid()) and family_id in (select private.family_ids()))
  )
  with check (
    family_id in (select private.owned_family_ids())
    or (author_id = (select auth.uid()) and family_id in (select private.family_ids()))
  );
create policy comments_delete on public.comments for delete to authenticated
  using (family_id in (select private.owned_family_ids()));

create policy reactions_select on public.reactions for select to authenticated
  using (family_id in (select private.family_ids()));
create policy reactions_insert on public.reactions for insert to authenticated
  with check (
    family_id in (select private.family_ids())
    and user_id = (select auth.uid())
  );
create policy reactions_delete on public.reactions for delete to authenticated
  using (user_id = (select auth.uid()) and family_id in (select private.family_ids()));

-- ---------------------------------------------------------------------------
-- device_tokens（與 family 無關，只認本人）
-- ---------------------------------------------------------------------------
create policy device_tokens_select on public.device_tokens for select to authenticated
  using (user_id = (select auth.uid()));
create policy device_tokens_insert on public.device_tokens for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy device_tokens_update on public.device_tokens for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy device_tokens_delete on public.device_tokens for delete to authenticated
  using (user_id = (select auth.uid()));

-- 「同一支裝置換帳號登入」必須走這支 RPC，直接的 INSERT／UPSERT／DELETE 三條路徑全都走不通：
--   INSERT  → token 是 PK，舊列還在，噴 23505
--   UPSERT  → on conflict 的 UPDATE 要通過舊列的 USING（user_id = 我），舊列屬於別人，噴 42501
--   DELETE  → 舊列不屬於我，policy 讓它影響 0 列
-- 三條都死的後果不是「不方便」而是跨家庭外洩：舊帳號的 token 綁定留在資料庫裡，
-- 新持有者裝置上會繼續收到舊帳號所屬家庭的推播。
-- SECURITY DEFINER 是必要的：接手的前提就是刪掉「別人的」那一列，那正是 RLS 擋住的事。
-- 這不是提權漏洞——push token 本身就是裝置持有者才拿得到的憑據。
create or replace function public.register_device_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception '未登入，無法註冊裝置 token' using errcode = '42501';
  end if;

  delete from public.device_tokens d where d.token = p_token;

  insert into public.device_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), p_platform::public.device_platform, now());
end;
$$;

-- SECURITY DEFINER 函式預設對 PUBLIC 開放 EXECUTE，先收回再逐一發放。
-- anon 要單獨寫出來：Supabase 的 default privileges 會對 public schema 的新函式
-- 額外授一份「明確的」EXECUTE 給 anon/authenticated，那份不會被 REVOKE … FROM PUBLIC 帶走。
-- 沒有這一句的話，未登入者可以呼叫這支 definer 函式改寫任何 token 的綁定。
revoke execute on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- feed_items（只讀。寫入權連 grant 都沒給，只有 trigger（definer）能動）
-- ---------------------------------------------------------------------------
create policy feed_items_select on public.feed_items for select to authenticated
  using (family_id in (select private.family_ids()));

-- ---------------------------------------------------------------------------
-- content_reports（§9-A1、§10-B）
-- 檢舉人看得到自己送出的；owner 看得到自家的；平台方用 service_role 跨家庭看（§10-B：
-- 被檢舉的很可能就是 owner 本人，所以不能只讓 owner 自理）。
-- ---------------------------------------------------------------------------
create policy content_reports_select on public.content_reports for select to authenticated
  using (
    reporter_id = (select auth.uid())
    or family_id in (select private.owned_family_ids())
  );
create policy content_reports_insert on public.content_reports for insert to authenticated
  with check (
    family_id in (select private.family_ids())
    and reporter_id = (select auth.uid())
  );
-- owner 對檢舉只能做一件事：標記為已處理（column grant 也只給了 status）。
-- 不開放 dismissed（駁回）：被檢舉的很可能就是 owner 本人（§10-B），
-- 讓他能一鍵駁回自己身上的檢舉，等於 UGC 檢舉機制不存在。駁回保留給平台方（service_role）。
create policy content_reports_update on public.content_reports for update to authenticated
  using (family_id in (select private.owned_family_ids()))
  with check (
    family_id in (select private.owned_family_ids())
    and status = 'resolved'
  );

-- ---------------------------------------------------------------------------
-- blocked_users（§9-A1）：只有封鎖者本人看得到與能操作；被封鎖者不該知道自己被封鎖
-- ---------------------------------------------------------------------------
create policy blocked_users_select on public.blocked_users for select to authenticated
  using (blocker_id = (select auth.uid()) and family_id in (select private.family_ids()));
create policy blocked_users_insert on public.blocked_users for insert to authenticated
  with check (blocker_id = (select auth.uid()) and family_id in (select private.family_ids()));
create policy blocked_users_delete on public.blocked_users for delete to authenticated
  using (blocker_id = (select auth.uid()) and family_id in (select private.family_ids()));

-- ---------------------------------------------------------------------------
-- private schema 的 EXECUTE 收斂
--
-- 函式建立時預設 `grant execute ... to public`，而 authenticated 是 PUBLIC 的一員、
-- 又持有 schema private 的 USAGE，因此在收回之前，登入者可以直接呼叫任何一支 private 函式——
-- 包括 SECURITY DEFINER 的 trigger 函式（private.media_storage_sync() 等）。
-- 本檔開頭那幾支集合函式是刻意開放的，用明確的 grant 表達；其餘一律不開放。
--
-- 這一段必須放在檔尾：triggers.sql（先執行）與本檔的所有 private 函式都要被涵蓋到。
-- ---------------------------------------------------------------------------
-- REVOKE ... FROM PUBLIC 只拿掉 PUBLIC 那份 ACL，
-- 檔案開頭給那五支集合函式的 `grant execute ... to authenticated` 是獨立的一份，不受影響。
revoke execute on all functions in schema private from public;

-- 為什麼這裡沒有配一句 `alter default privileges in schema private revoke execute on functions
-- from public`：那句話在 PostgreSQL 是 no-op，寫了會給人「未來的函式也守住了」的錯覺。
-- 物件建立時的 ACL = acldefault()（函式的內建預設就含 PUBLIC EXECUTE）與 pg_default_acl 的合併，
-- schema 範圍的條目只能「加」不能「減」內建預設；能取代內建預設的只有不指定 schema 的全域條目，
-- 而全域條目會一併改到 public schema 未來所有 RPC 的預設授權，副作用超出本票範圍。
-- 實測（PostgreSQL 16）：下了 schema 範圍的 revoke 後 pg_default_acl 不會產生任何列，
-- 新建的 private 函式 proacl 仍為 NULL（＝PUBLIC 可執行）。
--
-- 取代的機械式 gate：supabase/tests/60_default_privileges.sql 會列舉 schema private 的
-- 每一支函式，只要有任何一支對 PUBLIC 開放 EXECUTE 就失敗。日後新增 private 函式時，
-- 忘了補上面那句 revoke 會被測試擋下，而不是靠人記得。
