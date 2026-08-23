-- LS-40 — Storage：media bucket、storage.objects 的 RLS、檔案路徑規約
--
-- 這是 LS-20（相簿與照片上傳）的後端先行部分。public.media 管的是「照片的中繼資料」，
-- 它的 RLS 已經由 LS-6 建好；但**檔案本身**存在 Storage 的 storage.objects 裡，是另一份
-- 完全獨立的資料，media 表的 policy 一列也管不到它。沒有這個 migration，任何登入者都能
-- 直接讀寫別人家庭的檔案——中繼資料鎖得再好也沒有意義。
--
-- 邊界怎麼畫：Storage 沒有 family_id 欄位可以比對，唯一能表達歸屬的是**物件路徑**。
-- 因此 PLAN §5 的路徑規約 `{family_id}/{yyyy}/{mm}/{media_id}.{ext}` 在這裡從「約定」
-- 升格成「被 policy 強制的安全邊界」：路徑第一段就是這個檔案屬於哪個家庭。

-- ---------------------------------------------------------------------------
-- 0. 前置斷言：storage schema 的形狀必須符合本 migration 的前提（fail loud）
--
-- 為什麼這一段是「斷言」而不是「設定」——
-- storage.objects 的擁有者是 supabase_storage_admin，而我們的 migration 一律以
-- postgres 身分執行；postgres 既不是它的成員、也不能 SET ROLE 過去（本機 supabase CLI
-- 開發映像實測：`alter table storage.objects enable row level security` 直接噴
-- `42501 must be owner of table objects`；`set role supabase_storage_admin` 噴
-- `permission denied to set role`）。
--
-- 那我們憑什麼建得了下面那四條 policy？靠 Supabase 平台的 supautils 擴充：它的
-- `supautils.policy_grants` 設定把 storage.objects 等資料表明文列給 postgres 角色，
-- 允許非擁有者建立／刪除 policy（本機實測 `show supautils.policy_grants` 可見該清單）。
-- 這是**平台佈建**，不是我們的 migration 能保證的東西——正是 LS-15 的教訓
-- （「斷言只能依賴自己 migration 的保證或 Postgres 機制，不要押在 supabase 版本行為上」）。
--
-- 所以「RLS 有沒有啟用」我們只能斷言不能設定：一旦哪天平台改成預設不啟用，
-- 我們建的 policy 會安靜地永遠不被求值，而失敗的方向是「全世界都讀得到你家的照片」。
-- 這種洞不會有錯誤訊息，只會在外洩時才知道，所以寧可讓 migration 當場炸掉。
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise exception 'LS-40：找不到 storage.objects／storage.buckets——這個資料庫沒有 Supabase Storage 的 schema，本 migration 的前提不成立';
  end if;

  if not exists (
    select 1 from pg_class c
     where c.oid = 'storage.objects'::regclass and c.relrowsecurity
  ) then
    raise exception 'LS-40：storage.objects 沒有啟用 RLS，而 postgres 身分無權替它啟用（擁有者是 supabase_storage_admin）。此時建立 policy 只會得到一組永遠不被求值的擺設，等於檔案全開——停在這裡，不要繼續';
  end if;

  -- 路徑第一段的取法依賴這支平台函式；它不存在的話下面四條 policy 全部建不起來
  if to_regprocedure('storage.foldername(text)') is null then
    raise exception 'LS-40：找不到 storage.foldername(text)，policy 取不出路徑第一段';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. media bucket
--
-- private（public = false）：PLAN §8「全私有 bucket + 簽名 URL」，照片影片不會有公開網址。
--
-- file_size_limit 取 50 MiB：與 supabase/config.toml 的 `[storage] file_size_limit`
-- 對齊。bucket 的上限**不能超過**該全域上限，寫大了在本機只會被安靜地夾到 50 MiB，
-- 造成「本機測得過、雲端行為不同」。日後要放寬影片上限，兩個地方要一起改。
--
-- allowed_mime_types 是額度防線的一環（§10-A）：bucket 全開等於把付費的儲存空間
-- 交給任何註冊得了帳號的人拿去存任意檔案。image/heif 與 image/heic 都列：HEIC 檔本身
-- 就是 HEIF 容器，iOS 依來源可能回報其中任一個 UTI，只列一個會擋掉合法的上傳。
--
-- on conflict do update 而不是 do nothing：這個 migration 是 bucket 設定的唯一真相來源。
-- 雲端若曾有人從 dashboard 手動建過同名 bucket，套用時要把設定「校正」回來，
-- 而不是讓一個誰也不知道限制是什麼的 bucket 留在那裡。
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'media', 'media', false,
  52428800,  -- 50 MiB
  array[
    'image/jpeg', 'image/png', 'image/heic', 'image/heif',
    'video/mp4', 'video/quicktime'  -- quicktime = .mov
  ]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- 2. 路徑規約判斷式
--
-- PLAN §5：`{family_id}/{yyyy}/{mm}/{media_id}.{ext}`，縮圖為 `{media_id}_thumb.jpg`。
-- 寫成函式而不是把 regex 抄兩份（INSERT 與 UPDATE 的 WITH CHECK 都要用）：兩份 regex
-- 遲早會改一份忘一份，而漂移的方向沒有人看得出來。
--
-- 為什麼不加 `set search_path = ''`：這支函式不碰任何資料庫物件（只對參數做 regex），
-- 沒有 search_path 挾持的面；而帶 SET 子句的 SQL 函式**無法被規劃器 inline**，
-- 會變成每列一次真正的函式呼叫。這裡刻意留白換取 inline。
-- 同理它是 SECURITY INVOKER（預設）：沒有任何需要提權的動作。
--
-- 規約中「yyyy/mm 取上傳時間」這一條**沒有**寫進判斷式，是刻意的：DB 無從得知上傳時間
-- 與客戶端寫入的月份是否一致，若拿 now() 去比對，跨月的排隊上傳與失敗重試會在午夜
-- 前後莫名其妙被拒。那條是客戶端契約（docs/PLAN.md §5），不是 policy 管得到的事。
--
-- 大小寫：規約要求小寫正規形 UUID。這不是潔癖——public.media 的
-- `media_storage_path_family_prefix` CHECK 比對的是 `family_id::text`，Postgres 的
-- uuid 輸出恆為小寫正規形；兩邊若容許不同大小寫，同一張照片在 media 表與 Storage 裡
-- 會長成兩種路徑，未來 S3 sync 到 NAS 對不起來。Swift 的 `UUID.uuidString` 預設是
-- **大寫**，客戶端必須 `.lowercased()`——寫在 docs 裡，違反時這裡會直接擋下（42501）。
-- ---------------------------------------------------------------------------
create or replace function private.is_media_object_path(p_name text)
returns boolean
language sql
immutable
as $$
  select p_name ~ (
    -- {family_id}
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    -- /{yyyy}/{mm}
    || '/[0-9]{4}/(0[1-9]|1[0-2])'
    -- /{media_id}
    || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    -- 原檔副檔名，或縮圖的 _thumb.jpg
    || '(_thumb\.jpg|\.(jpg|jpeg|png|heic|heif|mp4|mov))$'
  );
$$;

-- 20260822120300_harden_default_privileges.sql 的全域 default privileges 已經讓
-- postgres 新建的函式不再繼承 PUBLIC 的內建 EXECUTE，但這一句照樣明寫：本檔的保證
-- 要由本檔自己給，不建立在「另一個 migration 剛好也做了這件事」上（60_ 第 3 段是
-- fail-closed 的列舉檢查，漏了會被擋下）。
revoke execute on function private.is_media_object_path(text) from public;
grant execute on function private.is_media_object_path(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. storage.objects 的四條 policy
--
-- 集合函式沿用 LS-6 的四支 private.*（STABLE SECURITY DEFINER，PLAN §5 的硬規定），
-- 不另外新增 text 版本：`select f::text from private.family_ids() f` 這個子查詢
-- **不引用外層資料列**，規劃器會收斂成一次性的 InitPlan／hashed SubPlan，與
-- rls_policies.sql 裡 `family_id in (select private.family_ids())` 是同一種形狀。
-- 由 supabase/tests/50_rls_plan_no_percall_subquery.sql 用 2 萬列實測把關。
--
-- 為什麼比對 text 而不是把路徑第一段 cast 成 uuid：cast 失敗會噴 22P02，
-- 也就是「路徑亂寫」會變成一個錯誤而不是一次乾淨的拒絕——而 policy 的 qual 裡
-- AND 沒有保證的短路求值順序（規劃器會依成本重排），先用 regex 擋格式再 cast
-- 這種寫法並不可靠。改成拿 `uuid::text`（恆為小寫正規形）去比對字串，
-- 整條路徑上根本沒有 cast，格式錯的第一段就只是「不屬於任何家庭」＝拒絕。
--
-- 全部只給 authenticated：未登入者（anon）沒有任何一條 policy 命中，
-- RLS 預設拒絕，因此 anon 讀不到、寫不進、刪不掉——不需要也不該寫「拒絕 anon」的 policy。
-- ---------------------------------------------------------------------------

-- 讀：同家庭成員（含 viewer）可讀自家路徑下的檔案。
-- 不檢查路徑規約：規約由寫入端把關；讀取端若也綁死規約，日後 service_role 從後台
-- 放進來的檔案（例如轉檔產物）會讓成員看不到自己的照片。
create policy media_bucket_select on storage.objects for select to authenticated
  using (
    bucket_id = 'media'
    and (storage.foldername(name))[1] in (select f::text from private.family_ids() f)
  );

-- 寫：必須是有上傳權的成員（owner 恆可；member 看 can_upload；viewer 一律不行），
-- 且路徑第一段必須是**自己所屬**的家庭——這一條就是跨家庭寫入的防線：
-- 把別人家的 family_id 塞進路徑第一段，那個 id 不在 uploadable_family_ids() 裡，直接拒絕。
create policy media_bucket_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'media'
    and private.is_media_object_path(name)
    and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
  );

-- 改／刪：上傳者本人（有上傳權時）或家庭 owner。
--
-- 「上傳者本人」兩個欄位都認：storage-api 依版本可能寫 owner（uuid，舊欄位）、
-- owner_id（text，新欄位）或兩者皆寫。只認一個等於把 policy 押在 storage 的版本行為上
-- （LS-15 教訓）。兩欄皆為 NULL 時退化成「只有家庭 owner 能動」——失敗方向是關緊，
-- 不是開放，這是可以接受的退化。
--
-- UPDATE 的 WITH CHECK 同時擋住「改名搬家」：storage-api 的 move/copy 是 UPDATE name，
-- 若只驗舊列（USING）不驗新列，有上傳權的成員可以把自家檔案改名成別家的路徑前綴，
-- 等於繞過 INSERT 那條防線把檔案送進別人家。新列一樣要通過規約與家庭歸屬。
create policy media_bucket_update on storage.objects for update to authenticated
  using (
    bucket_id = 'media'
    and (
      (storage.foldername(name))[1] in (select f::text from private.owned_family_ids() f)
      or (
        (owner = (select auth.uid()) or owner_id = (select auth.uid())::text)
        and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
      )
    )
  )
  with check (
    bucket_id = 'media'
    and private.is_media_object_path(name)
    and (
      (storage.foldername(name))[1] in (select f::text from private.owned_family_ids() f)
      or (
        (owner = (select auth.uid()) or owner_id = (select auth.uid())::text)
        and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
      )
    )
  );

-- 刪除的判準與 UPDATE 的 USING 相同。
-- 與 public.media 的差異要知道：media 表的**硬刪**只有 owner（一般刪除走 deleted_at，
-- §5 長輩誤刪要有救援路徑），這裡卻讓上傳者刪得掉自己的檔案。這不是筆誤——
-- 上傳失敗留下的孤兒物件只有上傳者知道它存在，要求家庭 owner 才能清，等於清不掉。
-- 代價與客戶端契約寫在 docs/PLAN.md §5：軟刪除的照片**不要**刪檔案，
-- 上傳者自刪只用於「沒有成功建出 media 列」的失敗上傳。
create policy media_bucket_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'media'
    and (
      (storage.foldername(name))[1] in (select f::text from private.owned_family_ids() f)
      or (
        (owner = (select auth.uid()) or owner_id = (select auth.uid())::text)
        and (storage.foldername(name))[1] in (select f::text from private.uploadable_family_ids() f)
      )
    )
  );
