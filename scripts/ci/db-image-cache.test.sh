#!/bin/bash
# db-image-cache.sh 的自測（LS-392）。CI rules job 跑。不碰真 docker：PATH 前置假 `docker`——把每次呼叫追加到 $FAKE_LOG；
# `docker images` 回 $FAKE_IMAGES 的內容（混入非 supabase／其他 registry／<none> 映像當負向樣本）；`docker load`／`docker save`
# 依 $FAKE_LOAD_RC／$FAKE_SAVE_RC 決定成敗，save 成功時寫一個假 tar。
# 覆蓋：① cache hit（tar 在）→ docker load -i <tar>、印「cache hit」與映像清單、刪 tar、不 save；② cache miss（tar 不在）→
# 完全不呼叫 docker、印「cache miss」與 registry；③ hit 但 load 失敗 → exit 0＋::warning::（CLI 會照常拉）；④ save 只收
# `<registry>/supabase/*` 映像（其他 registry／docker hub／<none> 不收）、寫出 tar；⑤ 無可存映像 → ::warning::、不 save、
# 不寫 tar；⑥ SUPABASE_INTERNAL_IMAGE_REGISTRY 未設／參數錯 → exit 2；⑦ mutation：拿掉 registry 過濾（DB-IMAGE-FILTER）
# → save 收進無關映像。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ci/db-image-cache.sh"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"
fail() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_LOG:?}"
case "$1" in
  images) cat "${FAKE_IMAGES:?}" ;;
  load) echo 'Loaded image: public.ecr.aws/supabase/postgres:17.6.1.159'; exit "${FAKE_LOAD_RC:-0}" ;;
  save)
    [ "${FAKE_SAVE_RC:-0}" -eq 0 ] || exit "$FAKE_SAVE_RC"
    out=; prev=
    for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
    printf 'fake tar\n' > "$out" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/docker"

printf '%s\n' \
  'public.ecr.aws/supabase/postgres:17.6.1.159' \
  'public.ecr.aws/supabase/realtime:v2.129.0' \
  'public.ecr.aws/supabase/storage-api:v1.69.11' \
  'public.ecr.aws/supabase/gotrue:v2.195.0' \
  'ghcr.io/supabase/postgres:17.6.1.159' \
  'mirror.example/public.ecr.aws/supabase/postgres:17' \
  'public.ecr.aws/supabase/postgres:<none>' \
  'ubuntu:24.04' > "$work/images-all"
: > "$work/images-none"
printf '%s\n' 'ubuntu:24.04' > "$work/images-other"

tar="$work/cache/images.tar"
# run <mode> [<script>] [env…]：輸出到 $work/out、docker 呼叫到 $work/calls
run() {
  local mode=$1 s=${2:-$script}
  : > "$work/calls"
  env FAKE_LOG="$work/calls" FAKE_IMAGES="${FAKE_IMAGES:-$work/images-all}" PATH="$work/bin:$PATH" \
    SUPABASE_INTERNAL_IMAGE_REGISTRY=public.ecr.aws "${@:3}" bash "$s" "$mode" "$tar" > "$work/out" 2>&1
}
calls() { paste -s -d '|' "$work/calls"; }

# ① cache hit
mkdir -p "$work/cache"; printf 'x\n' > "$tar"
run load; rc=$?
expect_exit 0 "$rc" '① cache hit → exit 0'
expect_has "$(calls)" "load -i ${tar}" '① cache hit → docker load -i <tar>'
expect_has "$(cat "$work/out")" 'cache hit——docker load 載入 4 個映像（actions/cache，不走 public.ecr.aws）' '① 印「cache hit」與載入的 supabase 映像數（4）'
expect_has "$(cat "$work/out")" '  public.ecr.aws/supabase/postgres:17.6.1.159' '① 列出載入的映像'
expect_not_has "$(calls)" 'save' '① cache hit 不 docker save'
[ -e "$tar" ] && fail '① docker load 成功後應刪 tar（省 runner 磁碟）' || ok '① docker load 成功後刪 tar'

# ② cache miss
rm -f "$tar"
run load; rc=$?
expect_exit 0 "$rc" '② cache miss → exit 0'
[ -s "$work/calls" ] && fail "② cache miss 不應呼叫 docker（實得：$(calls)）" || ok '② cache miss 完全不呼叫 docker'
expect_has "$(cat "$work/out")" 'cache miss——映像將由 public.ecr.aws 拉取' '② 印「cache miss」與 fallback registry'

# ③ hit 但 docker load 失敗
printf 'x\n' > "$tar"
run load "$script" FAKE_LOAD_RC=1; rc=$?
expect_exit 0 "$rc" '③ load 失敗 → exit 0（快取問題不擋 required check，CLI 照常拉）'
expect_has "$(cat "$work/out")" '::warning::db-image-cache：cache hit 但 docker load 失敗' '③ 印 ::warning::（不靜默）'
[ -e "$tar" ] && fail '③ load 失敗後應刪掉壞 tar' || ok '③ load 失敗後刪掉壞 tar'

# ④ save 只收 <registry>/supabase/*
rm -f "$tar"
run save; rc=$?
expect_exit 0 "$rc" '④ save → exit 0'
want_save="save -o ${tar} public.ecr.aws/supabase/postgres:17.6.1.159 public.ecr.aws/supabase/realtime:v2.129.0 public.ecr.aws/supabase/storage-api:v1.69.11 public.ecr.aws/supabase/gotrue:v2.195.0"
got_save=$(grep '^save' "$work/calls")
[ "$got_save" = "$want_save" ] && ok '④ docker save 恰好收 4 個 public.ecr.aws/supabase 映像（整行相等）' || fail "④ docker save 參數不符：${got_save}"
for neg in 'ghcr.io/supabase' 'mirror.example' '<none>' 'ubuntu'; do
  expect_not_has "$(grep '^save' "$work/calls")" "$neg" "④ save 不收「${neg}」"
done
[ -s "$tar" ] && ok '④ 寫出 tar 給 actions/cache/save' || fail '④ 沒寫出 tar'
expect_has "$(cat "$work/out")" '已 docker save 4 個映像' '④ 印存了幾個映像'

# ④b docker save 失敗 → warning、不留半截 tar
rm -f "$tar"
run save "$script" FAKE_SAVE_RC=1; rc=$?
expect_exit 0 "$rc" '④b docker save 失敗 → exit 0'
expect_has "$(cat "$work/out")" '::warning::db-image-cache：docker save 失敗' '④b 印 ::warning::'
[ -e "$tar" ] && fail '④b save 失敗不應留下 tar' || ok '④b save 失敗不留 tar'

# ⑤ 無可存映像
for f in images-none images-other; do
  rm -f "$tar"
  FAKE_IMAGES="$work/$f" run save; rc=$?
  expect_exit 0 "$rc" "⑤ ${f}：無 supabase 映像 → exit 0"
  expect_has "$(cat "$work/out")" "::warning::db-image-cache：本機沒有 public.ecr.aws/supabase/ 映像可存" "⑤ ${f}：印 ::warning::"
  expect_not_has "$(calls)" 'save' "⑤ ${f}：不呼叫 docker save"
  [ -e "$tar" ] && fail "⑤ ${f}：不應寫 tar" || ok "⑤ ${f}：不寫 tar"
done

# ⑥ 環境／參數錯
: > "$work/calls"
env FAKE_LOG="$work/calls" FAKE_IMAGES="$work/images-all" PATH="$work/bin:$PATH" SUPABASE_INTERNAL_IMAGE_REGISTRY= \
  bash "$script" save "$tar" > "$work/out" 2>&1; rc=$?
expect_exit 2 "$rc" '⑥ SUPABASE_INTERNAL_IMAGE_REGISTRY 未設 → exit 2'
[ -s "$work/calls" ] && fail '⑥ registry 未設時不應呼叫 docker' || ok '⑥ registry 未設時不呼叫 docker'
bash "$script" bogus "$tar" > /dev/null 2>&1; expect_exit 2 "$?" '⑥ 未知模式 → exit 2'
SUPABASE_INTERNAL_IMAGE_REGISTRY=public.ecr.aws bash "$script" load > /dev/null 2>&1; expect_exit 2 "$?" '⑥ 缺 <tar> → exit 2'

# ⑦ mutation：拿掉 registry 過濾 → save 收進無關映像
mut="$work/mut.sh"
sed 's/^    | awk .*# DB-IMAGE-FILTER$/    | cat   # LS-392 mutation/' "$script" > "$mut"
if ! grep -q 'LS-392 mutation' "$mut"; then
  fail '⑦ mutant 沒被正確合成（DB-IMAGE-FILTER 行未替換到）'
else
  rm -f "$tar"
  run save "$mut"
  if grep '^save' "$work/calls" | grep -qF 'ubuntu:24.04'; then
    ok '⑦ mutant（拿掉 registry 過濾）：save 收進 ubuntu 等無關映像——④ 的負向斷言會紅'
  else
    fail '⑦ mutant 未收進無關映像——④ 沒咬住過濾那行'
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ db-image-cache 自測失敗" >&2
  exit 1
fi
echo "✓ db-image-cache 自測通過"
