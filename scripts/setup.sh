#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 初始化
#
# 作用：把上游 OpenWrt 子树重置到固定基线，然后重放本工程的全部定制
#       （补丁集 → 接管文件删除 → 出树 DTS 校验 → defconfig → 目录归属），
#       最后断言配置有效。
#
# 上游通过 Git Submodule 引入（openwrt/openwrt，锁定在 BASE_COMMIT）。
# 本仓库因此不携带任何上游源码，克隆后由 bootstrap.sh 一次性拉取。
#
# 可重复执行：每次都从基线重放，结果是确定性的。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
PROJECT="$ROOT/project"

# 官方 OpenWrt 基线。正点原子的全部平台定制已导出为 project/patches/0100-0114，
# 所以这里直接用官方仓库，不依赖任何第三方分支。
BASE_COMMIT="${BASE_COMMIT:-0844937947ec1c9124dbb332b5fb5d1e3616b1e2}"

# 目录归属：下载缓存与构建产物都放在工程根目录下、upstream/ 之外。
# 依据是 OpenWrt 官方对 CONFIG_DOWNLOAD_FOLDER 的说明 —— dl 若留在树内，
# 会被 'git clean -xdf' / 'make distclean' 一并删除。
PROJ_DL="${PROJ_DL:-$ROOT/dl}"
PROJ_OUT="${PROJ_OUT:-$ROOT/out}"

DEVICE_SYMBOL="CONFIG_TARGET_imx_cortexa7_DEVICE_imx6ull-atk-mmc=y"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# WSL 会把 Windows 的 PATH 注入 Linux PATH，其中含空格的条目（C:\Program Files\...）
# 在传递过程中会被拆出裸的相对路径片段（典型是 "Files"）。GNU find 在执行
# -execdir 前会校验 PATH 每一项必须是绝对路径，否则直接报错退出 —— 这会让
# OpenWrt 的 include/rootfs.mk 做时间戳归一化时失败，进而 package/install 中断。
# 这里只保留绝对路径条目，不修改用户的 shell 配置。
# ---------------------------------------------------------------------------
P="$(printf '%s' "$PATH" | tr ':' '\n' | grep '^/' | paste -sd: || true)"
[ -n "$P" ] && export PATH="$P"

# ---------------------------------------------------------------------------
log "检查上游子树"
# submodule 的 .git 是一个指向 .git/modules/upstream 的「文件」，
# 因此这里用 -e 而不是 -d 判断。
if [ ! -e "$UPSTREAM/.git" ] || [ ! -f "$UPSTREAM/rules.mk" ]; then
  log "  尚未初始化，调用 scripts/bootstrap.sh"
  "$ROOT/scripts/bootstrap.sh"
fi

log "  重置到基线 ${BASE_COMMIT:0:12}"
git -C "$UPSTREAM" checkout --quiet --force "$BASE_COMMIT" \
  || die "基线 $BASE_COMMIT 不存在（先运行 scripts/bootstrap.sh）"
# -e feeds：feeds/ 里是 scripts/feeds.sh 拉下来的外部 feed 仓库（约 200 MB），
# 它不在上游 git 的版本控制内、但在 .gitignore 里，所以会被 -x 一起清掉。
# 排除掉它，feeds 就能跨多次重置保留，不必每次重下。
# 注意写法必须是 `-e feeds`，带前导斜杠的 `-e /feeds` 在 git clean 里不生效。
git -C "$UPSTREAM" clean --quiet -fdx -e feeds -e feeds.conf
ok "$(git -C "$UPSTREAM" log -1 --format='%h %s')"

# ---------------------------------------------------------------------------
log "隔离构建产物，让 git status 只反映真实改动"
# submodule 的 git 目录在父仓库的 .git/modules/upstream 下，
# 直接写 $UPSTREAM/.git/info/exclude 会失败（.git 是文件），所以先问 git 要路径。
GITDIR="$(git -C "$UPSTREAM" rev-parse --absolute-git-dir)"
EXCLUDE="$GITDIR/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"
if ! grep -q 'atk-imx6ull-openwrt' "$EXCLUDE" 2>/dev/null; then
  printf '%s\n' "# atk-imx6ull-openwrt 构建产物与本地缓存" >> "$EXCLUDE"
fi
for e in /bin /build_dir /staging_dir /tmp /feeds /dl /.config /.config.old /.config.orig '/*.log'; do
  grep -qxF "$e" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$e" >> "$EXCLUDE"
done
ok "写入 $EXCLUDE"

# ---------------------------------------------------------------------------
log "应用补丁集"
count=0
while read -r name _; do
  [ -n "${name:-}" ] || continue
  case "$name" in \#*) continue ;; esac
  f="$PROJECT/patches/$name"
  [ -f "$f" ] || die "补丁文件不存在: $f"

  # 用 git apply 而不是 patch(1)：补丁集中含二进制段（文档配图），
  # 只有 git 的二进制补丁格式能被正确重建。
  if ! git -C "$UPSTREAM" apply --check "$f" 2>/dev/null; then
    die "补丁无法应用（上游可能已变更）: $name
  排查: cd $UPSTREAM && git apply --check -v $f"
  fi
  git -C "$UPSTREAM" apply "$f"
  count=$((count + 1))
done < "$PROJECT/patches/series"
ok "$count 个补丁已应用"

# ---------------------------------------------------------------------------
log "移除由本工程接管的文件"
removed=0
while read -r path _; do
  [ -n "${path:-}" ] || continue
  case "$path" in \#*) continue ;; esac
  if [ -e "$UPSTREAM/$path" ]; then
    rm -f "$UPSTREAM/$path"
    ok "已删除 $path"
    removed=$((removed + 1))
  fi
done < "$PROJECT/remove.txt"
[ "$removed" -gt 0 ] || ok "无需删除（remove.txt 中列出的文件都不存在）"

# ---------------------------------------------------------------------------
log "检查出树 DTS"
DTS_FILE="$PROJECT/dts/imx6ull-atk-mmc.dts"
[ -f "$DTS_FILE" ] || die "缺少 $DTS_FILE"
grep -q 'no-1-8-v'      "$DTS_FILE" || die "DTS 缺少 no-1-8-v（抑制 1.8V 电平切换）"
grep -q 'max-frequency' "$DTS_FILE" || die "DTS 缺少 max-frequency"
ok "$(wc -l < "$DTS_FILE") 行，SD 卡相关属性就位"

# ---------------------------------------------------------------------------
log "安装配置并生成 .config"
cp "$PROJECT/config/atk_imx6ull_defconfig" "$UPSTREAM/.config"
cd "$UPSTREAM"
make defconfig >/dev/null 2>&1 || die "make defconfig 失败"

grep -q "^${DEVICE_SYMBOL}$" .config || die "设备未被选中: ${DEVICE_SYMBOL}
  这说明 defconfig 里的设备名与 target/linux/imx/image/cortexa7.mk 里
  define Device/<name> 的名字对不上 —— 参考历史上 imx6ull-atk-emmc 改名后
  漏改 defconfig 导致的「编译成功但没有镜像」事故。"
ok "设备已选中: imx6ull-atk-mmc"

grep -q '^CONFIG_TARGET_imx_cortexa7=y$' .config || die "CONFIG_TARGET_imx_cortexa7 未启用"
ok "目标已选中: imx/cortexa7"

# ---------------------------------------------------------------------------
# luci / ttyd 这类包不在 OpenWrt 核心仓库里，而在 feeds 里（见 scripts/feeds.sh）。
# feeds 未安装时，这些 CONFIG_PACKAGE_* 符号在 kconfig 里根本不存在，上面那次
# `make defconfig` 会把它们**静默丢弃** —— 表现就是「配置里写着要 LuCI，
# 编出来的固件却没有 web 界面」。这与「设备未被选中」属于同一类静默失败，
# 所以在这里显式拦住。确实不需要 LuCI 时用 SKIP_FEEDS_CHECK=1 跳过。
if grep -qE '^CONFIG_PACKAGE_luci=y$' "$PROJECT/config/atk_imx6ull_defconfig"; then
  if [ -e "$UPSTREAM/package/feeds/luci/luci-base" ]; then
    grep -qE '^CONFIG_PACKAGE_luci=y$' .config \
      || die "feeds 已安装，但 luci 仍未进入 .config，请检查 upstream/feeds.conf 里 luci 一行的地址与分支"
    ok "LuCI 已生效（feeds 已安装）"
  elif [ "${SKIP_FEEDS_CHECK:-0}" = "1" ]; then
    printf '\033[1;33m警告: feeds 未安装，LuCI 将被丢弃（SKIP_FEEDS_CHECK=1，已跳过检查）。\033[0m\n'
  else
    die "defconfig 启用了 LuCI，但 feeds 未安装 —— make defconfig 已丢弃这些符号，
  本次构建不会包含 web 管理界面。

  修复:
      ./scripts/feeds.sh      # 拉取 feeds（首次约 200 MB）
      ./scripts/setup.sh      # 重跑，让 luci 符号进入 .config

  确实不需要 LuCI 时: SKIP_FEEDS_CHECK=1 ./scripts/setup.sh"
  fi
fi

# ---------------------------------------------------------------------------
log "写入目录归属（下载缓存 / 构建产物）"
# CONFIG_DOWNLOAD_FOLDER 与 CONFIG_BINARY_FOLDER 定义在 config/Config-devel.in，
# 受 CONFIG_DEVEL 门控；本工程的 defconfig 已带 CONFIG_DEVEL=y，因此可写。
set_cfg() {
  local sym="$1" val="$2"
  if grep -q "^${sym}=" .config; then
    sed -i "s|^${sym}=.*|${sym}=\"${val}\"|" .config
  else
    printf '%s="%s"\n' "$sym" "$val" >> .config
  fi
}
set_cfg CONFIG_DOWNLOAD_FOLDER "$PROJ_DL"
set_cfg CONFIG_BINARY_FOLDER   "$PROJ_OUT"
make defconfig >/dev/null 2>&1 || die "make defconfig 失败"

if grep -q "^CONFIG_DOWNLOAD_FOLDER=\"${PROJ_DL}\"$" .config; then
  ok "CONFIG_DOWNLOAD_FOLDER = $PROJ_DL"
else
  log "  注意: kconfig 未保留 CONFIG_DOWNLOAD_FOLDER，fetch.sh/build.sh 会用命令行覆盖"
fi
if grep -q "^CONFIG_BINARY_FOLDER=\"${PROJ_OUT}\"$" .config; then
  ok "CONFIG_BINARY_FOLDER   = $PROJ_OUT"
else
  log "  注意: kconfig 未保留 CONFIG_BINARY_FOLDER，build.sh 会用命令行覆盖"
fi

# make val.<VAR> 是 OpenWrt 自带的变量求值入口（rules.mk 里的 val.% 规则），
# 用它回读 make 内部算出的真实路径，不必靠猜。
log "  生效路径（make 侧回读）"
for v in DL_DIR OUTPUT_DIR BIN_DIR; do
  printf '       %-11s = %s\n' "$v" \
    "$(make -s "val.$v" 2>/dev/null || echo '(取不到)')"
done

# ---------------------------------------------------------------------------
log "准备源码包缓存（$PROJ_DL）"
mkdir -p "$PROJ_DL"
if [ -z "$(ls -A "$PROJ_DL" 2>/dev/null || true)" ]; then
  # 播种来源（按顺序尝试）：显式指定 → 迁移过渡期的旧树 → 历史遗留工程
  for src in "${DL_CACHE:-}" "$ROOT/upstream.old/dl" "$HOME/imx6ull_openwrt/dl"; do
    [ -n "$src" ] && [ -d "$src" ] || continue
    log "  从 $src 播种（硬链接，秒级完成）"
    cp -al "$src/." "$PROJ_DL/" 2>/dev/null || cp -a "$src/." "$PROJ_DL/"
    break
  done
fi
ok "$(ls -1 "$PROJ_DL" 2>/dev/null | wc -l) 个源码包"

echo
printf '\033[1;32m初始化完成。\033[0m下一步:\n\n'
printf '  1) 取源码包（首次需要，约 700 MB。若 dl/ 已由本机缓存播种则可跳过）\n'
printf '       ./scripts/fetch.sh\n\n'
printf '  2) 构建\n'
printf '       ./scripts/build.sh\n\n'
printf '产物会落在 %s/targets/imx/cortexa7/\n\n' "$PROJ_OUT"
