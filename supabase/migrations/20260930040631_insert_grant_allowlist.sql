-- LS-414（源自 LS-337 merge-review R1 e79f8ad5 i5，池 6781e171）——欄位級 INSERT 允許清單
-- 收斂：`20260919045339_server_owned_timestamps.sql`（LS-337）只把 `created_at` 從
-- `albums`／`media`／`content_reports`／`blocked_users` 的 INSERT grant 拿掉，沒有逐欄
-- 盤點「哪些欄位是伺服器專屬、client 不該在 INSERT 時自帶」。本檔補上這一輪盤點，只動
-- `authenticated` 的權限面，不動任何 RLS policy 條件、不動 UPDATE grant。
--
-- 為什麼是同一套「先整表 revoke 再欄位級 grant 子集合」寫法：見上述 LS-337 檔頭第 1 段
-- （欄位級 REVOKE 只動得到 attacl，整表 grant 的 relacl 仍在、兩者 OR 語意，必須先整表
-- REVOKE 再欄位級 GRANT；選 grant 不選 BEFORE INSERT trigger 的取捨也同該段）。這裡不重述。
-- 整表 REVOKE 會連帶清掉該表的欄位級 INSERT 權限；欄位級 UPDATE 權限（attacl 的 `w`，
-- 例如 `media.deleted_at`／`albums.title` 的 UPDATE）是另一種權限，不受影響。
--
-- ---------------------------------------------------------------------------
-- 盤點結論（完整逐欄表見 PR body；`has_column_privilege('authenticated', …, 'INSERT')`
-- 對本機容器實測，範圍＝`public` schema 全部表）。這裡只記被收斂的欄位與理由：
-- ---------------------------------------------------------------------------
--
-- 1. `albums.deleted_at`／`albums.deleted_by`——撤。
--    `set_album_deleted` RPC（SECURITY DEFINER）是軟刪／還原的唯一合法路徑，`albums_
--    update` 的欄位級 UPDATE 也早已（LS-57 R2）排除這兩欄；INSERT 路徑仍開放＝已核准成員
--    可用原始 PostgREST 建一本「`deleted_at`＝過去、`deleted_by`＝任意成員 id」的相簿，
--    繞過上述兩層收斂，也讓 `deleted_by` 的刪除歸屬語意失真（LS-155／LS-57）。
--    iOS `CreateAlbumPayload` 只送 `family_id`／`title`／`created_by`，沒有任何 RPC／
--    edge function 以 authenticated 身分 INSERT 帶這兩欄。
--
-- 2. `content_reports.status`——撤。
--    欄位 default 是 `'pending'`（`report_status` enum：pending／resolved／dismissed；票面
--    寫「default 'open'」是筆誤，以本機 schema 為準）；`report_content` RPC（SECURITY
--    DEFINER）手寫 INSERT、不傳 status。檢舉者能自帶 `status='resolved'`／`'dismissed'`
--    就繞過 docs/API.md §2「只有 owner 能把 pending 改成 resolved、dismissed 保留給平台方」。
--
-- 3. `media.deleted_at`——撤（本機容器實測 `families.storage_used_bytes` 計量 trigger 對
--    「INSERT 時已帶 deleted_at」的列怎麼算，結論不是無害）。
--    `private.media_storage_sync()` 的 INSERT 分支只加總 `deleted_at is null` 的列，
--    所以一出生就軟刪的列 **不計入** 家庭額度（實測：INSERT 5,000,000 bytes 且帶
--    `deleted_at` → `storage_used_bytes` delta＝0）、`feed_sync_media` 不建 feed_items、
--    `notify_media_created` 也不通知——但 Storage 物件本身已佔空間，等於成員可用這條路徑
--    在額度之外暫存位元組；之後 `media_update` 的欄位級 UPDATE grant 允許把 `deleted_at`
--    改回 NULL，計量 trigger 才補記（實測復活後 delta＝5,000,000、feed_items 補上一列）。
--    `media` 軟刪的合法路徑是 UPDATE `deleted_at`（iOS `softDeleteMedia`，見
--    `MediaUploadService+SoftDelete.swift`）；iOS `MediaInsertPayload` 13 欄不含
--    `deleted_at`，沒有任何路徑需要「出生即軟刪」。UPDATE 端的欄位級 grant 留著（不在
--    本票範圍）。
--
-- 4. `profiles.deletion_requested_at`／`purged_at`／`suspended_at`／`eula_accepted_version`
--    ／`eula_accepted_at`——撤（同型欄，盤點時額外找到）。
--    `profiles` 對 `authenticated` 是整表 INSERT grant，但 UPDATE 早已收成只有
--    `display_name`／`avatar_url`；上述五欄的唯一寫入路徑是 SECURITY DEFINER 的
--    `delete_my_account`／`accept_eula`／管理端 service_role。INSERT 仍整表開放，
--    等於「UPDATE 收斂被 INSERT 路徑繞過」的同一形狀（profile 列在註冊時已由 `auth.users`
--    的 AFTER INSERT trigger 建好，client 的 `ensureProfileExists` 是 `on conflict do
--    nothing`，實務上撞 PK；但列若不存在〔例如被 purge 後〕就能一次寫入 `eula_accepted_
--    version`／`suspended_at` 等旗標，繞過 EULA gate）。iOS `ProfileUpsertPayload` 只送
--    `id`／`display_name`；`profiles_insert` policy 仍只限 `id = auth.uid()`，不動。
--
-- 盤點後保留（client 該填，不動）：`albums.id`／`family_id`／`title`／`cover_media_id`／
-- `created_by`；`media` 其餘 13 欄；`content_reports.id`／`family_id`／`target_type`／
-- `target_id`／`reporter_id`／`reason`；`profiles.id`／`display_name`／`avatar_url`。
-- 其他表（`album_media`／`diary_media`／`blocked_users`／`child_food_records`／
-- `device_tokens`／`families`／`growth_records`）的可 INSERT 欄位都是 client 內容欄或已有
-- default／trigger 兜底（`device_tokens.updated_at` 由 LS-337 trigger 強制 now()），不動。

revoke insert on public.albums from authenticated;
grant insert (id, family_id, title, cover_media_id, created_by)
  on public.albums to authenticated;

revoke insert on public.media from authenticated;
grant insert (
  id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by,
  thumb_path, thumb_width, thumb_height, duration_seconds
) on public.media to authenticated;

revoke insert on public.content_reports from authenticated;
grant insert (id, family_id, target_type, target_id, reporter_id, reason)
  on public.content_reports to authenticated;

revoke insert on public.profiles from authenticated;
grant insert (id, display_name, avatar_url) on public.profiles to authenticated;
