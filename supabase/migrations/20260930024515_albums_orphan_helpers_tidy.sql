-- LS-412 — 孤兒相簿 helper 收尾：收掉 `owned_family_member_pairs()` 的 authenticated EXECUTE、
-- 覆寫兩支函式註解的措辭（LS-408 R1 i2／LS-409 R1 i2、i4）
--
-- 來源：LS-409 merge-review R1 i2／i4（池 224dade6）、LS-408 merge-review R1 i2（池 19c2d7dd）。
-- 只動權限與函式註解：不改任何函式本體、policy、簽名或回傳，authenticated 的行為不變。
--
-- 規格分歧與取捨：
--   a) 票文寫「零引用時 drop、否則 revoke＋註解」。`git grep owned_family_member_pairs` 結果：
--      `private.owned_orphan_album_ids()` 的函式本體（20260930015819_set_album_children_orphan_owner.sql:62）
--      仍在呼叫它——LS-409 R1 i2 說「只從 owned_orphan_album_ids() 內呼叫」正是這個意思——
--      所以**不能 drop**（drop 會讓 owned_orphan_album_ids() 在下次呼叫時報「function does not
--      exist」，albums_update 的孤兒分支與 set_album_children 整條壞掉）。改走「revoke
--      authenticated EXECUTE＋comment」。owned_orphan_album_ids() 是 SECURITY DEFINER、以 postgres
--      身分執行，巢狀呼叫 pairs 不需要 authenticated 有 EXECUTE；policy 與 RPC 也都已不直接引用
--      pairs（只引用 owned_orphan_album_ids()），所以 revoke 不影響任何呼叫路徑。
--      好處：那支刻意「不帶停權過濾」的 helper（只能安全用在 NOT IN 方向）不再能被 authenticated
--      直接呼叫，日後有人在另一條 policy 正向 `IN` 引用它時會在測試（tests/60）而不是正式站爆出來。
--      tests/60 allowlist 同步拿掉這一項（不在 allowlist 的 private 函式一律斷言 authenticated
--      沒有 EXECUTE，等於把 revoke 變成常設 gate）。
--   b) 註解措辭（LS-409 R1 i4）：LS-409 migration 的檔頭取捨 b 與 pairs 的函式註解寫「補過濾會讓
--      NOT IN (空集合) 恆真，等於所有相簿都被判成孤兒」——這只在外層 owner 家庭條件**也**不帶停權
--      過濾時成立。現行組合下外層 `family_id in (select private.owned_family_ids())` 已含
--      caller_is_active()／family_is_active()，呼叫者被停權時外層本來就是空集合，孤兒集合已經是空，
--      補過濾結果不變（merge-review 以 X2 探針實測）。不補過濾的真正理由是防禦縱深：pairs 只在
--      NOT IN 方向，不過濾的 superset 是安全側；一旦外層停權過濾退步，補了過濾的 pairs 會空掉、
--      把作者仍在的相簿也判成孤兒（X3 探針：停權 owner 對作者仍在的相簿授權放行）。本檔以
--      `comment on function` 覆寫正確措辭；LS-409 舊 migration 檔不動（migration-immutable）。
--   c) `comment on function public.set_album_children`：該函式原本沒有 DB 註解，授權規則只寫在
--      檔內註解與 API.md。補一則，與 owned_orphan_album_ids() 同單一來源的說法一致。

revoke execute on function private.owned_family_member_pairs() from authenticated;

comment on function private.owned_family_member_pairs() is
  'LS-408：呼叫者是 owner 的家庭的全部 (family_id, user_id) 成員對（不含停權／停用過濾）。'
  '內部 helper，只供 owned_orphan_album_ids() 內部呼叫（LS-412 起 authenticated 無 EXECUTE）。'
  '只能用在 NOT IN 方向、並與 owned_family_ids() 搭配：不過濾的 superset 對 NOT IN 是安全側；'
  '停權語意由外層 owned_family_ids()（含 caller_is_active()／family_is_active()）承擔。'
  '不補停權過濾是防禦縱深——現行組合下補了結果不變（外層已空），但外層過濾若退步，'
  '補過濾的集合會變空、NOT IN 對空集合恆真，把作者仍在的相簿也判成孤兒。';

comment on function private.owned_orphan_album_ids() is
  'LS-409：呼叫者是 owner 的（未停權）家庭裡，孤兒相簿的 id 集合——孤兒判定的唯一定義處。'
  '孤兒＝created_by 為 NULL，或 created_by 不在該家庭的 family_members（降級成 viewer 仍在表內，'
  '不算孤兒）。albums_update policy 的 owner 分支與 set_album_children 共用；'
  '停權／停用語意由內層 owned_family_ids() 承擔（tests/122 §3 守）；'
  'plan 形狀（hashed SubPlan、loops=1、STABLE）由 tests/123 守。';

comment on function public.set_album_children(uuid, uuid[]) is
  'LS-409：覆寫相簿的寶貝標記。授權＝相簿作者本人（仍是該家庭 owner/member），'
  '或該家庭 owner 且相簿在 private.owned_orphan_album_ids() 內（孤兒相簿）；'
  '其餘 LS045。for update 鎖相簿列後才判定授權。';
