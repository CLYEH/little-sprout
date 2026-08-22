-- LS-34：外鍵反向索引列舉檢查（RI 效能防護網）
--
-- 為什麼要有這一關：每一個外鍵在刪除／更新父列時，Postgres 都要在子表上找出所有
-- 參照到那個值的列（RESTRICT 要擋、CASCADE 要清、SET NULL 要清）。這個查詢的
-- WHERE 條件永遠是「子表的外鍵欄位 = 父列的值」——沒有索引的話就是全表掃描，
-- 資料量大的表（media、comments……）刪一列父資料就會拖到有感的程度。
-- LS-33 review 實際踩過一次：join_requests.resolved_by 補了索引，但沒有任何測試
-- 盯著它（見 supabase/migrations/20260823010000_join_approval.sql 第 114-121 行
-- 的三段註解；commit 47f6970 的說明裡也承認「F5 沒有對應的 mutation」）。
--
-- 判準：外鍵參照欄位（conkey）必須是某個「非 partial」索引最前面幾欄的「集合」——
-- 不要求索引欄位順序與外鍵宣告順序相同，等值查找（= $1 and = $2 ...）不看順序，
-- 只要求這些欄位都在索引的最前段。排除 partial index：本 schema 的軟刪除表
-- （media／albums／diaries／comments…… 的 deleted_at）常見「WHERE deleted_at is null」
-- 的部分索引，那只覆蓋一部分列；RI 檢查要對「所有」列都成立（含已軟刪除的列），
-- 部分索引用不上。
--
-- 範圍只掃 public schema：auth／storage／_realtime／extensions 是 Supabase 平台自己
-- 佈建的 migration，我們不擁有也改不動，不是這道 gate 該管的範圍（本機掃描實測
-- 那幾個 schema 也有多處同樣缺索引，但那是平台的事）。
--
-- 白名單（已知缺口，非本票造成）：以下 11 個外鍵在本票開工前就已存在，是 LS-6～LS-15
-- 期間陸續加表時留下的技術債，這裡掃描第一次跑就會挑出來。列出來而不是悄悄放過——
-- PLAN.md §5 對 comments／reactions 的多型關聯已有「代價可接受但要知道它存在」的
-- 先例，這裡比照辦理：明確記錄、待開票逐一補索引，不能只靠一句「可接受」帶過。
-- 這份清單只能變短，不能變長：新增的外鍵沒有索引，不能靠加進這裡過關——第二段
-- 「白名單反向對照」會在清單內的項目其實已經補了索引時報錯，逼著清單保持誠實。
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_known_gaps text[] := array[
    'albums.albums_created_by_fkey',
    'blocked_users.blocked_users_blocked_id_fkey',
    'blocked_users.blocked_users_blocker_id_fkey',
    'comments.comments_author_id_fkey',
    'comments.comments_family_id_fkey',
    'content_reports.content_reports_reporter_id_fkey',
    'diaries.diaries_author_id_fkey',
    'families.families_created_by_fkey',
    'invites.invites_created_by_fkey',
    'media.media_uploaded_by_fkey',
    'reactions.reactions_user_id_fkey'
  ];
  v_missing text;
  v_stale text;
begin
  -- 真正缺索引、且不在已知缺口清單內的：FAIL，指名 table.constraint
  select string_agg(x.label, '、' order by x.label)
    into v_missing
    from (
      select t.relname || '.' || c.conname as label
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
       where c.contype = 'f'
         and t.relnamespace = 'public'::regnamespace
         and not exists (
           select 1 from pg_index i
            where i.indrelid = c.conrelid
              and i.indpred is null  -- partial index 不保證涵蓋所有列，不算數
              and (
                select array_agg(k order by k)
                  from unnest((i.indkey::int2[])[0:array_length(c.conkey,1)-1]) as k
              ) = (
                select array_agg(k order by k) from unnest(c.conkey) as k
              )
         )
    ) x
   where x.label <> all(v_known_gaps);

  if v_missing is not null then
    raise exception
      'FAIL：以下外鍵沒有可用的反向索引（RI 檢查／cascade 會全表掃描）—— %。若是刻意接受的技術債，要先開票記錄再加進本檔的 v_known_gaps 白名單，不能悄悄放過',
      v_missing;
  end if;

  -- 白名單反向對照：清單內的項目如果其實已經有索引了，代表清單過期沒清掉
  select string_agg(x.label, '、' order by x.label)
    into v_stale
    from (
      select t.relname || '.' || c.conname as label
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
       where c.contype = 'f'
         and t.relnamespace = 'public'::regnamespace
         and exists (
           select 1 from pg_index i
            where i.indrelid = c.conrelid
              and i.indpred is null
              and (
                select array_agg(k order by k)
                  from unnest((i.indkey::int2[])[0:array_length(c.conkey,1)-1]) as k
              ) = (
                select array_agg(k order by k) from unnest(c.conkey) as k
              )
         )
    ) x
   where x.label = any(v_known_gaps);

  if v_stale is not null then
    raise exception
      'FAIL：白名單裡的這些外鍵其實已經有索引了，清單過期——請把它們從 v_known_gaps 移除：%',
      v_stale;
  end if;

  raise notice
    'ok：public schema 內每一個外鍵，除了已登記的 % 項既有技術債，都有可用的反向索引',
    array_length(v_known_gaps, 1);
end;
$$;

rollback;
