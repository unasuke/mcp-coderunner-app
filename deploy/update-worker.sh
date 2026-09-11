#!/bin/sh
# ワーカーを origin/main に合わせて入れ替える。root で実行する。
#
#   sudo /opt/mcp-coderunner-app/deploy/update-worker.sh
#
# bundle install は要らない。ワーカーは stdlib だけで書かれているので、
# ファイルを置き換えて再起動すれば済む。
#
# 走っているジョブは再起動で中断されるが、終了処理が /deregister を打つので
# 試行回数を消費せずキューへ戻る。次に立ち上がったワーカーが拾い直す。
set -eu

CHECKOUT="${CHECKOUT:-/opt/mcp-coderunner-app}"
BRANCH="${BRANCH:-main}"
UNIT="${UNIT:-mcp-coderunner-app-worker}"

cd "$CHECKOUT"

before="$(git rev-parse --short HEAD)"

git fetch --prune origin
# pull ではなく reset。手元に差分が残っていても結果が一意になる
git reset --hard "origin/${BRANCH}"

after="$(git rev-parse --short HEAD)"

if [ "$before" = "$after" ]; then
  echo "既に ${after} です。再起動だけ行います"
fi

# 書き忘れると /admin/workers の「ずれ」表示が嘘になる
git rev-parse HEAD > REVISION

running="$(docker ps -q --filter label=mcp-coderunner-app.job | wc -l)"
if [ "$running" -gt 0 ]; then
  echo "実行中のジョブ ${running} 件を中断します（キューへ戻ります）"
fi

systemctl restart "$UNIT"

echo "${before} -> ${after} で再起動しました"
systemctl --no-pager --lines=0 status "$UNIT" || true
