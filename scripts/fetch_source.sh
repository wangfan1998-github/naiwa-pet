#!/bin/bash
# 下载原版奶蛙大笑视频（B 站 BV1JBuB6PEMF《奶蛙大笑（额外扩展版）》，简介写明视频与音频源于网络）
#   scripts/fetch_source.sh [BV 号] → build/src/laugh_ext_480.mp4
# 不登录只能拿到 480P。B 站网页会对没有访客 cookie 的请求回 412，所以先领一个 buvid3 再调接口。
set -euo pipefail
cd "$(dirname "$0")/.."
BV=${1:-BV1JBuB6PEMF}
OUT=build/src/laugh_ext_480.mp4
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p build/src

api() { curl -fsS -m 30 -A "$UA" -H "Referer: https://www.bilibili.com/" -b "buvid3=$BUVID" "$1"; }
BUVID=$(curl -fsS -m 30 -A "$UA" https://api.bilibili.com/x/frontend/finger/spi | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["b_3"])')
CID=$(api "https://api.bilibili.com/x/web-interface/view?bvid=$BV" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["cid"])')
api "https://api.bilibili.com/x/player/playurl?bvid=$BV&cid=$CID&qn=80&fnval=16" > "$TMP/play.json"
# 每个分片有主地址和几个备用地址，有的 CDN 节点会回 567，挨个试
urls() {
    python3 - "$TMP/play.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["data"]["dash"]
best = max(d["video"], key=lambda x: (x["height"], x["bandwidth"])) if sys.argv[2] == "video" else max(d["audio"], key=lambda x: x["bandwidth"])
for u in [best["baseUrl"], *(best.get("backupUrl") or [])]:
    print(u)
PY
}
fetch() {
    while read -r u; do
        curl -fsS -m 300 -A "$UA" -H "Referer: https://www.bilibili.com/" -o "$2" "$u" && return 0
    done < <(urls "$1")
    echo "下载 $1 失败" >&2
    return 1
}
fetch video "$TMP/v.m4s"
fetch audio "$TMP/a.m4s"
ffmpeg -v error -y -i "$TMP/v.m4s" -i "$TMP/a.m4s" -c copy "$OUT"
echo "${OUT}（$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$OUT")）"
