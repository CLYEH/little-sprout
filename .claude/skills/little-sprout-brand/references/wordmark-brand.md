# 字標與品牌

使用者定案（2026-08-23／24／25）＋LS-46 R9–R11 落地。素材與稿：`design/mengya-diary-crayon-v3.png`（1860×887）、`design/app-icon-photo-stack.png`（1024）、`design/littlesprout.pen` Brand 板與 01 家族。

## 名稱

- 中文產品名＝**「萌芽日記」**（使用者定案 2026-08-23；英文 Little Sprout 不變）。使用者可見的「小芽」一律改「萌芽日記」；內部 token 命名（sprout／芽綠）不改。
- 字標 lockup＝**四字等大**（C 軌比例）＋**蠟筆筆觸**（D 軌筆觸）。「萌芽為主、日記為輔」的 3:1 結構被使用者推翻；毛筆批素材全數作廢。

## 字標本體（蠟筆版 v3）

- 真重畫、非拉伸：四字高差 0.0%、寬度與原稿全異、筆寬比 0.886–0.973、覆蓋率極差 7.63pp（LS-46 R2 驗收；R1 抓到的 `-equal.png` 是縱拉 1.456× 的假貨，已刪）。字間距不得單調遞減（像寫到沒地方）。
- 素材驗收必含**手法證據**（與來源的差異度、IoU、筆寬比、色彩數），不只量結果——Codex 兩次交假貨都通過了「只量結果」的驗收。
- 淺墨版兩主題通用一份素材，**不另出深色資產**（`mengya-diary-crayon-v3-dark.png` 已於 R7 刪除；R10 起字標坐在 `$print-paper` 紙上，對比 18.2:1／15.3:1）。

## B 版式（使用者定案 2026-08-25：字標留標題列放大、相片縮）

| 板 | 字標尺寸 | tagline | Head 內容 |
|---|---|---|---|
| 01／01b／AX3（iPhone） | **190×90.6pt**，標題列 | 「給家人的私密相簿」`$fs-body` 17 `$text-secondary`，字標→tagline `$sp-label` 8 | 字標＋tagline＋信任列 |
| 01-iPad | 247×118pt（1.3×，長寬比 2.09 守住） | `$fs-body` 17（不是 display——字標當標題、副標退位，iPad 也要退） | 同上 |
| 01c 深色 | 190×90.6pt，**不進 Head** | `$print-ink-secondary`＋`textAlign:center`（紙上的墨） | **Head 只剩信任列 25pt** |

- 深色紙條（設計例外，唯一）：與相片同寬 361 的 `$print-paper` 紙條貼 Print Stage 上緣，字標＋tagline 坐其上；高 136.6＝padTop 4＋字標 90.6＋8＋tagline 26＋padBottom 8，零餘數；上兩顆角托壓在紙條與相紙接縫（釘住＝同一疊沖印品的標題紙，不是貼上去的卡）。紙條 fill 單一 `$print-paper`、**無暗角漸層**。板高 852 無特例。
- 為什麼不是底板：把手繪墨跡裝進框裡讀起來是貼紙；也解不了同一張紙上的其他文字（1.11–1.46:1）。正解是墨色單值 token，不是資產。
- A′ 版式（字標在相片白邊 200pt）留存於 `XUAAQ`「未採用・A′ 對照存檔」，不是規格板。

## a11y

- 字標 image 節點帶 metadata：`accessibilityLabel:"萌芽日記"`／`exemptDynamicType:true`／`role:"image"`；SwiftUI `Image(...).accessibilityLabel("萌芽日記")`＋`.accessibilityAddTraits(.isHeader)`。
- 字標不吃 Dynamic Type（AX3 板實證 190pt 固定、與 tagline 保持 8pt 不擠壓）——因為系統文字換成點陣圖是可及性倒退，所以 tagline／信任列必須是系統文字且隨字級長。
- Lab Imprint「LITTLE SPROUT」標 `.accessibilityHidden(true)` 或併進相片 alt 尾段（「…（相紙邊緣印著 LITTLE SPROUT）」），否則 VoiceOver 會把同一品牌名念兩種語言。

## 「LITTLE SPROUT」小字（眉標退場規則，`S1FuR`）

- **唯一出現地**：歡迎頁家族（01／01b／01c／01-iPad／AX3／F16 壓測板）相片白邊 Imprint Row。其他任何 UI 不得再出現英文名；橫式鎖版與 App Store 素材另計。
- 規格：`fs-imprint` 12／字距 3.5／`$print-ink-secondary`／**在白邊帶內水平置中**——印品帶四角暗角漸層，靠左會讓深色對比從 8.13 掉到 3.5 附近（Lab Imprint 置中在兩顆底角漸層半徑 0.432×361＝156pt 之外，取樣證實紙色 flat #E8D9D4）。
- 它是「印在紙上的字」：不吃 Dynamic Type、不承載唯一資訊。

## App icon

- 定案＝**photo-stack「累積」**（三張扇疊照片——日記會長大；LS-38 icon 第 5 輪 APPROVE 名單、第 4 輪唯一 KEEP／家族基準款）。素材 `design/app-icon-photo-stack.png` 1024；出貨時依 iOS 27 Icon Composer 官方 template 分層（深色／Tinted 外觀）。
- **icon 不可用「芽」字**（使用者裁決 2026-08-23：否決的是「icon＝字」，非筆觸）；Tokens 板 ⑥ 的「芽」icon 樣本只是歷史記錄，glyph 已改 `$print-ink`（紙上的墨規則）。
- 角托規則第②段：icon 實機 ≤60pt 用兩對角托（四顆在 60pt 會糊成一圈邊）；判準是實機尺寸不是稿面尺寸。
- 與字標的關係：「同一支蠟筆的兩種用法」——字標在描（線）、icon 在塗（面）。素材產線驗收要能證明真顏料（unique RGB ≥20k、grain ≥1.5），6 色點陣冒充炭筆曾被抓包。
- `design/*.png` 相片是設計佔位圖（1024×1536、2–2.6MB），**不是出貨資產**；只有 `app-icon-photo-stack.png` 尺寸本身正確可直接當 App Store icon。

## 登入鍵（品牌鍵）

- 順序固定：**Apple → Google → Email**（使用者定案）；層級靠形（實心／外框）不靠色。
- Apple 用官方 Sign in with Apple 標誌／`SignInWithAppleButton`，Google 用官方按鈕資產與 G 標——**不得用第三方仿繪（`phosphor/apple-logo-fill` 曾誤用）、色值不得改、品牌鍵不接光（不套窗光或任何漸層）**。
- 歡迎頁最強的兩個元素不能是別人的品牌：用自家裝置（沖印品／台紙）框住廠商的鍵，而不是把它們的鍵加大。
