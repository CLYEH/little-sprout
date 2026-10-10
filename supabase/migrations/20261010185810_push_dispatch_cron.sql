-- LS-395 — push-dispatch 每分鐘排程（LS-22 後端上線，範圍 1）
--
-- 背景：push-dispatch Edge Function（LS-172）與其 SQL 面（claim_notification_events／
-- notification_recipients，20260904095205_push_dispatch.sql）早已落地，但正式站沒有任何
-- 東西會呼叫它（docs/API.md §10「排程」原寫「未建立」）。這支 migration 補上
-- pg_cron 每分鐘 → pg_net.http_post → push-dispatch 這條線。
--
-- 與 purge-storage 排程（正式站手動建立，docs/API.md §6）的形狀差異與取捨：
--   1. purge-storage 的 cron job 是 orchestrator 直接在正式站 cron.schedule() 建的，URL 與
--      apikey 內嵌在 job 指令裡；這支改走 migration（`db push` 即部署、本機 reset 也套用），
--      所以 URL **不能寫死**（寫死 = 本機／CI 的 cron 也會打正式站）。URL 與 apikey 都放
--      vault：`ls172_push_dispatch_url`、`ls172_push_dispatch_secret_key`（後者即 API.md
--      §10 既有命名；值為新式 `sb_secret_…` default key，見 LS-196）。
--   2. cron 指令只有 `select private.invoke_push_dispatch();`，讀 vault、呼叫 pg_net 的邏輯
--      收進這支函式——要做「任一 secret 缺 → fail loud」：沒有這道守門時，缺 secret 會
--      變成 `{"apikey": null}` 的請求，EF 回 401，症狀看起來像金鑰錯而不是「根本沒建
--      secret」（API.md §6 同一段警告過）。raise exception 讓 cron.job_run_details 該分鐘
--      記 failed，prod-push-health.sh 會抓到。本機／CI 沒建 vault secret，cron 每分鐘會
--      記一筆 failed——預期內、無副作用（沒有發出任何 HTTP 請求）。
--   3. `timeout_milliseconds := 60000`：pg_net 預設 5000 ms，EF 內部時間預算 60 秒
--      （index.ts TIME_BUDGET_MS），逾時 cron 拿不到回應（API.md §6 LS-196 R2 N1）。
--
-- 部署順序（見 docs/API.md §10「排程」）：先建兩個 vault secret、deploy EF、設 APNS_*
-- secrets，最後才 `db push` 本 migration——排程一上線就會開始 claim 事件，EF／secrets
-- 沒就緒時 claim 後送失敗屬「寧可漏送不重送」語意（push_dispatch migration 檔頭），事件
-- 會被標記已送而實際沒送。
--
-- fail-soft：同 20260903110908_purge_expired.sql 第 6 段——本機映像若無 pg_cron，
-- CREATE EXTENSION 會噴錯，吞掉只留 NOTICE，不擋 migration chain。函式本身一律建立
-- （plpgsql 函式本體的 vault／net 參照在呼叫時才解析，缺 pg_net／vault 的環境建立不報錯）。
--
-- 非 BREAKING：新增函式與 cron job，不改既有物件。

create or replace function private.invoke_push_dispatch()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'ls172_push_dispatch_url';
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'ls172_push_dispatch_secret_key';

  if v_url is null or v_key is null then
    raise exception
      'push-dispatch 排程：vault secret 未建立（ls172_push_dispatch_url=%，ls172_push_dispatch_secret_key=%）——見 docs/API.md §10「排程」',
      case when v_url is null then '缺' else '有' end,
      case when v_key is null then '缺' else '有' end;
  end if;

  select net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) into v_request_id;

  return v_request_id;
end;
$$;

-- 不 grant 給任何人（harden_default_privileges.sql 的全域 default privileges 已收掉 PUBLIC
-- baseline）；pg_cron 以 postgres 身分執行，不受影響。只補 public／anon 的顯式 revoke，
-- 理由同 private.purge_expired（避免觸發 migration-breaking-check B3）。
revoke execute on function private.invoke_push_dispatch() from public, anon;

comment on function private.invoke_push_dispatch() is
  'LS-395：讀 vault（ls172_push_dispatch_url／ls172_push_dispatch_secret_key）後以 pg_net '
  '呼叫 push-dispatch Edge Function，回傳 pg_net request id；任一 secret 缺就 raise。'
  '由 pg_cron job ls395-push-dispatch-every-minute 每分鐘呼叫。security definer，'
  '只 postgres／service_role 可執行。';

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      create extension pg_cron;
    exception when others then
      raise notice
        'push-dispatch 排程：pg_cron 無法在本環境啟用（%），略過 cron.schedule',
        sqlerrm;
    end;
  end if;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      -- job 名稱固定：cron.schedule() 對同名 job 是更新語意（pg_cron ≥1.4），重複套用
      -- 不會疊出多個 job。
      perform cron.schedule('ls395-push-dispatch-every-minute', '* * * * *',
        $cron$select private.invoke_push_dispatch();$cron$);
    exception when others then
      raise notice 'push-dispatch 排程：pg_cron 已啟用但 cron.schedule() 失敗（%），略過排程註冊', sqlerrm;
    end;
  else
    raise notice 'push-dispatch 排程：pg_cron 未啟用，cron.schedule 略過';
  end if;
end;
$$;
