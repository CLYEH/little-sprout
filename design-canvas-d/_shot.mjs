// 逐板截圖，並且證明截到的就是整張板。
//
// 第 2 輪有 4 張截圖底部像是被裁掉 —— 查出來的原因：headless Chrome 的
// --window-size 是「視窗」不是「視區」，視區比它矮 87px（也有 500px 的最小寬）。
// 截圖卻是照視窗大小出圖，所以最後 87px 是合成器補的底色，不是板的內容。
// 這一版：① 開機先量出視窗與視區的差 ② 視窗開高，再把 PNG 的列裁回板高
//          ③ 讀 PNG 檔頭確認像素尺寸 ④ 把「板的最後 40px」單獨重渲染一次，
//             跟截圖的最後 40 列逐像素比對 —— 一致才算截到底。
// Run: node _shot.mjs   （需要本機 http server：python3 -m http.server 8741）
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { inflateSync, deflateSync, crc32 } from 'node:zlib';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
/* 第 1 輪 R9 說的是 measure.mjs 的預設埠指向軌 B —— 但同一個洞在這裡也有一份，
   而且更危險：截圖是要送給人看的東西。同樣兩道：埠改本軌的 8741，
   而且開跑前拿 server 上的 _root.json 與本地比對，不一致就 exit 1。 */
const URLBASE = process.env.LS_URL || 'http://localhost:8741';
const here = (f) => new URL(f, import.meta.url);
const localRoot = existsSync(here('_root.json')) ? JSON.parse(readFileSync(here('_root.json'), 'utf8')) : null;
if (!localRoot) { console.error('_shot: 找不到 _root.json —— 先跑 node build.mjs'); process.exit(1); }
const servedRoot = await fetch(`${URLBASE}/_root.json`).then((r) => (r.ok ? r.json() : null)).catch(() => null);
if (!servedRoot) { console.error(`_shot: ${URLBASE}/_root.json 抓不到 —— server 沒開，或根目錄不是這一軌。`); process.exit(1); }
if (servedRoot.track !== localRoot.track || servedRoot.fp !== localRoot.fp) {
  console.error(`_shot: ${URLBASE} 服務的是 ${servedRoot.track} #${servedRoot.fp}，本地是 ${localRoot.track} #${localRoot.fp} —— 截下去會是別軌的畫面，停在這裡。`);
  process.exit(1);
}
const cv = JSON.parse(readFileSync(here('canvas.json')));
const TAIL = 40;

/* ── PNG：只裁列。保留前 n 列的話濾波器鏈仍然自洽，不必重算 ── */
const cropRows = (file, keep) => {
  const b = readFileSync(file);
  let p = 8, ihdr = null; const idat = [];
  while (p < b.length) {
    const len = b.readUInt32BE(p), type = b.toString('ascii', p + 4, p + 8), data = b.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') ihdr = Buffer.from(data);
    if (type === 'IDAT') idat.push(data);
    p += 12 + len;
  }
  const w = ihdr.readUInt32BE(0), h = ihdr.readUInt32BE(4), depth = ihdr[8], ct = ihdr[9];
  if (h === keep) return [w, h];
  if (depth !== 8 || ihdr[12] !== 0) throw new Error(`不支援的 PNG（depth ${depth} interlace ${ihdr[12]}）`);
  const bpp = { 0: 1, 2: 3, 4: 2, 6: 4 }[ct];
  const raw = inflateSync(Buffer.concat(idat));
  const stride = 1 + w * bpp;
  const cut = raw.subarray(0, keep * stride);
  ihdr.writeUInt32BE(keep, 4);
  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); data.copy(out, 8);
    out.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), data])) >>> 0, 8 + data.length);
    return out;
  };
  writeFileSync(file, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(cut, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ]));
  return [w, keep];
};

/* ── 量視窗與視區的差（不同 Chrome 版本不一樣，所以每次量）── */
writeFileSync(here('_vp.html'), '<!doctype html><meta charset="utf-8"><body style="margin:0"><div id="o"></div><script>o.textContent="VP "+innerWidth+"x"+innerHeight</script></body>');
const probeWin = [800, 600];
const vpDump = execFileSync(CHROME, ['--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
  '--force-device-scale-factor=1', `--window-size=${probeWin}`, '--dump-dom', `${URLBASE}/_vp.html`],
{ encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
const vg = /VP (\d+)x(\d+)/.exec(vpDump);
if (!vg) { console.error('_shot: 量不到視區 —— http server 有開嗎？'); process.exit(1); }
const CH = probeWin[1] - +vg[2];
console.log(`視窗 → 視區：高度差 ${CH}px（截圖視窗要多開這麼多，再把列裁回來）`);

mkdirSync(here('shots'), { recursive: true });
for (const f of readdirSync(here('.'))) if (/^_(s|b)_.*\.html$/.test(f)) rmSync(here(f));

const strip = (src) => src.slice(src.indexOf('<x-dc>'), src.indexOf('</x-dc>') + 7).replace('<helmet>', '<helmet style="display:block">');
const page = (body) => `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;overflow:hidden}x-dc{display:block}helmet{display:none}</style>${body}`;

for (const a of cv.artboards) {
  const body = strip(readFileSync(here(a.file), 'utf8'));
  const name = a.file.replace('.dc.html', '');
  writeFileSync(here(`_s_${name}.html`), page(body));
  writeFileSync(here(`_b_${name}.html`), page(`<div style="height:${TAIL}px;overflow:hidden"><div style="margin-top:-${a.h - TAIL}px">${body}</div></div>`));
}

const shoot = (url, out, w, h) => {
  execFileSync(CHROME, ['--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
    '--force-device-scale-factor=1', '--virtual-time-budget=8000',
    `--window-size=${w},${h + CH}`, `--screenshot=${out}`, url], { stdio: ['ignore', 'ignore', 'ignore'] });
  return cropRows(out, h);
};

const sizeBad = [];
for (const a of cv.artboards) {
  const name = a.file.replace('.dc.html', '');
  const full = here(`shots/${name}.png`).pathname, tail = here(`shots/_tail_${name}.png`).pathname;
  const [fw, fh] = shoot(`${URLBASE}/_s_${name}.html`, full, a.w, a.h);
  const [tw, th] = shoot(`${URLBASE}/_b_${name}.html`, tail, a.w, TAIL);
  if (fw !== a.w || fh !== a.h) sizeBad.push(`${name} ${fw}x${fh}≠${a.w}x${a.h}`);
  if (tw !== a.w || th !== TAIL) sizeBad.push(`${name}/tail ${tw}x${th}`);
}

/* ── 底部 40px：截圖的最後 40 列 vs 單獨重渲染的那 40px，用瀏覽器當解碼器逐像素比 ── */
const names = cv.artboards.map((a) => a.file.replace('.dc.html', ''));
writeFileSync(here('_shotcheck.html'), `<!doctype html><meta charset="utf-8"><body style="margin:0;font:12px monospace">
<div id="out" style="white-space:pre;padding:8px"></div><script>
(async()=>{
 const names=${JSON.stringify(names)}, TAIL=${TAIL}, out=[];
 const load=(u)=>new Promise((r,j)=>{const i=new Image();i.onload=()=>r(i);i.onerror=()=>j(u);i.src=u;});
 for(const n of names){
  const [a,b]=await Promise.all([load('shots/'+n+'.png'),load('shots/_tail_'+n+'.png')]);
  const w=b.width,c=document.createElement('canvas');c.width=w;c.height=TAIL*2;
  const x=c.getContext('2d',{willReadFrequently:true});
  x.drawImage(a,0,a.height-TAIL,w,TAIL,0,0,w,TAIL);
  x.drawImage(b,0,0,w,TAIL,0,TAIL,w,TAIL);
  const d=x.getImageData(0,0,w,TAIL*2).data;
  let max=0,off=0,px=w*TAIL*4;
  for(let i=0;i<px;i+=4){
    for(let k=0;k<3;k++){const dv=Math.abs(d[i+k]-d[px+i+k]); if(dv>max)max=dv; if(dv>8){off++;break;}}
  }
  out.push(n+' maxDiff '+max+' offPx '+off+'/'+(w*TAIL));
 }
 document.getElementById('out').textContent='RES>>'+JSON.stringify(out)+'<<RES';
})();
</script></body>`);

const dump = execFileSync(CHROME, ['--headless', '--disable-gpu', '--no-sandbox',
  '--virtual-time-budget=60000', '--dump-dom', `${URLBASE}/_shotcheck.html`],
{ encoding: 'utf8', maxBuffer: 1 << 26, stdio: ['ignore', 'pipe', 'ignore'] });
const m = /RES&gt;&gt;([\s\S]*?)&lt;&lt;RES|RES>>([\s\S]*?)<<RES/.exec(dump);
if (!m) { console.error('_shot: 比對不到'); process.exit(1); }
const rows = JSON.parse((m[1] || m[2]).replace(/&quot;/g, '"').replace(/&amp;/g, '&'));

let maxDiff = 0; const tailBad = [];
for (const r of rows) {
  const g = /^(\S+) maxDiff (\d+) offPx (\d+)\/(\d+)/.exec(r);
  maxDiff = Math.max(maxDiff, +g[2]);
  if (+g[3] / +g[4] > 0.005) tailBad.push(`${g[1]} ${g[3]}/${g[4]}`);
}

const MJ = here('measured.json');
const M = existsSync(MJ) ? JSON.parse(readFileSync(MJ, 'utf8')) : {};
M.shot = { n: cv.artboards.length, chromeH: CH, sizeBad, tailBad, maxDiff, rows };
writeFileSync(MJ, JSON.stringify(M, null, 2));

rmSync(here('_vp.html'));
for (const f of readdirSync(here('.'))) if (/^_(s|b)_.*\.html$/.test(f)) rmSync(here(f));
if (!process.env.LS_KEEP) for (const f of readdirSync(here('shots'))) if (/^_tail_/.test(f)) rmSync(here(`shots/${f}`));

console.log(`shot ${cv.artboards.length} boards → shots/  · 尺寸不符 ${sizeBad.length} · 底部 40px 不一致 ${tailBad.length}（最大像素差 ${maxDiff}）`);
if (sizeBad.length) console.log('  ' + sizeBad.join(' '));
if (tailBad.length) console.log('  ' + tailBad.join(' '));
