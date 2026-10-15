#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 从工作树反向导出改动
#
# 场景：你在 upstream/ 里直接改了某个文件，调通之后想把改动固化成补丁，
#       纳入项目的补丁集管理。
#
# 注意：改设备树不需要用它 —— 直接编辑 project/dts/imx6ull-atk-mmc.dts 即可。
#
# 用法:
#   ./scripts/export-changes.sh                      查看当前有哪些改动
#   ./scripts/export-changes.sh 0004-xxx <路径...>   导出成补丁
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
PATCHES="$ROOT/project/patches"

# submodule 的 .git 是指向 .git/modules/upstream 的「文件」，不是目录，
# 因此用 -e 而不是 -d 判断。
[ -e "$UPSTREAM/.git" ] || { echo "upstream/ 尚未初始化，先跑 scripts/bootstrap.sh" >&2; exit 1; }
cd "$UPSTREAM"

if [ $# -eq 0 ]; then
  echo "upstream/ 当前的工作区改动："
  echo
  # fileMode=false: 通过 9p/网络文件系统访问时执行位读不准，会刷出满屏假改动
  git -c core.fileMode=false status --short
  echo
  echo "导出方式: ./scripts/export-changes.sh <补丁名> <路径> [更多路径...]"
  exit 0
fi

NAME="$1"; shift
[ $# -gt 0 ] || { echo "缺少要导出的路径" >&2; exit 1; }

case "$NAME" in
  *.patch) OUT="$PATCHES/$NAME" ;;
  *)       OUT="$PATCHES/$NAME.patch" ;;
esac

[ -e "$OUT" ] && { echo "已存在: $OUT（请换个名字）" >&2; exit 1; }

git -c core.fileMode=false diff -- "$@" > "$OUT"

if [ ! -s "$OUT" ]; then
  rm -f "$OUT"
  echo "指定的路径没有改动，未生成补丁" >&2
  exit 1
fi

echo "已导出: $OUT"
echo
echo "接下来："
echo "  1. 把「$(basename "$OUT")」那行追加到 project/patches/series"
echo "  2. ./scripts/check-patches.sh    # 确认 hunk 计数无误"
echo "  3. ./scripts/setup.sh            # 从基线重放全部补丁"
