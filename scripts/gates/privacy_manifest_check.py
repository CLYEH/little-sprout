#!/usr/bin/env python3
"""LS-145 Privacy Manifest gate 邏輯（供 privacy-manifest-check.sh 呼叫）。

四種模式，各自獨立判定＋各自印 ✓/✗ 開頭的診斷行、以 exit code 回報：
  manifest <PrivacyInfo.xcprivacy 路徑>
      合法 XML plist；頂層 dict 含 NSPrivacyTracking（布林）；NSPrivacyAccessedAPITypes
      至少一項，且每項的 NSPrivacyAccessedAPIType 是非空字串、
      NSPrivacyAccessedAPITypeReasons 是非空陣列且每個理由碼皆非空字串。
  infoplist <Info.plist 路徑>
      三個用途字串鍵（NSPhotoLibraryUsageDescription／NSPhotoLibraryAddUsageDescription／
      NSCameraUsageDescription）——只驗「存在的那幾個」：trim 後非空、Unicode 字元數
      ≥ MIN_LEN、不含模板片語黑名單（大小寫不敏感子字串比對）。一個鍵都不存在時印一行
      說明，不算失敗（該不該存在由呼叫端／人工判斷，這支只驗「存在的內容夠不夠具體」）。
  strings <.strings 路徑>
      與 infoplist 模式同一組規則，但來源是舊式 ASCII plist 格式的 .strings 檔
      （`"Key" = "Value";`，plistlib 不支援這個格式，故自行解析）——供未來若真的加了
      在地化用途字串時驗證；LS-145 目前刻意未出貨 en.lproj/InfoPlist.strings（見
      privacy-manifest-check.sh 檔頭 LS-112 衝突說明），呼叫端在檔案不存在時應略過、
      不要呼叫本模式。
  encryption <Info.plist 路徑>
      ITSAppUsesNonExemptEncryption 鍵存在且型別為布林 False（存在但非布林、或為
      True、或不存在，皆判失敗）。

exit：0＝該模式全過；1＝任何一項違規；2＝檔案讀不到／不是合法 plist（fail closed）。
"""
import plistlib
import re
import sys

MIN_LEN = 20  # PRIVACY-MIN-LEN
DESCRIPTION_KEYS = (
    "NSPhotoLibraryUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSCameraUsageDescription",
)
# 模板片語黑名單：大小寫不敏感子字串比對（Chinese 詞語不受大小寫影響，僅英文詞語需要）。
# LS-145 票文舉例「此 App」「需要存取」「Your app」「uses the camera」；另補幾個常見 AI
# 生成的空泛套話，供未來鍵補充。
BLACKLIST = (
    "此app",
    "此 app",
    "需要存取",
    "your app",
    "uses the camera",
    "this app needs",
    "we need access",
    "為了提供更好的服務",
)


def fail(msg):
    sys.stderr.write("✗ privacy_manifest_check：%s\n" % msg)
    sys.exit(2)


def load_plist(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as exc:
        fail("讀不到 %s（%s）" % (path, exc))
    try:
        return plistlib.loads(data)
    except Exception as exc:  # noqa: BLE001 - 印出來讓人判斷
        fail("%s 不是合法 plist（%s）" % (path, exc))


def check_description(key, value):
    """回傳 (ok, message)。"""
    if value is None:
        return None, "%s：未宣告，略過" % key
    if not isinstance(value, str):
        return False, "%s：值不是字串（型別 %s）" % (key, type(value).__name__)
    text = value.strip()
    if not text:
        return False, "%s：空字串" % key
    if len(text) < MIN_LEN:  # PRIVACY-MIN-LEN-CMP
        return False, "%s：只有 %d 字元（需 ≥ %d）——「%s」" % (key, len(text), MIN_LEN, text)
    lowered = text.lower()
    for phrase in BLACKLIST:  # PRIVACY-BLACKLIST
        if phrase in lowered:
            return False, "%s：命中模板片語黑名單「%s」——「%s」" % (key, phrase, text)
    return True, "%s：%d 字元、非模板字——「%s」" % (key, len(text), text)


def run_description_checks(values_by_key):
    any_present = False
    ok = True
    for key in DESCRIPTION_KEYS:
        result, msg = check_description(key, values_by_key.get(key))
        if result is None:
            print(msg)
            continue
        any_present = True
        if result:
            print("✓ %s" % msg)
        else:
            print("✗ privacy_manifest_check：%s" % msg, file=sys.stderr)
            ok = False
    if not any_present:
        print("（三個用途字串鍵一個都未宣告——不算失敗，是否該宣告由呼叫端判斷）")
    return ok


def cmd_infoplist(path):
    data = load_plist(path)
    if not isinstance(data, dict):
        fail("%s 頂層不是 dict" % path)
    ok = run_description_checks(data)
    sys.exit(0 if ok else 1)


def parse_strings_file(path):
    """解析舊式 ASCII plist（.strings）格式：`"Key" = "Value";`，允許 `/* */`／`//` 註解。
    不支援跳脫序列以外的複雜語法（本專案只需要讀用途字串這種單行 value）。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        fail("讀不到 %s（%s）" % (path, exc))
    # 先去掉區塊註解／行註解（皆不巢狀，符合 .strings 慣例）。
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", "", text)
    pairs = {}
    pattern = re.compile(
        r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.DOTALL
    )
    for m in pattern.finditer(text):
        key = m.group(1).replace('\\"', '"').replace("\\n", "\n")
        value = m.group(2).replace('\\"', '"').replace("\\n", "\n")
        pairs[key] = value
    return pairs


def cmd_strings(path):
    pairs = parse_strings_file(path)
    ok = run_description_checks(pairs)
    sys.exit(0 if ok else 1)


def cmd_encryption(path):
    data = load_plist(path)
    if not isinstance(data, dict):
        fail("%s 頂層不是 dict" % path)
    key = "ITSAppUsesNonExemptEncryption"
    if key not in data:
        print("✗ privacy_manifest_check：%s 未宣告 %s" % (path, key), file=sys.stderr)
        sys.exit(1)
    value = data[key]
    if not isinstance(value, bool) or value is not False:  # PRIVACY-ENC-FALSE
        print(
            "✗ privacy_manifest_check：%s 的 %s 不是布林 False（實得 %r）"
            % (path, key, value),
            file=sys.stderr,
        )
        sys.exit(1)
    print("✓ %s = false" % key)
    sys.exit(0)


def cmd_manifest(path):
    data = load_plist(path)
    if not isinstance(data, dict):
        fail("%s 頂層不是 dict" % path)
    ok = True
    if "NSPrivacyTracking" not in data:
        print("✗ privacy_manifest_check：缺 NSPrivacyTracking", file=sys.stderr)
        ok = False
    elif not isinstance(data["NSPrivacyTracking"], bool):
        print(
            "✗ privacy_manifest_check：NSPrivacyTracking 不是布林（實得 %r）" % (data["NSPrivacyTracking"],),
            file=sys.stderr,
        )
        ok = False
    else:
        print("✓ NSPrivacyTracking = %r" % data["NSPrivacyTracking"])

    api_types = data.get("NSPrivacyAccessedAPITypes")
    if not isinstance(api_types, list) or len(api_types) == 0:  # PRIVACY-APITYPES-NONEMPTY
        print(
            "✗ privacy_manifest_check：NSPrivacyAccessedAPITypes 缺漏或是空陣列",
            file=sys.stderr,
        )
        ok = False
    else:
        for i, item in enumerate(api_types):
            if not isinstance(item, dict):
                print("✗ privacy_manifest_check：NSPrivacyAccessedAPITypes[%d] 不是 dict" % i, file=sys.stderr)
                ok = False
                continue
            api_type = item.get("NSPrivacyAccessedAPIType")
            if not isinstance(api_type, str) or not api_type.strip():
                print(
                    "✗ privacy_manifest_check：NSPrivacyAccessedAPITypes[%d] 的 NSPrivacyAccessedAPIType 缺漏或空字串" % i,
                    file=sys.stderr,
                )
                ok = False
                api_type = "?"
            reasons = item.get("NSPrivacyAccessedAPITypeReasons")
            if not isinstance(reasons, list) or len(reasons) == 0:  # PRIVACY-REASON-NONEMPTY
                print(
                    "✗ privacy_manifest_check：%s 的 NSPrivacyAccessedAPITypeReasons 缺漏或是空陣列" % api_type,
                    file=sys.stderr,
                )
                ok = False
                continue
            for j, reason in enumerate(reasons):
                if not isinstance(reason, str) or not reason.strip():
                    print(
                        "✗ privacy_manifest_check：%s 的第 %d 個理由碼是空字串" % (api_type, j),
                        file=sys.stderr,
                    )
                    ok = False
                else:
                    print("✓ %s 理由碼 %s" % (api_type, reason))
    sys.exit(0 if ok else 1)


def main(argv):
    if len(argv) != 3:
        fail("用法：privacy_manifest_check.py <manifest|infoplist|strings|encryption> <路徑>")
    mode, path = argv[1], argv[2]
    dispatch = {
        "manifest": cmd_manifest,
        "infoplist": cmd_infoplist,
        "strings": cmd_strings,
        "encryption": cmd_encryption,
    }
    fn = dispatch.get(mode)
    if fn is None:
        fail("未知模式 %s（manifest|infoplist|strings|encryption）" % mode)
    fn(path)


if __name__ == "__main__":
    main(sys.argv)
