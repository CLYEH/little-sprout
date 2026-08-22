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
-- 判準（LS-34 review F5 加固過三處，都是實測過的潛伏誤判）：
--   - 外鍵參照欄位（conkey）必須是某個索引「鍵欄位」（不含 INCLUDE payload 欄）最前面
--     幾欄的「集合」——不要求索引欄位順序與外鍵宣告順序相同，等值查找不看順序。
--   - `indnkeyatts >= FK 欄位數` 這條 guard 是必要的：indkey 裡鍵欄位之後接著的是
--     INCLUDE 欄，兩者的 attnum 混在同一個陣列裡，沒有這條 guard 會把「鍵欄位不夠、
--     靠 INCLUDE 湊數」的索引誤判成可用（INCLUDE 欄不在索引的搜尋鍵裡，不能拿來做
--     等值查找）——已用假造的 `(family_id) include (invite_id)` 索引實測重現這個
--     誤判，加上 guard 後才被正確判為不可用。
--   - 排除 partial index（`indpred is null`）：本 schema 的軟刪除表（media／albums／
--     diaries／comments…… 的 deleted_at）常見「WHERE deleted_at is null」的部分索引，
--     只覆蓋一部分列；RI 檢查要對「所有」列都成立（含已軟刪除的列），部分索引用不上。
--   - 排除失效／正在被同時刪除的索引（`indisvalid and indislive`）：`CREATE INDEX
--     CONCURRENTLY` 失敗會留下 `indisvalid=false` 的殘骸，`DROP INDEX CONCURRENTLY`
--     進行中會有 `indislive=false` 的過渡態，兩者都不是「可用」的索引。
--   - 限定存取方法為 btree／hash（`am.amname`）：RI 檢查是單純的等值查找，GIN／GiST／
--     BRIN 即使剛好蓋到那些欄位也不是為這種查找設計的，不應該算數。
--
-- 範圍只掃 public schema：auth／storage／_realtime／extensions 是 Supabase 平台自己
-- 佈建的 migration，我們不擁有也改不動，不是這道 gate 該管的範圍（本機掃描實測
-- 那幾個 schema 也有多處同樣缺索引，但那是平台的事）。
--
-- 白名單（已知缺口，非本票造成）：LS-36 已把 LS-6～LS-15 期間留下的 11 項技術債
-- 全部補上反向索引（見 supabase/migrations/20260823020000_fk_reverse_indexes.sql
-- 的逐項裁量說明），目前沒有「有意不建」項，清單維持淨空。
-- 這份清單的技術債類條目只能變短，不能變長，且只能登記「目前真的存在」的外鍵：
--   - 清單內的項目其實已經有索引了 → 過期沒清掉（第 2 段擋）。
--   - 清單內的項目根本找不到對應的外鍵了（表／約束改名或刪除）→ 殭屍條目；
--     不擋的話，日後若有人重建一個同名外鍵，會被這個殭屍條目無聲豁免、繞過檢查
--     （LS-34 review F4）（第 3 段擋）。
-- 若日後有 FK 判定「有意不建」（極少反向查詢、父表也無 DELETE/UPDATE 觸發 RI 反查），
-- 才把該項加回這裡，並在 migration 註解記錄裁量理由——與這份「暫置技術債」清單
-- 語義不同：那是決定，不是債，理論上應該另分一段標記，但目前尚無此類項目。
--
-- 判定式只寫一次（LS-34 review F6）：一支查詢把 (label, has_index) 算好存進兩個
-- 平行陣列，後面三段檢查各自用 unnest 過濾這兩個陣列，不會出現「同一段 SQL 複製
-- 三份、改一處忘改另一處」的漂移風險。
\set ON_ERROR_STOP on

begin;

do $$
declare
  -- LS-36：11 項既有缺口已全部補上反向索引，清單收斂為空（見上方註解）
  v_known_gaps text[] := array[]::text[];
  v_labels text[];
  v_has_index boolean[];
  v_missing text;
  v_stale text;
  v_zombie text;
begin
  -- 單一判定式：每個外鍵是否有可用的反向索引，結果存進兩個平行陣列（依 label 排序）
  select array_agg(x.label order by x.label), array_agg(x.has_index order by x.label)
    into v_labels, v_has_index
    from (
      select t.relname || '.' || c.conname as label,
             exists (
               select 1
                 from pg_index i
                 join pg_class ic on ic.oid = i.indexrelid
                 join pg_am am on am.oid = ic.relam
                where i.indrelid = c.conrelid
                  and i.indpred is null                          -- 排除 partial index
                  and i.indisvalid and i.indislive                -- 排除失效／過渡態索引
                  and am.amname in ('btree', 'hash')              -- 等值查找限定存取方法
                  and i.indnkeyatts >= array_length(c.conkey, 1)  -- 鍵欄位數要夠，INCLUDE 欄不算數
                  and (
                    select array_agg(k order by k)
                      from unnest((i.indkey::int2[])[0:array_length(c.conkey,1)-1]) as k
                  ) = (
                    select array_agg(k order by k) from unnest(c.conkey) as k
                  )
             ) as has_index
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
       where c.contype = 'f'
         and t.relnamespace = 'public'::regnamespace
    ) x;

  -- 1) 真正缺索引、且不在已知缺口清單內的：FAIL，指名 table.constraint
  select string_agg(u.label, '、' order by u.label)
    into v_missing
    from unnest(v_labels, v_has_index) as u(label, has_index)
   where not u.has_index and u.label <> all(v_known_gaps);

  if v_missing is not null then
    raise exception
      'FAIL：以下外鍵沒有可用的反向索引（RI 檢查／cascade 會全表掃描）—— %。若是刻意接受的技術債，要先開票記錄再加進本檔的 v_known_gaps 白名單，不能悄悄放過',
      v_missing;
  end if;

  -- 2) 白名單反向對照：清單內的項目如果其實已經有索引了，代表清單過期沒清掉
  select string_agg(u.label, '、' order by u.label)
    into v_stale
    from unnest(v_labels, v_has_index) as u(label, has_index)
   where u.has_index and u.label = any(v_known_gaps);

  if v_stale is not null then
    raise exception
      'FAIL：白名單裡的這些外鍵其實已經有索引了，清單過期——請把它們從 v_known_gaps 移除：%',
      v_stale;
  end if;

  -- 3) 白名單第三向對照（F4）：清單項目對應的外鍵已經不存在了——殭屍條目，
  --    不清掉的話日後同名外鍵被重建會無聲繼承這份豁免，不再受檢查
  select string_agg(g, '、' order by g)
    into v_zombie
    from unnest(v_known_gaps) as g
   where g <> all(v_labels);

  if v_zombie is not null then
    raise exception
      'FAIL：白名單裡的這些條目找不到對應的外鍵了（表／約束已改名或刪除）——把殭屍條目從 v_known_gaps 清掉：%',
      v_zombie;
  end if;

  raise notice
    'ok：public schema 內每一個外鍵，除了已登記的 % 項既有技術債，都有可用的反向索引',
    coalesce(array_length(v_known_gaps, 1), 0);
end;
$$;

rollback;
