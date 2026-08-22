-- LS-36：補 LS-6～LS-15 期間遺留、被 supabase/tests/65_fk_reverse_index.sql 掃出的
-- 11 個外鍵反向索引（白名單見該檔 v_known_gaps）。
--
-- 逐一裁量的結論：11 個全部建索引，沒有「有意不建」項。理由分兩類，兩類同時成立：
--   1. 其中 10 個都是 profiles(id) 的外鍵（created_by／author_id／uploaded_by／
--      reporter_id／user_id／blocker_id／blocked_id），全部是 on delete set null
--      或 on delete cascade。profiles 表註解已明講「帳號刪除（§9-A2）時隨 auth.users
--      一起 cascade」——這是本產品已設計、非假設性的操作，一旦有人刪帳號，Postgres
--      要在「每一張」有這些外鍵的表上找子列。這條路徑本檔既有的
--      join_requests_resolved_by_idx（20260823010000_join_approval.sql 第 118-121 行）
--      已經是同一個理由的先例。
--   2. 同時也都對得上真實的反向查詢形狀（本產品「某人的所有 X」）：某人上傳的所有照片
--      （media）、某人寫的所有日記（diaries）／留言（comments）、某人建立的所有相簿
--      （albums）／家庭（families）／邀請碼（invites）、某人送出的所有檢舉
--      （content_reports）、某人的封鎖名單雙向（blocked_users 兩欄都要——「我封鎖的人」
--      與「封鎖我的人」是兩個不同方向的查詢，缺一不可）。
--   剩下 1 個是 comments.comments_family_id_fkey（family_id → families，on delete
--   cascade）：comments_target_idx 雖然也是 family_id 領頭，但那是
--   `where deleted_at is null` 的部分索引，覆蓋不到已軟刪除的列；family 被刪除時
--   cascade 必須連軟刪除的留言一起清，部分索引在這個路徑上用不上，需要一支完整索引。
--   （其餘表的 family_id 外鍵之所以沒被 65_ 掃出，是因為各自已經有非部分索引可用：
--   album_media/diary_media 的 `_idx`、content_reports_family_idx、reactions_target_idx
--   領頭欄位就是 family_id 且不是部分索引；media/albums/diaries 則是靠複合
--   `(family_id, id)` UNIQUE 約束的索引補上，同樣領頭是 family_id。）

-- families.families_created_by_fkey：某人建立的所有家庭；建立者刪帳號時的 set null 反查
create index if not exists families_created_by_idx on public.families (created_by);

-- invites.invites_created_by_fkey：某人建立的所有邀請碼；建立者刪帳號時的 set null 反查
create index if not exists invites_created_by_idx on public.invites (created_by);

-- media.media_uploaded_by_fkey：某人上傳的所有照片／影片；上傳者刪帳號時的 set null 反查
create index if not exists media_uploaded_by_idx on public.media (uploaded_by);

-- albums.albums_created_by_fkey：某人建立的所有相簿；建立者刪帳號時的 set null 反查
create index if not exists albums_created_by_idx on public.albums (created_by);

-- diaries.diaries_author_id_fkey：某人寫的所有日記；作者刪帳號時的 set null 反查
create index if not exists diaries_author_id_idx on public.diaries (author_id);

-- comments.comments_family_id_fkey：family 被刪除時 cascade 必須找出（含已軟刪除的）
-- 全部留言；comments_target_idx 是部分索引，覆蓋不到這個路徑
create index if not exists comments_family_id_idx on public.comments (family_id);

-- comments.comments_author_id_fkey：某人的所有留言；作者刪帳號時的 set null 反查
create index if not exists comments_author_id_idx on public.comments (author_id);

-- reactions.reactions_user_id_fkey：某人按過的所有讚；使用者刪帳號時的 cascade 反查
create index if not exists reactions_user_id_idx on public.reactions (user_id);

-- content_reports.content_reports_reporter_id_fkey：某人送出的所有檢舉；
-- 檢舉人刪帳號時的 set null 反查
create index if not exists content_reports_reporter_id_idx on public.content_reports (reporter_id);

-- blocked_users.blocked_users_blocker_id_fkey：我封鎖的人；封鎖者刪帳號時的 cascade 反查
create index if not exists blocked_users_blocker_id_idx on public.blocked_users (blocker_id);

-- blocked_users.blocked_users_blocked_id_fkey：封鎖我的人；被封鎖者刪帳號時的 cascade 反查
create index if not exists blocked_users_blocked_id_idx on public.blocked_users (blocked_id);
