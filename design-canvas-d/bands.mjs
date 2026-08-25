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
import { T, lch, lchHex, dHue, TEMP } from './tokens.mjs';

/* ── 色票那六條的邊界樣本（第 8 輪 D7-01①）──────────────────────────
   第 6 輪它們登記成「做不到」，理由是「對照複本換不掉 gate import 進來的色票」。
   第 7 輪 reviewer 裁那個理由**不成立**：換不掉是因為 MG4 用正則讀原始碼文字，
   而不是因為換不掉。MG4 改成從產物根目錄 import 整份色票之後，
   「把色票轉一個角度、讓算出來的值剛好落到門檻另一邊」就做得出來了。

   做法一律是**轉色相**（L*／C* 不動）：轉一個色票的兩個端點，
   它在漸層中點上的角度就整條跟著移；只轉一個端點，兩端的色相差就改變。
   而且轉多少是**從 v 算回去的** —— 與其他邊界樣本同一條規矩：
   v 同時是「寫進去的值」與「登記給 MG4 檢查的值」，同一個數用兩次。 */
const rot = (hex, d) => { const c = lch(hex); return lchHex(c.L, c.C, c.h + d); };
const gm = (th, k) => { const s = th.grad[k].filter(([c]) => /^#/.test(c)); const a = lch(s[0][0]), b = lch(s.at(-1)[0]); return a.h + dHue(b.h, a.h) / 2; };
const tri = (th) => { const p = gm(th, 'paper'); return { cool: -dHue(gm(th, 'win'), p), warm: Math.min(dHue(gm(th, 'win3'), p), dHue(gm(th, 'face'), p)), span: dHue(gm(th, 'win3'), p) - dHue(gm(th, 'win'), p) }; };
const dh = (th, k) => Math.abs(dHue(lch(th.grad[k].at(0)[0]).h, lch(th.grad[k].at(-1)[0]).h));
/* 「轉幾度」不能只算一次。8 bit 網格上低彩度顏色的色相是**粗的**：台紙那幾階的
   C* 只有 7 左右，半個 Lab 單位的量化誤差就是 4° 的色相誤差 —— 第一版直接算
   「要移 3.5 度」的那一發，量出來只移了 2.9 度，樣本落在門檻的合格側，
   等於一發不會轉紅的邊界樣本。所以改成**搜**：在 ±60° 內以 0.01° 為步長找出讓量出來的值
   最接近 v 的那個角度，量的用的就是 gate 之後會用的同一條算式。
   也因為網格是粗的，這六發的 v 不是隨手挑的整數，而是**網格上最貼近門檻的可達值**
   （例如凹那一條，6° 與 4.98° 之間根本沒有可表示的顏色）。
   v 因此仍然是同一個數用兩次（寫進複本的、與登記給 MG4 檢查的）。 */
const aim = (measure, v) => {
  let best = 0, err = Infinity;
  for (let d = -6000; d <= 6000; d++) { const e = Math.abs(measure(d / 100) - v); if (e < err) { err = e; best = d / 100; } }
  return best;
};
/* 把 light 主題的某幾支漸層整支轉 d 度之後的樣子（兩端一起轉，兩端色相差不變）。 */
const rotated = (keys, d) => {
  const grad = { ...T.light.grad };
  for (const k of keys) grad[k] = T.light.grad[k].map(([c, p]) => [/^#/.test(c) ? rot(c, d) : c, p]);
  return { ...T.light, grad };
};
/* 把某一支漸層的**最後一個端點**轉 d 度之後的樣子（兩端色相差跟著變）。 */
const endRot = (k, d) => {
  const grad = { ...T.light.grad };
  const st = T.light.grad[k];
  grad[k] = st.map(([c, p], i) => [i === st.length - 1 ? rot(c, d) : c, p]);
  return { ...T.light, grad };
};
const applyRot = (s, keys, d) => {
  for (const k of keys) for (const [hex] of T.light.grad[k].filter(([c]) => /^#/.test(c))) s = s.replaceAll(hex, rot(hex, d));
  return s;
};
const applyEnd = (s, k, d) => { const last = T.light.grad[k].at(-1)[0]; return s.replaceAll(last, rot(last, d)); };

export const BANDS = [
  {
    id: '邊界－對比剛好差一點（AAA）', of: 'CONTRAST.aaa', v: 6.9, gate: 'G6',
    why: 'AAA 是 7.0。把最低的那個文字節點放到 6.9 —— 差 0.1。點測試（1.1:1）在門檻被洗成 4.5 之後仍然會紅，這一發不會。',
    mutate: (d, v, h) => h.editJson(d, 'measured.json', (m) => { m.contrastMin = v; m.contrastFails = [`邊界樣本：最低節點 ${v}`]; }),
  },
  {
    id: '邊界－顆粒層剛好差一點', of: 'CONTRAST.grain', v: 5.9, gate: 'G22',
    why: '顆粒下限 6.0，實測 6.27（餘裕 0.27 —— 全稿最薄的門檻之一）。把它放到 5.9，差 0.1。',
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
  /* ── 以下六發是色票門檻的邊界樣本（第 8 輪；第 6 輪登記為「做不到」的那六條）──
     它們動的是複本的 tokens.mjs，咬的是 MG4：gate 自己的尺（import 進來的本尊色票）
     不隨樣本變，所以 G22／G23 仍然綠 —— 會叫的是「登記簿說實測是 X、現算是 Y」
     與「實測落到門檻的不合格側」這兩條，那正是 ⑤ 存在的理由。 */
  {
    id: '邊界－四階溫度偏一階（剛好超出容差）', of: 'TEMP_TOL', v: 3.1, gate: 'MG4',
    why: '容差 ±3°。把淺色 cta 那一階的色相轉到偏離宣告 3.1° —— 只超出 0.1°（8 bit 網格上這一階最接近門檻的可達值）。第 6 輪這一條登記成「做不到邊界樣本」，理由是複本換不掉色票；MG4 改成從複本 import 之後就換得掉了。',
    mutate: (dir, v, h) => h.edit(dir, 'tokens.mjs', (s) => {
      const dev = (d) => Math.abs(dHue(lch(rot(T.light.cta, d)).h, lch(T.light.board).h) - TEMP.cta);
      return s.replaceAll(T.light.cta, rot(T.light.cta, aim(dev, v)));
    }),
  },
  {
    id: '邊界－凹沒有冷夠（剛好差一點）', of: 'HUE_MIN.cool', v: 4.98, gate: 'MG4',
    why: '凹要比台紙冷 ≥6°，實測 9.31°。把淺色的凹與次要面一起往暖轉，讓「凹比台紙冷」剩 4.98° —— 比門檻低 1.02°，比值 1.21 仍在帶內。台紙那幾階的 C* 只有 2 左右，8 bit 網格上色相是**粗的**：6° 與 4.98° 之間根本沒有可表示的顏色，這一發已經是最貼線的一發。兩支一起轉，所以跨距不動：這一發只咬 cool。',
    mutate: (dir, v, h) => h.edit(dir, 'tokens.mjs', (s) => applyRot(s, ['win', 'win3'], aim((d) => tri(rotated(['win', 'win3'], d)).cool, v))),
  },
  {
    id: '邊界－次要面沒有暖夠（剛好差一點）', of: 'HUE_MIN.warm', v: 2.41, gate: 'MG4',
    why: '次要面要比台紙暖 ≥3°，實測 4.71°。把淺色的次要面往冷轉，讓它剩 2.41° —— 比值 1.24，同樣是網格上最貼線的一發。凹不動，所以跨距仍在 12° 之上：這一發只咬 warm。',
    mutate: (dir, v, h) => h.edit(dir, 'tokens.mjs', (s) => applyRot(s, ['win3'], aim((d) => tri(rotated(['win3'], d)).warm, v))),
  },
  {
    id: '邊界－四階跨距縮到剛好不夠', of: 'HUE_MIN.span', v: 11.07, gate: 'MG4',
    why: '冷端到暖端的跨距要 ≥12°，實測 14.02°。只把淺色的凹往暖轉，讓跨距剩 11.07° —— 差 0.93°，而凹自己仍然冷 6.37°（>6）：這一發只咬 span。',
    mutate: (dir, v, h) => h.edit(dir, 'tokens.mjs', (s) => applyRot(s, ['win'], aim((d) => tri(rotated(['win'], d)).span, v))),
  },
  {
    id: '邊界－「光」開始改色相（剛好越界）', of: 'LIGHT_DH', v: 7.07, gate: 'MG4',
    why: '光只改明度，兩端色相差 ≤7°，實測最大的一支 6.53°。把淺色 cta 那一支光的末端轉到兩端差 7.07° —— 只超出 0.07°。光與時間的分家就是靠這條線。',
    mutate: (dir, v, h) => h.edit(dir, 'tokens.mjs', (s) => applyEnd(s, 'cta', aim((d) => dh(endRot('cta', d), 'cta'), v))),
  },
  {
    id: '邊界－「時間」淡到只剩一支光', of: 'TIME_DH', v: 14.85, gate: 'MG4',
    why: '時間會改色相，兩端色相差 ≥15°，實測最小的一支 38.33°。把淺色 stub3（剛印好的號碼帶）的末端轉到兩端只差 14.85° —— 差 0.15°，剛好掉進光與時間之間那條 8° 的帶裡。',
    mutate: (dir, v, h) => h.edit(dir, 'tokens.mjs', (s) => applyEnd(s, 'stub3', aim((d) => dh(endRot('stub3', d), 'stub3'), v))),
  },
];
