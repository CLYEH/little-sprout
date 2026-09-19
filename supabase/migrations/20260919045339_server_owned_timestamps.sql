-- LS-337（源自 LS-336 merge-review R1 `d9183e11` i5＋LS-336 PR #499 body 的盤點表）——
-- 成員可用原始 PostgREST 呼叫竄改 `albums.created_at`／`media.created_at`（例如
-- `infinity`，會卡進 `get_family_timeline` 排序第一名，iOS 對 `occurred_at` 解成
-- 非 optional `Date` 大概率整頁解碼失敗）與 `growth_records.updated_at`（同樣可能讓
-- 成長頁解碼失敗，也能操縱「同日多筆取最後一筆」的判定）。這裡把這些欄位收回為
-- 伺服器專屬，本檔只動 `authenticated` 的權限面，不動任何既有 RLS policy 條件。
--
-- ---------------------------------------------------------------------------
-- 0. 盤點結論（完整逐檔 file:line 表見 PR body；這裡只記每張表的結論）
-- ---------------------------------------------------------------------------
--
-- `albums.created_at`／`media.created_at`：對 `authenticated` 目前是整表 INSERT
-- grant（`20260822120000_init_schema.sql`），沒有任何 RPC／SECURITY DEFINER 函式／
-- edge function／iOS payload 依賴呼叫端傳入 `created_at`——`SupabaseAlbumsAPIClient.
-- createAlbum`（`CreateAlbumPayload`：`family_id`／`title`／`created_by` 三欄）與
-- `MediaUploadService.insertMediaRow`（`MediaInsertPayload`）皆一律吃 DB 端
-- `default now()`。全 repo 沒有「匯入歷史日期」這類需要手動指定 `created_at` 的合法
-- 路徑。
--
-- `growth_records.updated_at`：`grant update (…, updated_at)`（`20260913065021_
-- growth_records.sql` 第 3 段）當初開放這欄的理由是「`upsert_growth_record` 的
-- UPDATE 陳述式本身要 SET 這欄，Postgres 對 SET 子句提到的每一欄都要欄位級 UPDATE
-- 權限」——但欄位級 grant 只檢查「這個角色能不能碰這一欄」，不檢查「碰的時候寫的是
-- 什麼值」，任何以該家庭 owner/member 身分直接 `PATCH` 這一欄的呼叫（不經過 RPC）
-- 一樣通得過同一份 grant。`child_food_records.updated_at`（`20260918205141_food_
-- encyclopedia.sql` 第 3 段）是同一支 RPC 設計手法（`upsert_child_food_record`）
-- 複製出來的同型缺口，盤點時一併找到，本檔一併修——這是票面「growth_records.
-- updated_at（以及盤點中其他 client 可寫的 updated_at）」那句話指名要處理的對象。
--
-- 低優先子項（票面第 3 段）：`content_reports.created_at`／`blocked_users.
-- created_at` 是同一種形狀（整表 INSERT grant、無驗證），`report_content`／
-- `block_user` 兩支 RPC 皆 SECURITY DEFINER 手寫 INSERT、皆不傳 `created_at`，iOS
-- `SupabaseSafetyAPIClient` 只呼叫這兩支 RPC，從未直接 `.insert()` 這兩張表——修法
-- 與 `albums`／`media` 完全同構，成本一樣是一句 REVOKE＋一句 GRANT，一併處理。
-- `device_tokens.updated_at` 額外記在第 4 段（跟 `growth_records`／`child_food_
-- records` 不同形狀：`device_tokens` 對 `authenticated` 是整表 INSERT／UPDATE
-- grant，不是欄位級，且 `updated_at` 目前沒有任何讀取端依賴這個值——`register_
-- device_token` RPC 內部手寫 `now()`，全 repo 找不到任何查詢用它做排序或過期判斷；
-- 選擇跟 `growth_records` 同一支共用 trigger 是因為成本同樣低（重用既有函式，不必
-- 另外設計），不是因為這裡有已知的資料完整性風險。
--
-- ---------------------------------------------------------------------------
-- 1. albums／media／content_reports／blocked_users：INSERT 欄位級收斂
--    ——選欄位級 grant，不選 BEFORE INSERT trigger
-- ---------------------------------------------------------------------------
--
-- 兩個選項：
--   (a) 欄位級 grant：`revoke insert on <table> from authenticated`，再只對允許的
--       欄位重新 `grant insert (…)`——這是本 schema 從第一天就有的既有慣例
--       （`families` 只給 `insert (name, created_by)`，`20260822120000_init_
--       schema.sql`；`growth_records`／`child_food_records` INSERT 從一開始就
--       不含 `created_at`／`updated_at`，同檔第 3 段），`albums`／`media` 反而是
--       目前還沒套用這個既有慣例的例外，不是新發明的做法。
--   (b) BEFORE INSERT trigger：`new.created_at := now(); return new;`，強制覆寫。
--
-- 選 (a)：`media` 這張表同一次 INSERT 還會一起寫 `taken_at`（EXIF 原始拍攝時間，
-- `docs/API.md` §3「`media`」，一個完全不同語意、必須放行呼叫端寫入的欄位）——
-- trigger 寫法要在同一支函式裡精確地「只覆寫 `created_at`、放過 `taken_at`」，
-- 純粹是函式本體邏輯正不正確的問題，日後這張表再加一個時間戳欄位時，trigger 需要
-- 被記得同步排除，忘記排除不會有任何錯誤或警告，只會安靜地覆寫掉一個不該覆寫的
-- 欄位。欄位級 grant 從授權層面就只精準點名 `created_at` 這一欄，其餘欄位（含未來
-- 新增的）預設沒被這句 REVOKE/GRANT 動到，不需要在函式邏輯裡逐欄判斷排除誰。
-- 唯一的維護成本（票面已指出）是「日後這幾張表加新欄位，需要人記得決定新欄位要不要
-- 進這份 INSERT 允許清單」——但這個成本本來就存在（`families`／`growth_records`／
-- `child_food_records` 從第一天就是這樣），且比「trigger 邏輯需要記得排除新欄位」
-- 更安全：忘記把新欄位加進 `grant insert (…)` 清單的後果是那一欄的 INSERT 撞
-- `42501`（吵、當場被撞出來，PR 或本機測試就會發現），不是「安靜地被覆寫成錯誤的
-- 值」。
--
-- 是否會擋到合法需要手動寫 `created_at` 的路徑（例如「匯入歷史日期」）：第 0 段
-- 盤點確認全 repo 沒有這種路徑（`albums`／`media` 皆一律 `default now()`）；若日後
-- 真的要支援匯入，屆時那張票應該新開一支 SECURITY DEFINER RPC（同 `delete_growth_
-- record` 的既有模式），RPC 以表擁有者身分執行、不受這裡收回的 `authenticated`
-- 欄位級 grant 影響，不需要重新放寬這裡的收斂。
--
-- 不能只下欄位級 REVOKE：`albums`／`media`／`content_reports`／`blocked_users`
-- 對 `authenticated` 目前是整表 INSERT grant（relacl），欄位級 REVOKE 只動得到
-- attacl，兩者是 OR 語意，整表授權還在，`created_at` 仍然能寫（本機實測結論，見
-- `20260825040000_deletion_attribution.sql` 檔頭對同一個 Postgres 行為的既有記載，
-- 這裡沿用不重新實測）——必須先整表 REVOKE 再欄位級 GRANT 子集合。

revoke insert on public.albums from authenticated;
grant insert (id, family_id, title, cover_media_id, created_by, deleted_at, deleted_by)
  on public.albums to authenticated;

revoke insert on public.media from authenticated;
grant insert (
  id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by,
  deleted_at, thumb_path, thumb_width, thumb_height, duration_seconds
) on public.media to authenticated;

-- 低優先子項（票面第 3 段）：同一種形狀、同一種修法，見第 0 段盤點。
revoke insert on public.content_reports from authenticated;
grant insert (id, family_id, target_type, target_id, reporter_id, reason, status)
  on public.content_reports to authenticated;

revoke insert on public.blocked_users from authenticated;
grant insert (family_id, blocker_id, blocked_id) on public.blocked_users to authenticated;

-- ---------------------------------------------------------------------------
-- 2. growth_records／child_food_records／device_tokens：`updated_at` 由 BEFORE
--    UPDATE trigger 強制 `now()`——選 trigger，不選撤掉欄位級 UPDATE grant
-- ---------------------------------------------------------------------------
--
-- 跟第 1 段的取捨方向刻意相反，理由是這兩張表的 `updated_at` 欄位級 UPDATE grant
-- 不能單純撤掉：`upsert_growth_record`／`upsert_child_food_record` 的 UPDATE／
-- `ON CONFLICT DO UPDATE` 陳述式本身要 `SET updated_at = now()`（見各自檔案第 6／8
-- 段），Postgres 要求 SET 子句提到的每一欄都要有欄位級 UPDATE 權限，撤掉這欄的
-- grant 會讓兩支 RPC 自己的 UPDATE 陳述式當場撞 `42501`（`growth_records` 那份
-- migration 註解裡就是這樣記載的既有事實，不是臆測）。第 1 段的 `created_at` 沒有
-- 這個問題（`created_at` 從來不在任何 SET 子句裡），這裡的 `updated_at` 有——兩欄
-- 的挑戰形狀不同，因此挑不同的解法，不是不一致。
--
-- 改用 BEFORE UPDATE trigger 無條件強制 `new.updated_at := now()`：grant 維持
-- 原狀（`upsert_*` 兩支 RPC 的 UPDATE／DO UPDATE 陳述式不受影響，繼續能寫這欄），
-- 但不論呼叫端在 `PATCH`／`.update()` 裡塞了什麼值，寫進資料庫的一律是 trigger
-- 求值當下的 `now()`，欄位級 grant 允不允許「碰這一欄」因此不再等於「碰的時候能
-- 塞任意值」——這正是這張票要堵的洞。這支 trigger 對兩支既有 RPC 是完全透明的：
-- 它們自己 SET 的也是 `now()`，trigger 再設一次同樣的值，不是行為改變，只是把
-- 「這欄只能是 now()」這件事從「呼叫端目前恰好都這樣寫」變成「grant 層面之後也
-- 沒有其他值進得去」。
--
-- 沒有既有的通用 `set_updated_at()` trigger 可以重用（檢查過
-- `supabase/migrations` 全庫，**client 可寫**的 `updated_at` 目前只有
-- `growth_records`／`child_food_records`／`device_tokens` 三張表有，過去都是
-- 各自在 RPC 本體手寫 `now()`，沒有共用 trigger 函式——R2 訂正（merge-review R1
-- m2）：`app_settings.updated_at`（`20260904212530_suspension_and_
-- registrations.sql:141`）與 `orphan_scan_cursor.updated_at`（`20260906050606_
-- soft_delete_unreferenced_media.sql:257`）這兩欄也存在，只是對 `authenticated`
-- 完全沒有 grant（`orphan_scan_cursor` 只有 `service_role`；`app_settings` 對
-- `authenticated` 無任何寫入 grant，見各自 migration），不影響「client 可寫的
-- `updated_at` 只有這三張」這個結論，R1 版本這句話少了「client 可寫」四個字，
-- 讀起來像是宣稱全庫只有三欄，訂正措辭，不影響決策本身）——新建 `private.
-- touch_updated_at()`，比照本
-- repo 其餘共用 trigger 函式（`private.enforce_deletion_attribution()`／
-- `private.enforce_child_not_deleted()`／`private.enforce_not_suspended()`）
-- 的既有形狀：`security definer`、`set search_path = ''`、不知道也不需要知道自己
-- 掛在哪張表上，只依賴呼叫端已經有 `updated_at` 這個同名欄位，可以直接掛在任何
-- 未來新增的、有 `updated_at` 欄位的表上，不必重寫一份等價邏輯。
create or replace function private.touch_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- 掛載順序（trigger 名稱決定同一個 BEFORE UPDATE 時機的執行順序，Postgres 依名稱
-- 字母序觸發）：`growth_records`／`child_food_records` 兩張表各自已有
-- `private.enforce_deletion_attribution()` 的 trigger（名稱含 `deletion_
-- attribution`），內部靠 `to_jsonb(new) - 'deleted_by' = to_jsonb(old) -
-- 'deleted_by'` 判斷「這次 UPDATE 是不是只碰了 deleted_by、其餘完全沒變」——
-- 這支 trigger 若排在它之前觸發，`updated_at` 會先被改掉，讓那個「其餘完全
-- 沒變」的比對永遠判定為假（就算真的只碰了 deleted_by）。命名成
-- `<table>_touch_updated_at`（字母序排在 `deletion_attribution`／`child_not_
-- deleted`／`not_suspended` 之後——`t` > `d`／`c`／`n`），確保這支 trigger 一律
-- 在其餘 BEFORE UPDATE trigger 都跑完、判斷完之後才把 `updated_at` 定案，不影響
-- 那些既有 trigger 內部依賴「新舊列差異」的邏輯。
--
-- **R2 訂正（merge-review R1 m1，blocker 等級的行為缺陷，reviewer 實跑重現）**：
-- R1 版本掛的是無條件 `before update`（沒有 `of <cols>`），任何一句 UPDATE，
-- 不論碰了哪些欄位，都會觸發這支 trigger 把 `updated_at` 刷新成 `now()`——包含
-- **FK 的 RI（referential integrity）動作**，不只是使用者主動編輯內容。
-- `growth_records.author_id`／`deleted_by` 兩欄都是 `references public.profiles
-- (id) on delete set null`：作者刪除帳號時，`auth.users` → `profiles`（on delete
-- cascade）→ 這兩欄被 Postgres 自動下一句 `UPDATE ... SET author_id = NULL`（或
-- `deleted_by = NULL`），這句 UPDATE 本身跟「使用者編輯了這筆紀錄」完全無關，卻一樣
-- 會被 R1 版本的無條件 trigger 誤判成「內容被動過」而刷新 `updated_at`。
-- reviewer 實測重現：一筆 `updated_at` 手動回填成過去值的成長紀錄，只要刪除其
-- 作者帳號，`updated_at` 就會跳成 `now()`——`LittleSprout/Services/Growth/
-- GrowthCurve.swift` 的 `deduplicatedByDay` 在同一天有多筆量測時取 `updatedAt`
-- 最大的那筆當代表值，同一個孩子同一天若有兩位作者的量測、其中一位刪除帳號，
-- 圖表上顯示的量測值會被換成已刪除作者的舊資料，不是真正「最後編輯」的那筆。
--
-- 修法：改成 `before update of <內容欄位…>, updated_at`——只列「使用者透過
-- `upsert_*` RPC 或原始 `PATCH` 可能編輯的欄位」加上 `updated_at` 自己，
-- **不列** `author_id`／`deleted_by`／`family_id`／`child_id` 這類治理／FK 欄位
-- （這些欄位的 grant 本來就沒開放給 `authenticated` 直接寫，唯一會改到它們的正是
-- RI 動作與 `enforce_deletion_attribution()` trigger，不該被這支 trigger 誤判成
-- 內容編輯）。Postgres 的 `UPDATE OF col1, col2` 觸發條件是「這句 UPDATE 的 SET
-- 子句是否提到列出的欄位」，不是「值有沒有真的改變」——FK RI 動作的 SET 子句只會
-- 提到 `author_id`／`deleted_by`，不會提到 `updated_at` 或任何內容欄位，因此不會
-- 觸發這支 trigger；`upsert_growth_record`／`upsert_child_food_record` 的 UPDATE／
-- `DO UPDATE` 陳述式與任何原始 `PATCH` 只要 SET 子句碰到 `updated_at`（票面要
-- 堵的洞）或任一內容欄位，一樣會觸發、一樣被強制覆寫成 `now()`——防禦效果不變，
-- 只是不再被 RI 動作誤觸發。連帶效果（非壞事）：`delete_growth_record`／
-- `delete_child_food_record` 的軟刪 UPDATE 只 `SET deleted_at = now()`，同樣不在
-- 這份欄位清單裡，軟刪不會刷新 `updated_at`——已刪除的列不會出現在任何查詢結果
-- （`deleted_at is null` 過濾），不影響任何可見行為。
--
-- `device_tokens` 不需要比照收斂（見下方獨立段落）：它唯一的 FK（`user_id
-- references public.profiles (id) on delete cascade`）是 cascade 不是 set null，
-- 使用者帳號刪除時整列會直接被刪掉，不會產生會誤觸發這支 trigger 的 RI UPDATE，
-- 沒有對應的缺陷可修。
create trigger growth_records_touch_updated_at
  before update of measured_on, height_cm, weight_kg, head_cm, note, updated_at
  on public.growth_records
  for each row execute function private.touch_updated_at();

create trigger child_food_records_touch_updated_at
  before update of first_tried_on, media_id, note, reaction, updated_at
  on public.child_food_records
  for each row execute function private.touch_updated_at();

-- `device_tokens` 跟上面兩張表不同：`authenticated` 對它是整表 INSERT／UPDATE
-- grant（`20260822120000_init_schema.sql`），不是欄位級，直接 `.insert()` 自己的
-- 裝置列（`device_tokens_insert` policy 只檢查 `user_id = auth.uid()`，不檢查
-- `updated_at`）一樣能塞任意 `updated_at`，因此這裡連 INSERT 也要掛（`register_
-- device_token` 內部是「先 DELETE 舊列、再 INSERT 新列」，同樣會走到這支 BEFORE
-- INSERT trigger，一樣被覆寫成 `now()`，跟它自己手寫的值相同，不影響既有行為）。
create trigger device_tokens_touch_updated_at
  before insert or update on public.device_tokens
  for each row execute function private.touch_updated_at();
