#!/bin/bash
# db-image-cache.sh — CI `db` job 的 supabase 映像快取（docker load／docker save 那一半；actions/cache 的 restore／save
# 由 ci.yml 負責），LS-392。
#
# 來源：09-28 一日三次（run 36363735578 main push、36371133062 development tip、36378063655 #556）`supabase db start`
# 拉 `public.ecr.aws/supabase/postgres:17.6.1.159` 撞 `toomanyrequests: Data limit exceeded`——ECR Public 匿名拉取有
# 資料量上限，GitHub runner 共用出口，重試 3 次仍紅、每次人工 rerun 30–60 分。db start 一次要拉 postgres／realtime／
# storage-api／gotrue 四個映像（約 3.8 GB 解壓後），快取命中就完全不碰 registry。
#
# 為何可行：supabase CLI 拉映像前先查本機是否已有同名映像（有就不拉）——實測成功 run（job 108755255247）的
# `db reset` 步驟沿用 db start 已拉的映像，log 沒有任何 `Pulling from`。docker save／load 保留 repo:tag，
# load 回來的名字與 CLI 要的一致（`<SUPABASE_INTERNAL_IMAGE_REGISTRY>/supabase/<name>:<tag>`）。
#
# 用法：
#   db-image-cache.sh load <tar>   actions/cache 還原後呼叫：<tar> 存在＝cache hit → docker load（成功後刪 tar 省磁碟），
#                                  印「cache hit」與載入的映像；不存在＝cache miss，印「將由 <registry> 拉取」。
#                                  docker load 失敗 → ::warning:: 後 exit 0（CLI 會照常從 registry 拉，快取問題不擋
#                                  required check；db-start-retry 的「映像來源」行會顯示這次有拉取）。
#   db-image-cache.sh save <tar>   db start 成功且 cache miss 時呼叫：把本機 `<registry>/supabase/*` 映像 docker save
#                                  成 <tar> 給 actions/cache/save 寫回。找不到映像或 docker save 失敗 → ::warning::
#                                  後 exit 0（不寫 tar；actions/cache/save 會因路徑不存在略過）。
# 需要 SUPABASE_INTERNAL_IMAGE_REGISTRY（ci.yml 寫進 $GITHUB_ENV）；未設 → exit 2（不猜 registry）。
# exit：0＝完成（含上述 warning 降級）；2＝參數／環境錯。
# 自測：scripts/ci/db-image-cache.test.sh（PATH 前置假 docker，掛 CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

mode=${1:-}; tar=${2:-}
case "$mode" in
  load|save) ;;
  *) echo "✗ db-image-cache：用法 db-image-cache.sh load|save <tar>" >&2; exit 2 ;;
esac
[ -n "$tar" ] || { echo "✗ db-image-cache：缺 <tar> 路徑" >&2; exit 2; }
registry=${SUPABASE_INTERNAL_IMAGE_REGISTRY:-}
[ -n "$registry" ] || { echo "✗ db-image-cache：SUPABASE_INTERNAL_IMAGE_REGISTRY 未設——無法判定要快取哪些映像" >&2; exit 2; }

# 本機屬於 <registry>/supabase/ 的映像（repo:tag，一行一個）
supabase_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | awk -v p="${registry}/supabase/" 'index($0, p) == 1 && $0 !~ /:<none>$/'   # DB-IMAGE-FILTER
}

if [ "$mode" = load ]; then
  if [ ! -f "$tar" ]; then
    echo "db-image-cache：cache miss——映像將由 ${registry} 拉取；db start 成功後 docker save 寫回快取"
    exit 0
  fi
  if ! docker load -i "$tar"; then
    echo "::warning::db-image-cache：cache hit 但 docker load 失敗——改由 ${registry} 拉取（快取檔可能損毀，key 變更後自然汰換）"
    rm -f "$tar"
    exit 0
  fi
  rm -f "$tar"
  imgs=$(supabase_images || true)
  n=$(printf '%s' "$imgs" | grep -c . || true)
  echo "db-image-cache：cache hit——docker load 載入 ${n} 個映像（actions/cache，不走 ${registry}）"
  printf '%s\n' "$imgs" | sed 's/^/  /'
  exit 0
fi

imgs=$(supabase_images || true)
if [ -z "$imgs" ]; then
  echo "::warning::db-image-cache：本機沒有 ${registry}/supabase/ 映像可存——不寫快取（db start 拉的映像名與 registry 不符？）"
  exit 0
fi
mkdir -p "$(dirname "$tar")"
# shellcheck disable=SC2086  # 映像名不含空白，逐一展開成 docker save 的參數
if ! docker save -o "$tar" $imgs; then
  echo "::warning::db-image-cache：docker save 失敗——這次不寫快取"
  rm -f "$tar"
  exit 0
fi
n=$(printf '%s\n' "$imgs" | grep -c .)
echo "db-image-cache：已 docker save ${n} 個映像 → ${tar}（$(du -h "$tar" | cut -f1)），交 actions/cache/save 寫回"
printf '%s\n' "$imgs" | sed 's/^/  /'
