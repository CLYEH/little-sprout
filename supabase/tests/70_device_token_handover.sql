-- LS-6：同一支裝置換帳號登入時，push token 必須跟著換人
--
-- 這不是便利性問題而是跨家庭外洩：device_tokens.token 是 PK，
-- 若舊帳號的綁定留在資料庫裡，賣掉／給家人用的那支手機會繼續收到舊帳號所屬家庭的推播
-- （照片標題、留言內容都在通知裡）。
--
-- 直接寫入的三條路徑在 RLS 下全部走不通，所以接手必須經過
-- public.register_device_token()（SECURITY DEFINER）。這個檔案先證明三條路真的都死，
-- 再證明 RPC 走得通——否則「所以我們加了一支 RPC」只是宣稱。

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. A 用 RPC 註冊自己的裝置
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  perform public.register_device_token('ls6-shared-device', 'ios');
  raise notice 'ok：A 用 RPC 註冊裝置 token';
end;
$$;
reset role;

do $$
declare
  v_user uuid;
begin
  select user_id into v_user from public.device_tokens where token = 'ls6-shared-device';
  if v_user is distinct from 'a0000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：RPC 註冊後 token 應綁定 A，實際 %', v_user;
  end if;
  raise notice 'ok：token 綁定在 A 身上';
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. 裝置換到 B 手上：三條直接路徑必須全部走不通（這是 RPC 存在的理由）
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_n int;
begin
  begin
    insert into public.device_tokens (token, user_id)
    values ('ls6-shared-device', 'b0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：直接 INSERT 竟然成功（token 是 PK，舊列還在）';
  exception when unique_violation then
    raise notice 'ok：直接 INSERT 撞 PK (23505)';
  end;

  begin
    insert into public.device_tokens (token, user_id)
    values ('ls6-shared-device', 'b0000000-0000-4000-8000-000000000001')
    on conflict (token) do update
      set user_id = excluded.user_id, updated_at = now();
    raise exception 'FAIL：UPSERT 竟然成功（舊列不屬於我，應被 RLS 的 USING 擋下）';
  exception when insufficient_privilege then
    raise notice 'ok：UPSERT 被舊列的 RLS USING 擋下 (42501)';
  end;

  delete from public.device_tokens where token = 'ls6-shared-device';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：B 竟然刪得掉 A 的 token 列（影響 % 列）', v_n;
  end if;
  raise notice 'ok：直接 DELETE 影響 0 列（舊列不屬於我）';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. B 用 RPC 接手
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.register_device_token('ls6-shared-device', 'ios');
  raise notice 'ok：B 用 RPC 接手裝置 token';
end;
$$;
reset role;

do $$
declare
  v_user uuid;
  v_rows int;
  v_stale int;
begin
  select count(*) into v_rows from public.device_tokens where token = 'ls6-shared-device';
  if v_rows <> 1 then
    raise exception 'FAIL：一個 token 應該只有 1 列，實際 % 列', v_rows;
  end if;

  select user_id into v_user from public.device_tokens where token = 'ls6-shared-device';
  if v_user is distinct from 'b0000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：接手後 token 應綁定 B，實際 %', v_user;
  end if;

  select count(*) into v_stale from public.device_tokens
   where token = 'ls6-shared-device'
     and user_id = 'a0000000-0000-4000-8000-000000000001';
  if v_stale <> 0 then
    raise exception 'FAIL：A 的舊綁定還在 —— A 會繼續收到 B 家庭的推播（跨家庭外洩）';
  end if;

  raise notice 'ok：換手後 token 只綁定 B，A 的舊綁定已消失';
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. RPC 本身的授權：SECURITY DEFINER 函式預設對 PUBLIC 開放，必須已經收回
-- ---------------------------------------------------------------------------
do $$
begin
  if has_function_privilege('anon', 'public.register_device_token(text, text)', 'execute') then
    raise exception 'FAIL：anon 可以執行 register_device_token（未登入者能改別人的 token 綁定）';
  end if;
  if not has_function_privilege('authenticated',
       'public.register_device_token(text, text)', 'execute') then
    raise exception 'FAIL：authenticated 不能執行 register_device_token，接手路徑不存在';
  end if;
  raise notice 'ok：register_device_token 只有 authenticated 可執行';
end;
$$;

rollback;
