#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 补丁自检
#
# 逐个 hunk 比对 @@ 声明行数与实际内容行数是否一致。
#
# 为什么需要它：手工在补丁中间增删行、却忘记同步 hunk 头时，patch 工具会
# 严格按「声明的行数」读取，多出来的内容被静默丢弃 —— 生成的文件在末尾被
# 截断，表现为「最后一行语法错误」这类看似离奇的报错。
# 本项目历史上就因此挂过一次（DTS 的 &wdog1 节点被截掉尾巴）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"

command -v "$PY" >/dev/null 2>&1 || {
  echo "找不到 $PY；可用 PYTHON=<路径> 指定解释器" >&2
  exit 1
}

echo "检查生效的补丁（依据 project/patches/series）"
echo
"$PY" "$ROOT/scripts/check_patch.py" --series "$ROOT/project/patches/series"

# 目录里存在、但没有被 series 引用的补丁 —— 通常是改名或重构后的遗留物。
# 它们不参与构建，但会让 self-check 的结论变得含混（例如扫到已被取代的旧补丁）。
ORPHAN=""
for f in "$ROOT/project/patches"/*.patch; do
  [ -e "$f" ] || continue
  n="$(basename "$f")"
  grep -qE "^[[:space:]]*${n//./\\.}[[:space:]]*$" "$ROOT/project/patches/series" || \
    ORPHAN="$ORPHAN$n"$'\n'
done
if [ -n "$ORPHAN" ]; then
  echo
  echo "注意: 以下补丁未被 series 引用（不参与构建，建议删除）："
  printf '%s' "$ORPHAN" | sed 's/^/      /'
fi

# 上游自带的 imx 内核补丁也扫一遍 —— 401 那类事故就是发生在这里
UP_PATCHES="$ROOT/upstream/target/linux/imx/patches-5.15"
if [ -d "$UP_PATCHES" ]; then
  echo
  echo "检查 $UP_PATCHES"
  "$PY" "$ROOT/scripts/check_patch.py" --dir "$UP_PATCHES"
fi
