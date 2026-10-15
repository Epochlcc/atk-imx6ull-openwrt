# atk-imx6ull-openwrt

正点原子 i.MX6ULL 阿尔法开发板（ATK-ALPHA）的 OpenWrt 构建工程。支持LuCI 中文全套 + 显示/触摸。

## 快速开始

构建依赖（Ubuntu 22.04）：

```bash
sudo apt install -y build-essential ccache ecj fastjar file g++ gawk gettext \
  git java-props libelf-dev libncurses5-dev libncursesw5-dev libssl-dev \
  python3 python3-dev python3-setuptools python3-pip rsync swig unzip \
  zlib1g-dev file wget
```

```bash
git clone <本仓库地址> atk-imx6ull-openwrt
cd atk-imx6ull-openwrt

./scripts/bootstrap.sh   # 拉取上游（submodule，约 1 GB，视网络 5-30 分钟）
./scripts/feeds.sh       # 拉取 LuCI 等外部 feed（约 200 MB，只需一次）
./scripts/setup.sh       # 重置到基线并重放全部定制补丁（约 1 分钟）
./scripts/fetch.sh       # 下载源码包到 dl/（约 700 MB；已有缓存则秒过）
./scripts/build.sh       # 首次约 30-60 分钟
```


五个脚本各司其职，都可以重复执行：

| 脚本 | 作用 |
|---|---|
| `bootstrap.sh` | 注册并拉取上游 submodule，检出到固定基线。只需首次运行 |
| `feeds.sh` | 拉取 feeds 并注册到 `package/feeds/` —— **LuCI 和 ttyd 不在核心仓库里，全靠它**。只需首次运行 |
| `setup.sh` | 把 `upstream/` 重置到基线 → 应用补丁集 → 删除被接管的文件 → 校验出树设备树 → 安装 defconfig → **断言设备确实被选中、LuCI 确实生效** → 写入目录归属 |
| `fetch.sh` | 把所有外部源码包取到 `dl/`。重跑一次等价于对 `dl/` 做全量哈希审计 |
| `build.sh` | 一键构建，产物落在 `out/targets/imx/cortexa7/` |

另有三个按需使用的工具：

| 脚本 | 作用 |
|---|---|
| `check-patches.sh` | 补丁健康自检：逐个 hunk 比对 `@@` 声明行数与实际行数 |
| `export-changes.sh` | 把你在 `upstream/` 里手工改好的文件**反向导出成补丁**，纳入补丁集管理 |

> **注意 feeds 的时序**：`feeds.sh` 必须在 `setup.sh` 的 `make defconfig` **之前**
> 完成 —— 或者在跑完 `feeds.sh` 后再执行一次 `setup.sh`。feeds 未安装时，
> defconfig 里的 `luci` 符号会被 `make defconfig` 静默丢弃，编出来的固件就没有
> web 管理界面。`setup.sh` 现在会对此做断言并直接报错。
---

## 目录结构

```
atk-imx6ull-openwrt/
├── .gitmodules                      submodule 定义（openwrt/openwrt）
├── .gitattributes                   强制仓库内一律 LF
├── .gitignore                       排除 upstream/ dl/ out/
├── upstream/                        ★ Git Submodule → 官方 OpenWrt @ 0844937947
│   ├── .config                      由 setup.sh 生成
│   └── feeds/                       ★ 由 feeds.sh 拉取（LuCI 等），跨重置保留
├── dl/                              ★ 下载的源码包（约 700 MB），位于 upstream/ 之外
├── out/                             ★ 构建产物与日志，combined.bin 在这里
├── project/                         ★ 本工程的全部自定义内容
│   ├── config/
│   │   └── atk_imx6ull_defconfig    配置的唯一来源（6687 行全集）
│   ├── dts/
│   │   ├── imx6ull-atk-mmc.dts      ★ 板级设备树，改它不用动补丁
│   │   └── lcd_touch.dtsi           ★ 屏与触摸（B 阶段新增，由 dts 里 #include）
│   ├── patches/
│   │   ├── series                   补丁应用顺序清单（21 条）
│   │   ├── 0100~0114-*.patch        平台支持定制（15 个提交）
│   │   └── 0201~0206-*.patch        本工程改进（6 个）
│   ├── feeds.conf                   feeds 源（0204 指向 GitHub 镜像）
│   └── remove.txt                   需从上游树删除、由本工程接管的文件
├── scripts/
│   ├── bootstrap.sh                 上游引导：submodule 注册 + 检出基线
│   ├── setup.sh                     初始化：重置上游 + 重放定制 + 写入目录归属
│   ├── feeds.sh                     ★ 拉取 feeds（LuCI / ttyd 的来源）
│   ├── fetch.sh                     下载源码包到 dl/
│   ├── build.sh                     一键构建
│   ├── check-patches.sh             补丁 hunk 计数自检
│   ├── export-changes.sh            把工作树上的改动固化成补丁
│   └── check_patch.py               check-patches.sh 的实现
├── README.md                        主文档：架构、日常操作、设计决策
├── BOARD.md                         板级接口与默认配置（网口 / WiFi / 4G / 防火墙 / USB）
├── NETWORK.md                       网络接口与连通性（WAN/LAN 物理位置 / 上行路线 / 排查）
└── VERIFY.md                        验证清单：每级的检验方法与判定标准
```

---

## 产物与烧录

```
out/targets/imx/cortexa7/
├── openwrt-23.05-snapshot-rXXXXX-imx-cortexa7-imx6ull-atk-mmc-squashfs-combined.bin    ← 烧这个
├── openwrt-...-squashfs-sysupgrade.bin
├── openwrt-...-rootfs.tar.gz
├── openwrt-...-uImage
├── packages/            所有 ipk
└── u-boot-mx6ull_atk_mmc/u-boot.imx
```

`combined.bin` 是完整的 SD 卡镜像（U-Boot 写在 1KB 偏移处，随后是 MBR + boot 分区
+ rootfs 分区）。


用 balenaEtcher 
写完插卡、拨码开关切到 SD 卡启动（10000010）、串口 115200 观察。

---
## 相关文档

| 文件 | 内容 |
|---|---|
| `BOARD.md` | 板级接口与默认配置：LAN/WAN 分配、默认 WiFi、4G 接口、防火墙区域 |
| `VERIFY.md` | 验证清单：工程重建 → 补丁完整性 → 出树机制 → 取包 → 构建 → 产物结构 → 上板 |
| `upstream/doc/quick_start_guide.md` | 快速上手 |
| `upstream/doc/burn_sd_image.md` | SD 卡烧录 |
| `upstream/doc/burn_emmc_image.md` | 通过 SD 卡烧 eMMC |
| `upstream/doc/ec20_network.md` | EC20 4G 模块上网 |
| `upstream/doc/eth_4g_auto_switching.md` | 有线/4G 自动切换 |
| `upstream/doc/faq.md` | 常见问题 |

---


## 致谢
[感谢boxwoodt佬给的灵感](https://github.com/boxwoodt/imx6ull_openwrt/tree/imx6ull_openwrt)

[感谢AELS的教程](https://github.com/Awesome-Embedded-Learning-Studio/imx-forge)

[openwrt原项目](https://github.com/openwrt/openwrt/releases)
