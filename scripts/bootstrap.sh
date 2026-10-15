#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 上游引导（Git Submodule）
#
# 作用：把官方 OpenWrt 仓库注册为本工程的 Git Submodule，并检出到固定基线。
#       只需要在「首次克隆本仓库」或「切换基线」时执行一次。
#
# 为什么用 Submodule 而不是把上游塞进仓库：
#   上游 OpenWrt 工作树 + 完整历史约 1 GB，且本身是独立演进的公开项目。
#   用 submodule 记录「URL + 一个确定的 commit」，本仓库因此只有几百 KB，
#   同时上游版本被精确锁定 —— clone 之后任何人得到的都是我验证过的那棵树。
#
# 用法:
#   ./scripts/bootstrap.sh
#   BASE_COMMIT=<其它提交> ./scripts/bootstrap.sh
#   UPSTREAM_URL=<镜像地址> ./scripts/bootstrap.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"

# 官方 OpenWrt 基线。正点原子的全部平台定制（target/linux/imx 的 target、
# U-Boot 补丁、板级脚本、文档）已由本工程导出为 project/patches/0100-0114，
# 因此这里直接以官方仓库为上游，不再依赖任何第三方分支。
BASE_COMMIT="${BASE_COMMIT:-0844937947ec1c9124dbb332b5fb5d1e3616b1e2}"

# 上游地址。GitHub 镜像对国内网络通常更快；官方源为
# https://git.openwrt.org/openwrt/openwrt.git
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/openwrt/openwrt.git}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$ROOT 还不是 git 仓库。请先执行：
    cd $ROOT && git init -b main && git add -A && git commit -m '初始提交'"

# ---------------------------------------------------------------------------
# 情形 1：upstream/ 已经是一个完整的子模块工作树（.git 为文件，指向
#         .git/modules/upstream）。此时只需同步到目标基线。
# 情形 2：upstream/ 存在但不是子模块（历史上由 git clone 直接生成）——
#         不能就地转换，必须先移走，否则 submodule add 会拒绝。
# 情形 3：upstream/ 不存在 —— bootstrap.sh 会自动 clone 官方仓库。
# ---------------------------------------------------------------------------
if [ -e "$UPSTREAM" ] && [ ! -f "$UPSTREAM/.git" ]; then
  cat >&2 <<EOF
错误: $UPSTREAM 已存在，但它不是 Git Submodule（.git 是目录而不是文件）。
      就地转换不可靠，请先把它移走再运行本脚本：

          cd $ROOT
          mv upstream upstream.old          # 同文件系统内瞬间完成

      如果里面有编译产物或 dl/ 缓存想保留，可在引导完成后播种：

          ./scripts/bootstrap.sh
          mkdir -p dl && cp -al upstream.old/dl/. dl/ 2>/dev/null || cp -a upstream.old/dl/. dl/
          rm -rf upstream.old

EOF
  exit 1
fi

if [ -f "$ROOT/.gitmodules" ] && grep -qE '^[[:space:]]*path[[:space:]]*=[[:space:]]*upstream$' "$ROOT/.gitmodules"; then
  log "已存在 submodule 定义，执行初始化"
  # 首次拉取会下载上游历史（约 1 GB，视网络 5-30 分钟）。
  # 若你的 git >= 2.36 且希望更快，可改用 partial clone：
  #   git -C "$ROOT" submodule update --init --filter=blob:none upstream
  git -C "$ROOT" submodule update --init upstream \
    || die "submodule 初始化失败，请检查网络或改用 UPSTREAM_URL=<镜像地址>"
else
  log "注册 submodule: $UPSTREAM_URL"
  log "  首次会克隆完整上游仓库（约 1 GB），请耐心等待"
  # --force 是必需的：.gitignore 里保留了 /upstream/（防止上游内容被误提交），
  # 而 git 默认拒绝把被忽略的路径加入索引 —— 加上 --force 才能登记这个 gitlink。
  git -C "$ROOT" submodule add --force "$UPSTREAM_URL" upstream \
    || die "submodule add 失败，请检查网络或改用 UPSTREAM_URL=<镜像地址>"
  # 子模块内部有自己的 .git 与产物（build_dir/staging_dir 等）。
  # 设为 untracked 后，父仓库的 git status 不会因为它们而刷屏。
  git -C "$ROOT" config -f .gitmodules submodule.upstream.ignore untracked
fi

# ---------------------------------------------------------------------------
log "检出基线 $BASE_COMMIT"
# 基线可能不在 clone 下来的默认分支里（本工程钉在官方 master 的一个历史提交上），
# 因此先尝试直接切换；失败则按需把该提交单独 fetch 进来。
if ! git -C "$UPSTREAM" cat-file -e "${BASE_COMMIT}^{commit}" 2>/dev/null; then
  log "  本地没有该提交，尝试单独获取"
  git -C "$UPSTREAM" fetch --depth 1 origin "$BASE_COMMIT" \
    || git -C "$UPSTREAM" fetch origin
fi
git -C "$UPSTREAM" checkout --force --quiet "$BASE_COMMIT" \
  || die "无法检出基线 $BASE_COMMIT"

# 让父仓库里的 gitlink 精确指向基线（submodule add 之后 HEAD 停在默认分支 tip）
git -C "$ROOT" add --force upstream

ok "$(git -C "$UPSTREAM" log -1 --format='%h %ad %s' --date=short)"
ok "submodule 就绪：$(git -C "$ROOT" config -f .gitmodules --get submodule.upstream.url)"

echo
printf '\033[1;32m上游引导完成。\033[0m下一步：\n\n'
printf '  ./scripts/setup.sh     # 重置到基线并重放全部定制补丁\n\n'
