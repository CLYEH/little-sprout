-- LS-155 R3 併發場景「情況 2 vs media（N2：真實在飛上傳）」的 session 0。
--
-- U1 自己的背景上傳：對 S2（U1 唯一成員的家）送出一張照片，交易持有到第 9 秒才
-- commit——模擬「上傳交易尚未提交」這個真實窗口（reviewer N2：不需要人工鎖，
-- media_storage_sync() 的 AFTER STATEMENT trigger 對 families(S2) 取的隱含列鎖
-- 就是這裡要撐開的那把鎖）。此時 U1 尚未標記 deletion_requested_at，LS051 guard
-- 是快照讀、放行這句 INSERT。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"ed000000-0000-4000-8000-000000000011","role":"authenticated"}', true);
  set local role authenticated;
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values ('ed000000-0000-4000-8000-000000000022', 'ed000000-0000-4000-8000-000000000002',
          'ed000000-0000-4000-8000-000000000002/2026/08/ed000000-0000-4000-8000-000000000022.jpg',
          'photo', 200, now(), 10, 10, 'ed000000-0000-4000-8000-000000000011');
  reset role;
end;
$$;

select pg_sleep(9);

commit;

\echo 'S0：U1 的在飛上傳（S2）已 commit'
