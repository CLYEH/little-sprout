-- LS-33：邀請碼、加入申請與管理員審核（LS-18 後端）
--
-- 這個檔案逐條驗 LS-33 的驗收條件。整個檔案跑在一個交易裡，結尾 rollback，
-- 不影響其他測試檔（併發時序測不進來，另見 supabase/tests/concurrency/join_race_*.sql
-- 與 approve_reject_race_*.sql）。
--
-- 斷言依據的標註慣例（LS-15 review round 2 定下）：每一段都註明該段斷言是靠
-- 「我們自己的 migration」還是「Postgres 的機械事實」，避免出現一條在空白環境
-- 也會通過、其實什麼都沒證明的斷言。

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 前置：四位測試帳號（都不屬於任何家庭，交易結束即消失）
--   甲 e…0001：走完 申請 → 核准 的主線
--   乙 e…0002：走 拒絕 / 撤回 / 重複申請 的分支
--   丙 e…0003：驗「審核關閉時直接入家」
--   丁 e…0004：驗「建立家庭時 creator 自動成為 owner」的回歸
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('e0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'e-applicant1@ls33.test', now(), now(), '{}', '{}'),
  ('e0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'e-applicant2@ls33.test', now(), now(), '{}', '{}'),
  ('e0000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'e-applicant3@ls33.test', now(), now(), '{}', '{}'),
  ('e0000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'e-founder@ls33.test',    now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱
-- （下面 1222 行驗 display_name = '申請人乙' 依賴的是這個名字）。
insert into public.profiles (id, display_name) values
  ('e0000000-0000-4000-8000-000000000001', '申請人甲'),
  ('e0000000-0000-4000-8000-000000000002', '申請人乙'),
  ('e0000000-0000-4000-8000-000000000003', '申請人丙'),
  ('e0000000-0000-4000-8000-000000000004', '自建家庭的丁')
on conflict (id) do update set display_name = excluded.display_name;

-- ---------------------------------------------------------------------------
-- 1. create_invite：只有 owner；碼的形狀是規約的一部分
--
-- 依據：全部由本票的 migration 保證（owner 檢查、字元集、長度、到期時間檢查都寫在函式裡）。
-- 「碼不含 0/O/1/I」不是美觀要求：長輩會把碼抄在紙上、在電話裡念，這四個字元是
-- 手抄與口述錯誤的最大來源，讀錯就是一次注定失敗的申請。
--
-- LS-90：長度 8→6（LS-89 裁決 A），字元集不變。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_distinct int;
  v_main text;
begin
  -- 主邀請碼（member、3 次）
  v_main := public.create_invite('fa000000-0000-4000-8000-000000000001', 'member',
                                 now() + interval '7 days', 3);
  perform set_config('ls33.code_main', v_main, true);

  if v_main !~ '^[2-9A-HJ-NP-Z]{6}$' then
    raise exception 'FAIL：邀請碼「%」不符字元集規約（6 碼、大寫、不含 0/O/1/I）', v_main;
  end if;

  -- 只剩一個名額的碼（併發／用罄測試用）
  perform set_config('ls33.code_last',
    public.create_invite('fa000000-0000-4000-8000-000000000001', 'member',
                         now() + interval '7 days', 1), true);
  -- viewer 角色的碼（驗「入家角色取自邀請碼」）
  perform set_config('ls33.code_viewer',
    public.create_invite('fa000000-0000-4000-8000-000000000001', 'viewer',
                         now() + interval '7 days', 1), true);
  -- 重複申請測試用（名額寬裕，確保撞到的是 LS014 而不是 LS012）
  perform set_config('ls33.code_dup',
    public.create_invite('fa000000-0000-4000-8000-000000000001', 'member',
                         now() + interval '7 days', 5), true);

  -- 連抽四支碼都不重複、都合規（撞碼重抽那段迴圈不會產生同一個碼）
  select count(distinct c) into strict v_distinct from (values
    (current_setting('ls33.code_main')), (current_setting('ls33.code_last')),
    (current_setting('ls33.code_viewer')), (current_setting('ls33.code_dup'))
  ) as t(c);
  if v_distinct <> 4 then
    raise exception 'FAIL：四支邀請碼出現重複（distinct=%）', v_distinct;
  end if;

  raise notice 'ok：owner 產碼成功，四支碼皆為 6 碼、字元集不含 0/O/1/I';
end;
$$;

-- ---------------------------------------------------------------------------
-- 1b. create_invite 的參數邊界（LS017）
--
-- 依據：本票 create_invite 裡的兩段驗證。RPC 是安全邊界不是 UI 的輔助——UI 的
-- 下拉選單擋得住手滑，擋不住直接打 /rest/v1/rpc/create_invite 的人，而
-- expires_at／max_uses 正是 PLAN §5、§8 用來限制邀請碼外洩後果的那兩個旋鈕。
-- 五種壞參數共用 LS017 一個錯誤碼（同一類失敗只給 UI 一種形狀）。
-- ---------------------------------------------------------------------------
do $$
declare
  c record;
begin
  for c in
    select * from (values
      ('到期時間在過去（建得起來但兌換不了，純粹的支援案件）', '-1 minute'::interval, 1),
      ('到期時間超過 30 天上限（外流一次就長期開放）',        '31 days'::interval,   1),
      ('可用次數 0',                                          '7 days'::interval,    0),
      ('可用次數 21（超過上限）',                             '7 days'::interval,   21),
      ('可用次數 NULL（原本裸噴 23502，UI 認不得）',          '7 days'::interval, null)
    ) as t(label, offs, uses)
  loop
    begin
      perform public.create_invite('fa000000-0000-4000-8000-000000000001', 'member',
                                   now() + c.offs, c.uses);
      raise exception 'FAIL：% —— 竟然建得起來', c.label;
    exception when sqlstate 'LS017' then
      raise notice 'ok：% → LS017', c.label;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1c. 邀請碼的熵：每一個位置都必須抽得到整個 32 字元的字元集
--
-- 依據：create_invite 挑選「完全隨機的那幾個位元組」那行（c_random_bytes）。
-- LS-90：6 碼版本只取 UUID v4 天生隨機的 byte 0-5（time_low ＋ time_mid，
-- RFC 9562 §5.4），不像原本 8 碼版本要刻意跳過帶版本／variant 位元的
-- byte 6、8（PR #36 review 抓到的坑：直接取 byte 0..7 會讓某一碼只抽得到
-- 半個字元集）——這條測試留著是回歸測試，確保日後不會有人把 c_random_bytes
-- 改回覆蓋到那兩個 byte。
--
-- 判準取 >16 而不是 =32：200 次抽樣下某個字元一次都沒出現的機率約 0.2%，
-- 要求 32 種全出現會偶爾假紅；而壞掉的版本在該位置最多只有 16 種，
-- 兩者之間差得夠遠，不會有模稜兩可的結果。
-- ---------------------------------------------------------------------------
do $$
declare
  c_samples constant int := 200;
  v_code text;
  v_i int;
  v_pos int;
  v_seen text[] := array_fill(''::text, array[6]);
  v_distinct int;
begin
  for v_i in 1..c_samples loop
    v_code := public.create_invite('fa000000-0000-4000-8000-000000000001', 'member',
                                   now() + interval '7 days', 1);
    for v_pos in 1..6 loop
      v_seen[v_pos] := v_seen[v_pos] || substr(v_code, v_pos, 1);
    end loop;
  end loop;

  for v_pos in 1..6 loop
    select count(distinct ch) into v_distinct
      from regexp_split_to_table(v_seen[v_pos], '') as ch
     where ch <> '';
    if v_distinct <= 16 then
      raise exception
        'FAIL 熵：邀請碼第 % 碼在 % 次抽樣中只出現 % 種字元（字元集有 32 種）—— 這一碼的亂數來源不是滿的 5 bits',
        v_pos, c_samples, v_distinct;
    end if;
  end loop;
  raise notice 'ok 熵：% 次抽樣下 6 個位置每一個都出現 >16 種字元（每碼都是滿的 5 bits）', c_samples;
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- 1d. 撞碼重試迴圈：LS-90 票面要求「確認存在」
--
-- 上面 1、1c 兩段本身就是這條迴圈的正向覆蓋——create_invite 每次呼叫都會執行
-- 同一段「產碼 → INSERT → exception when unique_violation」邏輯（1 段驗 4 支碼
-- 互不相同、1c 段驗 200 次抽樣），只是沒有一次真的撞上既有碼而觸發重抽分支。
--
-- 刻意不在這裡偽造一次真正的撞碼：30 bit 空間（2^30 ≈ 10.7 億）下，測試想在
-- 有限次呼叫內讓 gen_random_uuid() 真的抽出一支已存在的碼，機率低到不可能在
-- 合理測試時間內發生，硬湊只會做出一個要嘛跑不完、要嘛偶爾假紅的 flaky 測試；
-- 而且 gen_random_uuid() 走 pg_strong_random，沒有可以從測試端注入的種子。
-- 撞碼發生時要走的那條路徑（exception when unique_violation → 重抽，5 次仍撞
-- 才 LS016）已由函式本體逐行 code review 覆蓋，且與 request_join 第 412、425
-- 行處理「同一人不同碼併發申請」時翻譯 unique_violation 的手法一致（同一種
-- exception handler pattern，已經在別處被併發測試間接驗證過）。
--
-- 真正的併發覆蓋（LS-90 票面「兩連線同時 create」）在
-- supabase/tests/concurrency/invite_create_race_*.sql：兩個真的並行的 psql
-- session 同時呼叫 create_invite，驗證兩邊都成功、拿到的碼不相同、沒有互相
-- 卡住或噴出非預期錯誤。
-- ---------------------------------------------------------------------------

-- member / viewer / 非成員都不能產碼
do $$
declare
  v_actor text;
begin
  foreach v_actor in array array[
    'a0000000-0000-4000-8000-000000000002',  -- A 家 member
    'a0000000-0000-4000-8000-000000000003',  -- A 家 viewer
    'e0000000-0000-4000-8000-000000000001',  -- 完全的外人
    'b0000000-0000-4000-8000-000000000001'   -- B 家的 owner（別人家的 owner 不是 owner）
  ] loop
    perform set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', v_actor), true);
    set local role authenticated;
    begin
      perform public.create_invite('fa000000-0000-4000-8000-000000000001', 'member',
                                   now() + interval '7 days', 1);
      reset role;
      raise exception 'FAIL：% 竟然能為 A 家產生邀請碼', v_actor;
    exception when insufficient_privilege then
      reset role;
      raise notice 'ok：% 不能為 A 家產碼 (42501)', v_actor;
    end;
  end loop;
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- 2. request_join 的三種錯誤碼必須分得開
--
-- 驗收條件「過期／超次數碼被拒（分開的錯誤碼供 UI 分文案）」。
-- 依據：三個 raise 都在本票的 request_join 裡。混成同一個錯誤碼的後果不是不好看——
-- 使用者會對著一支永遠不會成功的碼反覆重打。
--
-- 「碼不存在」故意用 '0000-0000'：0 不在字元集裡，create_invite 永遠不可能產出這支碼，
-- 所以這條斷言不依賴亂數（用隨便一串英數當「不存在的碼」理論上會撞到真碼）。
-- ---------------------------------------------------------------------------
insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at) values
  ('1a000000-0000-4000-8000-000000000033', 'fa000000-0000-4000-8000-000000000001',
   'EXP22222', 'member', 'a0000000-0000-4000-8000-000000000001', 5, now() - interval '1 day');

-- LS-90 R1 F2：為 2b 段準備一支「曾經真實存在、被本票 migration 標記失效」的
-- 8 碼舊格式邀請。先插入一支尚未過期的 8 碼邀請（代表遷移套用前正式站可能存在
-- 的既有資料），再原封不動執行本票 migration 第 3 段那句 UPDATE
-- （`supabase/migrations/20260825070627_invite_code_6.sql`）；多加的
-- `and id = ...` 只是把這句 UPDATE 的作用範圍限定在這裡自己造的這一列，避免
-- 波及 ls33.code_main／code_last／code_viewer／code_dup 這幾支本檔後面很多段落
-- 都還要用、此刻也還沒過期的碼——不加限定詞的話，同一句 UPDATE 會把它們一併
-- 打過期，後面依賴它們仍有效的段落會連環 FAIL。判準（`expires_at > now()`）本身
-- 與遷移那句完全相同，這裡驗的正是那個判準的效果。
insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at) values
  ('1a000000-0000-4000-8000-000000000090', 'fa000000-0000-4000-8000-000000000001',
   'LEGACY8C', 'member', 'a0000000-0000-4000-8000-000000000001', 1, now() + interval '7 days');
update public.invites set expires_at = now()
 where expires_at > now() and id = '1a000000-0000-4000-8000-000000000090';

select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  begin
    perform public.request_join('0000-0000');
    raise exception 'FAIL：不存在的邀請碼竟然通過';
  exception when sqlstate 'LS010' then
    raise notice 'ok：邀請碼不存在 → LS010';
  end;

  begin
    perform public.request_join('EXP22222');
    raise exception 'FAIL：過期的邀請碼竟然通過';
  exception when sqlstate 'LS011' then
    raise notice 'ok：邀請碼已過期 → LS011';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2b. LS-90：8 碼舊格式邀請被拒——結果取決於那支碼原本是不是真的存在過
--
-- R1 F1 訂正：request_join 沒有專屬的長度／格式檢查，直接交給既有的三段檢查
-- 分流，8 碼舊格式碼因此不是單一結果：
--   - 'LEGACY8C'：上面已插入並被本票 migration 那句 UPDATE 標記過期的列——
--     列還在，code 完全比對找得到，但 expires_at 已是過去 → LS011（已過期）。
--   - 'ABCDEFGH'：從來沒被 create_invite（不論 6 碼或 8 碼年代）產生過、也沒被
--     任何 insert 造過的字串，查無此列 → LS010（不存在）。
-- 兩者的差異正是「失效＝UPDATE 標記過期、列還在」與「單純打錯／亂猜」的差異。
--
-- Mutation 自證：把上面那句 `update ... set expires_at = now() where
-- expires_at > now() and id = ...` 拿掉，本段 LEGACY8C 那個 begin/exception 會
-- 因為 request_join 直接成功（回 pending，不噴任何錯誤）而落到「沒有 exception
-- 可接」，`perform` 之後的 raise exception 'FAIL：...' 會執行，本檔案 FAIL——
-- 已於本機驗證（見 PR body／handoff）。
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    perform public.request_join('LEGACY8C');
    raise exception 'FAIL：被本票 migration 標記失效的 8 碼舊格式邀請竟然通過';
  exception when sqlstate 'LS011' then
    raise notice 'ok：既有 8 碼邀請被標記失效後 → LS011（列還在、只是過期，R1 F1 訂正）';
  end;

  begin
    perform public.request_join('ABCDEFGH');
    raise exception 'FAIL：從未存在過的邀請碼竟然通過';
  exception when sqlstate 'LS010' then
    raise notice 'ok：從未存在過的碼（對照組）→ LS010，未被誤判成過期';
  end;
end;
$$;

-- 甲用「只剩一個名額」的碼提出申請 → 名額當場消耗（不是等到核准才扣）
do $$
declare
  r record;
begin
  select * into r from public.request_join(current_setting('ls33.code_last'));
  if r.status <> 'pending' then
    raise exception 'FAIL：家庭預設 require_approval=true，request_join 應回 pending，實際 %', r.status;
  end if;
  if r.request_id is null then
    raise exception 'FAIL：pending 必須回傳 request_id，UI 沒有它就無法顯示／撤回這筆申請';
  end if;
  if r.family_id <> 'fa000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：回傳的 family_id 不對（%）', r.family_id;
  end if;
  perform set_config('ls33.req_jia', r.request_id::text, true);
  raise notice 'ok：甲的申請成立（pending，request_id=%）', r.request_id;
end;
$$;
reset role;

do $$
declare
  v_used int;
begin
  select used_count into v_used from public.invites where code = current_setting('ls33.code_last');
  if v_used <> 1 then
    raise exception 'FAIL：申請成立時 used_count 應已消耗為 1，實際 % —— 核准時才扣的話，一支碼可被無限多人同時申請占用', v_used;
  end if;
  raise notice 'ok：used_count 在「申請成立」當下就消耗（1/1）';
end;
$$;

-- 乙用同一支已用罄的碼 → LS012（與 LS010／LS011 分得開）
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.request_join(current_setting('ls33.code_last'));
    raise exception 'FAIL：用罄的邀請碼竟然還能申請';
  exception when sqlstate 'LS012' then
    raise notice 'ok：邀請碼次數用罄 → LS012';
  end;
end;
$$;
reset role;

do $$
declare
  v_used int;
  v_reqs int;
begin
  select used_count into v_used from public.invites where code = current_setting('ls33.code_last');
  select count(*) into v_reqs from public.join_requests
   where applicant_id = 'e0000000-0000-4000-8000-000000000002';
  if v_used <> 1 then
    raise exception 'FAIL：被 LS012 擋下的申請不該再消耗次數（used_count=%）', v_used;
  end if;
  if v_reqs <> 0 then
    raise exception 'FAIL：被 LS012 擋下卻留下了 % 筆申請', v_reqs;
  end if;
  raise notice 'ok：LS012 之後沒有殘留（used_count 仍為 1、乙沒有申請列）';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. 驗收條件：核准前，申請人看不到任何家庭內容
--
-- 依據：LS-6 既有的 RLS policy（都以 private.family_ids() 為界）＋本票沒有為了
-- 「讓申請人看到自己申請的家庭」而放寬任何一條。這裡逐表列舉而不是抽查：
-- 少驗一張表，就是少一個會外洩的地方，而且新表加進來時這個清單會提醒後人補上。
-- 反向的正向對照在第 6 段（核准後同一批表要看得到），否則「全部 0 列」也可能
-- 只是因為 session 設定錯了、根本沒有登入。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_tbl text;
  v_n bigint;
begin
  foreach v_tbl in array array[
    'family_members', 'invites', 'children', 'media', 'albums', 'album_media',
    'diaries', 'diary_media', 'comments', 'reactions', 'feed_items',
    'content_reports', 'blocked_users'
  ] loop
    execute format(
      'select count(*) from public.%I where family_id = %L',
      v_tbl, 'fa000000-0000-4000-8000-000000000001'
    ) into v_n;
    if v_n <> 0 then
      raise exception 'FAIL：待審核的申請人竟然看得到 public.% 的 % 列（家庭內容在核准前必須完全不可見）', v_tbl, v_n;
    end if;
  end loop;

  -- families 用 id 不是 family_id，另外驗
  select count(*) into v_n from public.families
   where id = 'fa000000-0000-4000-8000-000000000001';
  if v_n <> 0 then
    raise exception 'FAIL：待審核的申請人看得到 A 家的 families 列';
  end if;

  -- 正向對照：他看得到的只有「自己那筆申請」
  select count(*) into v_n from public.join_requests;
  if v_n <> 1 then
    raise exception 'FAIL：申請人應只看得到自己的 1 筆申請，實際 % 列', v_n;
  end if;

  raise notice 'ok 驗收：核准前申請人對 14 張家庭內容表全部 0 列，只看得到自己的申請';
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- 4. join_requests 的 RLS：申請人只見自己、owner 只見自家、寫入完全關閉
--
-- 依據：本票的 join_requests_select policy（可見範圍）＋「只 grant select」
-- 與「沒有 INSERT/UPDATE/DELETE policy」這兩層（寫入關閉）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_actor text;
  v_n bigint;
  v_expect bigint;
begin
  foreach v_actor in array array[
    'e0000000-0000-4000-8000-000000000001:1',  -- 申請人本人：自己那筆
    'a0000000-0000-4000-8000-000000000001:1',  -- A 家 owner：自家那筆
    'a0000000-0000-4000-8000-000000000002:0',  -- A 家 member：不是 owner，看不到
    'b0000000-0000-4000-8000-000000000001:0',  -- B 家 owner：別人家的申請看不到
    'e0000000-0000-4000-8000-000000000002:0'   -- 無關的外人
  ] loop
    v_expect := split_part(v_actor, ':', 2)::bigint;
    perform set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', split_part(v_actor, ':', 1)), true);
    set local role authenticated;
    select count(*) into v_n from public.join_requests;
    reset role;
    if v_n <> v_expect then
      raise exception 'FAIL：% 應看到 % 筆申請，實際 %', split_part(v_actor, ':', 1), v_expect, v_n;
    end if;
  end loop;
  raise notice 'ok：join_requests 可見範圍＝申請人本人 ∪ 該家 owner';
end;
$$;
reset role;

do $$
declare
  v_priv text;
begin
  -- 第一層：grant 只給了 SELECT
  foreach v_priv in array array['insert', 'update', 'delete'] loop
    if has_table_privilege('authenticated', 'public.join_requests', v_priv) then
      raise exception 'FAIL：authenticated 對 join_requests 有 % 權限（寫入唯一路徑應該是 definer RPC）', v_priv;
    end if;
  end loop;
  if not has_table_privilege('authenticated', 'public.join_requests', 'select') then
    raise exception 'FAIL 正向對照：authenticated 連 SELECT 都沒有，申請人看不到自己的申請';
  end if;

  -- 第二層：RLS 開著，而且只有 SELECT policy
  if not exists (select 1 from pg_class c
                  where c.oid = 'public.join_requests'::regclass and c.relrowsecurity) then
    raise exception 'FAIL：public.join_requests 沒有啟用 RLS';
  end if;
  if exists (select 1 from pg_policies p
              where p.schemaname = 'public' and p.tablename = 'join_requests'
                and p.cmd <> 'SELECT') then
    raise exception 'FAIL：join_requests 出現了 SELECT 以外的 policy —— 寫入路徑必須只有 definer RPC';
  end if;

  raise notice 'ok：join_requests 只有 SELECT 的 grant 與 policy，兩層都關住寫入';
end;
$$;

-- 實際打一發：申請人直接改自己那筆申請的狀態（最有動機的攻擊）
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    update public.join_requests set status = 'approved'
     where id = current_setting('ls33.req_jia')::uuid;
    raise exception 'FAIL：申請人竟然可以自己把申請改成 approved';
  exception when insufficient_privilege then
    raise notice 'ok：申請人不能直接改自己的申請狀態 (42501)';
  end;

  begin
    insert into public.join_requests (family_id, invite_id, applicant_id)
    values ('fa000000-0000-4000-8000-000000000001',
            '1a000000-0000-4000-8000-000000000033',
            'e0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：申請人竟然可以直接 INSERT 申請（繞過驗碼與次數消耗）';
  exception when insufficient_privilege then
    raise notice 'ok：不能直接 INSERT join_requests (42501)';
  end;
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- 5. 兩個 DB 層的 gate：pending 唯一索引、邀請碼必須同家庭
--
-- 依據：本票 migration 的 join_requests_pending_unique 與
-- join_requests_invite_same_family_fkey。這裡刻意以 postgres 身分直接寫表
-- （繞過 RLS 與 RPC）——要測的就是「就算寫入路徑被繞過，DB 自己還擋不擋得住」。
-- 這兩條斷言在拿掉對應的索引／外鍵之後會立刻變紅（mutation 對照見 PR 說明）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_invite_a uuid;
begin
  select i.id into v_invite_a from public.invites i where i.code = current_setting('ls33.code_main');

  -- 同一人對同一家庭的第二筆 pending
  begin
    insert into public.join_requests (family_id, invite_id, applicant_id)
    values ('fa000000-0000-4000-8000-000000000001', v_invite_a,
            'e0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：同一申請人對同一家庭出現了第二筆 pending 申請';
  exception when unique_violation then
    raise notice 'ok：同一申請人對同一家庭只能有一筆 pending (23505)';
  end;

  -- 用 B 家的邀請碼申請進 A 家
  begin
    insert into public.join_requests (family_id, invite_id, applicant_id)
    values ('fa000000-0000-4000-8000-000000000001',
            '1b000000-0000-4000-8000-000000000001',
            'e0000000-0000-4000-8000-000000000002');
    raise exception 'FAIL：竟然能用 B 家的邀請碼建立 A 家的申請（跨家庭關聯在資料層可表達）';
  exception when foreign_key_violation then
    raise notice 'ok：邀請碼必須屬於同一個家庭 (23503)';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. approve_join：只有該家 owner；核准後角色取自邀請碼
--
-- 依據：本票的 approve_join（owner 檢查、role 取自 invite）＋ LS-6 既有的 RLS
-- （核准後看得到內容這件事，是因為 family_members 多了一列，不是因為放寬了什麼）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_actor text;
begin
  foreach v_actor in array array[
    'a0000000-0000-4000-8000-000000000002',  -- A 家 member
    'a0000000-0000-4000-8000-000000000003',  -- A 家 viewer
    'b0000000-0000-4000-8000-000000000001',  -- B 家 owner
    'e0000000-0000-4000-8000-000000000001'   -- 申請人自己（最有動機的那個）
  ] loop
    perform set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', v_actor), true);
    set local role authenticated;
    begin
      perform public.approve_join(current_setting('ls33.req_jia')::uuid);
      reset role;
      raise exception 'FAIL：% 竟然核准得了 A 家的加入申請', v_actor;
    exception when insufficient_privilege then
      reset role;
      raise notice 'ok：% 不能核准 A 家的申請 (42501)', v_actor;
    end;
  end loop;
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  perform public.approve_join(current_setting('ls33.req_jia')::uuid);
  raise notice 'ok：A 家 owner 核准了甲的申請';

  -- 同一筆申請不能核准兩次，也不能核准完再拒絕（狀態機只走一次）
  begin
    perform public.approve_join(current_setting('ls33.req_jia')::uuid);
    raise exception 'FAIL：同一筆申請竟然可以核准兩次';
  exception when sqlstate 'LS015' then
    raise notice 'ok：重複核准 → LS015';
  end;

  begin
    perform public.reject_join(current_setting('ls33.req_jia')::uuid);
    raise exception 'FAIL：已核准的申請竟然還能被拒絕（成員已寫入，狀態卻變 rejected）';
  exception when sqlstate 'LS015' then
    raise notice 'ok：核准後再拒絕 → LS015';
  end;
end;
$$;
reset role;

do $$
declare
  v_role public.family_role;
  v_status public.join_request_status;
  v_resolved_at timestamptz;
  v_resolved_by uuid;
begin
  select m.role into v_role from public.family_members m
   where m.family_id = 'fa000000-0000-4000-8000-000000000001'
     and m.user_id = 'e0000000-0000-4000-8000-000000000001';
  if v_role is distinct from 'member'::public.family_role then
    raise exception 'FAIL：核准後應以邀請碼上的角色（member）入家，實際 %', v_role;
  end if;

  select r.status, r.resolved_at, r.resolved_by
    into v_status, v_resolved_at, v_resolved_by
    from public.join_requests r where r.id = current_setting('ls33.req_jia')::uuid;
  if v_status <> 'approved' or v_resolved_at is null
     or v_resolved_by is distinct from 'a0000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：核准後的申請列不完整（status=% resolved_at=% resolved_by=%）',
      v_status, v_resolved_at, v_resolved_by;
  end if;
  raise notice 'ok：甲以 member 入家，申請列 approved／resolved_at／resolved_by 三者齊備';
end;
$$;

-- 正向對照：同一批表，核准後看得見（證明第 3 段的「全部 0 列」不是因為 session 壞了）
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_media bigint;
  v_albums bigint;
  v_fam bigint;
begin
  select count(*) into v_media from public.media
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  select count(*) into v_albums from public.albums
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  select count(*) into v_fam from public.families
   where id = 'fa000000-0000-4000-8000-000000000001';
  if v_media = 0 or v_albums = 0 or v_fam = 0 then
    raise exception 'FAIL 正向對照：核准後仍看不到內容（media=% albums=% families=%）—— 第 3 段的 0 列不能算數',
      v_media, v_albums, v_fam;
  end if;
  raise notice 'ok 正向對照：核准後看得到 A 家內容（media % 列、albums % 列）', v_media, v_albums;
end;
$$;

-- 已是成員再拿同家庭的碼來申請 → LS013，且不消耗次數
do $$
begin
  begin
    perform public.request_join(current_setting('ls33.code_main'));
    raise exception 'FAIL：已經是成員的人竟然還能提出申請';
  exception when sqlstate 'LS013' then
    raise notice 'ok：已是成員 → LS013';
  end;
end;
$$;
reset role;

do $$
declare
  v_used int;
begin
  select used_count into v_used from public.invites where code = current_setting('ls33.code_main');
  if v_used <> 0 then
    raise exception 'FAIL：被 LS013 擋下不該消耗次數（used_count=%）', v_used;
  end if;
  raise notice 'ok：LS013 不消耗邀請碼次數';
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. reject_join：拒絕後無殘留權限
--
-- 依據：本票的 reject_join（只改狀態、不寫成員）＋ LS-6 的 RLS。
-- 「無殘留」不能只看 family_members 有沒有列——要回頭把第 3 段那組表再驗一次，
-- 因為殘留權限的定義是「他還看得到東西」，不是「表裡有沒有那一列」。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
begin
  select * into r from public.request_join(current_setting('ls33.code_main'));
  perform set_config('ls33.req_yi', r.request_id::text, true);
  raise notice 'ok：乙提出申請（%）', r.request_id;
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  perform public.reject_join(current_setting('ls33.req_yi')::uuid);
  raise notice 'ok：owner 拒絕了乙的申請';
  begin
    perform public.reject_join(current_setting('ls33.req_yi')::uuid);
    raise exception 'FAIL：同一筆申請竟然可以拒絕兩次';
  exception when sqlstate 'LS015' then
    raise notice 'ok：重複拒絕 → LS015';
  end;
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_tbl text;
  v_n bigint;
begin
  foreach v_tbl in array array[
    'family_members', 'invites', 'children', 'media', 'albums', 'album_media',
    'diaries', 'diary_media', 'comments', 'reactions', 'feed_items',
    'content_reports', 'blocked_users'
  ] loop
    execute format(
      'select count(*) from public.%I where family_id = %L',
      v_tbl, 'fa000000-0000-4000-8000-000000000001'
    ) into v_n;
    if v_n <> 0 then
      raise exception 'FAIL：被拒絕的申請人在 public.% 還看得到 % 列（殘留權限）', v_tbl, v_n;
    end if;
  end loop;
  raise notice 'ok 驗收：拒絕後無殘留——被拒絕的申請人對 13 張表全部 0 列';
end;
$$;
reset role;

do $$
declare
  v_members int;
  v_used int;
begin
  select count(*) into v_members from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id = 'e0000000-0000-4000-8000-000000000002';
  if v_members <> 0 then
    raise exception 'FAIL：被拒絕的申請人竟然有 family_members 列';
  end if;

  select used_count into v_used from public.invites where code = current_setting('ls33.code_main');
  if v_used <> 1 then
    raise exception 'FAIL：拒絕不應退還次數（used_count=%，期望 1）—— 退還會讓「申請→拒絕」變成免費的無限迴圈', v_used;
  end if;
  raise notice 'ok：拒絕後沒有成員列，且次數不退還（1/3）';
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. withdraw_join：只有本人、只有 pending
--
-- 依據：本票的 withdraw_join。被拒絕之後還能重新申請，是部分唯一索引
-- （where status = 'pending'）的直接後果——普通 UNIQUE 會讓人被拒絕一次就永遠不能再申請。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
begin
  select * into r from public.request_join(current_setting('ls33.code_main'));
  perform set_config('ls33.req_yi2', r.request_id::text, true);
  raise notice 'ok：被拒絕後可以重新申請（%）', r.request_id;

  -- 已有 pending 時，換一支同家庭的碼再申請 → LS014（不是 LS012，名額還有）
  begin
    perform public.request_join(current_setting('ls33.code_dup'));
    raise exception 'FAIL：同一人對同一家庭竟然能有第二筆待審申請';
  exception when sqlstate 'LS014' then
    raise notice 'ok：重複申請（換一支碼）→ LS014';
  end;
end;
$$;
reset role;

-- owner 不能替申請人撤回（撤回是申請人的意思表示，不是審核動作）
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.withdraw_join(current_setting('ls33.req_yi2')::uuid);
    raise exception 'FAIL：owner 竟然能替申請人撤回申請';
  exception when insufficient_privilege then
    raise notice 'ok：owner 不能替申請人撤回 (42501)';
  end;
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  perform public.withdraw_join(current_setting('ls33.req_yi2')::uuid);
  raise notice 'ok：申請人撤回了自己的申請';
  begin
    perform public.withdraw_join(current_setting('ls33.req_yi2')::uuid);
    raise exception 'FAIL：已撤回的申請竟然還能再撤回';
  exception when sqlstate 'LS015' then
    raise notice 'ok：重複撤回 → LS015';
  end;
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.approve_join(current_setting('ls33.req_yi2')::uuid);
    raise exception 'FAIL：已撤回的申請竟然還能被核准（申請人已經反悔了）';
  exception when sqlstate 'LS015' then
    raise notice 'ok：已撤回的申請不能被核准 → LS015';
  end;
end;
$$;
reset role;

do $$
declare
  v_status public.join_request_status;
  v_by uuid;
begin
  select r.status, r.resolved_by into v_status, v_by
    from public.join_requests r where r.id = current_setting('ls33.req_yi2')::uuid;
  if v_status <> 'withdrawn' then
    raise exception 'FAIL：撤回後狀態應為 withdrawn，實際 %', v_status;
  end if;
  if v_by is distinct from 'e0000000-0000-4000-8000-000000000002'::uuid then
    raise exception 'FAIL：撤回的 resolved_by 應為申請人本人，實際 %', v_by;
  end if;
  -- withdrawn 與 rejected 分開存：UI 對這兩件事要說不同的話
  if not exists (select 1 from public.join_requests r
                  where r.applicant_id = 'e0000000-0000-4000-8000-000000000002'
                    and r.status = 'rejected') then
    raise exception 'FAIL：乙先前被拒絕的那筆申請不見了（rejected 與 withdrawn 應各自留存）';
  end if;
  raise notice 'ok：撤回記為 withdrawn（與 rejected 分開），resolved_by 是本人';
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. require_approval：預設開、只有 owner 改得動；關掉之後驗碼即入家
--
-- 依據：本票的 column grant（require_approval）＋ LS-6 既有的 families_update policy
-- （USING/WITH CHECK 都要求 owned_family_ids）。非 owner 的 UPDATE 不會噴錯，
-- 而是「影響 0 列」——RLS 的 USING 過不了就等於那一列不存在，所以斷言要驗 row_count
-- 與實際值兩者，只驗「沒有噴錯」會過得莫名其妙。
-- ---------------------------------------------------------------------------
do $$
declare
  v_all boolean;
begin
  select bool_and(f.require_approval) into v_all from public.families f;
  if not v_all then
    raise exception 'FAIL：require_approval 的預設值應為 true（既有家庭升級後不得被動放寬）';
  end if;
  if not has_column_privilege('authenticated', 'public.families', 'require_approval', 'update') then
    raise exception 'FAIL：authenticated 沒有 require_approval 的 column UPDATE 權限，owner 改不了開關';
  end if;
  -- 回歸：§10-A 的成本防線沒有被本票的 column grant 一起放寬
  if has_column_privilege('authenticated', 'public.families', 'storage_quota_bytes', 'update')
     or has_column_privilege('authenticated', 'public.families', 'storage_used_bytes', 'update') then
    raise exception 'FAIL 回歸：families 的額度／用量欄位變成可 UPDATE 了（§10-A 成本防線）';
  end if;
  raise notice 'ok：require_approval 預設 true、可由 authenticated 更新（實際限制在 policy）、額度欄位仍不可改';
end;
$$;

do $$
declare
  v_actor text;
  v_n int;
  v_value boolean;
begin
  foreach v_actor in array array[
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003',  -- viewer
    'e0000000-0000-4000-8000-000000000001',  -- 剛入家的 member（甲）
    'b0000000-0000-4000-8000-000000000001'   -- 別人家的 owner
  ] loop
    perform set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', v_actor), true);
    set local role authenticated;
    update public.families set require_approval = false
     where id = 'fa000000-0000-4000-8000-000000000001';
    get diagnostics v_n = row_count;
    reset role;
    if v_n <> 0 then
      raise exception 'FAIL：非 owner（%）竟然改得動 require_approval（影響 % 列）', v_actor, v_n;
    end if;
  end loop;

  select f.require_approval into v_value from public.families f
   where f.id = 'fa000000-0000-4000-8000-000000000001';
  if not v_value then
    raise exception 'FAIL：非 owner 的 UPDATE 竟然真的改到了值';
  end if;
  raise notice 'ok：member／viewer／別家 owner 都改不動 require_approval（影響 0 列且值未變）';
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_n int;
begin
  update public.families set require_approval = false
   where id = 'fa000000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 應改得動 require_approval，實際影響 % 列', v_n;
  end if;
  raise notice 'ok：owner 關閉了 A 家的審核';
end;
$$;
reset role;

-- 審核關閉：丙驗碼即入家，角色取自邀請碼（viewer），且不留待審申請
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
begin
  select * into r from public.request_join(current_setting('ls33.code_viewer'));
  if r.status <> 'joined' then
    raise exception 'FAIL：審核關閉時 request_join 應回 joined，實際 %', r.status;
  end if;
  if r.request_id is not null then
    raise exception 'FAIL：直接入家不應產生待審申請（request_id=%）', r.request_id;
  end if;
  raise notice 'ok：審核關閉 → 驗碼即入家';
end;
$$;
reset role;

do $$
declare
  v_role public.family_role;
  v_reqs int;
  v_used int;
begin
  select m.role into v_role from public.family_members m
   where m.family_id = 'fa000000-0000-4000-8000-000000000001'
     and m.user_id = 'e0000000-0000-4000-8000-000000000003';
  if v_role is distinct from 'viewer'::public.family_role then
    raise exception 'FAIL：直接入家的角色應取自邀請碼（viewer），實際 %', v_role;
  end if;

  select count(*) into v_reqs from public.join_requests
   where applicant_id = 'e0000000-0000-4000-8000-000000000003';
  if v_reqs <> 0 then
    raise exception 'FAIL：直接入家竟然留下了 % 筆申請列', v_reqs;
  end if;

  select used_count into v_used from public.invites where code = current_setting('ls33.code_viewer');
  if v_used <> 1 then
    raise exception 'FAIL：直接入家也要消耗次數（used_count=%）', v_used;
  end if;
  raise notice 'ok：丙以 viewer 直接入家、沒有申請列、次數已消耗';
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. family_members 寫入收斂（LS-6 review m2 的技術債）
--
-- 依據：本票的 ALTER POLICY family_members_insert WITH CHECK (false) 與
-- REVOKE INSERT。兩層都要斷言：只驗「INSERT 會失敗」的話，日後有人把 policy
-- 改回去、grant 卻還在（或反之），測試仍然是綠的。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_n int;
begin
  begin
    insert into public.family_members (family_id, user_id, role)
    values ('fa000000-0000-4000-8000-000000000001',
            'e0000000-0000-4000-8000-000000000002', 'member');
    raise exception 'FAIL 驗收：owner 竟然可以繞過邀請碼直接把人塞進家庭';
  exception when insufficient_privilege then
    raise notice 'ok 驗收：owner 無法直接 INSERT 成員 (42501)';
  end;

  -- 同一件事的另一條路：不新增列，改寫既有列的 user_id。
  -- family_id 沒變，family_members_update policy 兩側都會通過——擋住它的只有
  -- column-level grant（PR #36 review 的 F1，實測可把陌生人塞進家庭並讀到全家照片）。
  begin
    update public.family_members set user_id = 'e0000000-0000-4000-8000-000000000002'
     where family_id = 'fa000000-0000-4000-8000-000000000001'
       and user_id = 'a0000000-0000-4000-8000-000000000003';
    raise exception 'FAIL 驗收：owner 改寫既有成員列的 user_id，把陌生人塞進了家庭（INSERT 關了但 UPDATE 沒關）';
  exception when insufficient_privilege then
    raise notice 'ok 驗收：owner 無法改寫成員列的 user_id (42501)';
  end;

  -- 正向對照：該能改的兩件事仍然能改，否則「收斂」就變成把功能一起關掉
  -- （PLAN §3：owner 可升降角色、可逐人關閉上傳）
  update public.family_members set role = 'viewer', can_upload = false
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id = 'a0000000-0000-4000-8000-000000000003';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：owner 改不動成員的 role／can_upload（影響 % 列）', v_n;
  end if;
  raise notice 'ok 正向對照：owner 仍改得動 role 與 can_upload';
end;
$$;
reset role;

do $$
declare
  v_check text;
  v_others int;
  v_col text;
begin
  if has_table_privilege('authenticated', 'public.family_members', 'insert') then
    raise exception 'FAIL：authenticated 還有 family_members 的 INSERT grant（收斂只做了 policy 那一層）';
  end if;

  -- UPDATE 的 column grant 必須逐欄列舉：這三欄是「這一列在講誰、屬於哪一家、何時加入」，
  -- 可改的話等於可以把任何一列的歸屬換掉，policy 完全攔不到（它只看 family_id）。
  foreach v_col in array array['user_id', 'family_id', 'created_at'] loop
    if has_column_privilege('authenticated', 'public.family_members', v_col, 'update') then
      raise exception
        'FAIL：authenticated 可以 UPDATE family_members.% —— owner 能改寫既有列的歸屬，把陌生人塞進家庭', v_col;
    end if;
  end loop;
  -- 正向對照：該給的兩欄要還在，否則角色升降與上傳開關就沒了（PLAN §3）
  foreach v_col in array array['role', 'can_upload'] loop
    if not has_column_privilege('authenticated', 'public.family_members', v_col, 'update') then
      raise exception 'FAIL 正向對照：authenticated 失去 family_members.% 的 UPDATE 權限', v_col;
    end if;
  end loop;

  select p.with_check into v_check from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'family_members'
     and p.policyname = 'family_members_insert';
  if v_check is distinct from 'false' then
    raise exception 'FAIL：family_members_insert 的 WITH CHECK 是「%」而不是 false（收斂只做了 grant 那一層）', v_check;
  end if;

  -- 其餘三個 policy 不該被本票動到（成員仍要能被 owner 移除／改角色、成員仍看得到彼此）
  select count(*) into v_others from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'family_members'
     and p.policyname in ('family_members_select', 'family_members_update',
                          'family_members_delete');
  if v_others <> 3 then
    raise exception 'FAIL 回歸：family_members 的 select/update/delete policy 少了（實際 % 條）', v_others;
  end if;

  raise notice 'ok 驗收：family_members 的直接寫入兩層都關——INSERT（grant 收回 + policy WITH CHECK false）、UPDATE（column grant 只剩 role/can_upload）';
end;
$$;

-- 回歸：建立家庭時 creator 仍自動成為 owner（definer trigger 不受 policy 收斂影響）。
-- 這條沒過的話，全新使用者連自己的家庭都建不起來（PLAN §9-C5，Guideline 4.2 風險）。
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_family uuid;
begin
  insert into public.families (name, created_by)
  values ('丁的新家', 'e0000000-0000-4000-8000-000000000004')
  returning families.id into v_family;
  perform set_config('ls33.family_ding', v_family::text, true);
  raise notice 'ok：丁建立了自己的家庭（%）', v_family;
end;
$$;
reset role;

do $$
declare
  v_role public.family_role;
  v_require boolean;
begin
  select m.role into v_role from public.family_members m
   where m.family_id = current_setting('ls33.family_ding')::uuid
     and m.user_id = 'e0000000-0000-4000-8000-000000000004';
  if v_role is distinct from 'owner'::public.family_role then
    raise exception 'FAIL 回歸：建立家庭的人沒有自動成為 owner（實際 %）—— add_creator_as_owner 被 policy 收斂弄壞了，新使用者將無法建立家庭', v_role;
  end if;

  select f.require_approval into v_require from public.families f
   where f.id = current_setting('ls33.family_ding')::uuid;
  if not v_require then
    raise exception 'FAIL：新建家庭的 require_approval 預設應為 true';
  end if;
  raise notice 'ok 回歸：creator 自動成為 owner，新家庭預設需要審核';
end;
$$;

-- ---------------------------------------------------------------------------
-- 11.（授權斷言已移至 60_ §8）per-RPC 授權（LS-15 的慣例）
--
-- LS-34 review（F2）：授權面（anon 不可／authenticated 可／PUBLIC 不可）與 definer／
-- search_path 硬化，已統一併入 supabase/tests/60_default_privileges.sql 第 8 段的
-- public SECURITY DEFINER RPC 白名單列舉——那裡現在逐支登記全部 8 支 public RPC
-- （本票這 7 支＋既有的 register_device_token），單一清單、單一斷言，不再兩處各自
-- 維護、互相漂移（原本這裡的清單沒有 register_device_token，那支的 definer／
-- search_path 因此零測試覆蓋，是 60_ §8 統一後才補上的洞）。
-- 這裡不再重複斷言；本檔其餘段落驗的是這 7 支 RPC 的「行為」（request_join／
-- approve_join／……各自的驗收條件），60_ §8 管的只是授權面。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 12. 兩支唯讀 RPC：審核清單看得到申請人姓名、等待畫面看得到家庭名稱
--
-- 依據：本票的 list_join_requests／get_my_join_request。這兩支是刻意開出來的
-- 「跨界讀取」窗口（申請人與家庭在核准前沒有成員關係，RLS 兩邊互相看不到），
-- 所以測試的重點不只是「看得到」，更是「只看得到該看的那幾欄、只有該看的人看得到」。
--
-- 場景重建：A 家在第 9 段被 owner 關掉審核，這裡先開回來（順帶驗開關可以雙向切），
-- 讓乙重新提出一筆 pending 申請；另外以 postgres 身分在 B 家也放一筆 pending，
-- 用來驗「多家庭的 owner 只看得到自家那筆」——沒有這一筆的話，
-- 「B 家 owner 看不到 A 家申請」也可能只是因為函式對誰都回空集合。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_n int;
begin
  update public.families set require_approval = true
   where id = 'fa000000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 應能把審核開關切回 true，實際影響 % 列', v_n;
  end if;
  raise notice 'ok：owner 把 A 家的審核開關切回 true（開關可雙向切）';
end;
$$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
begin
  select * into r from public.request_join(current_setting('ls33.code_dup'));
  if r.status <> 'pending' then
    raise exception 'FAIL：審核開回來之後應該回 pending，實際 %', r.status;
  end if;
  perform set_config('ls33.req_yi3', r.request_id::text, true);
end;
$$;
reset role;

-- B 家的待審申請（postgres 身分直接建，這是 setup 不是被測路徑）。
-- 順便把乙那筆 pending 的 created_at 往前挪一小時：整個測試檔在同一個交易裡，
-- now() 對每一列都相同，不動時間的話「pending 優先」這條規則會和「最近一筆」
-- 這條規則永遠給出相同答案，等於沒驗到。挪完之後乙有一筆「較舊的 pending」
-- 與兩筆「較新的已處理」，只有 pending 優先的規則才會回傳前者。
insert into public.join_requests (id, family_id, invite_id, applicant_id, status) values
  ('9a000000-0000-4000-8000-000000000012', 'fb000000-0000-4000-8000-000000000001',
   '1b000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000003', 'pending');

update public.join_requests set created_at = now() - interval '1 hour'
 where id = current_setting('ls33.req_yi3')::uuid;

-- 正向：A 家 owner 看得到申請人的顯示名稱與邀請碼角色
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
  v_n int;
begin
  select count(*) into v_n from public.list_join_requests();
  if v_n <> 1 then
    raise exception 'FAIL：A 家 owner 應看到 1 筆待審申請，實際 % 筆（B 家那筆不該出現）', v_n;
  end if;

  select * into r from public.list_join_requests();
  if r.request_id <> current_setting('ls33.req_yi3')::uuid then
    raise exception 'FAIL：待審清單回的不是乙那筆申請';
  end if;
  if r.family_id <> 'fa000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：待審清單的 family_id 不對（%）', r.family_id;
  end if;
  if r.applicant_id <> 'e0000000-0000-4000-8000-000000000002'::uuid then
    raise exception 'FAIL：待審清單的 applicant_id 不對（%）', r.applicant_id;
  end if;
  if r.display_name is distinct from '申請人乙' then
    raise exception 'FAIL：owner 看不到申請人的顯示名稱（實際 %）—— 審核畫面只剩一串 uuid', r.display_name;
  end if;
  if r.role is distinct from 'member' then
    raise exception 'FAIL：待審清單的 role 應取自邀請碼（member），實際 %', r.role;
  end if;
  if r.created_at is null then
    raise exception 'FAIL：待審清單沒有申請時間，UI 排不出「等最久的在前面」';
  end if;
  raise notice 'ok：A 家 owner 的待審清單看得到申請人姓名（%）與邀請碼角色（%）', r.display_name, r.role;
end;
$$;
reset role;

-- 正向對照：B 家 owner 看得到的是 B 家那筆，不是 A 家那筆
select set_config('request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
  v_n int;
begin
  select count(*) into v_n from public.list_join_requests();
  if v_n <> 1 then
    raise exception 'FAIL：B 家 owner 應看到自家那 1 筆，實際 % 筆', v_n;
  end if;
  select * into r from public.list_join_requests();
  if r.family_id <> 'fb000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：B 家 owner 竟然拿到別家的申請（family_id=%）', r.family_id;
  end if;
  raise notice 'ok 正向對照：B 家 owner 只看得到 B 家那筆（函式不是對誰都回空集合）';
end;
$$;
reset role;

-- 負向：不是 owner 的人一律拿到空集合（含申請人本人與同家庭的 member／viewer）
do $$
declare
  v_actor text;
  v_n int;
begin
  foreach v_actor in array array[
    'a0000000-0000-4000-8000-000000000002',  -- A 家 member
    'a0000000-0000-4000-8000-000000000003',  -- A 家 viewer
    'e0000000-0000-4000-8000-000000000001',  -- A 家 member（本檔第 6 段核准進來的甲）
    'e0000000-0000-4000-8000-000000000003',  -- A 家 viewer（第 9 段直接入家的丙）
    'e0000000-0000-4000-8000-000000000002',  -- 申請人本人
    'e0000000-0000-4000-8000-000000000004'   -- 完全的外人（丁）
  ] loop
    perform set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', v_actor), true);
    set local role authenticated;
    select count(*) into v_n from public.list_join_requests();
    reset role;
    if v_n <> 0 then
      raise exception
        'FAIL：% 不是任何家庭的 owner，卻從 list_join_requests 拿到 % 筆申請（含申請人的姓名與頭像）',
        v_actor, v_n;
    end if;
  end loop;
  raise notice 'ok：非 owner 一律拿到空集合（member／viewer／申請人本人／外人）';
end;
$$;
reset role;

-- 正向：申請人的等待畫面拿得到家庭名稱，且「pending 優先」勝過「最近一筆」
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
  v_n int;
begin
  select count(*) into v_n from public.get_my_join_request();
  if v_n <> 1 then
    raise exception 'FAIL：get_my_join_request 應回傳 1 列，實際 % 列', v_n;
  end if;

  select * into r from public.get_my_join_request();
  -- 先驗「這是不是我的申請」再驗「挑對了哪一筆」：兩種壞法的診斷訊息要分得開。
  -- （mutation M14 拿掉 applicant_id 過濾時，乙會拿到丙對 B 家那筆——若只有下面
  --  那條 request_id 斷言，測試雖然一樣會紅，訊息卻會誤指「pending 優先沒生效」。）
  if r.family_id <> 'fa000000-0000-4000-8000-000000000001'::uuid then
    raise exception
      'FAIL：get_my_join_request 回了別人的申請（family_id=%）—— applicant_id = auth.uid() 的過濾沒有生效',
      r.family_id;
  end if;
  if r.request_id <> current_setting('ls33.req_yi3')::uuid then
    raise exception 'FAIL：回的不是待審那筆 —— 乙另外兩筆（rejected／withdrawn）的 created_at 比較新，「pending 優先」沒有生效';
  end if;
  if r.status <> 'pending' then
    raise exception 'FAIL：狀態應為 pending，實際 %', r.status;
  end if;
  if r.family_name is distinct from 'A 家' then
    raise exception 'FAIL：申請人拿不到家庭名稱（實際 %）—— 等待畫面寫不出「等待〈家庭名〉核准」', r.family_name;
  end if;
  if r.resolved_at is not null then
    raise exception 'FAIL：pending 的申請不該有 resolved_at';
  end if;
  raise notice 'ok：申請人看得到「等待 % 核准」，且 pending 優先於較新的已處理申請', r.family_name;
end;
$$;
reset role;

-- 已處理之後的行為要明確：仍然回傳最近一筆，狀態照實回（UI 才能顯示「已被拒絕」）
select set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  r record;
begin
  select * into r from public.get_my_join_request();
  if r.status <> 'approved' then
    raise exception 'FAIL：甲的申請已核准，get_my_join_request 應回 approved，實際 %', r.status;
  end if;
  if r.resolved_at is null then
    raise exception 'FAIL：已處理的申請應有 resolved_at';
  end if;
  if r.family_name is distinct from 'A 家' then
    raise exception 'FAIL：已處理的申請也該回得出家庭名稱，實際 %', r.family_name;
  end if;
  raise notice 'ok：已核准的申請仍回得到（status=approved），UI 不會突然變成空白畫面';
end;
$$;
reset role;

-- 負向：看不到別人的申請；從未申請過的人拿到空集合
do $$
declare
  v_n int;
  v_fam uuid;
begin
  -- 丁從未申請過任何家庭 → 0 列（同時證明這支函式不是「回全表第一筆」）
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
  set local role authenticated;
  select count(*) into v_n from public.get_my_join_request();
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：從未申請過的人竟然拿到 % 列別人的申請', v_n;
  end if;

  -- 丙只申請過 B 家 → 只能拿到 B 家那筆，拿不到乙對 A 家那筆
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;
  select family_id into v_fam from public.get_my_join_request();
  reset role;
  if v_fam is distinct from 'fb000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：丙應只拿得到自己對 B 家的申請，實際 family_id=%', v_fam;
  end if;

  raise notice 'ok：get_my_join_request 只回呼叫者本人的申請（沒申請過就是空集合）';
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- 13. LS-37：invites 的寫入路徑收斂——唯一寫入路徑是 create_invite
--
-- 依據：20260823040000_invites_write_path.sql（DROP POLICY invites_insert／
-- invites_update ＋ REVOKE INSERT, UPDATE）。與第 10 段是同一件事的兩半：
-- 那裡關的是「不經邀請碼直接塞人進成員名單」，這裡關的是「不經 create_invite
-- 直接造一支不受限制的邀請碼」。
--
-- 兩層都要斷言（同第 10 段的理由）：只驗「INSERT 會失敗」的話，日後有人把 policy
-- 加回去、grant 卻還沒補（或反之），測試仍然是綠的，而兩層只要有一層在就擋得住——
-- 於是這個測試會在「防線已經破了一半」的狀態下繼續報綠。
--
-- request_join 的 used_count 加一不在這裡重測：本檔第 2、6、9 段全程走 request_join
-- 並逐段斷言 used_count，那些段落跑在同一份 migration 之上，收斂若弄壞了 definer
-- 那條路徑，它們會先紅。這裡只補「呼叫端寫不進去」這一面。
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_code text;
  v_n int;
  v_sql text;
  -- 每一句都是「合法 owner、對自己的家庭」——family_id 完全正確，所以舊的
  -- invites_insert/invites_update policy（qual 只看 family_id）會全部放行。
  -- 擋下它們的只有本票收掉的那兩層。
  v_probes text[] := array[
    -- 保險欄位 1：expires_at。create_invite 的上限是 30 天，這裡直接寫 100 年。
    $q$update public.invites set expires_at = now() + interval '100 years' where id = '1a000000-0000-4000-8000-000000000001'$q$,
    -- 保險欄位 2：max_uses。create_invite 的上限是 20，這裡寫 100000。
    $q$update public.invites set max_uses = 100000 where id = '1a000000-0000-4000-8000-000000000001'$q$,
    -- 保險欄位 3：used_count。可寫＝用罄的碼隨時歸零，max_uses 變成裝飾；
    -- 而且它是 request_join 併發正確性的根（FOR NO KEY UPDATE 重讀的就是這一欄）。
    $q$update public.invites set used_count = 0 where id = '1a000000-0000-4000-8000-000000000001'$q$,
    -- 保險欄位 4：code。改成自選的碼＝繞過 create_invite 的字元集與長度。
    $q$update public.invites set code = 'LS37EVIL' where id = '1a000000-0000-4000-8000-000000000001'$q$,
    -- role：approve_join 是在「核准的那一刻」才讀 invites.role 決定新成員的角色，
    -- 可改的話，一筆已送出的 member 申請能在 owner 按下核准之前被改成 owner。
    $q$update public.invites set role = 'owner' where id = '1a000000-0000-4000-8000-000000000001'$q$
  ];
begin
  -- 攻擊探針（本票的主要驗收條件）：owner 繞過 create_invite，直接寫一支
  -- 「100 年後到期、可用十萬次、且直接給 owner 權限」的邀請碼。
  -- 這一句在收斂前是會成功的——max_uses 與 expires_at 是 PLAN §5／§8 用來限制
  -- 「碼外流之後果」的兩個旋鈕，能由呼叫端自己填就等於沒有。
  begin
    insert into public.invites (family_id, code, role, created_by, max_uses, expires_at)
    values ('fa000000-0000-4000-8000-000000000001', 'ls37-forever-code', 'owner',
            'a0000000-0000-4000-8000-000000000001', 100000, now() + interval '100 years');
    raise exception 'FAIL 攻擊探針：owner 繞過 create_invite，直接寫進一支 100 年到期／可用 100000 次的 owner 邀請碼';
  exception when insufficient_privilege then
    raise notice 'ok 攻擊探針：owner 無法直接 INSERT invites (42501)——超長效期／超量次數的碼造不出來';
  end;

  -- 這幾句必須是「當場噴 42501」而不是「影響 0 列」。UPDATE 的 RLS 是靠 USING 篩掉
  -- 看不到的列，篩掉不會報錯（只有 WITH CHECK 違反才噴 42501）——所以少了 policy 但
  -- grant 還在的半破狀態下，這些句子會安靜地成功並影響 0 列。那個狀態一樣要紅：
  -- 它代表兩層防線只剩一層。失敗訊息把 row_count 一起印出來，日後這條紅燈亮起時，
  -- 讀訊息的人能直接分辨是「真的被改掉了」還是「grant 漏收」。
  foreach v_sql in array v_probes loop
    begin
      execute v_sql;
      get diagnostics v_n = row_count;
      raise exception
        'FAIL 攻擊探針：invites 的保險欄位沒有被 42501 擋下（影響 % 列）——「%」。'
        '影響 1 列＝policy 與 grant 兩層都回來了；影響 0 列＝policy 擋著但 grant 漏收，防線只剩一層',
        v_n, v_sql;
    exception when insufficient_privilege then
      null;
    end;
  end loop;
  raise notice 'ok 攻擊探針：owner 無法 UPDATE invites 的 expires_at／max_uses／used_count／code／role (42501)';

  -- 正向對照 1：唯一寫入路徑照常可用。沒有這一條，「把整張表對呼叫端關掉」
  -- 也會讓上面每一條攻擊探針變綠——收斂與砸壞功能在斷言上長得一模一樣。
  select public.create_invite(
    'fa000000-0000-4000-8000-000000000001', 'member',
    now() + interval '7 days', 3) into v_code;
  if v_code is null or v_code !~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$' then
    raise exception 'FAIL 正向對照：create_invite 產不出合規的邀請碼（實際 %）', v_code;
  end if;
  raise notice 'ok 正向對照：create_invite 照常可用（%）', v_code;

  -- 正向對照 2：owner 的撤銷路徑照常可用。本票裁定撤銷邀請＝DELETE 該列
  -- （invites 沒有 revoked_at 之類的欄位，LS-33 也沒有 revoke RPC；
  --   DELETE 只減不增，不需要為它建一支 RPC），所以 invites_delete 原樣保留。
  delete from public.invites where code = v_code;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：owner 撤銷不了自己剛產出的邀請碼（影響 % 列）—— 收斂把撤銷路徑一起關掉了', v_n;
  end if;
  raise notice 'ok 正向對照：owner 仍撤銷得掉自家邀請碼（DELETE 1 列）';
end;
$$;
reset role;

-- 未登入（anon）對 invites 四個動作全拒：policy 一律 `to authenticated`，
-- 且 init_schema 已把 public schema 的所有表對 anon 收乾淨（兩層都沒有它的份）。
set local role anon;
do $$
declare
  v_state text;
  v_sql text;
  v_blocked boolean;
  v_probes text[] := array[
    $q$select count(*) from public.invites$q$,
    $q$insert into public.invites (family_id, code, role, created_by, max_uses, expires_at) values ('fa000000-0000-4000-8000-000000000001', 'ls37-anon-code', 'member', 'a0000000-0000-4000-8000-000000000001', 1, now() + interval '1 day')$q$,
    $q$update public.invites set max_uses = 999 where id = '1a000000-0000-4000-8000-000000000001'$q$,
    $q$delete from public.invites where id = '1a000000-0000-4000-8000-000000000001'$q$
  ];
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  foreach v_sql in array v_probes loop
    v_blocked := false;
    begin
      execute v_sql;
    exception when others then
      v_blocked := true; v_state := sqlstate;
    end;
    if not v_blocked then
      raise exception 'FAIL anon：未登入者執行得了「%」', v_sql;
    end if;
    if v_state <> '42501' then
      raise exception 'FAIL anon：「%」被拒，但錯誤碼是 % 而不是 42501', v_sql, v_state;
    end if;
  end loop;
  raise notice 'ok anon：未登入者對 invites 的 select／insert／update／delete 全部被拒 (42501)';
end;
$$;
reset role;

-- 兩層各自的機械斷言（不靠上面那些行為探針推論——行為探針只要有一層在就會綠）
do $$
declare
  v_present int;
begin
  -- 第一層：grant。INSERT／UPDATE 兩面都不該還有「任何形態」的授權。
  --
  -- 用 has_any_column_privilege 而不是 has_table_privilege：後者對欄位級 grant 是回
  -- false 的，於是日後補上一句 `grant insert (family_id, code)` 或 `grant update (used_count)`
  -- 這種洞，只驗整表的斷言完全測不出來（PR #55 review F1——原本這裡只對 UPDATE 用
  -- 逐欄迴圈防住了這件事，INSERT 那一行一字不差地有同樣的洞卻沒防）。
  --
  -- has_any_column_privilege 一次涵蓋兩種形態：表級授權隱含所有欄位，所以它是整表斷言的
  -- 超集；而它問的是「有沒有任何一欄」，日後 invites 新增欄位（例如真的做了軟撤銷的
  -- revoked_at）也自動納入，不必回頭維護一份會漂移的欄位清單。
  if has_any_column_privilege('authenticated', 'public.invites', 'insert') then
    raise exception 'FAIL：authenticated 還有 invites 的 INSERT 授權（表級或任一欄位級）—— owner 能繞過 create_invite 自己造碼，收斂只做了 policy 那一層';
  end if;
  if has_any_column_privilege('authenticated', 'public.invites', 'update') then
    raise exception 'FAIL：authenticated 還有 invites 的 UPDATE 授權（表級或任一欄位級）—— 邀請碼的效期／次數／碼本身可被呼叫端改寫，create_invite 的邊界形同虛設';
  end if;

  -- 第二層：policy。兩條都該不在了（RLS 預設拒絕，沒有 policy ＝ 不通過）。
  select count(*) into v_present from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'invites'
     and p.policyname in ('invites_insert', 'invites_update');
  if v_present <> 0 then
    raise exception 'FAIL：invites 還留著 % 條 INSERT／UPDATE policy（收斂只做了 grant 那一層）', v_present;
  end if;

  -- 回歸：另外兩條 policy 與它們的 grant 不該被本票動到。
  -- owner 要看得到自家的碼（邀請畫面），也要撤銷得掉（本票裁定的撤銷路徑）。
  select count(*) into v_present from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'invites'
     and p.policyname in ('invites_select', 'invites_delete');
  if v_present <> 2 then
    raise exception 'FAIL 回歸：invites 的 select／delete policy 少了（實際 % 條）—— owner 看不到或撤銷不了自家邀請碼', v_present;
  end if;
  if not has_table_privilege('authenticated', 'public.invites', 'select')
     or not has_table_privilege('authenticated', 'public.invites', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 invites 的 SELECT 或 DELETE grant';
  end if;

  raise notice 'ok 驗收：invites 的呼叫端寫入兩層都關——INSERT／UPDATE（policy 已移除 + grant 已收回），SELECT／DELETE 原樣保留';
end;
$$;

rollback;
