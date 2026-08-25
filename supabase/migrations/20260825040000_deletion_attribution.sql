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
-- R1（merge-reviewer PR #98 review，2026-08-25）指出初版三個實質問題（B1 blocker、
-- B2／B3 應修，orchestrator 裁決比照 B1 一併處理），本檔是修過的版本：
--   B1：deleted_by 掛 FK 之後，帳號刪除觸發的 RI SET NULL 動作本身會被這支 trigger
--       擋下（見下方「B1：放行 FK RI 動作」段落）。
--   B2：owner 對「已被作者自刪」的內容再次移除時，deleted_by 必須升級成 owner，不能
--       維持作者不變（見下方「owner 後手移除＝歸屬升級」段落）。
--   B3：deleted_by 為 NULL 不再只代表「migration 套用前的既有資料」，帳號被刪除的
--       RI 動作也會產生 NULL——因此「deleted_by 為 NULL」統一按「只有 owner 能還原」
--       處理，不區分是舊資料還是移除者已消失（見下方「還原鎖」段落）。
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
-- B1：放行 FK RI 動作（merge-reviewer PR #98 review blocker，實測重現）
--
-- deleted_by 掛了 `references profiles(id) on delete set null`——刪除一個 profile
-- （帳號刪除流程，PLAN §9-A2／App Store Guideline 5.1.1(v) 要求的 MVP 必要功能）時，
-- Postgres 的 RI（referential integrity）動作本身就是一句
-- `update <table> set deleted_by = null where deleted_by = <即將消失的 profile id>`
-- ——這句 UPDATE 一樣會觸發這支 BEFORE UPDATE trigger。若不放行，trigger 會依下面的
-- 推導規則判斷「deleted_at 沒有變、不是刪除/還原的轉換」，把 RI 剛塞的 NULL 依規則
-- 改回舊值（即將消失的 profile id）——FK 檢查本身就會在這句 UPDATE 完成前噴
-- `23503 foreign key violation`，等於任何名下有「目前仍是軟刪狀態、且 deleted_by
-- 是他」的內容的使用者，帳號都刪不掉（即使已經把 owner 身分轉移給別人也一樣，因為
-- RI 動作是在帳號真正被刪除時才觸發，不是轉移 owner 的當下）。
--
-- 修法：判定式只認「deleted_by 從非 NULL 變 NULL、deleted_at 完全沒動」這個特徵——
-- SET NULL 的 RI 動作只寫 FK 欄位本身，不會動同一列的其他欄位——命中就直接
-- `return new`，略過後面所有推導與還原鎖判斷，不需要 auth.uid()（RI 動作不代表任何
-- 使用者身分，也不該套用任何使用者層級的授權判斷）。
--
-- 已知、刻意接受的殘餘風險：這個判定式無法區分「真的是 RI 動作」與「呼叫端自己送出
-- 一句只改 deleted_by、不改 deleted_at 的 UPDATE」（albums 的 hybrid 直接 UPDATE
-- 路徑對 deleted_by 沒有欄位級 grant 限制，理論上建立者能送出這種請求）——放行後
-- deleted_by 會被清成 NULL，但不构成繞過：deleted_by 為 NULL 之後，還原鎖（見下）
-- 一律要求 owner 才能還原，建立者不會因此拿到多的權限，只是把稽核用的歸屬值抹成
-- NULL，是資料完整性的小瑕疵，不是授權漏洞，暫不加額外欄位級限制去堵（YAGNI）。
--
-- 誠實記錄一個 mutation 測試意外發現的重疊（不是漏洞，是實作上的巧合）：下面
-- 「deleted_by 的推導規則」段落另外有一句「這次 UPDATE 沒有真的動 deleted_at 就
-- 直接放行」的判定式（保護 update_comment 編輯已軟刪留言那種場景，見該段落）——
-- RI 的 SET NULL 動作定義上只碰 deleted_by、不碰 deleted_at，所以單獨拿掉這裡的
-- B1 判定式、只靠後面那句「deleted_at 沒變就放行」，帳號刪除一樣不會被打死（本機
-- mutation 實測過：只移除這段、保留後面那句，帳號刪除測試仍然全綠）。這代表這裡
-- 這句判定式目前是可以被後面那句涵蓋的冗餘防線——刻意保留，不是沒發現：(a) 這裡
-- 是唯一明確標註「這是 RI 動作，不是使用者操作」語意的地方，後面那句只是廣義的
-- 「deleted_at 沒變就跳過」，兩者的意圈不同，讀者要理解「為什麼帳號刪得掉」該看
-- 這裡而不是去推敲後面那句的副作用；(b) 兩句判定式若日後任一句被改動（例如後面
-- 那句加了額外條件），這裡仍然獨立成立，不會因為另一句變動而悄悄回歸 B1 的問題。
-- `supabase/tests/88_deletion_attribution.sql` 的 mutation 說明對這個重疊有對應
-- 調整（見該檔 M4 的註記）。
--
-- ---------------------------------------------------------------------------
-- deleted_by 的推導規則（trigger 內，呼叫端無法覆寫）
--
-- 只在「這次 UPDATE 確實在動 deleted_at」（`new.deleted_at is distinct from
-- old.deleted_at`）時才介入；deleted_at 完全沒變的一般欄位編輯（例如 comments 對
-- 已軟刪留言的 update_comment——LS-58 定案「已軟刪除的留言仍可編輯」、albums 對
-- 自己相簿 title 的直接 UPDATE）直接放行，不推導也不檢查——trigger 看不到呼叫端
-- 原始的 SET 子句，無法區分「真的沒把 deleted_at 放進 SET 子句」與「放了但新舊值
-- 剛好相同」，選擇不介入是比較安全的方向：誤放行「同一交易內連續呼叫、now() 剛好
-- 沒變」這種邊角案例，好過誤擋下「已軟刪除的留言仍可編輯內容」這種既有、有文件
-- 記錄的合法行為。
--
--   呼叫者是這個家庭的 owner            → NEW.deleted_at 非 NULL 時 deleted_by :=
--                                          呼叫者本人；NULL 時 := NULL。owner 的
--                                          每一次觸碰都是權威動作，不論 OLD 狀態
--                                          為何（見下方「owner 後手移除＝歸屬升級」）。
--   呼叫者不是 owner，OLD.deleted_at 為 NULL（全新軟刪） → deleted_by := 呼叫者本人。
--   呼叫者不是 owner，OLD.deleted_at 非 NULL 且 OLD.deleted_by 是呼叫者本人
--     （自己刪的東西自己重複軟刪／還原）        → deleted_by 維持不變（還原時變 NULL，
--                                                重複軟刪時仍是自己）。
--   呼叫者不是 owner，OLD.deleted_at 非 NULL 且 OLD.deleted_by 不是呼叫者本人
--     （含 OLD.deleted_by 為 NULL——B3）        → 一律擋下（見下方「還原鎖」），
--                                                不會走到這條推導。
--
-- ---------------------------------------------------------------------------
-- owner 後手移除＝歸屬升級（B2，merge-reviewer PR #98 review 應修，實質等同 blocker）
--
-- 初版的推導規則「OLD／NEW 皆非 NULL → 維持 OLD.deleted_by 不變」是對稱套用在
-- owner 與作者身上的——這個對稱本身就是漏洞：作者自刪之後，owner 再按一次「移除」
-- （對已經是刪除狀態的列重複呼叫 set_*_deleted(true)，或 UI 上單純想確認這篇內容
-- 已經清掉），deleted_by 依對稱規則會維持是作者，不會變成 owner。owner 這個「移除」
-- 動作因此变成沒有實際效力的 no-op——作者事後仍能自行還原，架空了本票要堵的那件事
-- （owner 移除必須不可被作者撤銷）。實際會發生的兩種情境：
--   1. race：作者的自刪與 owner 的移除幾乎同時發出，作者那筆先 commit，owner 的
--      移除在歸屬上是 no-op。
--   2. stale UI：owner 的列表還沒 refresh，作者剛把自己那篇自刪掉，owner 對它按
--      「移除」——RPC 回 void、沒有任何錯誤，owner 合理相信已永久移除；作者稍後
--      還原，內容重新出現。
--
-- 修法：owner 分支不再對稱——owner 對 deleted_at 的任何觸碰（軟刪、重複軟刪、
-- 還原）一律把 deleted_by 覆寫成 owner 自己（還原時是 NULL），不論 OLD.deleted_by
-- 原本是誰。這是「owner 移除永遠壓過作者自刪」的直接體現：owner 的動作永遠是最新、
-- 最權威的一次。非 owner（只可能是作者本人，能走到推導規則代表已經通過還原鎖）的
-- 對稱保留規則不變——作者不能靠重複軟刪把別人（owner）設下的歸屬洗成自己，這條
-- 防線與初版相同，只是現在是單向的（owner 可以覆寫作者，作者不能覆寫 owner 或
-- 未知的移除者）。
--
-- ---------------------------------------------------------------------------
-- 還原鎖：非 owner 不能清空／重新觸碰「不是自己刪的」deleted_at
--
-- 條件：呼叫者不是這個家庭的 owner，且 OLD.deleted_at 非 NULL（現在確實是刪除
-- 狀態），且 OLD.deleted_by 不是呼叫者本人（含 OLD.deleted_by 為 NULL——B3，見下）
-- ——三者同時成立就擋，用 LS027，不論這次呼叫是想「還原」（NEW.deleted_at 變
-- NULL）還是「重複軟刪」（NEW.deleted_at 仍非 NULL）：兩個方向都是在觸碰一個
-- 「不是自己刪的」deleted_at，都不該被非 owner 的呼叫成功——重複軟刪雖然本身不會
-- 偷走歸屬（推導規則已經防住），但放行重複軟刪會讓呼叫端誤以為「移除」對這篇內容
-- 生效了（RPC 回 void、無錯誤），語意上與真正擁有這篇內容處置權的人（owner 或
-- 原刪除者本人）的預期不符，比照 B2 的精神一併擋下，不只挑還原方向。
--
-- B3（merge-reviewer PR #98 review 應修）：OLD.deleted_by 為 NULL 时的處理，不再是
-- 「跳過還原鎖、比照 LS-57 之前的行為放行」——deleted_by 為 NULL 現在有兩種成因，
-- 且都不能讓非 owner 的呼叫者暢通無阻：
--   (a) 本欄位新增之前就已軟刪除的既有資料——不知道當初是誰刪的。
--   (b) 移除者的帳號後來被刪除了（B1 的 RI 動作把 deleted_by 清成 NULL）——移除者
--       這個人已經不存在了，但這篇內容「被某個曾經有權限移除它的人移除過」這件事
--       本身沒有改變。
-- 兩種情況下，「deleted_by 是不是恰好等於呼叫者」這個問題都答不出「是」（NULL 不會
-- 等於任何具體 uuid），比照「不是自己刪的」同樣的邏輯，只有 owner 能處理——`old.
-- deleted_by is distinct from v_uid` 這個 NULL-safe 比較天然涵蓋這個情況（NULL
-- 與任何非 NULL 值比較恆為「is distinct」），不需要為 NULL 另外分支判斷。
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
-- family_id 參數，這裡不會因此悄悄開一個新洞。這項檢查不受「deleted_at 有沒有變」
-- 的短路影響，任何一次 UPDATE 都會檢查。
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
  '軟刪這篇日記的人（LS-57，private.enforce_deletion_attribution() trigger 推導寫入，'
  '呼叫端無法指定）。NULL＝目前未刪除；或雖是刪除狀態，但（a）本欄位新增之前就已'
  '軟刪除的既有資料，或（b）移除者的帳號後來被刪除（FK on delete set null）——兩種'
  'NULL 都視為「移除者不明」，只有 owner 能還原（B3，PR #98 review）。作者只能還原'
  ' deleted_by 是自己的；owner 能還原任何一篇，且 owner 對已被作者自刪的內容再次'
  '移除時，deleted_by 會升級成 owner（B2）；作者對 owner 刪的（含 deleted_by 為'
  ' NULL 的情況）呼叫還原或重複軟刪都會拿到 LS027。';
comment on column public.albums.deleted_by is
  '軟刪這本相簿的人（LS-57，set_album_deleted 或建立者直接 UPDATE deleted_at 皆由'
  ' private.enforce_deletion_attribution() trigger 推導寫入，呼叫端無法指定）。規則'
  '同 diaries（NULL 語意見該欄位註解）；albums 額外由同一支 trigger 擋下「直接'
  ' UPDATE 竄改 family_id」。';
comment on column public.comments.deleted_by is
  '軟刪這則留言的人（LS-57，set_comment_deleted 內部由'
  ' private.enforce_deletion_attribution() trigger 推導寫入，呼叫端無法指定）。規則'
  '同 diaries（NULL 語意見該欄位註解）。';

create or replace function private.enforce_deletion_attribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_label text;
  v_is_owner boolean;
begin
  -- B1：FK 的 on delete set null RI 動作——判定式見檔頭「B1：放行 FK RI 動作」。
  -- 必須是全函式第一件事：不需要 auth.uid()，也不該對 RI 動作套用 family_id／
  -- 授權判斷。
  if new.deleted_by is null
     and old.deleted_by is not null
     and new.deleted_at is not distinct from old.deleted_at then
    return new;
  end if;

  v_label := case tg_table_name
               when 'diaries' then '這篇日記'
               when 'albums' then '這本相簿'
               when 'comments' then '這則留言'
               else '這筆內容'
             end;

  -- family_id 不可變：不受「deleted_at 有沒有變」影響，任何一次 UPDATE 都檢查。
  if new.family_id is distinct from old.family_id then
    raise exception '% 所屬的家庭不可變更（family_id 是不可變欄位，LS-57）', v_label
      using errcode = '42501';
  end if;

  -- deleted_at 完全沒變的一般欄位編輯：deleted_by／還原鎖不必介入，見檔頭「deleted_by
  -- 的推導規則」段落的說明。
  if new.deleted_at is not distinct from old.deleted_at then
    return new;
  end if;

  v_uid := auth.uid();

  v_is_owner := exists (
    select 1 from public.family_members m
     where m.family_id = old.family_id and m.user_id = v_uid and m.role = 'owner'
  );

  if v_is_owner then
    -- B2：owner 後手移除＝歸屬升級——owner 的每一次觸碰都是權威動作，不論
    -- OLD.deleted_by 原本是誰，見檔頭同名段落。
    if new.deleted_at is null then
      new.deleted_by := null;
    else
      new.deleted_by := v_uid;
    end if;
    return new;
  end if;

  -- 非 owner（只可能是這一列的作者／建立者本人，能走到這裡代表已經通過呼叫端 RPC
  -- 或 albums 直接 UPDATE 各自的「是不是還在這個家庭」授權檢查）：
  if old.deleted_at is not null and old.deleted_by is distinct from v_uid then
    -- 現在是刪除狀態，且刪的人不是自己——含 OLD.deleted_by 為 NULL 的情況（B3：
    -- NULL 與任何非 NULL 的 v_uid 比較恆為 distinct，天然涵蓋「移除者不明」）。
    -- 不論這次呼叫是想「還原」還是「重複軟刪」，一律擋下，不放行也不動 deleted_by。
    raise exception '% 已被家庭管理者移除，只有管理者能還原', v_label
      using errcode = 'LS027';
  end if;

  -- 走到這裡：要嘛是全新軟刪（OLD.deleted_at 為 NULL），要嘛是自己刪的東西自己
  -- 重複軟刪／還原。
  if new.deleted_at is null then
    new.deleted_by := null;
  elsif old.deleted_at is null then
    new.deleted_by := v_uid;
  else
    new.deleted_by := old.deleted_by;  -- 自己重複軟刪：維持原值（＝自己），no-op
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
