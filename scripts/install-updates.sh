#!/usr/bin/env bash
#
# atk-imx6ull-openwrt · 一次性安装脚本（2026-10-14）
#
# 背景：git.openwrt.org 的 git 端点可用，但实际传输长时间停在 "Cloning into ..."，
#       feeds 拉不下来。本脚本把「换到 GitHub 官方镜像」这一轮改动落到工程里。
#
# 做这些事（只改文件，不触发编译；可重复执行）：
#   1) project/patches/series   登记新补丁 0204
#   2) scripts/feeds.sh         换成带网络预检 + 残留清理的新版
#   3) scripts/setup.sh         git clean 增加 -e feeds.conf
#   4) README.md                更新 feeds 源地址 + 新增排查章节
#   5) 清理遗留文件
#
# 用法（不需要可执行位）：
#   bash scripts/install-updates.sh
#
# 完成后本脚本可自行删除：
#   rm -f scripts/install-updates.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  跳过\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1) series 登记 0204
# ---------------------------------------------------------------------------
log "登记补丁 0204"
if [ ! -f project/patches/0204-feeds-use-github-mirrors.patch ]; then
  skip "project/patches/0204-feeds-use-github-mirrors.patch 不存在"
elif grep -qx '0204-feeds-use-github-mirrors.patch' project/patches/series; then
  skip "series 已含 0204"
else
  printf '0204-feeds-use-github-mirrors.patch\n' >> project/patches/series
  ok "已追加 0204 到 series"
fi

# ---------------------------------------------------------------------------
# 2) feeds.sh
# ---------------------------------------------------------------------------
log "安装新版 feeds.sh"
if [ -f scripts/feeds.sh.new ]; then
  mv -f scripts/feeds.sh.new scripts/feeds.sh
  ok "feeds.sh 已更新"
else
  skip "scripts/feeds.sh.new 不存在（可能已安装过）"
fi

# ---------------------------------------------------------------------------
# 3) setup.sh：git clean 增加 -e feeds.conf
# ---------------------------------------------------------------------------
log "更新 setup.sh 的 git clean 排除项"
if grep -q -- '-e feeds -e feeds.conf' scripts/setup.sh; then
  skip "setup.sh 已含 -e feeds.conf"
elif grep -q -- 'clean --quiet -fdx -e feeds$' scripts/setup.sh; then
  sed -i 's|clean --quiet -fdx -e feeds$|clean --quiet -fdx -e feeds -e feeds.conf|' scripts/setup.sh
  ok "setup.sh 已更新为 -e feeds -e feeds.conf"
else
  skip "未匹配到预期行，请手工确认 setup.sh 里的 git clean 行"
fi

# ---------------------------------------------------------------------------
# 4) README.md
# ---------------------------------------------------------------------------
log "更新 README.md"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$ROOT" <<'PYEOF'
import io, os, sys

root = sys.argv[1]
path = os.path.join(root, "README.md")
text = io.open(path, encoding="utf-8").read()
orig = text

url_map = [
    ("https://git.openwrt.org/feed/packages.git",  "https://github.com/openwrt/packages.git"),
    ("https://git.openwrt.org/project/luci.git",   "https://github.com/openwrt/luci.git"),
    ("https://git.openwrt.org/feed/routing.git",   "https://github.com/openwrt/routing.git"),
    ("https://git.openwrt.org/feed/telephony.git", "https://github.com/openwrt/telephony.git"),
]

# 4a) 只改 feeds 清单所在的行（src-git 行，或说明里带 `src-git 的行）。
#     这样不会误改排查章节里用于 A/B 对比的 git ls-remote 命令，
#     也让本脚本可以重复执行。
lines = text.split("\n")
hit = 0
for i, ln in enumerate(lines):
    if ln.lstrip().startswith("src-git") or "`src-git" in ln:
        new = ln
        for old, new_url in url_map:
            if old in new:
                hit += new.count(old)
                new = new.replace(old, new_url)
        lines[i] = new
if hit:
    text = "\n".join(lines)
    print("  ok    源地址替换 %d 处（仅 src-git 清单行）" % hit)
else:
    print("  跳过  源地址（已是镜像地址或未匹配）")

# 4b) git clean 排除项说明（文中可能出现多处，全部更新）
repls = [
    ("git clean -fdx -e feeds`",        "git clean -fdx -e feeds -e feeds.conf`"),
    ("`git clean` 时用 `-e feeds` 保留", "`git clean` 时用 `-e feeds`（同时保护 `package/feeds/`）保留"),
]
for old, new in repls:
    n = text.count(old)
    if n:
        text = text.replace(old, new)
        print("  ok    说明更新 %d 处: %s" % (n, old[:38]))
    else:
        print("  跳过  说明已是新版: %s" % old[:38])

# 4c) 追加排查章节
marker = "## feeds 拉取卡住 / 拉不下来"
if marker in text:
    print("  跳过  排查章节已存在")
else:
    section = u"""
---

## feeds 拉取卡住 / 拉不下来

**现象**：`./scripts/feeds.sh` 长时间停在 `Cloning into './feeds/packages'...` 不动，
`upstream/feeds/` 里出现 `packages.tmp/`（内含只有一个 `location` 文件的空壳），
以及一批 `*.index` 软链接。

**原因**：`git.openwrt.org` 的 git 端点本身是通的（`info/refs` 能返回完整分支表），
但实际抓数据可能长时间卡住、字节数几乎不动。`*.index` 是 feeds 脚本建的软链接，
指向 `<feed>.tmp/.packageinfo`；克隆没成功时它们就成了悬空链接（从 Windows 侧
访问会显示 I/O 错误）。

**先测哪个源能用**（各等 20 秒，比较能否连通）：

```bash
timeout 20 git ls-remote --heads https://github.com/openwrt/packages.git refs/heads/openwrt-23.05
timeout 20 git ls-remote --heads https://git.openwrt.org/feed/packages.git refs/heads/openwrt-23.05
```

**清理中断残留**（可安全重复执行，只删 feeds 的中间状态，不动 `upstream/` 源码）：

```bash
cd ~/atk-imx6ull-openwrt/upstream
rm -rf feeds package/feeds
rm -f  feeds.conf tmp/.packageinfo tmp/.targetinfo
```

**重试**：`./scripts/feeds.sh`。新版会先做网络预检（每个 feed 最多等 20 秒），
连不上就直接退出并打印可用的地址，不会再盲等；同时会自动清掉上一次的残留。

**换源**：在 `project/feeds.conf` 写一份自定义清单即可 —— 它的优先级高于
`feeds.conf.default`，且 `setup.sh` 不会删它。例：

```
src-git packages https://github.com/openwrt/packages.git;openwrt-23.05
src-git luci     https://github.com/openwrt/luci.git;openwrt-23.05
src-git routing  https://github.com/openwrt/routing.git;openwrt-23.05
src-git telephony https://github.com/openwrt/telephony.git;openwrt-23.05
```
"""
    if not text.endswith("\n"):
        text += "\n"
    text += section
    print("  ok    已追加排查章节")

if text != orig:
    io.open(path, "w", encoding="utf-8", newline="").write(text)
    print("  README.md 已写回")
else:
    print("  README.md 无改动")
PYEOF
else
  skip "找不到 python3，README.md 未更新（可稍后手工改）"
fi

# ---------------------------------------------------------------------------
# 5) 遗留清理 + 可执行位
# ---------------------------------------------------------------------------
log "清理遗留文件"
for f in scripts/verify-image.py scripts/_wbtest.txt project/patches/_probe2; do
  if [ -e "$f" ]; then rm -f "$f" && ok "删除 $f"; fi
done
if [ -d scripts/__pycache__ ]; then rm -rf scripts/__pycache__ && ok "删除 scripts/__pycache__"; fi
if chmod +x scripts/*.sh scripts/*.py 2>/dev/null; then ok "已设置 scripts/*.sh 可执行位"; fi

# ---------------------------------------------------------------------------
# 6) 自检
# ---------------------------------------------------------------------------
echo
log "自检"
for s in scripts/*.sh; do
  if bash -n "$s" 2>/dev/null; then printf '  ok    %s\n' "$s"; else printf '  FAIL  %s\n' "$s"; fi
done
if git -C upstream -c safe.directory='*' apply --check \
     project/patches/0204-feeds-use-github-mirrors.patch 2>/dev/null; then
  ok "补丁 0204 可干净应用"
else
  skip "0204 当前无法应用（upstream 若已被改动属正常；setup.sh 会先重置再重放）"
fi

echo
cat <<'NEXT'
下一步：
  ./scripts/feeds.sh       # 先做网络预检；不通会立刻告诉你，不会盲等
  ./scripts/setup.sh       # 让 luci 符号进入 .config（并重放含 0204 的补丁集）
  ./scripts/build.sh       # 编译

若 feeds.sh 预检报不可达，按它打印的提示换源后再跑。
NEXT
