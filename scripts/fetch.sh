#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 下载源码包
#
# 把所有外部源码包（Linux 内核、U-Boot、各软件包源码）取到本工程的 dl/ 目录。
#
# 目录归属：下载位置由 .config 的 CONFIG_DOWNLOAD_FOLDER 决定，setup.sh 已把它指向
# <工程根>/dl。这不是权宜之计 —— OpenWrt 官方在 config/Config-devel.in 里对该选项的
# 说明原文是：「若不设置则默认为 './dl'，而它会被 'git clean -xdf' 或
# 'make distclean' 一并删除；把路径设到树外可以让下载内容得以保留。」
# 因此 dl/ 放在工程根目录、位于 upstream/ 之外，是一次真正的修复。
#
# 可重复执行：scripts/download.pl 对「已存在」的文件也会重算哈希并与包声明的
# PKG_HASH / PKG_MIRROR_HASH 比对，所以重跑一次等价于对 dl/ 做一次全量哈希审计。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
DL="${PROJ_DL:-$ROOT/dl}"
LOG="$ROOT/out/fetch.log"
JOBS="${JOBS:-$(nproc)}"

# 播种来源（按顺序尝试）：显式指定的 DL_CACHE → 迁移过渡期的旧树 →
# 历史遗留的本机工程。dl/ 里放的是第三方源码包的原始压缩包，
# 复用它们纯粹是省流量，与上游代码来源无关。
SEED_SOURCES=("${DL_CACHE:-}" "$ROOT/upstream.old/dl" "$HOME/imx6ull_openwrt/dl")

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  注意\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$UPSTREAM/Makefile" ] || die "$UPSTREAM 不是 OpenWrt 源码树，请先运行 scripts/setup.sh"
[ -f "$UPSTREAM/.config" ]  || die "缺少 .config，请先运行 scripts/setup.sh"

# ---------------------------------------------------------------------------
# WSL 会把 Windows 的 PATH 注入 Linux PATH，其中含空格的条目（C:\Program Files\...）
# 在传递过程中会被拆出裸的相对路径片段（典型是 "Files"）。GNU find 执行 -execdir 前
# 会校验 PATH 每一项必须是绝对路径，否则直接报错退出。这里只保留绝对路径条目，
# 不改动用户的 shell 配置。
# ---------------------------------------------------------------------------
P="$(printf '%s' "$PATH" | tr ':' '\n' | grep '^/' | paste -sd: || true)"
[ -n "$P" ] && export PATH="$P"

mkdir -p "$ROOT/out" "$DL"

# ---------------------------------------------------------------------------
# 1) 播种：若有可用缓存，用硬链接搬进来（秒级，几乎不占额外空间）
if [ -n "$(ls -A "$DL" 2>/dev/null || true)" ]; then
  ok "dl 已有 $(ls -1 "$DL" | wc -l) 个文件，跳过播种"
else
  seeded=0
  for src in "${SEED_SOURCES[@]}"; do
    [ -n "$src" ] && [ -d "$src" ] || continue
    log "从 $src 播种（硬链接）"
    cp -al "$src/." "$DL/" 2>/dev/null || cp -a "$src/." "$DL/"
    ok "$(ls -1 "$DL" | wc -l) 个文件"
    seeded=1
    break
  done
  [ "$seeded" -eq 1 ] || \
    log "dl 为空，将从网络下载全部源码包（约 700 MB，视网速可能需要较久）"
fi

# ---------------------------------------------------------------------------
# 2) 报告生效路径
#    make val.<VAR> 是 OpenWrt 自带的变量求值入口（rules.mk 里的 val.% 规则），
#    用它可以直接读到 make 内部按 .config 算出的真实路径，不必靠猜。
# ---------------------------------------------------------------------------
log "生效路径"
VALS="$(cd "$UPSTREAM" && make -s val.DL_DIR val.OUTPUT_DIR 2>/dev/null || true)"
printf '    %-11s = %s\n' DL_DIR     "$(printf '%s\n' "$VALS" | sed -n 1p)"
printf '    %-11s = %s\n' OUTPUT_DIR "$(printf '%s\n' "$VALS" | sed -n 2p)"
printf '    %-11s = %s  (本脚本以命令行传入，优先级高于 .config)\n' DL_DIR_实际 "$DL"

# ---------------------------------------------------------------------------
# 3) 下载
#    用 -k（keep going）而不是默认的「遇错即停」：历史上 make download -j1 在
#    rtl8188eu 处中断，导致后面所有包（连同 uci/ubus 这些基础包）根本没被尝试，
#    看起来「只有一个包缺失」。加上 -k 可以一次列出全部缺包。
# ---------------------------------------------------------------------------
echo
log "开始下载（-j$JOBS -k，日志追加到 $LOG）"
echo

rc=0
set +e
make -k -j"$JOBS" V=s DL_DIR="$DL" download 2>&1 | tee -a "$LOG"
rc="${PIPESTATUS[0]}"
set -e
echo

# ---------------------------------------------------------------------------
# 4) 完整性检查
fail=0

# download.pl 成功后会删除 <file>.dl 与 <file>.hash（cleanup()）；
# 二者之一残留，就说明该包没有下载成功。
leftover="$(find "$DL" -maxdepth 1 \( -name '*.dl' -o -name '*.hash' \) 2>/dev/null | sort || true)"
if [ -n "$leftover" ]; then
  warn "以下包的下载未完成（残留 .dl/.hash 标记）："
  printf '%s\n' "$leftover" | sed 's|^.*/|      |'
  fail=1
fi

log "dl 现状"
printf '    文件数 = %s\n' "$(ls -1 "$DL" 2>/dev/null | wc -l)"
printf '    体积   = %s\n' "$(LC_ALL=C du -sh "$DL" 2>/dev/null | cut -f1)"

if [ "$rc" -ne 0 ]; then
  printf '\033[1;31m  make download 未全部成功（退出码 %d）\033[0m\n' "$rc"
  fail=1
fi

# ---------------------------------------------------------------------------
# 5) 结论
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1;32m源码包齐备。\033[0m下一步：\n\n  ./scripts/build.sh\n\n'
  echo "提示：重跑本脚本等价于对 dl/ 做一次全量哈希审计"
  echo "      （download.pl 会为已存在的文件重算哈希，并与包声明的"
  echo "        PKG_HASH / PKG_MIRROR_HASH 比对）。"
  echo
else
  echo "常见原因与处理："
  echo
  echo "  · 官方镜像 404 —— 该包未被 sources.openwrt.org / sources.cdn.openwrt.org 收录。"
  echo "    这两个镜像是扁平目录 sources.openwrt.org/<文件名>，与仓库地址无关；"
  echo "    第三方包（如 rtl8188eu）本来就不在其中，必然 404。"
  echo "    此时会回退到 git 源，所以要保证包定义的 PKG_SOURCE_URL 是 https:// 而不是 git@。"
  echo "    历史案例：rtl8188eu 曾写成 git@github.com:（SSH，缺公钥必然失败），"
  echo "    本工程已改回 https://github.com/（见 project/patches/0202-*.patch）。"
  echo
  echo "  · 网络中断 / 单个镜像不可达 —— 直接重跑本脚本，已成功的包不会重复下载。"
  echo "    指定本地镜像：在 upstream/.config 里设 CONFIG_LOCALMIRROR。"
  echo
  exit 1
fi
