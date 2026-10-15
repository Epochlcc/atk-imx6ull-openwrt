#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 构建
#
# 用法:
#   ./scripts/build.sh                          完整构建（等价于 make world）
#   ./scripts/build.sh target/linux/compile     只编内核
#   ./scripts/build.sh target/linux/dtb         只编设备树（快速检查点，不用编整个内核）
#   ./scripts/build.sh package/kernel/rtl8188eu/compile
#   JOBS=4 ./scripts/build.sh                   限制并行度
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
DL="${PROJ_DL:-$ROOT/dl}"
OUT="${PROJ_OUT:-$ROOT/out}"
LOG="$OUT/build.log"
BIN="$OUT/targets/imx/cortexa7"
JOBS="${JOBS:-$(nproc)}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  注意\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$UPSTREAM/Makefile" ] || die "$UPSTREAM 不是 OpenWrt 源码树，请先运行 scripts/setup.sh"
[ -f "$UPSTREAM/.config" ]  || die "缺少 .config，请先运行 scripts/setup.sh"

# ---------------------------------------------------------------------------
# PATH 加固（WSL 专属问题，会直接搞挂 package/install）
#
# WSL 会把 Windows 的 PATH 注入 Linux PATH。关键在于 OpenWrt 自己的
# rules.mk:162 会这样处理 PATH：
#     TARGET_PATH := $(subst $(space),:,$(...$(subst :,$(space),$(PATH))))
# 即「冒号→空格」再「空格→冒号」——后果是 **任何含空格的 PATH 条目都会被拆开**。
# 于是 C:\Program Files 这类条目被拆出一个裸的 "Files"，而 GNU find 执行
# -execdir 时要求 PATH 每一段都是绝对路径，直接报错退出：
#     find: The relative path 'Files' is included in the PATH environment variable...
# 它会让 include/rootfs.mk 的时间戳归一化失败 → package/install 中断，
# 而此时全部包其实已经编译完了（通常已经跑了半小时）。
#
# 所以这里必须把两类条目都丢掉：
#   1) 不以 / 开头的（相对路径）
#   2) 含空白字符的（会被 rules.mk 拆成多段）
# 不改动用户的 shell 配置，只影响本次构建进程。
# ---------------------------------------------------------------------------
_dropped="$(printf '%s' "$PATH" | tr ':' '\n' | grep -Ev '^/[^[:space:]]+$' || true)"
P="$(printf '%s' "$PATH" | tr ':' '\n' | grep -E '^/[^[:space:]]+$' | paste -sd: || true)"
if [ -n "$_dropped" ]; then
  warn "已从本次构建的 PATH 中移除 $(printf '%s\n' "$_dropped" | wc -l) 个不安全条目（WSL 互操作注入）："
  printf '%s\n' "$_dropped" | sed 's/^/         /'
fi
[ -n "$P" ] || die "过滤后 PATH 为空；请用 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin 前缀运行"
export PATH="$P"

# 功能性子预检：直接验证 find -execdir 能不能用（就是失败点的那个动作）。
# 通过 = 不会再跑到 package/install 才挂；不通过 = 立刻停下，不浪费半小时。
cd "$UPSTREAM"
if find . -maxdepth 0 -execdir true {} + >/dev/null 2>&1; then
  ok "PATH 安全检查通过（find -execdir 可用）"
else
  die "PATH 仍含不安全条目，find -execdir 会失败。请改用：
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ./scripts/build.sh"
fi

# 编译前先确认设备仍然被选中 —— 这个检查能挡住「编了一场却没有镜像」的情况
grep -q '^CONFIG_TARGET_imx_cortexa7_DEVICE_imx6ull-atk-mmc=y$' "$UPSTREAM/.config" \
  || die "设备 imx6ull-atk-mmc 未被选中，请重跑 scripts/setup.sh"

# luci / ttyd 来自 feeds。缺 feeds 时 .config 里不会有这些符号，固件也就没有
# web 管理界面 —— 这里提醒一次，避免编完才发现。
if [ ! -e "$UPSTREAM/package/feeds/luci/luci-base" ]; then
  warn "feeds 未安装，本次构建不包含 LuCI（web 管理界面）。"
  printf '      需要的话: ./scripts/feeds.sh && ./scripts/setup.sh\n\n'
fi

mkdir -p "$OUT" "$DL"

log "开始构建（并行度 $JOBS，日志追加到 $LOG）"
printf '       %-11s = %s\n' DL_DIR     "$(make -s val.DL_DIR     2>/dev/null || echo '?')"
printf '       %-11s = %s\n' OUTPUT_DIR "$(make -s val.OUTPUT_DIR 2>/dev/null || echo '?')"
echo

# DL_DIR / OUTPUT_DIR 同时用命令行传入：.config 里已经写过，但命令行可以保证
# 即使 .config 之后被 menuconfig 等操作重写，路径也不会漂回 upstream/ 内部。
# 两处取值完全相同，因此不存在不一致的风险。
make -j"$JOBS" V=s \
  DL_DIR="$DL" \
  OUTPUT_DIR="$OUT" \
  "$@" 2>&1 | tee -a "$LOG"

echo
log "构建结束，检查产物"
if ls "$BIN"/*.bin >/dev/null 2>&1; then
  ls -lh "$BIN"/*.bin
  echo
  echo "烧 SD 卡用这个（combined.bin，含 U-Boot，直接写整盘）："
  ls -1 "$BIN"/*combined.bin
  echo
  echo "结构验证（不需要硬件，也不需要额外脚本）：见 VERIFY.md 阶段 5 ——"
  echo "用 file / fdisk / xxd / sha256sum / dtc 逐条核对。最关键的一条："
  echo
  echo "  DTB=\$(ls $UPSTREAM/build_dir/target-*/linux-imx_cortexa7/image-imx6ull-atk-mmc.dtb)"
  echo "  sha256sum \$DTB        # 期望 3632108c7f28ac626cb0b5b76b1fa444caaea259ebb59ded505dd2139b572e0c"
  echo "  $UPSTREAM/staging_dir/host/bin/dtc -I dtb -O dts \$DTB \\"
  echo "    | grep -A12 'mmc@2190000'    # 期望看到 no-1-8-v 与 max-frequency"
else
  die "没有生成 .bin 文件，请检查 $LOG"
fi
