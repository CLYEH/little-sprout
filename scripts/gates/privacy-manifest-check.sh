#!/bin/bash
# Privacy Manifest gate（LS-145）：PLAN §6 Phase 2-2、§9-B 的機械 gate——App Store Connect 上傳前
# PrivacyInfo.xcprivacy／Info.plist 用途字串／出口合規旗標三件套是否到位。實際 plist／.strings 解析
# 邏輯在 privacy_manifest_check.py（python3，跨 macOS／ubuntu-latest 都內建，同 api-contract-check.sh
# 呼叫 api_contract_check.py 的既有慣例）。
#
# 檢查範圍：
#   (a) <root>/LittleSprout/PrivacyInfo.xcprivacy 存在＋合法 XML plist＋NSPrivacyTracking（布林）＋
#       NSPrivacyAccessedAPITypes 至少一項、每項有非空 API type 與至少一個非空理由碼。
#   (b) <root>/LittleSprout/Info.plist 的三個用途字串鍵（存在的那幾個）：非空、Unicode 字元數 ≥20、
#       不含模板片語黑名單。
#   (c) <root>/LittleSprout/Info.plist 的 ITSAppUsesNonExemptEncryption 存在且為布林 false。
#
# LS-145 刻意不驗 <root>/LittleSprout/en.lproj/InfoPlist.strings 的「必須存在」——與 LS-112 定案衝突：
# 該票證實 app 目前一個 .lproj 資源都不出貨，因為 SignInWithAppleButton 的顯示語系跟隨 app 實際打包的
# 在地化資源集合走，一旦有了 en.lproj（即使只放 InfoPlist.strings）就會讓偏好英文的裝置上 Apple 官方鈕
# 變回英文、與其餘寫死中文的按鈕再度不一致（LS-112 merge-review R1 已用 DerivedData 產物實測驗證這個
# 機制，不是猜測）。所以這裡把它列為「存在就驗內容，不存在就略過（不算失敗）」——先把驗證機制建好，
# 等未來做全 String Catalog 多語系時才真的出貨這個檔案（見 LS-145 handoff）。
#
# 用法：privacy-manifest-check.sh [--root <dir>]（預設 repo root；自測用 --root 指向合成 fixture 目錄，
#       不碰真檔——fixture 目錄結構需與真 repo 一致：<root>/LittleSprout/PrivacyInfo.xcprivacy、
#       <root>/LittleSprout/Info.plist、可選 <root>/LittleSprout/en.lproj/InfoPlist.strings）
# exit：0＝全過；1＝任一項違規；2＝參數／環境錯誤（fail closed）
# 自測：privacy-manifest-check.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/privacy_manifest_check.py"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ -n "${2:-}" ] || { echo "✗ privacy-manifest-check：--root 缺值" >&2; exit 2; }
      root=$2; shift 2 ;;
    *) echo "✗ privacy-manifest-check：未知參數 $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "✗ privacy-manifest-check：需要 python3（macOS 與 ubuntu-latest 皆內建）" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ privacy-manifest-check：找不到 ${py}" >&2; exit 2; }

manifest="${root}/LittleSprout/PrivacyInfo.xcprivacy"
infoplist="${root}/LittleSprout/Info.plist"
en_strings="${root}/LittleSprout/en.lproj/InfoPlist.strings"

fail=0

# ---- (a) PrivacyInfo.xcprivacy ----
if [ ! -f "$manifest" ]; then
  echo "✗ privacy-manifest-check：找不到 ${manifest}" >&2
  fail=1
else
  python3 "$py" manifest "$manifest"
  rc=$?
  [ "$rc" -eq 0 ] || fail=1
fi

# ---- (b) Info.plist 用途字串 ----
if [ ! -f "$infoplist" ]; then
  echo "✗ privacy-manifest-check：找不到 ${infoplist}" >&2
  fail=1
else
  python3 "$py" infoplist "$infoplist"
  rc=$?
  [ "$rc" -eq 0 ] || fail=1

  # ---- (c) ITSAppUsesNonExemptEncryption ----
  python3 "$py" encryption "$infoplist"
  rc=$?
  [ "$rc" -eq 0 ] || fail=1
fi

# ---- (b) 附加：en.lproj/InfoPlist.strings，存在才驗（LS-112 衝突，見檔頭）----
if [ -f "$en_strings" ]; then
  python3 "$py" strings "$en_strings"
  rc=$?
  [ "$rc" -eq 0 ] || fail=1
else
  echo "（${en_strings} 不存在——LS-145 依 LS-112 定案刻意未出貨 en 在地化資源，見本檔檔頭；不算失敗）"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ privacy-manifest-check 全過"
fi
exit "$fail"
