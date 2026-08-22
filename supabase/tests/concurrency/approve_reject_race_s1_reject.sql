-- 併發場景二（方向 B：拒絕先動）的 session 1：媽媽先拒絕，故意壓住 3 秒不 commit。
--
-- 方向 A（核准先動）測不到 approve_join 自己那把 `for update`：先動的那一邊反正會在
-- 自己的 UPDATE 上取得列鎖，後動的一邊只要有鎖就會排隊。要讓 approve_join 的鎖成為
-- 唯一的防線，必須讓「核准」當後動的那一個——這就是這個方向存在的理由（由 mutation
-- test 發現：只有方向 A 的時候，拿掉 approve_join 的 for update 測試仍然全綠）。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"eb000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;

select public.reject_join('9f000000-0000-4000-8000-000000000001');

select pg_sleep(3);

commit;

\echo 'S1：媽媽的拒絕已 commit'
