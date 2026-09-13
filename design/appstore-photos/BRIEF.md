# LS-247 生圖 Brief — App Store 海報六板 Hero Photo

A 段產出。本檔只寫生圖規格，不含任何 `.pen` 編輯；B 段（置換、裁切重算、收據、VR）依第 7 節計畫另派。

## 0. 現況量測（獨立於票文敘述，直接讀 `design/littlesprout.pen` JSON 核實）

六個 Hero Photo 節點與其容器鏈（父→子）：

| 主題 | 裝置 | 板（root frame） | Print 容器 | Photo Wrap（顯示區，clip:true） | Hero Photo 節點 |
|---|---|---|---|---|---|
| hero（阿嬤與孫子） | iPhone | `c2yk3s`「01 時間軸」 | `s1Kzm`→`FKjPv` | `XkEUh` **690×380.2** | `scpdc`（現圖 690×1030，y=−168） |
| hero（阿嬤與孫子） | iPad | `Vn4TL`「01 時間軸」 | `N3mjp6`→`JyHDo` | `lBVso` **1079×594.5** | `ayJoy`（現圖 1079×1610.6，y=−262.7） |
| invite（邀請阿公阿嬤） | iPhone | `Bm7Lx`「03 邀請加入」 | `ay53J`→`kJVts` | `yY2YM` **690×380.2** | `F92jh`（現圖 690×1030，y=−168） |
| invite（邀請阿公阿嬤） | iPad | `BnjqP`「03 邀請加入」 | `ScEdE`→`DjJsT` | `V3mlZ` **1079×594.5** | `yzfCx`（現圖 1079×1610.6，y=−262.7） |
| join（爸媽一起） | iPhone | `ZRyXL`「04 日記詳情」 | `hUNFn`→`k4Tyqi` | `s0OmUy` **690×380.2** | `aD9EO`（現圖 690×1030，y=−168） |
| join（爸媽一起） | iPad | `b59DUk`「04 日記詳情」 | `D2juW`→`cNSP8` | `iWjMR` **1079×594.5** | `j5Bns`（現圖 1079×1610.6，y=−262.7） |

**關鍵發現**：iPhone 三板（01/03/04）Photo Wrap 完全同尺寸 690×380.2；iPad 三板同尺寸 1079×594.5。兩個尺寸的長寬比幾乎相同（690/380.2=1.8148、1079/594.5=1.8150）——**全部六個 Photo Wrap 只有一個目標長寬比**，不需要三題各自定義不同比例。現圖三張皆為直幅人像 1024×1536（比例 0.667），塞進橫幅顯示區時只能取中段一小塊、犧牲大半構圖（y 偏移 −168／−262.7 正是這個代價）——這就是票文說「690×1030 塞進 690×380」的來源，也是本 brief 要求改拍橫幅的原因。

板底色（App Store 板本身）＝`$bg` #EDD3D6；照片緊貼的白邊紙面（`$print-paper`）＝#FBEBEC——選圖判準 5 用後者。

## 1. 三題語意（對應現佔位圖敘事，不抄圖）

現有三張佔位圖分別是：hero-grandma（阿嬤側臉貼嬰兒臉頰、雙雙面向鏡頭）、invite-grandma（阿嬤側身低頭親吻嬰兒額頭、嬰兒伸手摸阿嬤下巴）、join-parents（爸媽額頭相貼、中間抱著新生兒）。三者都只是「app 截圖裡露出的示範照片內容」，不是要求畫面去演出「邀請」這個 UI 動作本身——沿用這個定位，只換掉直幅構圖為橫幅構圖、拍法更貼近真實家庭生活照。

### (a) hero —— 阿嬤與孫子的日常
- **畫面描述**：東亞阿嬤（55–70 歲）在家中日常空間裡抱著／陪著一名嬰兒或學步兒童，兩人肌膚相貼（臉頰對臉頰、額頭相貼、或十指相扣），視線可望向彼此或望向鏡頭外景深處，不擺拍式對鏡頭微笑。場景在客廳沙發／臥室床邊／餐桌旁，橫幅構圖讓阿嬤與孩子左右或斜對角分佈，留出自然背景景深。
- **情緒**：溫暖、安穩、日復一日的天倫之樂——不是「特別的一天」，是「任何一個普通午後」。
- **必有元素**：東亞面孔阿嬤（可見皺紋、白髮或灰白夾雜髮色，符合真實年齡質感）＋嬰兒／學步兒童；自然室內光（單一方向的窗光或暖黃燈光）；至少 3 項台灣家庭生活道具（見下方每則 prompt）。
- **禁止元素**：擺拍式正面燦笑看鏡頭、影棚打光、都市時尚感場景、任何 AI slop 特徵（見第 4 節）。

### (b) invite —— 邀請阿公阿嬤一起看
- **畫面描述**：阿嬤（或阿公，四個變體可混一位阿公版本增加素材多樣性）與嬰兒更貼近、更私密的互動片刻——側臉親吻額頭、嬰兒小手扶著阿嬤的臉或衣領、阿嬤閉眼享受這一刻。這類「特寫、慢動作感」的畫面適合放在「邀請長輩加入家庭圈」情境——暗示這正是那種「你會想讓阿公阿嬤也收到通知、也能點開看」的珍貴瞬間。
- **情緒**：珍惜、私密、跨世代連結——比 (a) 更聚焦兩人之間、背景更虛化。
- **必有元素**：東亞長輩（阿嬤或阿公）與嬰兒的親密接觸動作（親吻額頭／臉貼臉／額頭相貼）；室內自然光；背景可見 1–2 項暗示「這是長輩自己的家」的道具（老花眼鏡、藤椅、舊木櫃、窗邊盆栽等）。
- **禁止元素**：任何暗示長輩在「操作 3C 產品」或「看手機」的畫面（會偏題成產品示範照，不是家庭生活照）；擺拍式對鏡頭笑容；影棚打光。

### (c) join —— 爸媽一起
- **畫面描述**：一對年輕東亞父母（25–38 歲）與新生兒／小嬰兒的溫馨時刻——額頭隔著嬰兒相碰、雙手交疊護著嬰兒、或爸爸從後方環抱媽媽與嬰兒。臥室或客廳，柔軟寢具／沙發，橫幅構圖讓三人身形自然分佈在畫面左右。
- **情緒**：初為人父母的溫柔與慎重、兩人一起守護一個新生命。
- **必有元素**：可辨識性別的一男一女成年人（爸媽）＋嬰兒；三人同框且有肢體接觸（不是各自分開的兩張臉拼接感）；柔和窗光。
- **禁止元素**：任何一方臉部被遮擋到看不出是兩位不同的人；過度甜膩的婚紗照打光；影棚背景布。

## 2. 技術規格

- **目標長寬比**：**1.815:1**（橫幅，即 iPhone Photo Wrap 690:380.2 與 iPad Photo Wrap 1079:594.5 的共同比例；不必三題各自區分，六板共用同一比例）。近似值可讀作 11:6 或介於 16:9（1.778）與 3:1.65 之間；**寧可生成得比目標略寬／略高留裁切餘裕，也不要生成窄於 1.7:1 的畫面**（窄於此裁切會犧牲太多水平構圖）。
- **最小像素**：≥ **1079×594.5px**（iPad Photo Wrap 顯示尺寸本身，取六板中最大者；iPhone 690×380.2 已被 iPad 需求涵蓋，故以 iPad 為準——**R3 訂正**，VR R2 MJ-C：最終上架素材匯出一律 `scale:1`（Notes `WUjfA`：「板尺寸本身已等於目標像素，不可再乘 2x」；實測 App Store iPhone 6.9" 板 `c2yk3s` 等＝1320×2868px、iPad 13" 板 `Vn4TL` 等＝2064×2752px，正是 Apple 截圖規格的像素值本身），故 Photo Wrap 690／1079 已是成品像素、不需再乘 2；原版「2160×1190」把這個目標值算重複了 2 倍）。**建議值 ≥1200×661px 以上**（同比例，留裁切安全邊界，見下；此為建議留餘裕，非硬性下限）。
- **若生圖工具僅提供固定預設比例**（例如 1536×1024／1024×1536／1024×1024 三選一）：選最接近的橫幅選項（1536×1024，比例 1.5）並取最高可用解析度，構圖時**主體與關鍵動作（擁抱、親吻額頭、十指相扣）需落在畫面水平置中 70% 範圍內**，讓後製可以從 1536×1024 中央裁切出 1536×846（比例 1.816，符合目標）而不切到臉部或手部；裁切後需確認仍 ≥ 真正下限 1079×594.5（建議值 1200×661 以上留餘裕；如否，需以更高解析度重新生成或做無損放大）。
- **色彩**：暖色調、褪色相片粉調（呼應品牌 `$bg` #EDD3D6／`$print-paper` #FBEBEC 的暖玫瑰基調）——膚色維持自然暖調，不要冷藍色偏、不要青橙電影感分離色調（teal-orange）、不要 HDR 過飽和。
- **顆粒**：輕微底片顆粒感（約 ISO 400–800 底片質感），不是數位雜訊網格。
- **光線**：單一方向的自然光（窗光，柔和、有方向性、可見自然陰影）或室內暖黃燈光（傍晚場景）；不要棚燈、不要正面閃光燈打光、不要多光源打斜影。
- **景深**：中淺景深（約 f/2.8–f/4 效果），主體五官／皮膚紋理清晰銳利（保留真實毛孔、細紋，不磨皮），背景柔焦但仍可辨識場景元素（不是純色散景空洞）。
- **輸出格式**：PNG。
- **每題變體數**：4 個（見第 5 節：每題變體 1–2 為同一構圖家族的姿勢/角度微調，變體 3–4 為另一種構圖角度，增加選圖空間）。

## 3. 品牌約束

依 `little-sprout-brand` skill 十條不可協商第 9 條精神延伸：「照片是一件被印出來的實體沖印品」——這張照片本身必須看起來像真的被人用手機或傻瓜相機拍下來、會被沖洗出來夾進相簿的家庭照，不是設計素材、不是宣傳廣告照。

- **必須像真的被拍下**：手持拍攝的自然構圖感（可以有輕微傾斜、視角不完美置中），手機或傻瓜相機的色彩與焦外質感，而不是商業攝影棚的完美打光。
- **不得有 AI 生成質感**：過度平滑對稱的皮膚（尤其嬰兒與長輩皮膚都該有真實紋理——長輩有皺紋老斑、嬰兒有正常嬰兒肥與紅潤感，不是磨皮過的「完美」皮膚）、扭曲或多餘/融合的手指、無意義的背景物體（漂浮物、重複紋理拼貼痕跡、無來由的第三隻手）、完全對稱的五官與構圖、莫名其妙的文字或浮水印。
- **人物設定**：東亞面孔家庭（台灣/華人家庭生活感），繁體中文生活環境——建議每則 prompt 內至少安插 3–5 項具體道具細節（見第 5 節逐則列出，例如：印花棉被、藤編椅、老花眼鏡、保溫杯、月曆、瓷器擺飾、窗邊晾曬的衣物、國產品牌家電輪廓等），避免落入無地域感的「歐美風格 stock photo」樣板。
- **不得生成可辨識的真人**：不得模仿或神似任何真實存在、可指名道姓的個人（名人、政治人物或使用者本人親屬照片），生成結果須為完全合成、無特定身分指涉的一般人物形象。

## 4. 負面清單（negative prompt，供生圖模型使用）

**English**：
```
no text, no watermark, no logo, no signature, no caption overlay, no subtitles,
no extra fingers, no fused fingers, no six fingers, no missing fingers, no distorted or warped hands,
no warped or asymmetric face, no crossed eyes, no uncanny valley expression, no perfectly symmetrical face,
no plastic skin, no waxy skin, no over-smoothed airbrushed skin, no CGI render look, no 3D render look, no doll-like face, no mannequin skin,
no HDR oversharpened look, no teal-and-orange color grade, no oversaturated colors, no cool blue color cast, no neon lighting,
no studio ring-light catchlight, no direct flash photography look, no harsh multi-directional shadows,
no vignette frame, no black bars, no border, no split-screen, no collage, no multiple exposure,
no cartoon, no illustration, no anime style, no painting style,
no lens flare artifacts, no motion blur smear, no visible camera or phone in frame, no mirror reflection showing photographer,
no clothing or objects with visible brand logos or text, no identifiable celebrity likeness, no over-processed swirl bokeh
```

**中文對照**：
```
不要文字、不要浮水印、不要 logo、不要簽名、不要字幕疊字、
不要多餘手指、不要融合的手指、不要六根手指、不要缺手指、不要扭曲變形的手、
不要臉部扭曲或不對稱、不要鬥雞眼、不要恐怖谷詭異表情、不要完美對稱的臉、
不要塑膠感皮膚、不要蠟像感皮膚、不要過度磨皮的皮膚、不要 CGI 渲染感、不要 3D 渲染感、不要人偶臉、不要假人模特兒皮膚、
不要 HDR 過度銳化、不要青橙電影分離色調、不要色彩過飽和、不要偏冷藍色調、不要霓虹燈光、
不要棚燈環形反光點、不要正面閃光燈直打感、不要多方向生硬陰影、
不要暗角、不要黑邊、不要外框、不要分割畫面、不要拼貼、不要多重曝光、
不要卡通風格、不要插畫風格、不要動漫風格、不要繪畫風格、
不要鏡頭光斑瑕疵、不要動態模糊拖影、不要畫面中出現相機或手機、不要鏡子反射出攝影師、
不要衣物或物品上出現可辨識品牌 logo 或文字、不要神似真實名人的臉、不要過度處理的漩渦散景
```

## 5. 完整 prompt 草稿（每題 4 變體）

檔名規則：`design/appstore-photos/candidates/<hero|invite|join>-<1..4>.png`。變體 1–2 為同一構圖家族的姿勢/角度微調（同場景不同瞬間），變體 3–4 為另一種構圖角度（增加選圖空間，供 VR／核可頁比較）。每則已內嵌長寬比與畫質要求；負面清單另附於生圖工具的 negative prompt 欄位，不必重複貼在正向 prompt 內。

### hero-1（`hero-1.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1. An East Asian grandmother in her early 60s, short greying dark hair, natural wrinkles and age spots, wearing a soft pink linen blouse, sits on a worn fabric sofa in a warm Taiwanese living room, cheek pressed gently against the cheek of a 6-month-old East Asian baby she is cradling in her arms. Both face slightly toward camera, unposed, mid-afternoon. Soft directional window light from screen-left, warm color temperature, faded film tones, subtle 35mm film grain, shallow depth of field with a softly blurred background showing a rattan side chair, a pair of reading glasses on a side table, and a hand-embroidered floral cushion. Natural skin texture, visible pores and creases, unretouched. Shot on a mirrorless camera with a 50mm lens, f/2.8.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1。一位六十出頭的東亞阿嬤，灰黑短髮、有自然皺紋與老人斑，穿著粉色亞麻上衣，坐在略舊的布沙發上，懷裡抱著一位六個月大的東亞嬰兒，臉頰輕貼著嬰兒的臉頰。兩人微微朝向鏡頭，非擺拍、像午後隨手一拍。畫面左側有柔和方向性窗光，暖色調、褪色底片色感，輕微 35mm 底片顆粒，淺景深，背景虛化可見藤編扶手椅、桌上一副老花眼鏡、一個手工繡花抱枕。皮膚保留真實毛孔與細紋，未經修圖。以無反相機 50mm 鏡頭 f/2.8 拍攝。

### hero-2（`hero-2.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1. Same East Asian grandmother and baby as a continuous family moment, now captured from a slightly wider angle: grandmother sits cross-legged on a low wooden platform bed, baby lying tummy-down across her lap, both her hands gently supporting the baby's back, grandmother looking down at the baby with a soft closed-mouth smile. Warm late-afternoon window light from the left, sheer curtains diffusing the light, a small potted plant on the windowsill, a folded patterned quilt beside them, an insulated tea tumbler on the floor nearby. Faded warm film tones, visible skin texture on both grandmother and baby (natural baby chub, no airbrushing), shallow depth of field, subtle grain.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1。同一位阿嬤與嬰兒的另一個瞬間，鏡頭稍微拉遠：阿嬤盤腿坐在矮木質台階床上，嬰兒趴臥在她腿上，她雙手輕扶著嬰兒的背，低頭看著嬰兒露出抿嘴微笑。左側傍晚窗光透過紗簾柔化，窗台上有一盆小盆栽，旁邊放著疊好的印花棉被與一個保溫杯。暖色調褪色底片感，阿嬤與嬰兒皮膚都保留真實紋理（嬰兒有自然嬰兒肥，未修圖），淺景深，輕微顆粒。

### hero-3（`hero-3.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1, different composition angle from a wider household scene: an East Asian grandmother stands in a modest Taiwanese kitchen holding a toddler (about 18 months) on her hip, toddler reaching one hand toward her face, both mid-laugh, natural and slightly blurred motion in the toddler's reaching arm. Background softly out of focus shows a traditional round electric rice cooker on the counter, a wall calendar with Chinese characters, hanging kitchen towels. Warm incandescent kitchen light mixed with daylight from a window off-frame, faded warm tones, visible skin texture, natural unposed expressions, subtle film grain, shallow depth of field.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1，換一個更寬的居家場景角度：一位東亞阿嬤站在台灣家庭常見的廚房裡，一手抱著約 18 個月大的學步兒，孩子伸手摸向她的臉，兩人正在笑、孩子伸手的手臂帶有自然的些微動態模糊。背景虛化可見流理台上的大同電鍋、牆上印有中文字的月曆、掛著的擦手巾。溫暖的室內燈光混合畫面外窗戶透進的日光，暖色調褪色感，皮膚保留真實紋理，表情自然不擺拍，輕微底片顆粒，淺景深。

### hero-4（`hero-4.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1, alternate composition: an East Asian grandmother lies on her side on a bed next to a sleeping 3-month-old baby, both facing each other, her hand resting lightly on the baby's tummy, her eyes half-closed in a peaceful moment. Soft morning window light from screen-right, gauzy white curtains, a woven bamboo fan and a small stack of picture books visible on the nightstand in soft focus. Faded warm pastel tones, visible skin texture, natural film grain, shallow depth of field, tender quiet mood.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1，另一種構圖：一位東亞阿嬤側躺在床上，身旁是熟睡的三個月大嬰兒，兩人面對面，她的手輕輕放在嬰兒的肚子上，眼睛半閉、神情安穩。畫面右側清晨柔和窗光，白色紗簾，床頭櫃上虛焦可見一把竹編扇子與一疊繪本。暖色系褪色柔和色調，皮膚保留真實紋理，自然底片顆粒，淺景深，安靜溫柔的氛圍。

### invite-1（`invite-1.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1. Close, intimate framing: an East Asian grandmother in her mid-60s, short curly greying hair, leans down and kisses the forehead of a 4-month-old baby she holds against her chest, eyes closed in tenderness. Baby's small hand rests on her collarbone. Warm terracotta-colored blouse, softly blurred background of a wooden display cabinet with ceramic ornaments, a window showing distant city buildings out of focus. Warm directional daylight from the window, faded film tones, visible skin texture on both, subtle grain, shallow depth of field emphasizing the two faces.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1。近距離親密構圖：一位六十多歲、短捲灰髮的東亞阿嬤，低頭親吻懷中四個月大嬰兒的額頭，閉眼享受這一刻。嬰兒小手搭在她的鎖骨上。她穿著暖磚紅色上衣，背景虛化可見木質展示櫃與瓷器擺飾、窗外模糊的城市樓房。窗邊暖色日光，褪色底片色調，兩人皮膚保留真實紋理，輕微顆粒，淺景深聚焦兩張臉。

### invite-2（`invite-2.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1. Same tender grandmother-and-baby pairing, alternate angle: grandmother sits in a wooden rocking chair, baby held upright against her shoulder, baby's face turned toward camera with a curious wide-eyed expression while grandmother's face is turned toward the baby in profile, her lips near the baby's ear as if humming softly. Background softly blurred shows a woven laundry basket and hanging cloth diapers drying near a window. Warm afternoon light, faded warm tones, visible natural skin texture, subtle grain, shallow depth of field.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1。同一組溫馨的阿嬤與嬰兒，換個角度：阿嬤坐在木製搖椅上，嬰兒被直立抱在她肩上，嬰兒轉頭面向鏡頭露出好奇睜大眼的表情，阿嬤側臉貼近嬰兒耳邊像是在輕聲哼歌。背景虛化可見藤編洗衣籃與窗邊晾曬的紗布尿布。溫暖午後光線，褪色暖色調，皮膚保留自然紋理，輕微顆粒，淺景深。

### invite-3（`invite-3.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1, different composition featuring a grandfather: an East Asian grandfather in his late 60s, wearing reading glasses pushed up on his head, wire-frame glasses case visible on a nearby table, gently holds the hands of a toddler taking wobbly steps toward him, both mid-motion, genuine laughter on both faces. Softly blurred background of a traditional tiled balcony with potted plants. Warm late-afternoon light, faded film tones, natural skin texture including age spots on the grandfather's hands, subtle grain, medium depth of field to keep both figures in focus.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1，換成阿公的構圖：一位近七十歲的東亞阿公，老花眼鏡推到頭頂上、旁邊桌上放著眼鏡盒，牽著正搖搖晃晃學走路朝他走來的學步兒的雙手，兩人都帶著真實的笑容、動作中帶有自然的移動感。背景虛化是鋪磁磚的傳統陽台與盆栽。溫暖的傍晚光線，褪色底片色調，皮膚保留真實紋理（含阿公手上的老人斑），輕微顆粒，中景深讓兩人都清晰。

### invite-4（`invite-4.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1, alternate composition: an East Asian grandmother sits at a round dining table set for a family meal, a high chair with a 1-year-old baby beside her, she is wiping the baby's mouth with a small cloth while the baby giggles and grabs at her wrist. Background softly blurred shows a thermos, a bowl of rice, chopsticks resting on a ceramic rest. Warm indoor lamp light mixed with daylight, faded warm tones, visible skin texture, natural unposed motion blur on the baby's grabbing hand, subtle grain, shallow depth of field.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1，另一種構圖：一位東亞阿嬤坐在擺著家常菜的圓餐桌旁，旁邊兒童餐椅上坐著一歲大的嬰兒，她正用小毛巾擦嬰兒的嘴，嬰兒咯咯笑著抓她的手腕。背景虛化可見保溫壺、一碗白飯、擱在瓷製筷架上的筷子。室內暖黃燈光混合日光，褪色暖色調，皮膚保留真實紋理，嬰兒抓握的手帶有自然不擺拍的動態模糊，輕微顆粒，淺景深。

### join-1（`join-1.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1. A young East Asian couple in their late 20s to early 30s sit close together on a bed with soft pink-toned linens, foreheads touching over a sleeping newborn baby cradled between their joined arms, eyes closed, both smiling gently. Soft window light from screen-left, sheer curtains, warm faded tones, subtle film grain, shallow depth of field with a softly blurred headboard and a stack of folded baby clothes in the background. Natural skin texture on both parents and the baby, no retouching.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1。一對二十多到三十出頭的東亞年輕夫妻，並肩坐在鋪著粉色系寢具的床上，額頭隔著懷中熟睡的新生兒相碰，兩人閉眼、帶著溫柔的微笑。畫面左側柔和窗光，紗簾，暖色褪色調，輕微底片顆粒，淺景深，背景虛化的床頭與一疊摺好的嬰兒衣物。爸媽與嬰兒皮膚都保留真實紋理，未經修圖。

### join-2（`join-2.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1. Same young couple and newborn, alternate angle: father sits behind mother on the bed, arms wrapped around both mother and baby from behind, chin resting on mother's shoulder, mother looking down at the baby in her arms with a soft expression, baby's tiny hand wrapped around mother's finger. Warm morning light, faded tones, visible skin texture, subtle grain, shallow depth of field, softly blurred pillows and a wooden crib visible in the background.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1。同一對年輕夫妻與新生兒，換個角度：爸爸坐在媽媽身後,雙手從後方環抱著媽媽與嬰兒，下巴靠在媽媽肩上，媽媽低頭看著懷中嬰兒神情溫柔，嬰兒小手抓著媽媽的手指。溫暖晨光，褪色調，皮膚保留真實紋理，輕微顆粒，淺景深，背景虛化的枕頭與一個木製嬰兒床。

### join-3（`join-3.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1, different composition: a young East Asian mother and father stand side by side in a nursery room, father holding the baby while mother adjusts the baby's blanket, both looking down at the baby with focused tender expressions, shoulders touching. Softly blurred background shows a wooden crib with hanging fabric mobile, a folded stack of muslin swaddles on a shelf, a small potted plant. Warm daylight from a window off to the side, faded warm tones, visible skin texture, subtle grain, medium depth of field keeping both parents' faces sharp.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1，另一種構圖：一對年輕東亞夫妻並肩站在嬰兒房裡，爸爸抱著嬰兒、媽媽在一旁整理嬰兒的包巾，兩人低頭看著嬰兒、表情專注溫柔，肩膀輕輕相靠。背景虛化可見掛著布製吊飾的木製嬰兒床、層架上疊好的紗布巾、一盆小盆栽。畫面側邊窗戶透進暖色日光，褪色暖色調，皮膚保留真實紋理，輕微顆粒，中景深讓兩人的臉都清晰。

### join-4（`join-4.png`）
**EN**: Candid documentary-style photograph, horizontal landscape orientation, aspect ratio 1.8:1, alternate composition: a young East Asian couple sit on a living room sofa, mother holding the newborn baby against her chest while father leans in from the side, gently stroking the baby's back with one hand and resting his other arm around mother's shoulder, all three in soft natural contact. Background softly blurred shows a bookshelf with a few framed photos and a knit throw blanket draped over the sofa arm. Warm afternoon light, faded film tones, visible skin texture, subtle grain, shallow depth of field.
**中文**：紀實風格橫幅照片，長寬比約 1.8:1，另一種構圖：一對年輕東亞夫妻坐在客廳沙發上，媽媽將新生兒抱在胸前，爸爸從旁側身靠近，一手輕撫嬰兒的背，另一手環繞在媽媽肩上，三人有著自然的肢體接觸。背景虛化可見書架上擺著幾張相框照片、搭在沙發扶手上的針織毯。溫暖午後光線，褪色底片色調，皮膚保留真實紋理，輕微顆粒，淺景深。

## 6. 選圖判準（給 VR 與核可頁，五條可機械或半機械檢查）

1. **比例／可裁切性**（機械）：`sips -g pixelWidth -g pixelHeight <file>` 讀出的寬高比需落在 1.70–1.90 之間，或裁切後可落在此區間且裁切後仍 ≥2160×1190px；比例落在此區間之外的候選直接淘汰，不進入人工複審。
2. **無文字／浮水印**（機械，OCR）：跑 `tesseract`（或等效 OCR 工具）掃描全圖，任何 confidence > 50 的文字區塊數必須為 0；命中即淘汰。
3. **手部與五官完整性**（半機械／人工）：人工目視每隻可見手掌，手指數＝5，無融合、無多指、無扭曲；五官左右基本合理（不要求數學對稱，但不得歪斜錯位）。VR 逐張列出檢查結果，不採用「大致看起來還好」這種不可覆核的說法。
4. **主體落在安全裁切框內**（半機械）：候選圖裁切至 1.815:1 後，人臉／關鍵動作（親吻點、十指相扣處）需完全落在裁切後畫面水平置中 70% 範圍內，不得因裁切而被邊緣切到；用裁切座標與人工標記的臉部/動作 bounding box 核對。
5. **與印品白邊的邊界融合度**（機械，色差；**R2 訂正**——VR R1 MJ-3：原版只寫「CIE ΔE」未指定公式，導致同一組候選在 ΔE76 與 ΔE2000 下結論相反，一個未定義的判準卻獨自淘汰 9/12 張，不可接受）：
   - **公式**：CIEDE2000（`ΔE00`；CIE 現行建議公式，比舊版 ΔE76 對感知均勻性更準確，尤其在低彩度區域——本判準比對的正是 `#FBEBEC` 這種低彩度粉膚色，公式選錯會系統性誤判）。色彩轉換路徑固定為 sRGB → 線性 RGB（D65 gamma）→ CIE XYZ（D65 白點）→ CIE Lab；不得用 ΔE76（歐氏距離）替代。
   - **量測對象**：**裁成 1.815:1 之後的最終畫面四角**（不是候選原圖的四角）——上板顯示的是裁切後的照片，原圖邊緣如果被裁掉就與判準目的無關；每角取 32×32px 區塊、算術平均後轉 Lab，逐角與 `#FBEBEC` 算 ΔE00。
   - **門檻**：四角**全部** ΔE00 須 > 15（門檻數值沿用舊版；ΔE2000 尺度雖比 ΔE76 略小，但經 R2 實測 12 張候選後，通過／淘汰的分界與原始設計意圖仍吻合，不需要另外調降）。
   - **邊際保護**（VR R1 MN-3）：任一角 ΔE00 落在門檻 ±1.0 內（14.0–16.0）者，**不得單憑本判準淘汰或入選**，須加註「邊際值，進人工複審」並由 VR／核可頁人工判斷邊界視覺觀感是否可接受。

## 7. B 段計畫（置換、裁切重算、收據、VR 輪次；本輪不執行）

1. **前置**：確認 Pen MCP 已重連（`get_app_state()` 核對 active 文件路徑＝本 worktree 的 `design/littlesprout.pen`）；六張定稿候選（orchestrator 派 codex-rescue 依第 5 節 prompt 生成後）落地到 `design/appstore-photos/candidates/`，經第 6 節判準初篩。
2. **置換 `fill.url`**：六個 Hero Photo 節點（`scpdc`／`ayJoy`／`F92jh`／`yzfCx`／`aD9EO`／`j5Bns`）的 image fill 改指新檔。Fill 的 url／asset 屬性不在已知的 `width`/`height`/`metadata`/`underline` 黑名單內，理論上 `Update()` 可用，但仍要**讀回驗證**（Pencil 已知限制條款要求任何 Update 後必須讀回或截圖確認）；若讀回發現 fill 未真正套用，改用 `Replace()` 整節點寫入。
3. **Photo Wrap／y 偏移重算**：新圖若已生成在目標比例 1.815:1 附近，六節點的 `width`/`height`/`y`（皆為字面硬寫值，見 Pencil 限制條款）需依新圖實際像素比例重新計算——公式：等比縮放使圖片覆蓋滿 Photo Wrap（寬或高取較大覆蓋倍率），再置中裁切另一維，`y` 偏移＝−(縮放後高度−Wrap高度)/2（若寬度已貼合）或反之。六個節點逐一 `Update` 後個別截圖比對，不假設六板數值相同（iPhone 三板共用一組數值、iPad 三板共用另一組，但仍要各自截圖複驗，因為三個 Print 容器雖同尺寸，實際 Hero Photo 目前 x/y 已有共用慣例，需確認新圖沿用同一慣例後仍居中正確）。
4. **`JbTfv` 是否連動**：**建議不連動**。`JbTfv` 是既有「寶貝管理」畫面既有素材（`child-ipad-v2.jpg` 複合截圖來源），不在本票六個 Hero Photo 節點清單內，票面驗收條件的 `grep -c` 只檢查三個佔位圖檔名對六節點的引用數，未涵蓋 `JbTfv`；若連動需另外重跑 LS-234 R3 BL-7 複合截圖流程，屬於範圍外擴張。留待使用者於核可頁決定是否要在後續小票一併處理。
5. **收據與 VR 輪次**：置換完成後，`SCAN_BOARDS` 至少含六個 root frame（`c2yk3s`／`Bm7Lx`／`ZRyXL`／`Vn4TL`／`BnjqP`／`b59DUk`）與 Notes 板 `H73kPC`（本輪若動了 Notes 內容）；跑六支全樹掃描產出 `design/evidence/LS-247-r1-overflow.json`。VR ≥3 輪，前兩輪一律退修，主攻兩件事：①AI 質感獵殺（比對第 4 節負面清單逐項核對）②沖印品可信度（照片本身是否騙得過「這是被拍下來、被沖印出來的」——構圖是否太完美、太像廣告)。每輪落地走完整 `pen-land.sh` SOP（`--expect-nodes`／`--after`／視情況 `--marker`）。
6. **Notes 板更新**：`H73kPC` 的 `H7782`（D10 相片來源揭露段）依沿革寫法追加「LS-247 已置換，圖源＝Codex 生圖，候選見 `design/appstore-photos/candidates/`，定稿檔名見核可頁」，並解除「第 0 步 blocker」狀態；`design-notes-check.sh` 需綠。
7. **核可頁**：VR APPROVE 後產出 artifact，三題各列 2–4 張候選圖並列比較＋各自貼上六板效果截圖（裁切後在 Photo Wrap 內的實際呈現），交使用者選定稿；定稿清單另交 LS-248 換 demo 種子。
