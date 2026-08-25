-- LS-90 併發場景「兩連線同時 create_invite」的最終狀態斷言。
--
-- 兩條，缺一不可：
--   1. 兩支碼都合規（6 碼、大寫、字元集不含 0/O/1/I）——併發下任何一邊的碼生成
--      邏輯被打斷，最容易先在格式上露餡。
--   2. 兩支碼互不相同——這是撞碼重試迴圈要保護的不變量：即使兩個交易「同時」
--      執行到 INSERT 那一步，DB 的 UNIQUE 約束 + 應用層的重抽會讓最終落地的
--      兩列一定不同（若真的撞上同一個隨機值，較晚 commit 的那邊會在自己的
--      迴圈裡重抽，不會是同一支碼；30 bit 空間下這裡兩支碼本來就幾乎不可能撞，
--      這條斷言主要抓的是「兩邊互相干擾導致其中一邊複製到另一邊的碼」這種
--      邏輯錯誤，不是在賭真的撞碼）。

\set ON_ERROR_STOP on

do $$
declare
  v_count int;
  v_distinct int;
  v_bad int;
begin
  select count(*), count(distinct code) into v_count, v_distinct
    from public.invites
   where family_id = '9a000000-0000-4000-8000-000000000001';

  if v_count <> 2 then
    raise exception
      'FAIL 併發：產碼併發家應有 2 支邀請碼（S1、S2 各一），實際 %', v_count;
  end if;
  if v_distinct <> 2 then
    raise exception
      'FAIL 併發：S1／S2 同時 create_invite 產出了重複的碼（distinct=%）', v_distinct;
  end if;

  select count(*) into v_bad from public.invites
   where family_id = '9a000000-0000-4000-8000-000000000001'
     and code !~ '^[2-9A-HJ-NP-Z]{6}$';
  if v_bad <> 0 then
    raise exception
      'FAIL 併發：產碼併發家有 % 支邀請碼格式不合規（應為 6 碼、字元集不含 0/O/1/I）', v_bad;
  end if;

  raise notice 'ok 併發：兩線同時 create_invite 都成功，2 支碼皆合規且互不相同';
end;
$$;
