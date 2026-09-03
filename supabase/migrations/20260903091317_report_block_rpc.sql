-- LS-149（LS-23 後端切片）——檢舉／封鎖／Owner 移除內容 RPC＋封鎖過濾（時間軸／留言／相簿）。
-- PLAN §9-A1（UGC 三件套）／§10-A（額度查詢）／§10-B（檢舉要進到你看得到的地方）。
--
-- ---------------------------------------------------------------------------
-- 設計裁量總覽（逐項記錄取捨，不只留最終狀態）
--
-- 1. report_content 的參數簽章刻意跟票文字面（`report_content(kind, ref_id, reason)`）不同，
--    改成 `(p_family_id, p_target_type, p_target_id, p_reason)`——比照 create_comment／
--    toggle_reaction 既有的 4 參數慣例（20260825020000_comments_reactions_notifications.sql），
--    理由：(a) 一致性，呼叫端已經很熟這個形狀；(b) 可以直接沿用既有的 LS026（「target 存在但
--    屬於別的家庭」）語意與既有 private.target_family_id() 輔助函式，不必為了「不接受呼叫端
--    指定 family_id」這個更嚴謹但更少見的設計新開一個錯誤碼——本專案的錯誤碼三方對帳
--    （scripts/gates/error-codes-check.sh）連動 iOS 端 LSErrorCode，這張票明確不碰 iOS，
--    新增自訂碼會讓 push-gate 的錯誤碼對帳直接紅、卡死本票，所以整張票刻意只重用既有碼／
--    標準 Postgres 碼，不開新碼。孤兒 target_id（查不到）維持既有裁量放行，與
--    create_comment／toggle_reaction 一致。
-- 2. 「同人同內容去重」用 partial unique index（target_type, target_id, reporter_id）
--    where status='pending' ＋ INSERT ... ON CONFLICT DO NOTHING 做成冪等，不當錯誤處理
--    ——重複檢舉同一內容直接回傳既有那筆 pending 報告的 id，呼叫端不需要特殊處理衝突。
--    只排除 pending：同一人若先前的檢舉已經 resolved，代表內容已被處理過一輪，之後若同一
--    內容又有新狀況，應該能再檢舉一次——不永久排除。
-- 3. block_user／unblock_user 新增為 RPC，但**刻意不收回** blocked_users 既有的直接
--    INSERT／DELETE grant 與 policy（20260822120200_rls_policies.sql 的
--    blocked_users_insert／blocked_users_delete）——票文只要求新增 RPC，既有直接寫入路徑
--    本身已經安全（policy 的 WITH CHECK 恆要求 blocker_id = 呼叫者本人，且
--    blocked_users_not_self 這條 CHECK 約束擋自我封鎖），收回屬於未被要求的額外 scope，
--    留給日後真的有需要（例如要在 RPC 內加「blocked_id 必須是這個家庭當下的成員」這類
--    直接 INSERT 表達不出的驗證）時再另外評估。這兩支 RPC 的價值是冪等（ON CONFLICT DO
--    NOTHING／DELETE 對不存在的列本來就是 no-op）與單一呼叫端入口，不是收斂寫入面。
-- 4. remove_content_as_owner 是純 owner 專用的移除入口（跟 set_album_deleted／
--    set_diary_deleted／set_comment_deleted 允許「owner 或作者本人」不同，這支只認
--    owner——名字就叫 as_owner），內部直接呼叫既有三支 RPC（album／diary／comment），
--    不重寫軟刪邏輯；media 沒有對應的 RPC（media 的軟刪從建表以來就是直接 UPDATE
--    deleted_at 的欄位級 grant，見 docs/API.md §3 media 段），這裡直接對 media 做同樣的
--    UPDATE。**已知不對稱**：album／diary／comment 三種都有 deleted_by 欄位記錄移除者
--    （LS-57），media 沒有這個欄位——這是既有 schema 的既有缺口，不在本票範圍內補（票文
--    寫的是「既有 soft delete＋deleted_by」，media 的既有 soft delete 本來就沒有
--    deleted_by，這裡忠實沿用既有能力，不新增欄位）。移除成功後把該內容全部 pending
--    的檢舉標記 resolved。
-- 5. 封鎖過濾（時間軸／留言／相簿三處）：
--    - 新增 private.blocked_pairs()：無參數、STABLE SECURITY DEFINER，回傳呼叫者封鎖的
--      (family_id, blocked_id) 配對全集——跟 private.family_ids() 等既有集合函式同一個
--      理由（PLAN §5「不要直接內嵌子查詢」）：規劃器可以把它收斂成一次性求值，不必逐列
--      重算；三個過濾點（albums_select／comments_select policy、get_family_timeline、
--      list_comments）共用同一份判斷，不重複造輪子。
--    - albums_select／comments_select 兩條 RLS policy 用 ALTER POLICY 疊加
--      `NOT EXISTS (SELECT 1 FROM private.blocked_pairs() bp WHERE bp.family_id = <table>.family_id
--      AND bp.blocked_id = <table>.created_by/author_id)`——這是「相簿」與「留言」兩處。
--      LS-23 票文提到的「comments SELECT policy 補強……用既有集合函式做，不放應用層」
--      在這裡落地。
--    - get_family_timeline（本身是 SECURITY INVOKER，不是 definer——見既有函式定義）：
--      feed_items 表沒有作者欄位（LS-6 刻意精簡，PLAN §5），新增 private.feed_item_actor_id()
--      （SECURITY DEFINER，依 kind 分流查 albums.created_by／diaries.author_id／
--      media.uploaded_by）取得真正的作者。**為什麼不能讓 get_family_timeline 自己用
--      invoker 身分直接查 albums／diaries／media**：那三張表的 SELECT policy 現在都疊了
--      封鎖過濾（albums 已在本檔加、diaries 未加但道理相同），對一列「本來就該被封鎖過濾掉」
--      的內容，invoker 身分查它的 created_by 會因為 RLS 直接查不到（回 NULL），NOT EXISTS
--      判斷會把「查不到」誤判成「沒有封鎖關係」而放行——definer 繞過這層直接拿到真正的
--      作者 id，只回傳一個 uuid，不構成新的資訊外洩面（這個項目本身看不看得到仍完全由
--      feed_items_select RLS 決定，這支函式只決定「要不要因為封鎖而排除」）。四條靜態分支
--      （不篩 child／篩 child × 有無游標）都加同一個 NOT EXISTS 條件，維持 LS-48 F1 立下的
--      「先篩選＋排序＋LIMIT，才做逐列的額外查詢」規則不變——封鎖過濾条件本身就在篩選
--      階段完成，不是額外一層 LIMIT 後才做的事。
--    - list_comments（本身已經是 SECURITY DEFINER，繞過 comments_select RLS，見既有函式
--      定義的說明）：comments 列本身就帶 author_id，不需要額外查詢，直接在既有的篩選子
--      查詢裡加同一個 NOT EXISTS 條件即可。
--    - **範圍刻意排除**：media_select（單張照片／影片的直接讀取）與 diaries_select 沒有
--      加封鎖過濾——LS-149 票文列的三處是「時間軸／留言／相簿」，media 是相簿內頁的
--      內容而不是獨立瀏覽入口（時間軸已經把它擋住），diaries 的閱讀路徑也不在票文列的
--      三處測項內。這是刻意縮小的範圍，不是遺漏，記在這裡供之後擴大時參考。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 0. private.blocked_pairs()／private.feed_item_actor_id()：封鎖過濾共用的輔助函式
-- ---------------------------------------------------------------------------

create or replace function private.blocked_pairs()
returns table (family_id uuid, blocked_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select bu.family_id, bu.blocked_id
    from public.blocked_users bu
   where bu.blocker_id = auth.uid();
$$;

create or replace function private.feed_item_actor_id(
  p_kind public.feed_kind,
  p_ref_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
begin
  case p_kind
    when 'album' then select a.created_by into v_actor from public.albums a where a.id = p_ref_id;
    when 'diary' then select d.author_id into v_actor from public.diaries d where d.id = p_ref_id;
    when 'media' then select m.uploaded_by into v_actor from public.media m where m.id = p_ref_id;
  end case;
  return v_actor;
end;
$$;

grant execute on function
  private.blocked_pairs(),
  private.feed_item_actor_id(public.feed_kind, uuid)
to authenticated;

-- ---------------------------------------------------------------------------
-- 1. 封鎖過濾：albums_select／comments_select 兩條既有 RLS policy 疊加條件
--
-- 注意：NOT EXISTS 子查詢裡刻意用 `albums.family_id`／`albums.created_by`（表名限定，不是
-- 裸欄名）——private.blocked_pairs() 回傳的欄位本身也叫 family_id，裸欄名在子查詢範圍內
-- 會先比對到子查詢自己 FROM 裡的 bp.family_id（Postgres 的作用域規則：非限定欄名優先在
-- 最內層範圍找），造成 `bp.family_id = family_id` 實際變成恆真的 `bp.family_id = bp.family_id`
-- ——這裡明確限定表名，避免這個隱性 bug。
-- ---------------------------------------------------------------------------

alter policy albums_select on public.albums using (
  family_id in (select private.family_ids())
  and not exists (
    select 1 from private.blocked_pairs() bp
     where bp.family_id = albums.family_id
       and bp.blocked_id = albums.created_by
  )
);

alter policy comments_select on public.comments using (
  family_id in (select private.family_ids())
  and not exists (
    select 1 from private.blocked_pairs() bp
     where bp.family_id = comments.family_id
       and bp.blocked_id = comments.author_id
  )
);

-- ---------------------------------------------------------------------------
-- 2. get_family_timeline：CREATE OR REPLACE 加封鎖過濾（簽章與回傳型別皆不變）
--
-- **實測後修正的設計**（原本每條分支都無條件加 NOT EXISTS + private.feed_item_actor_id()
-- 逐列查詢，本機用既有 supabase/tests/50_rls_plan_no_percall_subquery.sql 的效能資料集
-- 一跑就抓到分支 3（篩 child、無游標）從 136 buffers 惡化到 2015——feed_items／
-- feed_item_children 兩張表都沒有作者欄位，`NOT EXISTS (... bp.blocked_id =
-- private.feed_item_actor_id(f.kind, f.ref_id))` 把一個不透明的 plpgsql 函式呼叫塞進
-- Hash Anti Join 的 Hash Cond，規劃器對「篩 child」這種候選集合較小的分支直接放棄
-- Index Scan Backward＋LIMIT 提早結束，改選「整段掃描候選集合→Hash Anti Join→顯式
-- Sort」，掃描量與候選集合大小成正比，不是本票要的「與 LIMIT 成正比」——跟 list_comments
-- 那次 RLS 疊加造成規劃器誤判是同一種教訓、不同觸發點（這次觸發點是「per-row 函式呼叫」，
-- 不是「RLS 選擇度估計」）。
--
-- 修法：**只有呼叫者在這個家庭真的封鎖過人，才走加了 NOT EXISTS 的變體**——用
-- `v_has_blocks`（一次性 exists 查詢，不是逐列）先判斷。絕大多數呼叫（沒有任何封鎖
-- 關係）完全走原本未改動過的查詢，效能與封鎖過濾上線之前逐字相同；只有真的封鎖過人的
-- 呼叫者才付出額外的 per-row 查找成本（population 小、非熱路徑，可接受）。代價是四條
-- 分支各自變成兩個靜態子變體（有封鎖／無封鎖），程式碼量加倍，但延續 LS-48 F1「每個
-- 分支都是規劃器能獨立求出走索引 plan 的靜態查詢」這條既有規則，不引入新的 OR／動態
-- SQL。50_ 的效能回歸資料集本身沒有封鎖關係（perf 帳號沒有封鎖任何人），因此完整走
-- 「無封鎖」變體，量到的 buffers 與封鎖過濾上線前完全一致。
-- ---------------------------------------------------------------------------

create or replace function public.get_family_timeline(
  p_family_id uuid,
  p_child_id uuid default null,
  p_cursor_occurred_at timestamptz default null,
  p_cursor_ref_id uuid default null,
  p_limit integer default 20
)
returns table (
  kind public.feed_kind,
  ref_id uuid,
  occurred_at timestamptz,
  child_ids uuid[]
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  -- 一次性判斷（不是逐列）：呼叫者在這個家庭封鎖過任何人嗎？絕大多數情況是 false，
  -- 走完全未加過濾條件的原始查詢，效能不受影響（見上方說明）。
  v_has_blocks boolean := exists (
    select 1 from private.blocked_pairs() bp where bp.family_id = p_family_id
  );
begin
  if (p_cursor_occurred_at is null) <> (p_cursor_ref_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_occurred_at／p_cursor_ref_id）'
      using errcode = 'LS022';
  end if;

  if p_child_id is null then
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    end if;
  else
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    end if;
  end if;
end;
$$;

-- 簽章不變（CREATE OR REPLACE 已足夠），但 revoke/grant 兩句是既有慣例，重申一次無害。
revoke execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. list_comments：CREATE OR REPLACE 加封鎖過濾（簽章與回傳型別皆不變）
-- ---------------------------------------------------------------------------

create or replace function public.list_comments(
  p_family_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_cursor_created_at timestamptz default null,
  p_cursor_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  author_id uuid,
  author_display_name text,
  author_avatar_url text,
  body text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
begin
  if v_uid is null then
    raise exception '未登入，無法讀取留言' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能讀取留言' using errcode = '42501';
  end if;

  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_created_at／p_cursor_id）'
      using errcode = 'LS022';
  end if;

  if p_cursor_created_at is null then
    return query
      select c.id, c.author_id, pr.display_name, pr.avatar_url, c.body, c.created_at
        from (
          select cm.id, cm.author_id, cm.body, cm.created_at
            from public.comments cm
           where cm.family_id = p_family_id
             and cm.target_type = v_target_type
             and cm.target_id = p_target_id
             and cm.deleted_at is null
             and not exists (
               select 1 from private.blocked_pairs() bp
                where bp.family_id = cm.family_id
                  and bp.blocked_id = cm.author_id
             )
           order by cm.created_at desc, cm.id desc
           limit v_limit
        ) c
        left join public.profiles pr on pr.id = c.author_id
       order by c.created_at desc, c.id desc;
  else
    return query
      select c.id, c.author_id, pr.display_name, pr.avatar_url, c.body, c.created_at
        from (
          select cm.id, cm.author_id, cm.body, cm.created_at
            from public.comments cm
           where cm.family_id = p_family_id
             and cm.target_type = v_target_type
             and cm.target_id = p_target_id
             and cm.deleted_at is null
             and (cm.created_at, cm.id) < (p_cursor_created_at, p_cursor_id)
             and not exists (
               select 1 from private.blocked_pairs() bp
                where bp.family_id = cm.family_id
                  and bp.blocked_id = cm.author_id
             )
           order by cm.created_at desc, cm.id desc
           limit v_limit
        ) c
        left join public.profiles pr on pr.id = c.author_id
       order by c.created_at desc, c.id desc;
  end if;
end;
$$;

revoke execute on function
  public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. report_content：檢舉（去重）
-- ---------------------------------------------------------------------------

create unique index content_reports_reporter_target_pending_key
  on public.content_reports (target_type, target_id, reporter_id)
  where status = 'pending';

create or replace function public.report_content(
  p_family_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
  v_target_family uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception '未登入，無法檢舉' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能檢舉內容' using errcode = '42501';
  end if;

  -- 同 create_comment／toggle_reaction：查得到且不一致才擋（LS026），查不到（孤兒
  -- target_id）維持既有裁量放行。
  v_target_family := private.target_family_id(v_target_type, p_target_id);
  if v_target_family is not null and v_target_family <> p_family_id then
    raise exception '這個檢舉目標不屬於這個家庭' using errcode = 'LS026';
  end if;

  -- 去重：同一人對同一內容若已有一筆 pending 報告，不重複新增，直接回傳既有那筆的 id。
  insert into public.content_reports (family_id, target_type, target_id, reporter_id, reason)
  values (p_family_id, v_target_type, p_target_id, v_uid, p_reason)
  on conflict (target_type, target_id, reporter_id) where status = 'pending'
  do nothing
  returning id into v_id;

  if v_id is null then
    select r.id into v_id
      from public.content_reports r
     where r.target_type = v_target_type
       and r.target_id = p_target_id
       and r.reporter_id = v_uid
       and r.status = 'pending'
     order by r.created_at desc
     limit 1;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.report_content(uuid, text, uuid, text) from public, anon;
grant execute on function public.report_content(uuid, text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. block_user／unblock_user：封鎖／解除封鎖（見上方設計裁量第 3 點：既有直接寫入
--    路徑刻意保留，這兩支是額外的冪等入口，不是收斂）
-- ---------------------------------------------------------------------------

create or replace function public.block_user(
  p_family_id uuid,
  p_blocked_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception '未登入，無法封鎖' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能封鎖其他成員' using errcode = '42501';
  end if;

  -- 自我封鎖由既有的 blocked_users_not_self CHECK 約束擋下（23514），這裡不重複判斷。
  insert into public.blocked_users (family_id, blocker_id, blocked_id)
  values (p_family_id, v_uid, p_blocked_id)
  on conflict (family_id, blocker_id, blocked_id) do nothing;
end;
$$;

create or replace function public.unblock_user(
  p_family_id uuid,
  p_blocked_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception '未登入，無法解除封鎖' using errcode = '42501';
  end if;

  -- 對不存在的封鎖關係是 no-op（冪等），不報錯——同 unblock 語意本來就該是「確保現在沒有
  -- 封鎖」，呼叫兩次或呼叫在沒封鎖過的人身上都不該是錯誤。
  delete from public.blocked_users
   where family_id = p_family_id
     and blocker_id = v_uid
     and blocked_id = p_blocked_id;
end;
$$;

revoke execute on function public.block_user(uuid, uuid) from public, anon;
grant execute on function public.block_user(uuid, uuid) to authenticated;
revoke execute on function public.unblock_user(uuid, uuid) from public, anon;
grant execute on function public.unblock_user(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. remove_content_as_owner：Owner 移除他人內容（見上方設計裁量第 4 點）
-- ---------------------------------------------------------------------------

create or replace function public.remove_content_as_owner(
  p_target_type text,
  p_target_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
  v_family_id uuid;
  v_is_owner boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除內容' using errcode = '42501';
  end if;

  v_family_id := private.target_family_id(v_target_type, p_target_id);

  -- 找不到內容與「不是 owner」共用同一個 42501：對呼叫端而言兩者都是「這件事辦不到」，
  -- 不需要為了區分這兩種情況新開一個自訂碼（同 LS015／LS020 既有的「不存在或已處理」
  -- 這種語意合併的既有慣例，見 docs/API.md §5）。
  if v_family_id is null then
    raise exception '找不到這個內容，或你不是它所屬家庭的 owner' using errcode = '42501';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  if not v_is_owner then
    raise exception '只有該內容所屬家庭的 owner 能移除內容' using errcode = '42501';
  end if;

  -- album／diary／comment 直接複用既有的軟刪 RPC（呼叫者已驗證是 owner，這三支各自的
  -- owner 分支會再驗一次，屬廉價的防禦性重複，不是繞過）；media 沒有對應 RPC，既有的
  -- 軟刪路徑本來就是直接 UPDATE deleted_at（見 docs/API.md §3 media 段）。
  case v_target_type
    when 'album' then perform public.set_album_deleted(p_target_id, true);
    when 'diary' then perform public.set_diary_deleted(p_target_id, true);
    when 'comment' then perform public.set_comment_deleted(p_target_id, true);
    when 'media' then
      update public.media m set deleted_at = now() where m.id = p_target_id;
  end case;

  -- 這則內容全部待處理的檢舉一併標記 resolved（PLAN §10-B：內容既然已經移除，檢舉
  -- 自然算處理完畢）。
  update public.content_reports r
     set status = 'resolved'
   where r.family_id = v_family_id
     and r.target_type = v_target_type
     and r.target_id = p_target_id
     and r.status = 'pending';
end;
$$;

revoke execute on function public.remove_content_as_owner(text, uuid) from public, anon;
grant execute on function public.remove_content_as_owner(text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. get_family_quota：額度查詢（§10-A，供 UI 顯示用量條）
-- ---------------------------------------------------------------------------

create or replace function public.get_family_quota(p_family_id uuid)
returns table (storage_used_bytes bigint, storage_quota_bytes bigint)
language sql
stable
set search_path = ''
as $$
  select f.storage_used_bytes, f.storage_quota_bytes
    from public.families f
   where f.id = p_family_id;
$$;

revoke execute on function public.get_family_quota(uuid) from public, anon;
grant execute on function public.get_family_quota(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. 檢舉通知：content_reports 新增一筆時記進 notification_events（kind='report'，
--    見 20260903091313_notification_kind_report.sql）。只做資料層，不含發送——同既有
--    comment／reaction／diary／album 四種 kind 的既有慣例（20260825020000_comments_
--    reactions_notifications.sql §3），發送邏輯是 LS-22 Edge Function 的範圍。
--    **已知後續工作**：Edge Function 送出時需要對 kind='report' 特殊處理——只通知家庭
--    owner，不像其餘四種 kind 廣播給全家庭成員（§10-B：檢舉內容本身只有 owner 讀得到，
--    見 content_reports_select policy）；本票不實作那個判斷本身，留給 LS-22。
-- ---------------------------------------------------------------------------

create or replace function private.notify_report_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select family_id, target_type, target_id,
           count(*)::integer as n,
           (array_agg(reporter_id order by created_at desc))[1] as actor_id
      from new_rows
     group by family_id, target_type, target_id
  loop
    perform private.record_notification_event(
      r.family_id, 'report', r.target_type, r.target_id, r.actor_id, r.n);
  end loop;
  return null;
end;
$$;

create trigger content_reports_notify_insert after insert on public.content_reports
  referencing new table as new_rows
  for each statement execute function private.notify_report_created();

-- ---------------------------------------------------------------------------
-- 9. schema private 的 EXECUTE 收斂（比照既有慣例，檔尾重申一次涵蓋本檔新增的兩支
--    private 函式）
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public;
