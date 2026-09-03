#!/bin/bash
# privacy-manifest-check.sh／privacy_manifest_check.py 的自測（LS-145）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若 manifest／用途字串／出口合規旗標任一檢查退化成「只要檔案
# 存在就過」（不看內容），或字數／黑名單／布林值比對被拿掉，這裡會紅。全程用合成 fixture 目錄
# （--root 指向 $work 底下的樹），不碰真正的 LittleSprout/PrivacyInfo.xcprivacy／Info.plist。
set -uo pipefail

root_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root_repo}/scripts/gates/privacy-manifest-check.sh"
py="${root_repo}/scripts/gates/privacy_manifest_check.py"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# mkroot：建一個全新的 fixture root（<dir>/LittleSprout/…），回傳路徑。用 mktemp -d 保證每次
# 唯一——不能靠遞增計數器（`r=$(mkroot)` 是 command substitution，函式跑在子殼層，對 n 的遞增
# 只在子殼層內生效、回到呼叫端後 n 沒有真的變，會讓每次呼叫都撞回同一個目錄，樣本互相污染）。
mkroot() {
  local d
  d=$(mktemp -d "$work/root-XXXXXX")
  mkdir -p "$d/LittleSprout"
  printf '%s' "$d"
}

# write_manifest <root> <內容>：寫 PrivacyInfo.xcprivacy。
write_manifest() { printf '%s' "$2" > "$1/LittleSprout/PrivacyInfo.xcprivacy"; }
# write_infoplist <root> <內容>：寫 Info.plist。
write_infoplist() { printf '%s' "$2" > "$1/LittleSprout/Info.plist"; }
# write_en_strings <root> <內容>：寫 en.lproj/InfoPlist.strings。
write_en_strings() { mkdir -p "$1/LittleSprout/en.lproj"; printf '%s' "$2" > "$1/LittleSprout/en.lproj/InfoPlist.strings"; }

plist_head='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">'

good_manifest="${plist_head}
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>"

good_photo_desc='萌芽日記需要讀取你的相簿，才能挑選寶貝照片上傳到私密家庭相簿。'

good_infoplist="${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>${good_photo_desc}</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"

# expect <期望 exit> <名稱> <輸出必含|''> <root>
expect() {
  local want=$1 name=$2 must=$3 rootdir=$4 out got
  out="$(bash "$check" --root "$rootdir" 2>&1)"; got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ==== ① 正樣本（≥3）====
r=$(mkroot); write_manifest "$r" "$good_manifest"; write_infoplist "$r" "$good_infoplist"
expect 0 '① 合格 manifest＋合格 Info.plist（含 encryption=false）→ 全過' '全過' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
expect 0 '① 三個用途字串鍵一個都未宣告 → 不算失敗' '不算失敗' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>${good_photo_desc}</string>
	<key>NSCameraUsageDescription</key>
	<string>萌芽日記需要使用相機，讓你直接拍照更新寶貝的大頭貼。</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
expect 0 '① 兩個用途字串鍵皆合格 → 過' '全過' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"; write_infoplist "$r" "$good_infoplist"
write_en_strings "$r" '/* comment */
"NSPhotoLibraryUsageDescription" = "Little Sprout needs access to your photo library so you can pick your child'"'"'s photos to upload.";
'
expect 0 '① en.lproj/InfoPlist.strings 存在且合格 → 過' '全過' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"; write_infoplist "$r" "$good_infoplist"
expect 0 '① en.lproj/InfoPlist.strings 不存在 → 不算失敗（LS-112 定案）' '刻意未出貨 en 在地化資源' "$r"

# ==== ② 負樣本（manifest，≥3）====
r=$(mkroot); write_infoplist "$r" "$good_infoplist"
expect 1 '② manifest 檔案不存在 → 紅' '找不到' "$r"

r=$(mkroot); write_manifest "$r" "${plist_head}
<dict>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>"; write_infoplist "$r" "$good_infoplist"
expect 1 '② manifest 缺 NSPrivacyTracking → 紅' '缺 NSPrivacyTracking' "$r"

r=$(mkroot); write_manifest "$r" "${plist_head}
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
</dict>
</plist>"; write_infoplist "$r" "$good_infoplist"
expect 1 '② manifest 的 NSPrivacyAccessedAPITypes 是空陣列 → 紅' '缺漏或是空陣列' "$r"

r=$(mkroot); write_manifest "$r" "${plist_head}
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array/>
		</dict>
	</array>
</dict>
</plist>"; write_infoplist "$r" "$good_infoplist"
expect 1 '② manifest 某項的 reasons 是空陣列 → 紅' 'NSPrivacyAccessedAPITypeReasons 缺漏或是空陣列' "$r"

r=$(mkroot); write_manifest "$r" 'not a plist at all'; write_infoplist "$r" "$good_infoplist"
expect 1 '② manifest 不是合法 plist → 紅（fail closed，非靜默放行）' '不是合法 plist' "$r"

# ==== ③ 負樣本（用途字串／黑名單，≥3）====
r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string></string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
expect 1 '③ 用途字串為空字串 → 紅' '空字串' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>存取相簿</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
expect 1 '③ 用途字串 <20 字元 → 紅' '需 ≥ 20' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>此 App 需要存取你的相簿才能運作正常喔，請務必開啟權限</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
expect 1 '③ 命中中文模板黑名單「此 App」／「需要存取」→ 紅' '模板片語黑名單' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>Your App uses the camera to let you take a new photo of your child right now</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
expect 1 '③ 英文模板黑名單「Your app」大小寫不敏感 → 紅' '模板片語黑名單' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>${good_photo_desc}</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>"
write_en_strings "$r" '"NSPhotoLibraryUsageDescription" = "short";'
expect 1 '③ en.lproj/InfoPlist.strings 存在但太短 → 紅（存在就驗內容）' '需 ≥ 20' "$r"

# ==== ④ 負樣本（ITSAppUsesNonExemptEncryption，≥3）====
r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>${good_photo_desc}</string>
</dict>
</plist>"
expect 1 '④ 缺 ITSAppUsesNonExemptEncryption → 紅' '未宣告 ITSAppUsesNonExemptEncryption' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>${good_photo_desc}</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<true/>
</dict>
</plist>"
expect 1 '④ ITSAppUsesNonExemptEncryption=true → 紅' '不是布林 False' "$r"

r=$(mkroot); write_manifest "$r" "$good_manifest"
write_infoplist "$r" "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>${good_photo_desc}</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<string>false</string>
</dict>
</plist>"
expect 1 '④ ITSAppUsesNonExemptEncryption 是字串 "false"（型別不符）→ 紅' '不是布林 False' "$r"

# ==== ⑤ 參數／環境錯誤：fail closed（exit 2）====
out="$(bash "$check" --root 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF -- '--root 缺值'; then
  echo "✓ ⑤ --root 缺值 → exit 2"
else
  echo "✗ ⑤ --root 缺值（期望 exit 2，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
out="$(bash "$check" --bogus 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF -- '未知參數'; then
  echo "✓ ⑤ 未知參數 → exit 2"
else
  echo "✗ ⑤ 未知參數（期望 exit 2，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ==== ⑥ mutation 負控：直接對 privacy_manifest_check.py 的關鍵判定行做替換，證明樣本釘住的是那一行 ====
# mutate <標記> <取代整行>：以 awk 找含標記文字的那一行整行替換，輸出到 $work/mutant.py。
mutate() {
  awk -v repl="$2" -v marker="$1" '
    index($0, marker) > 0 { print repl; found=1; next }
    { print }
    END { if (!found) { print "NOTFOUND" > "/dev/stderr"; exit 1 } }
  ' "$py" > "$work/mutant.py"
}

# ⑥a：拿掉最短長度比對（PRIVACY-MIN-LEN-CMP）→ 太短的用途字串不再被擋
if mutate 'PRIVACY-MIN-LEN-CMP' '    if False:  # PRIVACY-MIN-LEN-CMP'; then
  tmp_ip="$work/short.plist"
  printf '%s' "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>太短</string>
</dict>
</plist>" > "$tmp_ip"
  out="$(python3 "$work/mutant.py" infoplist "$tmp_ip" 2>&1)"; got=$?
  if [ "$got" -eq 0 ]; then echo "✓ ⑥a mutant（拿掉字數比對）：短字串樣本改判過──證明字數比對是這裡在擋"; else echo "✗ ⑥a mutant 未如預期翻轉（實得 exit ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ ⑥a mutate：找不到 PRIVACY-MIN-LEN-CMP 標記，負控本身無效" >&2; fail=1
fi

# ⑥b：拿掉黑名單迴圈（PRIVACY-BLACKLIST）→ 模板片語不再被擋
if mutate 'PRIVACY-BLACKLIST' '    for phrase in ():  # PRIVACY-BLACKLIST'; then
  tmp_ip="$work/blacklisted.plist"
  printf '%s' "${plist_head}
<dict>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>此 App 需要存取你的相簿才能運作正常喔，請務必開啟權限</string>
</dict>
</plist>" > "$tmp_ip"
  out="$(python3 "$work/mutant.py" infoplist "$tmp_ip" 2>&1)"; got=$?
  if [ "$got" -eq 0 ]; then echo "✓ ⑥b mutant（拿掉黑名單迴圈）：模板片語樣本改判過──證明黑名單是這裡在擋"; else echo "✗ ⑥b mutant 未如預期翻轉（實得 exit ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ ⑥b mutate：找不到 PRIVACY-BLACKLIST 標記，負控本身無效" >&2; fail=1
fi

# ⑥c：拿掉 encryption=false 比對（PRIVACY-ENC-FALSE）→ true 也會被當成過
if mutate 'PRIVACY-ENC-FALSE' '    if False:  # PRIVACY-ENC-FALSE'; then
  tmp_ip="$work/enc-true.plist"
  printf '%s' "${plist_head}
<dict>
	<key>ITSAppUsesNonExemptEncryption</key>
	<true/>
</dict>
</plist>" > "$tmp_ip"
  out="$(python3 "$work/mutant.py" encryption "$tmp_ip" 2>&1)"; got=$?
  if [ "$got" -eq 0 ]; then echo "✓ ⑥c mutant（拿掉 encryption 布林比對）：true 樣本改判過──證明布林比對是這裡在擋"; else echo "✗ ⑥c mutant 未如預期翻轉（實得 exit ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ ⑥c mutate：找不到 PRIVACY-ENC-FALSE 標記，負控本身無效" >&2; fail=1
fi

# ⑥d：拿掉 NSPrivacyAccessedAPITypes 非空比對（PRIVACY-APITYPES-NONEMPTY）→ 空陣列也會被當成過
if mutate 'PRIVACY-APITYPES-NONEMPTY' '    if False:  # PRIVACY-APITYPES-NONEMPTY'; then
  tmp_mf="$work/empty-apitypes.xcprivacy"
  printf '%s' "${plist_head}
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
</dict>
</plist>" > "$tmp_mf"
  out="$(python3 "$work/mutant.py" manifest "$tmp_mf" 2>&1)"; got=$?
  if [ "$got" -eq 0 ]; then echo "✓ ⑥d mutant（拿掉 API types 非空比對）：空陣列樣本改判過──證明非空比對是這裡在擋"; else echo "✗ ⑥d mutant 未如預期翻轉（實得 exit ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ ⑥d mutate：找不到 PRIVACY-APITYPES-NONEMPTY 標記，負控本身無效" >&2; fail=1
fi

# ⑥e：拿掉 reasons 非空比對（PRIVACY-REASON-NONEMPTY）→ 空 reasons 陣列也會被當成過
if mutate 'PRIVACY-REASON-NONEMPTY' '            if False:  # PRIVACY-REASON-NONEMPTY'; then
  tmp_mf="$work/empty-reasons.xcprivacy"
  printf '%s' "${plist_head}
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array/>
		</dict>
	</array>
</dict>
</plist>" > "$tmp_mf"
  out="$(python3 "$work/mutant.py" manifest "$tmp_mf" 2>&1)"; got=$?
  if [ "$got" -eq 0 ]; then echo "✓ ⑥e mutant（拿掉 reasons 非空比對）：空 reasons 樣本改判過──證明非空比對是這裡在擋"; else echo "✗ ⑥e mutant 未如預期翻轉（實得 exit ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
else
  echo "✗ ⑥e mutate：找不到 PRIVACY-REASON-NONEMPTY 標記，負控本身無效" >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ privacy-manifest-check 自測通過"
fi
exit "$fail"
