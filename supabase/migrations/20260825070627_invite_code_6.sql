-- LS-90（LS-89 使用者裁決 A，2026-08-25）— 邀請碼長度 8 碼→6 碼（32 字元字母表不變，30 bit）
--
-- 背景：LS-46 使用者定案是「邀請碼英數 6 碼、3+3 分組」，但 LS-33 落地時
-- create_invite 產的是 8 碼／40 bit（正式站已部署）。LS-30 PR #136 review 發現
-- 這個落差本身還帶了一個數學錯誤（brand skill 誤寫「6 碼、對齊後端 40-bit」——
-- 6 × log2(32) = 30 bit，不是 40）。LS-89 裁決：後端改 6 碼——「核准必開」下邀請碼
-- 外洩／猜中最多只是多一筆待核申請給 owner 看，安全由審核承擔，6 碼＋審核比
-- 8 碼＋無審核更貼近「長輩手抄口述」的產品定位（理由全文見 LS-89）。
--
-- 這支 migration 只改「碼長度」這一件事，逐項交代：
--
-- 1. create_invite()：碼長度 8→6，字元集不變（32 字元、2 的冪，逐碼仍是滿的 5 bits，
--    理由與原本相同）。CREATE OR REPLACE 保留既有函式簽章與既有 grant
--    （authenticated 可執行、public/anon 不行是 20260823010000_join_approval.sql
--    第一次建立時做的，OR REPLACE 不會清掉物件的既有權限，不需要重新 revoke/grant）。
--
-- 2. request_join()：本檔不動它。它從來沒有對 p_code 做過長度／格式檢查——
--    正規化（去除非英數、轉大寫）之後直接對 invites.code 做「完全比對」，
--    不合規的輸入天生查不到任何列，回既有的 LS010（邀請碼不存在）。8 碼舊格式碼
--    在下面第 3 段失效之後同樣查不到列，一樣是 LS010，不需要、也不應該，額外加一層
--    專屬的長度／格式檢查（多一個要跟字元集規則保持同步的地方，見 supabase/tests/
--    80_join_approval.sql 新增的「8 碼舊格式被拒」案例）。
--
-- 3. 既有未過期的邀請一律失效：正式站目前沒有真實家庭在使用邀請碼（LS-90 票面
--    確認），用 UPDATE 而不是 DELETE／TRUNCATE——邀請碼底下的稽核紀錄與已經
--    核准／拒絕的 join_requests 都要留著，這裡只是讓「還沒被兌換」的碼失效，
--    跟 owner 手動撤銷（DELETE，20260823040000_invites_write_path.sql 第 3 段）是
--    不同的動作，語意上更接近「碼過期」而不是「碼被刪除」。
--    這一步刻意不用 DROP／TRUNCATE／DISABLE ROW LEVEL SECURITY 這幾個字
--    （scripts/gates/migration-breaking-check.sh 的 D1-D4）——一句 UPDATE 改
--    expires_at 不具那個性質，不需要 PR body 的 DESTRUCTIVE-APPROVED 核可標記；
--    但 create_invite 的 CREATE OR REPLACE（既有函式、本體行為改變）仍會被判
--    BREAKING（B4），PR body 仍要 `BREAKING:` 段落＋同 PR 動 docs/API.md。
--    只更新 expires_at 已經是未來的列（`where expires_at > now()`）——已經過期的
--    列不去動它，維持「這句話只做它宣稱要做的事」。
--
-- invites.code 的 CHECK 是 `char_length(code) between 6 and 64`
-- （20260822120000_init_schema.sql:86），6 已經在既有範圍內，不需要 ALTER TABLE。

create or replace function public.create_invite(
  p_family_id uuid,
  p_role text,
  p_expires_at timestamptz,
  p_max_uses integer
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- 32 個字元剛好是 2 的冪：亂數位元組 mod 32 沒有取模偏差（256 = 8 × 32）。
  c_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  -- 6 碼只需要 6 個完全隨機的位元組。UUID v4（gen_random_uuid()）的隨機位元組
  -- 落在 byte 0-5（time_low 4 bytes ＋ time_mid 2 bytes，RFC 9562 §5.4）；
  -- 不隨機的版本／variant 位元分別在 byte 6 高 nibble 與 byte 8 高 2 bits。
  -- 原本 8 碼版本要湊滿 8 個位置才需要跳過去挑 byte 7、9（見
  -- 20260823010000_join_approval.sql 的 c_random_bytes 與其註解，PR #36 review
  -- 抓到直接取 byte 0..7 會讓第 7 碼只剩半個字元集的坑）；6 碼只取前 6 個位元組
  -- 就夠，完全落在天生隨機的範圍內，不需要再挑選、跳過任何 byte。
  c_random_bytes constant int[] := array[0, 1, 2, 3, 4, 5];

  v_uid uuid := auth.uid();
  v_code text;
  v_bytes bytea;
  k int;
  attempt int;
begin
  if v_uid is null then
    raise exception '未登入，無法建立邀請碼' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid and m.role = 'owner'
  ) then
    raise exception '只有該家庭的 owner 能建立邀請碼' using errcode = '42501';
  end if;

  -- 參數邊界不變（LS017），理由見 20260823010000_join_approval.sql 對應段落——
  -- 這支 migration 不改這一段的任何行為，原封抄過來只是因為 CREATE OR REPLACE
  -- 要整支函式本體。
  if p_expires_at is null
     or p_expires_at <= now()
     or p_expires_at > now() + interval '30 days' then
    raise exception '邀請碼的到期時間必須在未來 30 天內' using errcode = 'LS017';
  end if;

  if p_max_uses is null or p_max_uses < 1 or p_max_uses > 20 then
    raise exception '邀請碼的可用次數必須介於 1 到 20 之間' using errcode = 'LS017';
  end if;

  -- 撞碼機率重新計算（LS-90 票面要求）：30 bit 空間，重試上限維持 5 次不變、
  -- 撞完仍是既有的 LS016，不新增錯誤碼（票面明講「不新增碼」）。即使同時有
  -- 10,000 支未過期邀請碼在使用（遠超過 PLAN §1「一家人」的量級），單次抽樣
  -- 撞中既有碼的機率也只有 10,000 / 2^30 ≈ 0.00093%，連撞 5 次的機率是這個數字
  -- 的 5 次方，實務上不可能發生；真的連撞 5 次代表亂數來源壞了，理由與原本
  -- 8 碼版本相同：fail loud，不要把 CPU 燒完。
  for attempt in 1..5 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for k in 1..6 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, c_random_bytes[k]) % 32) + 1, 1);
    end loop;

    begin
      insert into public.invites (family_id, code, role, created_by, max_uses, expires_at)
      values (p_family_id, v_code, p_role::public.family_role, v_uid, p_max_uses, p_expires_at);
      return v_code;
    exception when unique_violation then
      -- 撞碼重抽，理由與原本相同：真的連撞 5 次代表亂數來源壞了，不能寫成無限迴圈。
      null;
    end;
  end loop;

  raise exception '邀請碼產生連續撞碼，請重試' using errcode = 'LS016';
end;
$$;

-- ---------------------------------------------------------------------------
-- 既有未過期邀請一律失效（見上方第 3 點）。
-- ---------------------------------------------------------------------------
update public.invites set expires_at = now() where expires_at > now();
