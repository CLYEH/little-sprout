"""LS-342 — food_catalog 過敏原啟發式規則（單一來源）。

背景：LS-339 merge-review R1 抓到 `pork_floss`／`fish_floss`（肉鬆／魚鬆）漏標
`soy` 是靠人工逐列核對，「沒有機械 gate 能防新增食物漏標過敏原」記在 LS-96 池項
`708422e5`（i-risk）。本檔把票文範圍 1 的關鍵字→過敏原規則表，寫成單一資料結構，
供兩個呼叫端共用（不各寫一份規則）：

  1. `scripts/ops/food-catalog-sql.py check-allergens`
     ——純 Python，直接讀 `supabase/seed-data/food_catalog.csv`，不需要 DB。
     供 CI `rules` job（無 DB）與本機快速檢查使用（CSV 端 deny）。
  2. `scripts/ops/food-catalog-sql.py check-allergens-sql`
     ——把同一份規則（`KEYWORD_RULES`／`SOY_SAUCE_DISH_IDS`／`WHITELIST`）轉成一段
     SQL `do $$ ... $$` 區塊，對 `public.food_catalog` 目前內容（DB 現況，天然涵蓋
     多支 migration 累加後的結果）跑同樣的檢查（DB 端 deny）。供
     `supabase/tests/run.sh` 在有 DB 時執行，理由與既有 `food-catalog-sql.py check`
     相同（docker exec 通道下 psql 看不到 host 的 CSV 檔案路徑，兩邊都是「host 端
     先產生 SQL 文字，再交給既有 `run_sql()` 執行」）。

規則對應現有 `food_catalog_allergens_valid` check constraint 的 8 個合法值
（`egg`／`milk`／`peanut`／`tree_nut`／`shellfish`／`fish`／`wheat`／`soy`）。
票文另提到「芝麻→sesame」——**刻意不實作**：`'sesame'` 不在這個列舉裡，而本票
範圍明講「不做：新增 allergen 列舉值」，兩者衝突時以「不做」為準。含「芝麻」的
兩列（`sesame_oil`／`tahini`）現況 `allergens` 皆為空，沒有規則會檢查它們——這是
已知留白，不是本票要修的漏標（若日後要支援，需要先開票新增列舉值，非本票範圍）。

過敏原關鍵字刻意選「複合詞」而非單一「豆」字：豆腐／豆干／豆皮／豆漿／納豆／
黃豆／毛豆——避免像豌豆、紅豆、綠豆、豆薯、鷹嘴豆這類「豆」字但非黃豆製品的
品項變成一長串萬用例外（票文本身也點名了這個陷阱：「綠豆／紅豆／豌豆等非大豆
的『豆』、『豆薯』」）。「醬油調味慣例列」不是名稱關鍵字——274 列裡沒有任何
品項名稱字面上帶「醬油」二字，這條規則是既有 migration 檔頭
（`20260919073805_food_catalog_expansion.sql`：「本表把『醬油調味』視為 `soy`
過敏原的觸發條件，不論是主料還是調味」）記錄的判準延伸，所以用顯式 id 清單
（`SOY_SAUCE_DISH_IDS`）表示，不是用猜字面（也不是萬用字元）。

基準結果（對現況 274 列跑過一次，見 LS-342 handoff）：規則命中的項目裡，
「還沒有正確過敏原標記」的全部是這份規則自己的已知例外（頭足類含「魚」字、
音譯詞含「貝」字、蔬菜品種名含「奶」字、燕麥／藜麥含「麥」字但非小麥製品），
逐筆列在 `WHITELIST` 並附理由；沒有找到任何真正的既有漏標，不需要 orchestrator
裁決資料本身。
"""
from __future__ import annotations

# ── 規則表 ──────────────────────────────────────────────────────────────
# (allergen, [name_zh 關鍵字...], 說明)
KEYWORD_RULES: list[tuple[str, list[str], str]] = [
    ("fish", ["魚", "鮭", "鱈", "鯛", "鰻"], "名稱含魚類字"),
    ("shellfish", ["蝦", "蟹", "貝", "蛤", "蚵", "牡蠣", "干貝", "九孔", "龍蝦"], "名稱含蝦蟹貝類字"),
    ("soy", ["豆腐", "豆干", "豆皮", "豆漿", "納豆", "黃豆", "毛豆", "味噌"], "名稱含大豆製品字"),
    ("egg", ["蛋"], "名稱含蛋字"),
    ("milk", ["奶", "乳", "起司", "優格"], "名稱含奶／乳製品字"),
    ("peanut", ["花生"], "名稱含花生字"),
    ("tree_nut", ["杏仁", "核桃", "腰果", "開心果", "榛果", "夏威夷豆", "胡桃", "堅果"], "名稱含堅果字"),
    ("wheat", ["麵", "麥", "吐司", "饅頭"], "名稱含麵／麥製品字"),
]

# 「醬油調味慣例列」——不是名稱關鍵字，見檔頭說明。日後若再有同類判斷（例如
# 新增其他醬油滷製的加工品），在這裡逐筆加 id，不要改成猜字面。
SOY_SAUCE_DISH_IDS: frozenset[str] = frozenset({
    "braised_pork_sauce",   # 滷肉燥
    "braised_pork_rice",    # 滷肉飯
    "three_cup_chicken",    # 三杯雞
    "pork_floss",           # 肉鬆（LS-339 R2 m1）
    "fish_floss",           # 魚鬆（LS-339 R2 m1）
})

# 例外白名單：(id, allergen) -> 理由。逐筆列 id，不得用萬用字元（票文硬性要求）。
WHITELIST: dict[tuple[str, str], str] = {
    ("flying_squid", "fish"): "頭足類（魷魚），非魚類，沿用既有 squid／neritic_squid／octopus 慣例不標 fish（LS-96 池項 708422e5 i5-a）",
    ("octopus", "fish"): "頭足類（章魚），非魚類，理由同 flying_squid",
    ("portobello", "shellfish"): "波特貝勒菇（洋菇）為音譯詞，名稱含「貝」字純屬音譯巧合，非貝類海鮮",
    ("cream_bok_choy", "milk"): "奶油白菜為蔬菜品種俗名（類似奶油萵苣），非乳製品調味，不含奶",
    ("oatmeal", "wheat"): "燕麥非小麥，現行 8 類過敏原無獨立燕麥項目，不對應 wheat",
    ("quinoa", "wheat"): "藜麥為藜科植物種子（pseudocereal），非小麥製品",
}


def _row_allergens(raw: str) -> set[str]:
    return {a for a in raw.split(";") if a}


def check_rows(rows) -> list[str]:
    """rows：iterable of dict，至少含 'id'／'name_zh'／'allergens'（`;` 分隔字串）。

    回傳違規訊息 list（空 list＝全過）。每一則訊息都點名 id、name_zh、缺的
    allergen、實際 allergens——供 CSV 端與自測直接比對。
    """
    violations: list[str] = []
    for row in rows:
        rid = row["id"]
        name = row["name_zh"]
        allergens = _row_allergens(row["allergens"])

        for allergen, keywords, desc in KEYWORD_RULES:
            if not any(kw in name for kw in keywords):
                continue
            if allergen in allergens:
                continue
            if (rid, allergen) in WHITELIST:
                continue
            violations.append(
                f"FAIL：{rid}（{name}）{desc}，allergens 應含 '{allergen}'，"
                f"實際 {sorted(allergens) or '{}'}"
            )

        if rid in SOY_SAUCE_DISH_IDS and "soy" not in allergens and (rid, "soy") not in WHITELIST:
            violations.append(
                f"FAIL：{rid}（{name}）屬醬油調味慣例列，allergens 應含 'soy'，"
                f"實際 {sorted(allergens) or '{}'}"
            )
    return violations


def _sql_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def generate_sql_do_block() -> str:
    """把 KEYWORD_RULES／SOY_SAUCE_DISH_IDS／WHITELIST 轉成一段對
    `public.food_catalog` 現況跑檢查的 SQL `do $$ ... $$`（DB 端 deny 路徑）。

    與 `check_rows()` 是同一份規則表產生的兩種形式（Python 直接跑 vs. 產生 SQL
    交給 DB 跑），不是各自維護一份規則——改規則只改這個檔案的 KEYWORD_RULES／
    SOY_SAUCE_DISH_IDS／WHITELIST，兩條路徑一起變。
    """
    lines = [
        r"\set ON_ERROR_STOP on",
        "do $$",
        "declare",
        "  v_bad text;",
        "begin",
    ]

    for allergen, keywords, desc in KEYWORD_RULES:
        name_like = " or ".join(
            "name_zh like " + _sql_quote("%" + kw + "%") for kw in keywords
        )
        exempt_ids = sorted(rid for (rid, a) in WHITELIST if a == allergen)
        exempt_clause = ""
        if exempt_ids:
            exempt_list = ", ".join(_sql_quote(rid) for rid in exempt_ids)
            exempt_clause = f"\n     and id not in ({exempt_list})"
        lines += [
            "  select string_agg(id || '（' || name_zh || '）', ', ') into v_bad",
            "    from public.food_catalog",
            f"   where ({name_like})",
            f"     and not ('{allergen}' = any(allergens)){exempt_clause};",
            "  if v_bad is not null then",
            f"    raise exception 'FAIL：{desc}但 allergens 缺 {allergen}：%', v_bad;",
            "  end if;",
            "",
        ]

    soy_ids = ", ".join(_sql_quote(rid) for rid in sorted(SOY_SAUCE_DISH_IDS))
    soy_exempt_ids = sorted(rid for (rid, a) in WHITELIST if a == "soy" and rid in SOY_SAUCE_DISH_IDS)
    soy_exempt_clause = ""
    if soy_exempt_ids:
        soy_exempt_list = ", ".join(_sql_quote(rid) for rid in soy_exempt_ids)
        soy_exempt_clause = f"\n     and id not in ({soy_exempt_list})"
    lines += [
        "  select string_agg(id || '（' || name_zh || '）', ', ') into v_bad",
        "    from public.food_catalog",
        f"   where id in ({soy_ids})",
        f"     and not ('soy' = any(allergens)){soy_exempt_clause};",
        "  if v_bad is not null then",
        "    raise exception 'FAIL：屬醬油調味慣例列但 allergens 缺 soy：%', v_bad;",
        "  end if;",
        "",
        "  raise notice 'ok：food_catalog 過敏原啟發式檢查通過（LS-342，%d 條關鍵字規則＋%d 條醬油慣例列＋%d 條白名單例外）';"
        % (len(KEYWORD_RULES), len(SOY_SAUCE_DISH_IDS), len(WHITELIST)),
        "end;",
        "$$;",
    ]
    return "\n".join(lines) + "\n"
