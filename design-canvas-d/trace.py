#!/usr/bin/env python3
"""蠟筆字樣「萌芽」→ 向量（第 6 輪；使用者定案：字標筆觸＝蠟筆）。

第 1–5 輪的字標是 brush.mjs 程式生成的貝茲筆跡。使用者的判決是「很醜」——
那是 glyph 品質層的否決，不是規則層的問題，所以換的是**字樣本身**不是規則：
外部生成的蠟筆手寫「萌芽」（透明背景 PNG）描成向量，規則（材質標記、aria 包法、
跨板縫合、G15/G26 的每一條）逐條留著。

這一支是那個描摹的**配方**，不是一次性的手工。它的輸出 ink.mjs 記著來源檔的
SHA-256 與這裡的每一個參數，G33 會回頭比對磁碟上的 PNG —— 所以「這份路徑資料
真的出自那張蠟筆」是可以被程式驗的，不是一句話。

三個講究（每一個都是被字的用途逼出來的，不是好看）：
  · **顆粒留著**。蠟筆壓在紙上會崩邊，那是這支字唯一抄不走的東西。
    DP 的 ε 取 1.0 原圖像素（原圖 1787px 寬）：140px 的 iPad 字標上崩邊仍然看得見，
    ε 抬到 2.2 以上就開始像麥克筆。代價是 path 變大 —— 見下面的預算。
  · **小洞填掉、大洞留著**。蠟筆沒吃到紙的地方會留白點；那些白點在 26pt 的信件
    明細上是雜訊，在 20pt 的圖示上會直接吃掉墨覆蓋率。所以面積 < HOLE 的內部
    白點填實，「日」「月」「牙」真正的反白（遠大於它）原封不動。
  · **只出字標，不出落款印**。第 6 輪原本的計畫是順手把「芽」那半邊裁出來換掉 app icon
    的落款印（同一隻手）；使用者於 2026-08-23 否決了「app icon ＝ 一個字」這個概念本身
    ——不是筆觸問題，是字形 icon 這件事——外部 icon 素材另外生成中。所以這裡**刻意不輸出**
    那份裁切資料：留著沒人用的匯出就是死碼。要的時候把 split 那幾行接回來即可（見 main()）。

Run: python3 trace.py   （需要 numpy / opencv-python / Pillow；輸出 ink.mjs）
"""
import hashlib
import json
import os

import cv2
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'mengya-crayon-alpha.png')
OUT = os.path.join(HERE, 'ink.mjs')

ALPHA_T = 110   # 二值化門檻（alpha 0–255）。蠟筆的邊是軟的，這個值落在崩邊的中段。
SPECK = 90      # 小於這個面積（原圖 px²）的孤立碎屑丟掉 —— 掃描雜訊，不是筆跡。
HOLE = 900      # 小於這個面積的內部白點填掉；真反白（日／月／牙）比它大兩個數量級。
EPS = 1.0       # Douglas-Peucker 容差（原圖 px）。顆粒的存廢就在這個數上。
UNIT = 193.0    # 字身單位：兩字並排的總寬 ＝ 193（沿用貝茲版的座標語彙：兩字各 100、字距 93）
DEC = 1         # 座標小數位。1 位在 193 個單位上 ＝ 0.05% —— 遠小於一個裝置像素。


def mask():
    a = np.array(Image.open(SRC).convert('RGBA'))[:, :, 3]
    m = (a >= ALPHA_T).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(m, 8)
    keep = np.zeros_like(m)
    for i in range(1, n):
        if st[i, cv2.CC_STAT_AREA] >= SPECK:
            keep[lab == i] = 1
    n2, lab2, st2, _ = cv2.connectedComponentsWithStats(1 - keep, 8)
    out = keep.copy()
    for i in range(1, n2):
        touches = (st2[i, cv2.CC_STAT_LEFT] == 0 or st2[i, cv2.CC_STAT_TOP] == 0
                   or st2[i, cv2.CC_STAT_LEFT] + st2[i, cv2.CC_STAT_WIDTH] >= m.shape[1]
                   or st2[i, cv2.CC_STAT_TOP] + st2[i, cv2.CC_STAT_HEIGHT] >= m.shape[0])
        if not touches and st2[i, cv2.CC_STAT_AREA] < HOLE:
            out[lab2 == i] = 1
    return out


def trace(m):
    cs, _ = cv2.findContours(m, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    out = []
    for c in cs:
        p = cv2.approxPolyDP(c, EPS, True).reshape(-1, 2).astype(float)
        if len(p) >= 3:
            out.append(p)
    return out


def emit(polys, k, ox, oy):
    """輪廓 → path d。fill-rule 用 evenodd（洞與外框都是同一批多邊形，
       瀏覽器與 icon.mjs 的掃描線光柵器因此判得一模一樣）。"""
    parts = []
    for p in polys:
        q = (p - [ox, oy]) * k
        s = f'M{q[0][0]:.{DEC}f} {q[0][1]:.{DEC}f}'
        for r in q[1:]:
            s += f'L{r[0]:.{DEC}f} {r[1]:.{DEC}f}'
        parts.append(s + 'Z')
    return ''.join(parts)


def bbox(polys):
    a = np.vstack(polys)
    return a[:, 0].min(), a[:, 1].min(), a[:, 0].max(), a[:, 1].max()


def main():
    m = mask()
    polys = trace(m)
    x0, y0, x1, y1 = bbox(polys)
    k = UNIT / (x1 - x0)
    lock_d = emit(polys, k, x0, y0)

    # 落款印的裁切（本輪未輸出，見檔頭）：兩字之間 bbox 內最寬的那一段全空直欄的中點
    # 就是取字界線 —— split = mid(最長的 col.sum()==0 區段)，右邊那幾條輪廓即「芽」。

    sha = hashlib.sha256(open(SRC, 'rb').read()).hexdigest()
    im = Image.open(SRC)
    js = f'''/* ── 蠟筆字樣「萌芽」的向量資料（第 6 輪；**這個檔是 trace.py 產生的，不要手改**）──
   使用者定案：字標筆觸＝蠟筆。第 1–5 輪程式生成的貝茲筆跡被判「很醜」，
   換掉的是字樣本身；規則（材質標記 data-ink、aria 包法、跨板縫合、字距與版位）逐條留著。

   LOCKUP  兩字並排的輪廓，座標系＝字身單位（總寬 {UNIT}，沿用貝茲版的語彙）。
           兩字的相對位置、下沉與參差不是我們排的 —— 是寫的人自己那樣寫的。

   洞與外框在同一個 d 裡，靠 fill-rule="evenodd" 分 —— 描摹器輸出的外框與洞方向不保證，
   nonzero 會把洞填實；evenodd 只看穿越次數，所以「哪裡是墨」不依賴輪廓方向。

   SRC 記著來源 PNG 的 SHA-256，TRACE 記著描摹的每一個參數 —— G33 回頭雜湊磁碟上那張圖
   比對，所以「這份路徑真的出自那張蠟筆」是驗得出來的，不是一句話。 */
export const SRC = {{
  file: 'mengya-crayon-alpha.png',
  sha256: '{sha}',
  w: {im.size[0]}, h: {im.size[1]},
}};
export const TRACE = {{ alphaT: {ALPHA_T}, speck: {SPECK}, hole: {HOLE}, eps: {EPS}, unit: {UNIT}, dec: {DEC} }};
export const FILL_RULE = 'evenodd';

export const LOCKUP = {{
  n: {len(polys)},
  vb: {{ x: 0, y: 0, w: {round(UNIT, 2)}, h: {round((y1 - y0) * k, 2)} }},
  d: '{lock_d}',
}};
'''
    open(OUT, 'w').write(js)
    print(json.dumps({
        'contours': len(polys),
        'lockupBytes': len(lock_d),
        'lockupVb': [UNIT, round((y1 - y0) * k, 2)],
        'sha256': sha[:16],
    }, indent=1))


if __name__ == '__main__':
    main()
