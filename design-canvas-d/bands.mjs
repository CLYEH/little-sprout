/* ── 邊界樣本登記簿（第 6 輪 D5-02 ／ MG4②a）─────────────────────────
   第 5 輪的負面對照全部是**點測試**：ΔE 從 8 掉到 0、對比從 12 掉到 1.1、
   照片亮度比從 0.5 跳到 0.99 —— 荒謬的值。荒謬的值證明得了「gate 沒有睡著」，
   證明不了「那條線畫在哪裡」：reviewer 把 AAA 從 7 改成 4.5，144 項全綠、
   14 發照常全部轉紅。門檻可以一路放寬到剛好放行現況，而沒有一發會醒。

   這張表是那件事的修法。每一發把量到的值放在**門檻旁邊**（與門檻的比值 ≤1.3）：
   門檻被放寬一點點，這一發就轉綠 → selftest exit 1。

   為什麼獨立成一個檔：verify 的 MG4 要在**跑對照之前**就知道「每一條自己開的門檻
   有沒有配一發邊界樣本、那一發貼得夠不夓近」。如果這份宣告只存在 selftest.json 裡，
   第一次加樣本時會卡在雞生蛋（baseline 要綠才跑得了對照，而對照的結果才讓 baseline 綠）。
   宣告在這裡、結果在 selftest.json，兩件事分開。

   欄位：of ＝ 它守著 THRESHOLDS 登記簿上的哪一條；v ＝ 放到哪個值；
   mutate(dir, v, h) ＝ 怎麼把那個值寫進複本（h 是 selftest 提供的兩個檔案改寫工具）。
   **v 同時是寫進去的值與登記給 MG4 檢查的值** —— 同一個數用兩次，
   所以它不可能是一個誰都可以填的宣稱。 */
export const BANDS = [
  {
    id: '邊界－對比剛好差一點（AAA）', of: 'CONTRAST.aaa', v: 6.9, gate: 'G6',
    why: 'AAA 是 7.0。把最低的那個文字節點放到 6.9 —— 差 0.1。點測試（1.1:1）在門檻被洗成 4.5 之後仍然會紅，這一發不會。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => { m.contrastMin = v; m.contrastFails = [`邊界樣本：最低節點 ${v}`]; }),
  },
  {
    id: '邊界－顆粒層剛好差一點', of: 'CONTRAST.grain', v: 5.9, gate: 'G22',
    why: '顆粒下限 6.0，實測 6.29（餘裕 0.29 —— 全稿最薄的門檻之一）。把它放到 5.9，差 0.1。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => { m.grainMin = v; m.grainFails = [`邊界樣本：顆粒最暗格 ${v}`]; }),
  },
  {
    id: '邊界－少一格光偏掉一點點', of: 'PHOTO_STOP_TOL', v: 0.05, gate: 'G31',
    why: '容差 ±0.04。把平均亮度比放到離「一格」0.05 的地方 —— 只超出 0.01。第 4 輪那一發是 0.99（幾乎沒暗），門檻放寬到 0.5 也還是會紅。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => { m.photo.meanRatio = +(0.5 + v).toFixed(3); m.photo.p99Ratio = +(0.5 + v).toFixed(3); }),
  },
  {
    id: '邊界－呼吸帶剛好超過一點', of: 'RULE.pause', v: 124, gate: 'G10',
    why: '呼吸帶上限 120px。一段 124px 的空白沒掛牌 —— 超出 4px。掛牌與否是意圖 gate，所以「剛好超過」正是它該咬的形狀。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => { m.pauseBad = [{ file: 'Main.dc.html', col: 'phone', len: v, at: 400 }]; }),
  },
  {
    id: '邊界－主按鈕剛好掉出可及範圍', of: 'RULE.btnPct', v: 72, gate: 'G10',
    why: '主按鈕中心要落在畫面 70% 以內。放到 72% —— 差 2 個百分點，肉眼看不出來，拇指搆不搆得到卻是二值的。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => {
      const tail = new Set(m.boards.filter((b) => b.trail > 120 && !/Tokens|Notes|Stress|AppIcon|GlassSeam/.test(b.file)).map((b) => b.file));
      const t = m.mainBtn.find((x) => tail.has(x.file)) || m.mainBtn[0];
      t.pct = v;
    }),
  },
  {
    id: '邊界－浮起面貼到玻璃交界', of: 'SP.l', v: 13, gate: 'G30',
    why: '交界 16pt 之內不得有我們的浮起面（兩套光會疊在一起）。放到 13pt —— 差 3pt。第 5 輪這一條的樣本數是零，現在它有一發貼著線的。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => { m.glass[0].nearRaise = v; }),
  },
];
