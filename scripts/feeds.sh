#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 安装 / 更新 feeds
#
# 作用：把 feeds.conf(.default) 里列出的外部仓库拉到 upstream/feeds/，
#       并把其中的包注册进 upstream/package/feeds/，使它们出现在 kconfig 中。
#
# 为什么需要它：LuCI、ttyd 这类包**不在 OpenWrt 核心仓库**里，而在 feeds 里。
#   本工程 defconfig 启用了 26 个 luci 包 + ttyd。feeds 未安装时，这些
#   CONFIG_PACKAGE_* 符号在 kconfig 里根本不存在，`make defconfig` 会把它们
#   **静默丢弃** —— 结果就是「配置里写着要 LuCI，编出来的固件却没有 web 界面」。
#
# 源地址：默认走 OpenWrt 官方在 GitHub 上的同名镜像（由补丁 0204 写入
#   feeds.conf.default）。git.openwrt.org 的 git 端点本身可用（info/refs 能返回
#   完整分支表），但实际抓数据经常长时间停在 "Cloning into ..."，几乎不动。
#
# 时序：必须在 setup.sh 的 `make defconfig` **之前**完成 —— 或者跑完本脚本后
#       再执行一次 ./scripts/setup.sh（后者更省事，推荐）。
#
# setup.sh 重置上游时用的是 `git clean -fdx -e feeds -e feeds.conf`，
# 所以 feeds/ 与 feeds.conf 不会被清掉，本脚本通常只需要跑一次。
#
# 用法:
#   ./scripts/feeds.sh                 # 网络预检 → 清理中断残留 → update → install
#   ./scripts/feeds.sh luci            # 只处理 luci 这一个 feed
#   UPDATE=0 ./scripts/feeds.sh        # 只 install 不 update（不做残留清理）
#   SKIP_PROBE=1 ./scripts/feeds.sh    # 跳过网络预检，直接开拉
#   PROBE_TIMEOUT=10 ./scripts/feeds.sh
#
# 换源：在 project/feeds.conf 放一份自定义清单即可（feeds.conf 优先于
#       feeds.conf.default，且 setup.sh 不会删它）。例：
#         src-git luci https://git.openwrt.org/project/luci.git;openwrt-23.05
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
FEEDS="${1:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  注意\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$UPSTREAM/Makefile" ] \
  || die "$UPSTREAM 不是 OpenWrt 源码树，请先运行 scripts/bootstrap.sh"
command -v git >/dev/null 2>&1 || die "找不到 git"

# ---------------------------------------------------------------------------
# 同 setup.sh / build.sh：WSL 会把 Windows 的 PATH 注入 Linux PATH，含空格的
# 条目会被拆出裸的相对路径片段。这里只保留绝对路径条目，不改动用户的 shell 配置。
# ---------------------------------------------------------------------------
P="$(printf '%s' "$PATH" | tr ':' '\n' | grep '^/' | paste -sd: || true)"
[ -n "$P" ] && export PATH="$P"

cd "$UPSTREAM"

# ---------------------------------------------------------------------------
# 1) 允许用 project/feeds.conf 覆盖源地址（换镜像时不用改补丁）
# ---------------------------------------------------------------------------
if [ -f "$ROOT/project/feeds.conf" ]; then
  cp -f "$ROOT/project/feeds.conf" "$UPSTREAM/feeds.conf"
  log "使用 project/feeds.conf（优先级高于 feeds.conf.default）"
fi

CONF="feeds.conf"
[ -f "$CONF" ] || CONF="feeds.conf.default"
[ -f "$CONF" ] || die "既没有 feeds.conf 也没有 feeds.conf.default"

# ---------------------------------------------------------------------------
# 2) 解析清单：每行 src-git <name> <url>;<branch>
# ---------------------------------------------------------------------------
feed_lines() {
  grep -Ev '^[[:space:]]*(#|$)' "$1" | while read -r type name rest; do
    [ "$type" = "src-git" ] || continue
    [ -n "${name:-}" ] && [ -n "${rest:-}" ] || continue
    url="${rest%%;*}"
    case "$rest" in
      *";"*) branch="${rest##*;}" ;;
      *)     branch="" ;;
    esac
    printf '%s\t%s\t%s\n' "$name" "$url" "$branch"
  done
}

NEED=()
while IFS=$'\t' read -r name url branch; do
  [ -n "$name" ] || continue
  [ -z "$FEEDS" ] || [ "$name" = "$FEEDS" ] || continue
  NEED+=("$name|$url|$branch")
done < <(feed_lines "$CONF")

[ "${#NEED[@]}" -gt 0 ] \
  || die "$CONF 里没有可用的 src-git 条目（或 feed 名 '$FEEDS' 不存在）"

# ---------------------------------------------------------------------------
# 3) 网络预检 —— 先确认「能连上」且「分支存在」，避免盲等
# ---------------------------------------------------------------------------
probe_one() {   # $1=url $2=branch
  local out
  if [ -n "$2" ]; then
    out="$(timeout "${PROBE_TIMEOUT:-20}" git ls-remote --heads "$1" "refs/heads/$2" 2>/dev/null || true)"
  else
    out="$(timeout "${PROBE_TIMEOUT:-20}" git ls-remote --heads "$1" 2>/dev/null || true)"
  fi
  [ -n "$out" ]
}

failed=()
if [ "${SKIP_PROBE:-0}" = "1" ]; then
  warn "SKIP_PROBE=1，跳过网络预检"
else
  log "网络预检（每个 feed 最多等 ${PROBE_TIMEOUT:-20}s）"
  for item in "${NEED[@]}"; do
    IFS='|' read -r name url branch <<<"$item"
    printf '  %-10s %s' "$name" "$url"
    if probe_one "$url" "$branch"; then
      printf '  \033[1;32m可达\033[0m\n'
    else
      printf '  \033[1;31m不可达\033[0m\n'
      failed+=("$item")
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    echo
    warn "有 ${#failed[@]} 个 feed 连不上（超时）或分支不存在："
    for item in "${failed[@]}"; do
      IFS='|' read -r name url branch <<<"$item"
      printf '      %-10s %s  (branch=%s)\n' "$name" "$url" "${branch:-默认}"
    done
    cat <<'HINT'

    可以这样定位（在 WSL 里逐条跑，比较哪条能通、大概多快）：
      timeout 20 git ls-remote --heads https://github.com/openwrt/packages.git refs/heads/openwrt-23.05
      timeout 20 git ls-remote --heads https://git.openwrt.org/feed/packages.git refs/heads/openwrt-23.05

    换源办法（二选一，都不需要改补丁）：
      1) 在 project/feeds.conf 写一份自定义清单，本脚本会优先使用它；
      2) 直接编辑 upstream/feeds.conf.default 里的 URL。

    本轮尚未开始克隆，没有留下任何残留。
HINT
    exit 1
  fi
  ok "全部 ${#NEED[@]} 个 feed 可达"
fi

# ---------------------------------------------------------------------------
# 4) 清理上次中断留下的残留（只在 update 时做）
#    - feeds/<name>.tmp  ：feeds 脚本的元数据目录（location / info）
#    - feeds/<name>.index：指向 <name>.tmp/.packageinfo 的软链接
#    克隆没成功时它们是孤儿，留着会让下一次 update 反复纠缠
# ---------------------------------------------------------------------------
if [ "${UPDATE:-1}" = "1" ]; then
  cleaned=0
  for item in "${NEED[@]}"; do
    IFS='|' read -r name url branch <<<"$item"
    if [ -d "feeds/$name.tmp" ] && [ ! -d "feeds/$name" ]; then
      rm -rf "feeds/$name.tmp"
      printf '  清理孤儿元数据 feeds/%s.tmp\n' "$name"
      cleaned=$((cleaned + 1))
    fi
    if [ -d "feeds/$name" ] && { [ ! -d "feeds/$name/.git" ] || [ ! -e "feeds/$name/.git/HEAD" ]; }; then
      rm -rf "feeds/$name"
      printf '  清理不完整克隆 feeds/%s\n' "$name"
      cleaned=$((cleaned + 1))
    fi
  done
  for i in feeds/*.index feeds/*.targetindex; do
    [ -L "$i" ] || continue
    [ -e "$i" ] || { rm -f "$i"; cleaned=$((cleaned + 1)); }
  done
  if [ "$cleaned" -gt 0 ]; then
    ok "清理了 $cleaned 项残留"
  else
    ok "无残留需要清理"
  fi
fi

# ---------------------------------------------------------------------------
# 5) update + install
# ---------------------------------------------------------------------------
if [ "${UPDATE:-1}" = "1" ]; then
  if [ -n "$FEEDS" ]; then
    log "feeds update $FEEDS"
    ./scripts/feeds update "$FEEDS" || die "feeds update 失败（见上方输出）"
  else
    log "feeds update -a（首次约 200 MB，视网络 2-10 分钟）"
    ./scripts/feeds update -a || die "feeds update 失败（见上方输出）"
  fi
  ok "feeds/ 已更新"
fi

if [ -n "$FEEDS" ]; then
  log "feeds install $FEEDS"
  ./scripts/feeds install "$FEEDS" || die "feeds install 失败"
else
  log "feeds install -a"
  ./scripts/feeds install -a || die "feeds install 失败"
fi
ok "package/feeds/ 已建立"

# ---------------------------------------------------------------------------
# 6) 校验：注册结果是 package/feeds/<feed>/<pkg> 形式的符号链接。
#    只挑本项目 defconfig 里真正启用的几个来确认，不去枚举全部。
# ---------------------------------------------------------------------------
log "校验关键包已注册"
missing=0
check() {
  local path="$1" label="$2"
  if [ -e "$UPSTREAM/$path" ]; then
    ok "$label"
  else
    warn "未注册: $label"
    missing=$((missing + 1))
  fi
}
check package/feeds/luci/luci-base                "luci/luci-base"
check package/feeds/luci/luci-mod-admin-full      "luci/luci-mod-admin-full"
check package/feeds/luci/luci-app-firewall        "luci/luci-app-firewall"
check package/feeds/luci/luci-i18n-base-zh-cn     "luci/luci-i18n-base-zh-cn"
check package/feeds/packages/ttyd                 "packages/ttyd"

echo
if [ "$missing" -eq 0 ]; then
  printf '\033[1;32mfeeds 就绪。\033[0m重跑一次 setup.sh，让这些符号进入 .config：\n\n'
  printf '       ./scripts/setup.sh\n'
  printf '       ./scripts/build.sh\n\n'
else
  printf '\033[1;33m有 %d 个包未注册。\033[0m\n' "$missing"
  printf '若 luci 相关全部缺失，检查 %s 里 luci 那一行的地址与分支。\n\n' "$CONF"
fi
