-- LS-213 範圍 1（b）—— 軟刪「media 列存在、deleted_at IS NULL、從未被任何
-- diary_media／album_media 引用」的孤兒（未引用活列），並排入既有 30 天軟刪／
-- 硬刪流程。
--
-- 來源（LS-96 comment c2050d43，LS-212 merge-review R3 8d1e57bc 查實）：
-- 離線放棄編輯器路徑——uploadAllMedia() 對每張都已經「Storage PUT 成功、
-- insertMediaRow 也成功」（media 列確實存在、storage_used_bytes 已加上去），
-- 之後在 attachMedia 斷線失敗，使用者在離線狀態下放棄編輯器，
-- DiaryComposerStore.pendingOrphanMediaIDs 的重試（softDeleteMedia）也因為離線
-- 失敗，discardDraft() 是這個 store 生命週期最後一次呼叫，pending 隨 store 消失
-- ——殘留一列 `deleted_at IS NULL` 的活 media 列，全 repo 對 media 的讀取只有
-- SupabaseTimelineAPIClient.fetchMedia(ids:)／SupabaseAlbumsAPIClient.fetchMedia
-- (ids:) 兩處、皆帶明確 id（來自 diary_media／album_media），沒有任何「列出家庭
-- 所有 media」的查詢——這種列在 UI 上完全看不見、使用者刪不掉，永久佔用
-- families.storage_used_bytes 額度。
--
-- 這是與 docs/API.md §6「自動清除（LS-153）」③（Storage 有物件、media 列從未
-- 成功 insert 的孤兒，見 LS-213 另一支 Edge Function 修法）**不同的查詢**：這裡
-- 的 media 列存在，只是從未被任何內容引用，`private.purge_expired()` 與③的
-- Storage 反向掃描都接不住它。
--
-- 判準：type in ('photo', 'video')（media_type 枚舉目前只有這兩個值，明寫是為了
-- 在未來枚舉擴充時這條規則不會意外把新型別也算進來，見 §6「media_type」定義）、
-- deleted_at is null（還沒被任何人軟刪過）、不存在於 diary_media／album_media
-- （用既有的 diary_media_media_idx／album_media_media_idx，(family_id, media_id)
-- 兩欄複合索引，避免全表掃描——見下方新增的 media 索引）、created_at 超過寬限期
-- （預設 24 小時，避免正常上傳流程中「PUT 成功、insert 成功，但 attachMedia 還
-- 沒來得及跑」的列被誤判為孤兒——這條寬限期常數與 docs/API.md 的說明是同一個
-- 24 小時，改動需要同步兩處）。
--
-- 處置：直接設 deleted_at = p_now（走既有的軟刪＋30 天 purge 流程）——
-- private.media_storage_sync()（20260822120100_triggers.sql）的 AFTER UPDATE
-- trigger 會在這句 UPDATE 觸發時自動把 families.storage_used_bytes 扣回去
-- （trigger 判斷 old.deleted_at is null、new.deleted_at is not null，屬於它既有
-- 涵蓋的三種操作分支之一，不需要這裡另外處理額度）。30 天後 private.purge_expired()
-- 會依照既有規則把這些列跟其他軟刪列一起硬刪、送進 Storage 清除佇列（③③兩支
-- 未來走的是同一條硬刪路徑，不重複建置）。`media` 沒有 `deleted_by` 欄位（見
-- 20260903084231_delete_account.sql、docs/API.md §3「media」——LS-57 的
-- deleted_by 語意在這張表上不適用），這裡沒有東西需要標記「誰刪的」。
--
-- 掛進既有排程入口：獨立 pg_cron job（不是塞進 private.purge_expired() 內部呼叫）
-- ——purge_expired() 是一支已經過四輪 merge-review、被大量既有測試與併發場景覆蓋
-- 的既有函式，為了一個新查詢重新 `create or replace` 整支函式本體、承擔改壞既有
-- 六張表清除邏輯的風險，不符合手術式修改原則；獨立 job 沿用同一種 fail-soft
-- 註冊慣例（見下方），互不依賴，各自測試。

-- ---------------------------------------------------------------------------
-- 0. 效能索引：`media_family_created_idx`（既有，20260822120000_init_schema.sql）
--    是 `(family_id, created_at desc, id desc) where deleted_at is null`——這支
--    新查詢沒有 family_id 篩選（要跨全部家庭找孤兒），無法用上那支索引的領先欄。
--    新增一支只以 created_at 為鍵的 partial index，讓 `created_at < 截止時間`
--    這段範圍掃描不必落回全表 Seq Scan（media 一多，同一份問題見
--    20260903110908_purge_expired.sql 開頭「0. 效能索引」的既有說明）。
--    diary_media／album_media 的 NOT EXISTS 反查沿用既有的
--    diary_media_media_idx／album_media_media_idx（(family_id, media_id)，
--    20260822120000_init_schema.sql 已建），不需要新索引。
-- ---------------------------------------------------------------------------
create index media_deleted_at_null_created_at_idx
  on public.media (created_at)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 1. private.soft_delete_unreferenced_media(p_grace, p_now) —— 主體
--
-- security definer：必須跨越全部家庭掃描，若受呼叫者 RLS 限制只看得到自己家庭的
-- media，這支函式只能處理呼叫者自己所屬家庭，其餘家庭永遠處理不到（理由同
-- private.purge_expired()）。
--
-- 權限：不 grant 給任何人，繼承 harden_default_privileges.sql 的全域 default
-- privileges（public/anon/authenticated 天生零 EXECUTE，service_role 天生有）。
-- 下面仍明確 REVOKE public／anon，理由同 purge_expired()：讓「不開放給
-- authenticated」這件事在檔案裡看得到，不必回頭翻另一支 migration。
--
-- 回傳值：這次呼叫實際軟刪的列數（單一整數，不像 purge_expired() 需要回傳六張表
-- 各自的計數與失敗明細——這裡只有一張表、一種操作，回傳一個整數已足夠，不需要
-- 比照建一張 private.purge_runs 等級的觀測表，見 LS-96 c2050d43「不需要新的執行
-- 框架」的 size 估算）。
-- ---------------------------------------------------------------------------
create or replace function private.soft_delete_unreferenced_media(
  p_grace interval default '24 hours',
  p_now timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.media m
     set deleted_at = p_now
   where m.deleted_at is null
     and m.type in ('photo', 'video')
     and m.created_at < p_now - p_grace
     and not exists (
       select 1 from public.diary_media dm
        where dm.family_id = m.family_id and dm.media_id = m.id
     )
     and not exists (
       select 1 from public.album_media am
        where am.family_id = m.family_id and am.media_id = m.id
     );

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function private.soft_delete_unreferenced_media(interval, timestamptz) from public, anon;

comment on function private.soft_delete_unreferenced_media(interval, timestamptz) is
  '軟刪「media 列存在、deleted_at IS NULL、從未被任何 diary_media／album_media'
  ' 引用、且 created_at 超過寬限期（預設 24 小時）」的孤兒列（LS-213，來源 LS-96'
  ' c2050d43／LS-212 R3 查實：離線放棄編輯器路徑留下的殘留活列）——與'
  ' docs/API.md §6「自動清除」③（Storage 有物件、media 列從未 insert 的孤兒）是'
  ' 兩支不同的查詢，這裡的 media 列存在，只是未被引用。處置是設 deleted_at＝走'
  ' 既有軟刪＋30 天 purge 流程，額度由 private.media_storage_sync() 既有 trigger'
  ' 回落。p_now 預設 now()，測試注入固定值驗證寬限期邊界。security definer，只'
  ' service_role／pg_cron 可呼叫，authenticated 沒有 EXECUTE（天生零授權，見'
  ' harden_default_privileges.sql，這裡的收回動作只補了 public／anon 兩個角色）。';

-- ---------------------------------------------------------------------------
-- 1b. service_role 對 media 的最小讀取授權（LS-213 範圍 2 的先決條件，動工時
--    本機容器實測發現）：`public.media` 只對 `authenticated` 開過
--    `grant select, insert, delete`（`init_schema.sql`），從來沒有對 `service_role`
--    開過任何欄位——`service_role` 的 RLS 略過（bypassrls）跟表級 GRANT 是兩件
--    互不相干的事，缺這句話 `purge-storage` Edge Function（`service_role` 身分）
--    對 `media.storage_path`／`thumb_path` 的 `select` 會直接拿到
--    `permission denied for table media`（本機 `supabase functions serve` 實測
--    重現，見票 handoff）。只開 `storage_path`／`thumb_path` 兩個欄位（範圍 2 的
--    掃描只需要拿這兩欄反查物件路徑是否已有對應列），不開整表，比照
--    `purge_storage_queue` 只給 `service_role` 消化佇列實際需要的 select／delete
--    的既有窄授權慣例（見該表 migration 說明）。
-- ---------------------------------------------------------------------------
grant select (storage_path, thumb_path) on public.media to service_role;

-- ---------------------------------------------------------------------------
-- 1c. public.purge_storage_queue_enqueue_orphans(p_bucket_id, p_family_id,
--    p_object_paths) —— LS-213 範圍 2 的 `purge-storage` Edge Function 用這支
--    定義器函式把「Storage 掃到、找不到對應 media 列」的物件路徑排入既有
--    `purge_storage_queue`（本機 `supabase functions serve` 實測重現：
--    `purge_storage_queue` 只 `grant select, delete` 給 `service_role`（第 2
--    段建表時的既有設計），沒有 `insert`——當時的設計理由是「service_role 自己
--    不應該能直接塞列，只透過 `purge_storage_queue_mark_failed()` 表達單一意圖」，
--    但那個理由只涵蓋了「硬刪 media 之後由 trigger 入列」這一種既有情境，沒有
--    預見這裡的新情境：Edge Function 自己掃描 Storage 發現一批全新的孤兒物件、
--    需要新增列（不是更新既有列的 attempts）。沿用同一個「service_role 只透過
--    definer 函式表達單一意圖」的架構決定，而不是直接放寬 `grant insert`——這裡
--    只讓它表達「這批路徑（同一個家庭）需要排入清除佇列」，不能直接寫任意欄位。
--
--    `on conflict (bucket_id, object_path) do nothing`：天生冪等，同一個物件路徑
--    被掃到兩次（例如上一輪已經 enqueue、還沒被消化迴圈刪除）不會報錯也不會
--    產生重複列（既有 `purge_storage_queue_bucket_object_key` unique 約束）。
--    `media_id` 固定寫 NULL——這批物件從來就沒有對應的 media 列，不像既有的硬刪
--    路徑那樣附得上 media_id。
-- ---------------------------------------------------------------------------
create or replace function public.purge_storage_queue_enqueue_orphans(
  p_bucket_id text,
  p_family_id uuid,
  p_object_paths text[]
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  insert into public.purge_storage_queue (bucket_id, object_path, family_id, media_id)
  select p_bucket_id, path, p_family_id, null
    from unnest(p_object_paths) as path
  on conflict (bucket_id, object_path) do nothing;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.purge_storage_queue_enqueue_orphans(text, uuid, text[]) from public, anon;
-- 只從 public／anon 收回，理由同 purge_storage_queue_mark_failed() 收尾那句
-- REVOKE 的既有寫法：這支函式從建立的第一刻就沒有對 authenticated 開放過
-- EXECUTE（全域 default privileges），特意不 REVOKE authenticated 純粹是避免
-- 誤觸 migration-breaking-check.sh 的 BREAKING 分級（REVOKE 名單含
-- authenticated 會被判成動到既有授權）。

comment on function public.purge_storage_queue_enqueue_orphans(text, uuid, text[]) is
  '`purge-storage` Edge Function（LS-213 範圍 2）用來把 Storage 掃描到、找不到'
  ' 對應 media 列的孤兒物件路徑排入 purge_storage_queue——service_role 對這張表'
  ' 原本只有 select／delete（見第 2 段），沒有 insert，這支 SECURITY DEFINER'
  ' 函式讓它只能表達「這批路徑（同一家庭）需要排入清除佇列」這個單一意圖，不能'
  ' 直接寫任意欄位。media_id 固定 NULL（這批物件從未有對應 media 列）；'
  ' on conflict do nothing 天生冪等。回傳值是這次呼叫真正新增的列數。';

-- ---------------------------------------------------------------------------
-- 2. pg_cron 排程（獨立 job，fail-soft，沿用 20260903110908_purge_expired.sql
--    第 6 段既有慣例——pg_cron 擴充的啟用已由該 migration 處理，這裡只需要確認
--    擴充存在就註冊 job；本機開發映像若擴充仍未啟用，同樣不擋 migration chain，
--    只留 NOTICE）。
--
-- 排程時間：19:30 UTC（≈台北時間凌晨 3 點半），purge_expired 既有排程
-- （19:00 UTC）之後 30 分鐘、同一個低流量時段——兩支 job 彼此獨立，順序不影響
-- 正確性（這裡新軟刪的列 deleted_at 是「現在」，purge_expired 的 30 天窗口不會
-- 在同一輪就碰到它們，先後執行都一樣）。
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.schedule('ls213-soft-delete-unreferenced-media-daily', '30 19 * * *',
        $cron$select private.soft_delete_unreferenced_media();$cron$);
    exception when others then
      raise notice 'soft_delete_unreferenced_media 排程：pg_cron 擴充已啟用，但 cron.schedule() 失敗（%），略過排程註冊', sqlerrm;
    end;
  else
    raise notice 'soft_delete_unreferenced_media 排程：pg_cron 未啟用，cron.schedule 略過（見 purge_expired migration 的既有 NOTICE）';
  end if;
end;
$$;
