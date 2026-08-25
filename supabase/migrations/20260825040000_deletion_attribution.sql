-- LS-57 — owner 軟刪的內容記錄 deleted_by：作者不能自行還原被 owner 移除的內容；
-- albums/comments 的 family_id 收斂為不可變欄
--
-- 背景（PR #70 review F4 實測，見 LS-57 ticket）：owner 對 diaries／albums／comments
-- 呼叫 set_*_deleted(id, true) 軟刪之後，原作者只要還過得了各支 RPC 既有的「還是不是
-- 該家庭成員」授權檢查，就能直接呼叫 set_*_deleted(id, false) 把它還原回來——PLAN
-- §10-B「owner 要有移除內容的能力」的意圖沒有真的達成，owner 的「移除」其實是可被
-- 當事人單方面撤銷的 advisory 動作。使用者定案（2026-08-25）：owner 移除必須是**不可
-- 被作者撤銷**的——記錄 deleted_by；作者只能還原自己設下的 deleted_at，owner 設的
-- 只有 owner 能還原。
--
-- ---------------------------------------------------------------------------
-- 為什麼用一支共用的 BEFORE UPDATE trigger，而不是分別改三支 RPC 的函式本體
--
-- diaries／comments 的 INSERT/UPDATE 已經是 RPC-only（LS-48／LS-58，直接 INSERT/UPDATE
-- 對 authenticated 的 grant 已整個收回），三支 set_*_deleted 尾端那句
-- `update ... set deleted_at = case when p_deleted then now() else null end` 是這兩張表
-- 唯一還能寫到 deleted_at 的入口——授權判斷可以完全留在 RPC 裡。但 albums 仍是 LS-52
-- 定案的 hybrid 模式：建立者對自己的相簿保留直接 `.update()` 路徑
-- （20260825010000_albums_comments_owner_scope.sql 的 albums_update policy），且這條
-- 路徑上 RLS 完全沒有機會看到 deleted_by（USING/WITH CHECK 只判 created_by／
-- family_id，不看這一列現在是誰刪的）——作者能直接 `update albums set deleted_at = null`
-- 繞過 set_album_deleted 裡任何寫在 PL/pgSQL 裡的檢查。要讓「owner 刪的作者不能自行
-- 還原」這條規則對 albums 的兩條寫入路徑（RPC／直接 UPDATE）都成立，唯一的施力點是
-- 資料表本身的 BEFORE UPDATE trigger——不管寫入是從哪條路徑來的，trigger 都會跑。
--
-- 既然 albums 非用 trigger 不可，diaries／comments 沒有理由另外在 RPC 裡重寫一份等價
-- 邏輯（兩份日後會漂移，正是 CLAUDE.md「前饋必有反饋」要避免的重複維護）：三張表共用
-- 同一支 trigger 函式，只依賴 deleted_at／deleted_by／family_id 三個同名欄位，函式本身
-- 不知道也不需要知道自己被掛在哪張表上（TG_TABLE_NAME 只用來組錯誤訊息的中文名稱）。
-- 三支 set_*_deleted RPC 的函式本體因此完全不需要修改——它們尾端那句 UPDATE 不論寫不
-- 寫 deleted_by，實際寫進資料庫的值都由這支 trigger 決定（BEFORE 觸發器可以覆寫 NEW，
-- Postgres 最終寫入的是 trigger 跑完之後的 NEW，不是呼叫端 UPDATE 語句原本 SET 的值）。
-- 對 diaries／comments 而言，這支 trigger 純粹是既有 RPC 授權邏輯之外的第二道防線
-- （目前唯一寫入路徑就是 RPC 本身，trigger 恆為 no-op 或與 RPC 邏輯同向），但這正是
-- 「新增重要規則＝同時新增機械 gate」的體現：日後若 diaries／comments 的直接 UPDATE
-- grant 被重新打開（不論有意或失誤），這條規則不會因此silently失效。
--
-- ---------------------------------------------------------------------------
-- deleted_by 的推導規則（trigger 內，呼叫端無法覆寫）
--
--   NEW.deleted_at 為 NULL（還原）              → NEW.deleted_by 恆為 NULL
--   OLD.deleted_at 為 NULL 且 NEW 不是 NULL（全新軟刪） → NEW.deleted_by := auth.uid()
--   其餘（OLD／NEW 皆非 NULL，例如已刪除狀態下改別的欄位、或對已刪除列重複呼叫
--     p_deleted=true）                          → NEW.deleted_by 維持 OLD 的值不變
--
-- 第三條刻意存在，不是遺漏：如果對「已經被 owner 刪除」的列重新呼叫
-- set_diary_deleted(id, true)，若讓 deleted_by 跟著改寫成這次呼叫者，等於讓通過
-- RPC 既有「還是不是成員」檢查的作者，用一次「重複軟刪」就把 deleted_by 的歸屬從
-- owner 洗成自己，再呼叫一次還原就繞過下面的鎖——這是比直接測還原更隱蔽的繞過路徑，
-- 必須在推導規則本身就堵掉，不能只靠下面的還原檢查。這條規則的直接後果：只有「從
-- 未刪除到已刪除」的那一次轉換，deleted_by 才會被寫入／更新；重複軟刪只更新
-- deleted_at 的時間戳，不動 deleted_by。
--
-- deleted_by 一律不接受呼叫端指定——它完全由上面三條規則推導，這支 trigger 對
-- NEW.deleted_by 的賦值會覆寫任何呼叫端（不論是這三支 RPC 自己的 UPDATE 語句，還是
-- albums 作者的直接 UPDATE）試圖寫入的值，物理上不可能被竄改。
--
-- ---------------------------------------------------------------------------
-- 還原鎖：非 owner 不能清空「別人設下」的 deleted_at
--
-- 只在「還原方向」（NEW.deleted_at 變成 NULL）且「原本確實是刪除狀態」
-- （OLD.deleted_at 不是 NULL，排除本來就沒刪、NULL→NULL 的 no-op）時檢查；「刪除方向」
-- （重複軟刪／首次軟刪）完全不受這條規則限制——見上一段，重複軟刪不會偷走 deleted_by
-- 的歸屬，物理上就不構成繞過，沒有理由連帶擋下，維持規則最小、只管票面要求的「作者
-- 不能自行還原 owner 刪的」這一件事（YAGNI；不擴大成「非 owner 不能碰別人刪的
-- deleted_at 的任何動作」這種票面沒要求的更廣規則）。
--
-- 條件：OLD.deleted_by 不是 NULL（有明確歸屬）、OLD.deleted_by 不是這次呼叫者本人
-- （不是自己刪的）、且呼叫者現在不是這個家庭的 owner（owner 可以還原任何人的移除，
-- 不限於自己刪的）——三者同時成立才擋，用 LS027。
--
-- OLD.deleted_by 為 NULL 時（這支欄位是新加的，本 migration 套用前就已經軟刪除的
-- 既有列，deleted_by 預設為 NULL——沒有回溯的稽核資料可以回填「當初是誰刪的」）刻意
-- 不擋：對這些既有列，維持 LS-57 之前「作者能自行還原」的舊行為，不會讓歷史資料在
-- migration 套用的那一刻突然被鎖死、變成誰都還原不了。這是誠實反映「我們就是不知道
-- 當初是誰刪的」，不是漏洞——新產生的每一筆刪除，從這支 migration 套用的那一刻起，
-- deleted_by 保證非 NULL（見上面的推導規則），這條例外只會隨著舊資料被還原或保持刪除
-- 狀態而自然消失，不需要額外的回填或清理排程。
--
-- ---------------------------------------------------------------------------
-- family_id 不可變（PR #70 review N2 追加）
--
-- albums／comments 的 family_id 對建立者／作者可寫，是「作者能把自己建立的相簿／
-- 留言整列搬到自己也是 contributor 的另一個家庭」這個側門成立的前提——這正是
-- N1 跨家庭越權 race（見 supabase/tests/concurrency/album_edit_vs_delete_s2_delete_
-- after_move.sql 的歷史說明）之所以「有東西可以被搬」的原因。diaries／comments 因為
-- INSERT/UPDATE 已經是 RPC-only、且兩支 update RPC（update_diary_entry／
-- update_comment）簽章都不接受 family_id 參數，這條路徑其實已經不存在；只有 albums
-- 的 hybrid 直接 UPDATE 路徑還真的碰得到。三張表仍然統一在同一支 trigger 裡擋下（不
-- 只擋 albums）：函式本身不分表，多擋兩張已經物理上碰不到這條路的表沒有額外代價，
-- 且是面向未來的防線——哪天 diaries／comments 的 RPC 簽章改了、意外多接受一個
-- family_id 參數，這裡不會因此悄悄開一個新洞。
--
-- 用裸 42501（不開新錯誤碼）：這不是使用者操作下會踩到的正常情境（app 不會、也不該
-- 生出「把 family_id 塞進 UPDATE body」這種請求），沒有 UI 需要用專屬碼區分文案，比照
-- 現有「直接寫入被 grant 擋下」的慣例（docs/API.md §5 42501 列）。
--
-- 副作用：album_edit_vs_delete「方向 C：作者搬家」併發場景（原本驗 set_album_deleted
-- 的 `for update` 在「family_id 被搬到別家」這個 race 下是否守得住）的**前提**——
-- family_id 可以被作者直接 UPDATE 改掉——不再成立：作者的搬家 UPDATE 本身現在會直接
-- 被這支 trigger 擋下 42501，不需要、也不可能靠併發時序去踩這個攻擊面。這組場景
-- 隨本票一起退役，比照 LS-58 讓 comments 版同一場景退役的處理方式（見
-- supabase/tests/run.sh 對應段落的說明）。
-- ---------------------------------------------------------------------------

alter table public.diaries add column deleted_by uuid references public.profiles (id) on delete set null;
alter table public.albums add column deleted_by uuid references public.profiles (id) on delete set null;
alter table public.comments add column deleted_by uuid references public.profiles (id) on delete set null;

-- 65_fk_reverse_index.sql 的反向索引要求：deleted_by 是新的外鍵欄位，需要各自的索引。
create index diaries_deleted_by_idx on public.diaries (deleted_by);
create index albums_deleted_by_idx on public.albums (deleted_by);
create index comments_deleted_by_idx on public.comments (deleted_by);

comment on column public.diaries.deleted_by is
  '軟刪這篇日記的人（LS-57，set_diary_deleted 內部由 private.enforce_deletion_attribution()'
  ' trigger 推導寫入，呼叫端無法指定）。NULL＝目前未刪除，或本欄位新增之前就已軟刪除的'
  '既有資料（無法回溯歸屬）。作者只能還原 deleted_by = 自己的；owner 能還原任何一篇；'
  '作者對 owner 刪的呼叫還原會拿到 LS027。';
comment on column public.albums.deleted_by is
  '軟刪這本相簿的人（LS-57，set_album_deleted 或建立者直接 UPDATE deleted_at 皆由'
  ' private.enforce_deletion_attribution() trigger 推導寫入，呼叫端無法指定）。NULL＝'
  '目前未刪除，或本欄位新增之前就已軟刪除的既有資料。規則同 diaries；albums 額外由'
  '同一支 trigger 擋下「直接 UPDATE 竄改 deleted_by／family_id」。';
comment on column public.comments.deleted_by is
  '軟刪這則留言的人（LS-57，set_comment_deleted 內部由'
  ' private.enforce_deletion_attribution() trigger 推導寫入，呼叫端無法指定）。規則同'
  ' diaries。';

create or replace function private.enforce_deletion_attribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_label text := case tg_table_name
                    when 'diaries' then '這篇日記'
                    when 'albums' then '這本相簿'
                    when 'comments' then '這則留言'
                    else '這筆內容'
                  end;
begin
  -- family_id 不可變：不論走哪條寫入路徑，一律擋下。
  if new.family_id is distinct from old.family_id then
    raise exception '% 所屬的家庭不可變更（family_id 是不可變欄位，LS-57）', v_label
      using errcode = '42501';
  end if;

  -- deleted_by 推導（呼叫端無法覆寫，見檔頭說明）
  if new.deleted_at is null then
    new.deleted_by := null;
  elsif old.deleted_at is null then
    new.deleted_by := v_uid;
  else
    new.deleted_by := old.deleted_by;
  end if;

  -- 還原鎖：只管「清空別人設下的 deleted_at」這一個方向
  if new.deleted_at is null
     and old.deleted_at is not null
     and old.deleted_by is not null
     and old.deleted_by is distinct from v_uid
     and not exists (
       select 1 from public.family_members m
        where m.family_id = old.family_id and m.user_id = v_uid and m.role = 'owner'
     ) then
    raise exception '% 已被家庭管理者移除，只有管理者能還原', v_label
      using errcode = 'LS027';
  end if;

  return new;
end;
$$;

create trigger diaries_deletion_attribution
  before update on public.diaries
  for each row execute function private.enforce_deletion_attribution();

create trigger albums_deletion_attribution
  before update on public.albums
  for each row execute function private.enforce_deletion_attribution();

create trigger comments_deletion_attribution
  before update on public.comments
  for each row execute function private.enforce_deletion_attribution();
