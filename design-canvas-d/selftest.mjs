/* ── 負面對照（第 5 輪 D4-07③）───────────────────────────────────
   「全綠」只證明**沒有人破壞**，不證明 gate 還有牙。第 4 輪三發突變全綠放行
   （M1b 任意值豁免、M2b 偷改驗收排的繪製尺寸、M8 兩行改寫讓三方對帳恆真）——
   三發都不是漏抓，是**根本沒有那條檢查**，而管線一路印 PASS。

   所以這一支做一件事：把產物複製到暫存目錄，**刻意弄壞一個地方**，
   再用同一份 gate 程式去跑它。沒有轉紅就 exit 1。
   兩個設計上的講究：
     ① 先跑一次沒動手腳的複本（baseline），它必須全綠 —— 不然後面每一發都會
        「因為別的原因」變紅，對照就沒有意義。
     ② 每一發都**指名它應該咬到哪一條**。只要求「有 gate 叫」是不夠的：
        下一次別的地方改壞了，這一發會誤報成綠。

   邊界（誠實話，也印在 handoff 上）：這裡咬的是「gate 對證據的反應」。
   量測本身（probe 有沒有量對）由三方對帳（measure）與每一輪 reviewer 的突變測試守，
   不由這一支守 —— 兩者互補，不互相取代。
   Run: node selftest.mjs   （或 node measure.mjs --selftest；管線第 ⑤ 步） */
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, cpSync, rmSync, readdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { hash12 } from './tokens.mjs';
import { BANDS } from './bands.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const CODE = ['build.mjs', 'verify.mjs', 'measure.mjs', 'tokens.mjs', 'icon.mjs', 'brush.mjs', 'ink.mjs', '_probe.html', 'selftest.mjs', 'bands.mjs'];
const codeFp = hash12(CODE.map((f) => `${f}:${hash12(readFileSync(join(HERE, f), 'utf8'))}`).join('|'));

const stage = () => {
  const dir = mkdtempSync(join(tmpdir(), 'ls38d-self-'));
  for (const f of readdirSync(HERE)) {
    if (/^(node_modules|shots)$/.test(f)) continue;
    if (/album-board\.html$/.test(f)) continue;          // 3MB 的匯出檔，gate 不看它
    cpSync(join(HERE, f), join(dir, f), { recursive: true });
  }
  mkdirSync(join(dir, 'shots'), { recursive: true });
  for (const f of readdirSync(join(HERE, 'shots'))) cpSync(join(HERE, 'shots', f), join(dir, 'shots', f));
  return dir;
};

const edit = (dir, file, fn) => writeFileSync(join(dir, file), fn(readFileSync(join(dir, file), 'utf8')));
const editJson = (dir, file, fn) => {
  const o = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  fn(o);
  writeFileSync(join(dir, file), JSON.stringify(o, null, 2));
};

/* 跑一次 verify（用**本尊的 gate 程式**，只把產物根目錄換掉），回報它叫了哪幾條。 */
const runVerify = (dir) => {
  try {
    const out = execFileSync(process.execPath, [join(HERE, 'verify.mjs')],
      { encoding: 'utf8', env: { ...process.env, LS_ROOT: dir, LS_SELFTEST: '1' }, maxBuffer: 1 << 26 });
    return { code: 0, hits: [] };
  } catch (e) {
    const out = (e.stdout || '') + (e.stderr || '');
    const hits = [...new Set([...out.matchAll(/^(?:FAIL|SKIP)\s+(MG\d|G\d+[a-z]?)/gm)].map((m) => m[1]))];
    return { code: e.status || 1, hits, out };
  }
};

/* 跑一次 measure（同上，只換根目錄；URLBASE 仍然指向真的 server）——
   這一發驗的是「三方對帳會不會當場停下來」。 */
const runMeasure = (dir) => {
  try {
    execFileSync(process.execPath, [join(HERE, 'measure.mjs')],
      { encoding: 'utf8', env: { ...process.env, LS_ROOT: dir }, stdio: 'pipe' });
    return { code: 0, hits: [] };
  } catch (e) {
    return { code: e.status || 1, hits: ['measure'], out: (e.stdout || '') + (e.stderr || '') };
  }
};

/* ── 壞樣本表：每一發都寫「它模擬的是哪一種真實的漏法」 ── */
const SAMPLES = [
  {
    id: 'M1b-任意值豁免', gate: 'MG2', run: runVerify,
    why: '第 4 輪原版：在任何元素上加 data-light="隨便什麼值" 就能整個豁免 G24，而且沒有任何一份清單記得誰被豁免。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { m.exemptSeen.push({ file: 'Main', marker: 'data-light', role: 'whatever' }); }),
  },
  {
    id: 'M1b-豁免不生效也要留痕', gate: 'MG2', run: runVerify,
    why: 'probe 拒絕了一個沒登記的豁免 —— 拒絕本身也必須讓管線紅，否則「悄悄不生效」與「沒有人加過」長得一樣。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { m.exemptBad = ['Main:data-light="whatever" 不在具名清單上 —— 豁免不生效']; }),
  },
  {
    id: 'M1b-登記了卻沒用到', gate: 'MG2', run: runVerify,
    why: '死掉的豁免也是漏洞：清單上留著一筆沒人用的豁免，下一個人就會把它當成「可以用」。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { m.exemptSeen = m.exemptSeen.filter((e) => e.marker !== 'data-sys'); }),
  },
  {
    id: 'M2b-偷改驗收排的繪製尺寸', gate: 'G26c', run: runVerify,
    why: '第 4 輪原版：G26 驗 path 與 viewBox（畫的是不是同一份幾何），不驗「畫多大」—— 驗收排上把一顆偷偷畫大，全綠。',
    /* 第 6 輪：它指名的那一族在 AppIcon 板上暫停了（使用者否決字形 icon 概念），
       所以這一發現在**必然**是綠的 —— 留著它會讓 MG3 因為一個已知的理由而紅，
       對照就失去分辨力。**不刪掉**：刪掉的樣本沒有人會記得要補回來。
       它跟著 G26 族一起停，恢復條件與登記簿那一筆同一句話。 */
    suspended: 'G26 族在 AppIcon 板上暫停（EXEMPT 的 data-veto=icon-concept）。恢復條件＝外部 icon 素材到位、AppIcon 板重做、那一筆豁免被刪掉。',
    mutate: (d) => edit(d, 'AppIcon.dc.html', (s) => s.replace('data-icon-acc="20" style="width:20px;height:20px', 'data-icon-acc="20" style="width:28px;height:28px')),
  },
  {
    id: '深色 ON 母體缺格', gate: 'MG1', run: runVerify,
    why: '第 4 輪原版：G19b 量了四張板的開關，可是「深色 × ON」整格是空的，gate 照樣印 PASS。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { m.knobs = m.knobs.filter((k) => !(k.on && /Dark/.test(k.file))); }),
  },
  {
    id: '深色照片不變暗', gate: 'G31', run: runVerify,
    why: '第 4 輪原版：深色版與淺色版的照片逐像素平均差 ΔRGB −2.6 —— 整個世界都暗了，只有照片沒有。',
    mutate: (d) => editJson(d, 'measured.json', (m) => {
      m.photo.meanRatio = 0.99; m.photo.p99Ratio = 0.99;
      m.photoPix = m.photoPix.map((r) => ({ ...r, filter: 'none' }));
    }),
  },
  {
    id: '刻度回到「兩端」版', gate: 'G29', run: runVerify,
    why: '第 4 輪原版：未用格永遠畫 stub3、用掉的格永遠畫 stub0 —— 五個狀態裡三個逐格 ΔE=0。',
    mutate: (d) => editJson(d, 'measured.json', (m) => {
      const three = m.scale.find((r) => r.uses === '3');
      for (const r of m.scale) r.cells = r.cells.map((c, i) => (c.state === 'left' ? { ...c, bg: three.cells[i].bg } : c));
    }),
  },
  {
    id: '銷記被拿掉', gate: 'G29', run: runVerify,
    why: '刻度只剩顏色差（褪色階本來就是邊緣加權的，相鄰兩階的色差很小）—— 遮住文字就讀不出剩幾次。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { for (const r of m.scale) r.cells = r.cells.map((c) => ({ ...c, ink: null })); }),
  },
  {
    id: '齒距沒跟著 AX 長大', gate: 'G27', run: runVerify,
    why: '紙變大、紙上的齒沒變大 —— 那就表示它又變回一張貼上去的圖樣，不是這張紙自己的形狀。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { for (const r of m.perf) if (/AX/.test(r.file)) r.pitch = 18; }),
  },
  {
    id: '騎縫線改回畫上去的線', gate: 'G27', run: runVerify,
    why: '第 4 輪原版：1px 高的橫向 repeating 漸層。撕了不會有東西分開，AX5 下也不變大。',
    mutate: (d) => edit(d, 'InviteReady.dc.html', (s) => s.replace('background:linear-gradient', 'background:repeating-linear-gradient')),
  },
  {
    id: '一張板只剩一種區塊寬度', gate: 'G28', run: runVerify,
    why: '第 4 輪原版：156 個區塊只有 6 種寬度、72% 是同一個 342px —— 材質做滿、空間沒做。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { m.widths.Email = { list: [342], kinds: 1, n: 4 }; }),
  },
  {
    id: 'AX5 兩顆鍵都只剩「登入」而且折行', gate: 'G32', run: runVerify,
    why: '第 4 輪原版：等高達標但語意塌；折行則是這一輪新加的下界。',
    mutate: (d) => editJson(d, 'measured.json', (m) => { m.brandLab = m.brandLab.map((b) => ({ ...b, title: 'short', text: '登入', lines: 2 })); }),
  },
  {
    id: '換了字樣卻沒改宣告', gate: 'G33', run: runVerify,
    why: '字標換成外部素材之後多了一段以前沒有的距離：那串 37KB 的 path 憑什麼說它出自那張蠟筆？這一發換掉來源圖的內容而不動 ink.mjs 的宣告 —— 沒有 G33 的話，畫面與宣告都沒有人會叫。',
    mutate: (d) => edit(d, 'mengya-crayon-alpha.png', (s) => `${s}\n`),
  },
  {
    id: '手改字標的一個座標', gate: 'G33', run: runVerify,
    why: '描摹出來的 path 是 40 條輪廓、幾千個座標，手改一個沒有人看得出來。板上畫的必須逐字元等於 ink.mjs 那一份（與 G26「板上畫的就是被量的那一份」同一招）。',
    mutate: (d) => edit(d, 'Main.dc.html', (s) => s.replace('data-ink="brush" style="display:block;flex:none"><path d="M', 'data-ink="brush" style="display:block;flex:none"><path d="M1')),
  },
  /* ── 門檻洗白重放（reviewer 第 5 輪 D5-02 的原始突變）────────────────────
     這一發不弄壞任何證據 —— 它只把 tokens.mjs 裡的 AAA 從 7 改成 4.5。
     第 5 輪這一招讓 144 項全綠、selftest 14 發全部照常轉紅：門檻本身沒有任何人在守。
     現在 MG4① 讀的是**產物根目錄的原始碼文字**（不是 gate 自己 import 的那一份），
     所以複本裡被洗白的那一行會與登記簿對不上，當場咬 MG4。 */
  {
    id: '門檻洗白－AAA 7→4.5（reviewer 重放）', gate: 'MG4', run: runVerify,
    why: '第 5 輪的原始突變：一行改動把 AAA 洗成 AA，全綠。門檻沒有出處、沒有登記、沒有人比對 —— 這正是 MG4 存在的理由。',
    mutate: (d) => edit(d, 'tokens.mjs', (s) => s.replace('export const CONTRAST = { aaa: 7, grain: 6 };', 'export const CONTRAST = { aaa: 4.5, grain: 6 };')),
  },
  {
    id: '門檻洗白－HIG 的 44 改成 40', gate: 'MG4', run: runVerify,
    why: '同一招換一條門檻：命中盒從 HIG 的 44 洗成 40。登記簿記著它出自 HIG，所以改掉它等於親手刪掉那句引用。',
    mutate: (d) => edit(d, 'tokens.mjs', (s) => s.replace('tap: 44 }', 'tap: 40 }')),
  },
  {
    id: '門檻洗白－推導式改回手寫字面值', gate: 'MG4', run: runVerify,
    why: '把 SCALE_DE 從推導式改回三個手寫的數（值一模一樣，全綠）。推導式的門檻沒有自由度，寫回字面值就把自由度放回來了 —— MG4③ 咬的是這件事，不是那三個數。',
    mutate: (d) => edit(d, 'tokens.mjs', (s) => s.replace('export const SCALE_DE = { adj: 3 * HUE_DE_MIN, ends: 6 * HUE_DE_MIN, band: 1 * HUE_DE_MIN };', 'export const SCALE_DE = { adj: 3, ends: 6, band: 1.0 };')),
  },
  {
    id: 'M8-三方對帳（指紋對不上）', gate: 'measure', run: runMeasure,
    why: '第 4 輪 reviewer 兩行改寫就讓三方對帳恆真。這一發把本地 _root.json 改掉，measure 必須當場停 —— 對帳若被改成恆真，它會若無其事地量下去。',
    mutate: (d) => editJson(d, '_root.json', (o) => { o.fp = 'deadbeef0000'; }),
  },
  {
    id: 'M8-三方對帳（磁碟與瀏覽器讀到的不同）', gate: 'measure', run: runMeasure,
    why: '板名、尺寸、_root.json 全部一樣，只有內容差一個字元 —— 這正是第 2 輪那台殘留 server 的形狀。',
    mutate: (d) => edit(d, 'Notes.dc.html', (s) => s.replace('實作註記', '實作註記 ')),
  },
];

/* 邊界樣本（bands.mjs）併進來 —— 宣告在那裡、結果寫在 selftest.json，
   verify 的 MG4②a 讀的是宣告，MG3③ 讀的是結果。分開才不會雞生蛋。 */
for (const b of BANDS) {
  SAMPLES.push({
    id: b.id, gate: b.gate, why: b.why, band: { of: b.of, v: b.v },
    mutate: (d) => b.mutate(d, b.v, { edit, editJson }),
    run: runVerify,
  });
}

/* ── 跑 ── */
const base = stage();
const baseline = runVerify(base);
if (baseline.code !== 0) {
  console.error('selftest: **baseline 就不是綠的** —— 對照實驗沒有意義，先讓管線全綠再跑。');
  console.error((baseline.out || '').split('\n').filter((l) => /^FAIL|^SKIP/.test(l)).slice(0, 8).join('\n'));
  rmSync(base, { recursive: true, force: true });
  process.exit(1);
}
console.log(`selftest: baseline 全綠（gate 程式 #${codeFp}）—— 開始餵 ${SAMPLES.length} 發壞樣本`);

const out = [];
for (const smp of SAMPLES) {
  /* 暫停中的樣本不跑，但**留在表上**（帶著理由寫進 selftest.json，MG3 會驗那個理由
     真的對應到一筆具名豁免）。刪掉的樣本沒有人會記得要補回來。 */
  if (smp.suspended) {
    out.push({ id: smp.id, gate: smp.gate, why: smp.why, suspended: smp.suspended, red: null, hits: [], hitExpected: null });
    console.log(`  暫停 －  ${smp.id} → ${smp.gate}（${smp.suspended.slice(0, 28)}…）`);
    continue;
  }
  const dir = mkdtempSync(join(tmpdir(), 'ls38d-case-'));
  cpSync(base, dir, { recursive: true });
  /* band 一併傳進去 —— 邊界樣本寫進 measured.json 的值，就是它登記給 MG4 檢查的值。
     同一個數用兩次，所以 band.v 不可能是一個誰都可以填的宣稱。 */
  smp.mutate(dir, smp.band);
  const r = smp.run(dir);
  const red = r.code !== 0;
  const hitExpected = smp.gate === 'measure' ? red : r.hits.includes(smp.gate);
  out.push({ id: smp.id, gate: smp.gate, why: smp.why, band: smp.band || null, red, hits: r.hits, hitExpected });
  console.log(`  ${red ? (hitExpected ? '轉紅 ✓' : '轉紅但咬錯 ✗') : '**全綠 ✗**'}  ${smp.id} → 期望 ${smp.gate}${red && r.hits.length ? `，實際 ${r.hits.join('/')}` : ''}`);
  rmSync(dir, { recursive: true, force: true });
}
rmSync(base, { recursive: true, force: true });

const bad = out.filter((x) => !x.suspended && (!x.red || !x.hitExpected));
writeFileSync(new URL('selftest.json', import.meta.url),
  `${JSON.stringify({ codeFp, when: new Date().toISOString().slice(0, 10), samples: out }, null, 2)}\n`);
console.log(`selftest: ${out.length} 發（暫停 ${out.filter((x) => x.suspended).length}），${out.filter((x) => x.red && x.hitExpected).length} 發咬到指名的那一條`);
if (bad.length) {
  console.error(`selftest: **${bad.length} 發沒有咬到** —— 那幾條 gate 現在沒有牙：${bad.map((x) => x.id).join('、')}`);
  process.exit(1);
}
