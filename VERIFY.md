# 验证清单 —— 确认这套工程化确实可用

判断「能不能用」分六级。前四级成本极低，能在真正编译（30–60 分钟）之前就把问题挡住；
第五级给出可量化的等价性证据；第六级才需要动硬件。

参考值来源：由上游基线构建出的固件实测得出（该固件已在板上跑通）。

---

## 阶段 0 —— 上游引导与工程重建（约 2 分钟 + 首次 clone 时间）

```bash
cd ~/atk-imx6ull-openwrt

./scripts/bootstrap.sh   # 仅首次：注册 submodule 并检出基线（会下载约 1 GB 上游）
./scripts/setup.sh       # 每次：重置到基线并重放全部定制
```

`bootstrap.sh` 做三件事：把 `openwrt/openwrt` 注册为 submodule → 检出到
基线 `0844937947` → 更新父仓库的 gitlink 指向。

`setup.sh` 做六件事：把 `upstream/` 重置到基线 → 应用 21 个补丁 →
删除被接管的 `401-fix-support-atk-board.patch` → 校验出树 DTS → 装 defconfig →
**断言设备被选中** → 写入目录归属（`dl/`、`out/`）→ 播种源码包缓存。

**通过标准**（关键行）：

```
  ok 0844937947 umdns: update to Git 7c675979 (2024-03-04)
  ok 21 个补丁已应用
  ok 已删除 target/linux/imx/patches-5.15/401-fix-support-atk-board.patch
  ok 468 行，SD 卡相关属性就位
  ok 设备已选中: imx6ull-atk-mmc
  ok 目标已选中: imx/cortexa7
  ok CONFIG_DOWNLOAD_FOLDER = /home/<user>/atk-imx6ull-openwrt/dl
  ok CONFIG_BINARY_FOLDER   = /home/<user>/atk-imx6ull-openwrt/out
       DL_DIR      = /home/<user>/atk-imx6ull-openwrt/dl
       OUTPUT_DIR  = /home/<user>/atk-imx6ull-openwrt/out
       BIN_DIR     = /home/<user>/atk-imx6ull-openwrt/out/targets/imx/cortexa7
```

其中「设备已选中」这一条最关键 —— 它挡住的正是历史上那次
「编译成功但 `bin/` 里一个镜像都没有」的事故（defconfig 里的设备名失效后
静默回落成 `Device/Default`，而它的 `IMAGES` 是空的）。

那三行 `DL_DIR / OUTPUT_DIR / BIN_DIR` 是用 OpenWrt 自带的变量求值入口
（`rules.mk` 里的 `val.%` 规则）回读的 make 内部真实取值 —— 路径是否按设计归位，
看这三行即可，不必靠猜。

`setup.sh` 可重复执行，每次都从基线重放，结果是确定性的。

---

## 阶段 1 —— 补丁集完整性（不编译）

本工程的全部定制以 21 个补丁的形式存在。补丁本身是否健康，
可以在**不接触上游**的情况下先验证：

```bash
cd ~/atk-imx6ull-openwrt

# 1) 清单与实际文件是否一一对应（21 个生效条目）
grep -vc '^\s*#\|^\s*$' project/patches/series
#   期望: 21

# 2) 每个补丁都能被 git 解析（含二进制段；--numstat 只解析，不修改任何文件）
for f in project/patches/01*.patch project/patches/02*.patch; do
  git -C upstream apply --numstat "$f" >/dev/null 2>&1 \
    && echo "OK   $(basename "$f")" || echo "FAIL $(basename "$f")"
done
#   期望: 全部 OK

# 3) 补丁自带 hunk 计数自检（防「改了内容忘改 @@ 行数」导致的静默截断）
./scripts/check-patches.sh
#   期望: 无 MISMATCH

# 4) 二进制补丁段确实存在（文档配图不能丢）
grep -l 'GIT binary patch' project/patches/*.patch | wc -l
#   期望: 4  （0103 / 0109 / 0113 / 0114）
```

> **为什么强调二进制段**：这 4 个补丁含 `doc/img/` 的配图。
> 用 `patch(1)` 应用会直接失败或产生损坏文件，只有 `git apply` 能重建。
> `setup.sh` 用的正是 `git apply`。

---

## 阶段 2 —— 出树 DTS 机制的静态证据（不编译）

DTS 从内核补丁里搬出来，靠的是 OpenWrt 原生支持的 `DEVICE_DTS_DIR`。
这个机制在**编译前**就能验证成立：

```bash
cd ~/atk-imx6ull-openwrt/upstream

# 1) 设备定义里确实设置了 DEVICE_DTS_DIR
grep -n "DEVICE_DTS_DIR" target/linux/imx/image/cortexa7.mk
#   期望: DEVICE_DTS_DIR := $(TOPDIR)/../project/dts

# 2) 镜像组装确实改用出树产物
grep -n "image-\$(notdir" target/linux/imx/image/common.mk
#   期望: 出现 $(if $(DEVICE_DTS_DIR),$(KDIR)/image-$(notdir $(dts)).dtb,...)

# 3) 上游框架原生支持该变量（不是我们硬塞的）
sed -n '595,601p' include/image.mk
#   期望: $(if $$(DEVICE_DTS_DIR),$$(DEVICE_DTS_DIR),$$(DTS_DIR))

# 4) 出树 DTS 仍能 #include "imx6ull.dtsi"（Image/BuildDTB 带 -I$(DTS_DIR)）
sed -n '184,197p' include/image.mk
#   期望: -I$(DTS_DIR) 与 -I$(DTS_DIR)/include

# 5) 被接管的 401 补丁已不在
ls target/linux/imx/patches-5.15/401* 2>&1
#   期望: No such file or directory

# 6) 内核补丁里不再有该 dtb 的注册行（出树后不再走内核编译）
grep -rl "imx6ull-atk-mmc.dtb" target/linux/imx/patches-5.15/ | wc -l
#   期望: 0
```

### 可选的加速检查点：只编 DTB

全量编译约 30–60 分钟。若想早点拿到「出树路径是否接通」的结论，可以只编设备树：

```bash
cd ~/atk-imx6ull-openwrt/upstream
make -j$(nproc) tools/install
make -j$(nproc) toolchain/install
make -j$(nproc) target/linux/dtb V=s
```

`target/linux/dtb` 是上游自带的目标（`target/linux/Makefile` 转发 →
`include/kernel-build.mk` 里 `dtb:` 配方 → `$(MAKE) -C image compile-dtb`），
只编设备树，不编整个内核。

**通过标准**：

```bash
ls -l build_dir/target-*/linux-imx_cortexa7/image-imx6ull-atk-mmc.dtb
sha256sum build_dir/target-*/linux-imx_cortexa7/image-imx6ull-atk-mmc.dtb
#   参考值（B 阶段显示+触摸定稿，2026-10-15）:
#   9538354fd1a0265dd8a583d8083f7c9a5f76cbf7585493958da2d98a8134bb4b  (31324 字节)
```

> **不要把这个哈希当验收判据。** 它随 `project/dts/` 的任何改动而变，写死只会
> 制造假失败。真正要判的是**一致性**：编出的 dtb 与镜像 boot 分区里的 dtb 必须
> 同一个哈希。用 `industrial_control/tools/wsl_dtb_image_check.sh` 一次核对四层
> （多出的一层是 `out/` 里的 dtb 副本 —— `target/install` 不写它，会停在旧版）。

> 若这一步报找不到交叉编译器或 `-C image` 失败，说明该目标的依赖链需要先整链构建 ——
> 直接跳到阶段 4 跑全量即可，不影响结论。

---

## 阶段 3 —— 取源码包

```bash
cd ~/atk-imx6ull-openwrt
./scripts/fetch.sh
```

把所有外部源码包（内核 / U-Boot / 各软件包）取到 `dl/`。位置由
`CONFIG_DOWNLOAD_FOLDER` 决定，已经指向工程根目录，**不在 `upstream/` 里面** ——
所以日后的 `make distclean`、`git clean -xdf` 都不会误删它。

脚本内部用 `make -k` 而不是「遇错即停」：历史上 `make download -j1` 曾在
`rtl8188eu` 处中断，导致其后所有包（连同 uci/ubus 这类基础包）根本没被尝试，
看上去「只有一个包缺失」。加 `-k` 可以一次列出全部缺包。

**通过标准**：

```
  ok dl 已有 N 个文件，跳过播种          （或「从 ... 播种（硬链接）」）
  ok 源码包齐备。下一步: ./scripts/build.sh
  文件数 = ...
  体积   = 约 700M
```

脚本末尾还会检查残留的 `<file>.dl` / `<file>.hash` —— 这两个文件是
`scripts/download.pl` 的中间标记，成功后会由 `cleanup()` 删除，
**残留即代表该包没有下载成功**。

重跑一次本脚本等价于对 `dl/` 做一次全量哈希审计：
`download.pl` 对已存在的文件也会重算哈希，并与包声明的
`PKG_HASH` / `PKG_MIRROR_HASH` 比对。

若某些包确实取不到，见文末「排查速查」；本工程已修复历史上那个
`rtl8188eu` 的 SSH 源问题（`project/patches/0202-*.patch`）。

---

## 阶段 4 —— 完整构建

```bash
cd ~/atk-imx6ull-openwrt
./scripts/build.sh
```

`build.sh` 内置了 PATH 清理（只保留绝对路径条目），这是为了绕开 WSL 把 Windows
的 `C:\Program Files\...` 拆出裸 `Files` 导致 `find -execdir` 拒绝执行的问题 ——
不改动任何 shell 配置文件。

**通过标准**：末尾打印

```
out/targets/imx/cortexa7/openwrt-...-imx6ull-atk-mmc-squashfs-combined.bin
```

日志在 `out/build.log`。

---

## 阶段 5 —— 产物结构验证（手工命令，量化证据）

不需要额外脚本，用系统自带的 `file` / `fdisk` / `xxd` / `sha256sum`，加上 OpenWrt
自己编出来的 `dtc`，逐条回答两件事：**这份固件是给 i.MX6ULL / 正点原子的吗**，
以及**SD 卡修复真的进去了吗**。

```bash
cd ~/atk-imx6ull-openwrt
IMG=$(echo out/targets/imx/cortexa7/*combined.bin)
```

### 5.1 整盘识别与分区表

```bash
file "$IMG"
fdisk -l "$IMG"
```

期望：`file` 认出 DOS/MBR boot sector；`fdisk` 列出两个分区
（boot 16 MB @扇区 2048、rootfs 104 MB @扇区 36864）。记下两个起始扇区，
后面要用它们的字节偏移。

### 5.2 i.MX Boot ROM 表头（IVT）—— 「给 i.MX6ULL 的」最硬的证据

```bash
xxd -s 1024 -l 32 "$IMG"
```

期望输出形如：

```
00000400: d1 00 40 20 00 00 80 87 ...
```

- `d1` = IVT tag（必须是 `0xD1`）
- `00 00 80 87` 是**小端**写法，实际值 **`0x87800000`** —— i.MX6ULL Boot ROM 的
  标准 U-Boot 入口地址
- 紧随其后的 dcd / boot_data / self 指针都落在 `0x877ff4xx` 一带（OCRAM 区间），
  三者自洽

> 字节序容易搞错：IVT 头部的 tag / length / version 是**大端**，
> 而 entry / dcd / boot_data / self 是**小端**。

### 5.3 rootfs 分区是 squashfs

把 5.1 里读到的 rootfs 起始扇区代入（示例为 36864）：

```bash
xxd -s $((36864*512)) -l 4 "$IMG"
```

期望：`hsqs`（squashfs 的 magic）。

### 5.4 内核确实是 ARM 架构

内核 uImage 打在 boot 分区（ext4）里，用独立产物来验：

```bash
UIMG=$(ls out/targets/imx/cortexa7/*uImage)
file "$UIMG"
xxd -s 28 -l 4 "$UIMG"
```

期望：`uImage, Linux kernel ARM ...`；偏移 28 与 29 字节分别是 os 与 arch，
即 `05 02`（os = 5 = Linux，arch = **2 = ARM**）。

### 5.5 设备树：SD 卡修复真的进去了吗（最关键的一条）

```bash
DTB=$(ls upstream/build_dir/target-*/linux-imx_cortexa7/image-imx6ull-atk-mmc.dtb)
sha256sum "$DTB"

upstream/build_dir/target-*/linux-imx_cortexa7/linux-5.15.148/scripts/dtc/dtc -I dtb -O dts "$DTB" > /tmp/atk.dts

grep -n -A12 'mmc@2190000' /tmp/atk.dts    # SD 卡控制器
grep -n -A6  'mmc@2194000' /tmp/atk.dts    # eMMC 控制器
grep -n 'model' /tmp/atk.dts | head -1
```

期望：

- `sha256sum` = `9538354fd1a0265dd8a583d8083f7c9a5f76cbf7585493958da2d98a8134bb4b`
  （B 阶段显示+触摸定稿的参照值；**它随 `project/dts/` 改动而变，不是判据**，
  要判的是「编出的 dtb 与镜像 boot 分区里的 dtb 一致」）
- `mmc@2190000`（SD 卡槽）带 `no-1-8-v`、`max-frequency = <0x2faf080>`
  （十进制 50000000）、`cd-gpios`
- `mmc@2194000`（eMMC）带 `non-removable`，且**不应**带 `no-1-8-v`
- `model = "Freescale ATK IMX6ULL Board"`

> `dtc` 用**内核自带**的那一份：
> `build_dir/target-*/linux-imx_cortexa7/linux-5.15.148/scripts/dtc/dtc`。
> ★ 实测（2026-10-15）：它挂在 **`target-*/`** 下，**`toolchain-*/` 下没有 dtc**。
> 把 glob 写错不会报错，只会让「反编译核对」整段被静默跳过、看起来照样全绿。
> 注意 `upstream/staging_dir/host/bin/dtc` **并不存在** —— 有些提示里写的路径是错的，
> 据此找 dtc 会白费功夫。版本要与内核 dts 语法匹配，也不建议改用系统 dtc。

### 5.6 软件包清单

```bash
grep -c . out/targets/imx/cortexa7/*.manifest
grep -E 'rtl8188eu|usb-serial-option|uqmi|comgt' out/targets/imx/cortexa7/*.manifest
```

期望：包含 `kmod-rtl8188eu`（WiFi 驱动）、`kmod-usb-serial-option`（4G 的 AT 串口）、
`uqmi`、`comgt`。

B 阶段改的是 **goodix 驱动本身**（工程补丁 `0206`，落成内核补丁
`target/linux/imx/patches-5.15/403-goodix-use-chip-config-not-firmware.patch`）：它把
`load_cfg_from_disk` 置 `false`，让 probe **直接** `goodix_configure_dev()`，从而消掉
「触摸要等约 60 秒才注册 input 设备」（根因见 README「显示与触摸（B 阶段）」第七个坑）。

> ★ **不要往 rootfs 里放 `/lib/firmware/goodix_911_cfg.bin`**（曾经试过、已撤销）：
> 空文件会让 `goodix_check_cfg()` 的 `len < GOODIX_CONFIG_MIN_LENGTH(186)` 判定返回
> `-EINVAL`，回调直接 `goto err_release_cfg`，`goodix_configure_dev()` 永不执行
> （触摸彻底不可用，比等 60 秒更糟）。

确认补丁在内核树里生效（构建后）：

```bash
K=upstream/build_dir/target-*/linux-imx_cortexa7/linux-5.15.148
grep -n 'load_cfg_from_disk' $K/drivers/input/touchscreen/goodix.c
#   期望: 赋值处是 `ts->load_cfg_from_disk = false;`（那一行不再是 true）
```

并确认 rootfs 里**没有**那个固件文件：

```bash
IMG=out/targets/imx/cortexa7/*combined.bin
# 36864 扇区 × 512 = 18874368 字节
unsquashfs -o 18874368 -l "$IMG" | grep -c goodix_911_cfg
#   期望: 0
```

> ★ 对整盘 `grep` 或 `strings` 查不到这类小文件（squashfs 压缩了目录项），要
> `unsquashfs -l` 才算判据。`combined.bin` 里 squashfs 在**第二个分区**（起始扇区
> 36864 = 字节偏移 **18874368**），**必须带 `-o 18874368`**（squashfs-tools 4.5 支持）；
> 不带就会直接报 `FATAL ERROR: Can't find a valid SQUASHFS superblock`（2026-10-15 实测）。
> 老版本没有 `-o` 就先把分区切出来：`dd if=$IMG of=/tmp/rootfs.part bs=512 skip=36864 count=212992`
> 再对 `/tmp/rootfs.part` 跑 `unsquashfs -l`（已验证可用，能列出 2363 项）。

### 5.7 直接读固件里的默认配置（可选）

```bash
sudo mount -o loop,ro,offset=$((36864*512)) "$IMG" /mnt
sed -n '1,30p' /mnt/etc/config/firewall
sudo umount /mnt
```

期望：`wan` 区域的 `option input` 是 `ACCEPT`（被补丁放宽过），
且**没有** `wan_4g` —— 与 `BOARD.md` 的描述一致。

（rootfs 是 squashfs，只读挂载即可。`/etc/config/wireless` 不在固件里 ——
它是首次启动时由 `mac80211.sh` 生成的。）

### 判定标准

| 检查项 | 期望值 |
|---|---|
| MBR 签名 | `0x55AA` @510 |
| 分区 | boot 16 MB @扇区 2048；rootfs 104 MB @扇区 36864 |
| **i.MX IVT** @1024 | tag=`0xD1`, version=`0x40`, **entry=`0x87800000`** |
| IVT dcd/boot_data/self | 落在 `0x877FF000`–`0x87800000`（OCRAM，自洽） |
| rootfs 分区首 4 字节 | `hsqs`（squashfs） |
| **内核 uImage** | `type=2`，`arch=2 (ARM)`，`load/entry=0x80008000` |
| **firmware 内 dtb 的 model** | `Freescale ATK IMX6ULL Board` |
| **SD 控制器**（`mmc@2190000`） | 带 `no-1-8-v` + `max-frequency=50000000` + `cd-gpios` |
| **eMMC 控制器**（`mmc@2194000`） | 带 `non-removable`（**不应**带 `no-1-8-v`） |
| dtb 产物 sha256（B 阶段参照） | `9538354fd1a0265dd8a583d8083f7c9a5f76cbf7585493958da2d98a8134bb4b`（随 DTS 改动而变，仅示当前版本） |
| **goodix 走芯片配置而非固件** | 内核树里的 `goodix.c` 是 `ts->load_cfg_from_disk = false;`，且 rootfs 里**没有** `/lib/firmware/goodix_911_cfg.bin`（见 5.6） |
| **触摸 input 设备出现的时机** | 开机**几秒内**就有 `/dev/input/event0`；不是等约 60 秒（见阶段 6） |

脚本退出码 `0` = 通过，`1` = 存在致命问题。末尾会给出项数与告警数。

### 出树等价性怎么验（不要靠记哈希）

出树改造要保证的是：`Device/Build/dtb`（出树后走的那条）与内核 `make dtbs`
对**同一份 DTS** 编出的产物逐字节相同。但出树之后内核树里已经没有这个 dts 了：

```
ls upstream/build_dir/target-*/linux-imx_cortexa7*/linux-5.15.148/arch/arm/boot/dts/imx6ull-atk-mmc.dts
#   → 不存在（出树前才有，靠补丁注册）
```

所以改成**四层一致性核对**来验（出树源码 → 编出的 dtb → 镜像 boot 分区里的 dtb →
`out/` 里的 dtb 副本）：

```bash
bash industrial_control/tools/wsl_dtb_image_check.sh
```

判据：四层全部一致，且 `pwm1grp` 的驱动能力是 `0x110b0`、dtb 里是 `gt9147@5d`
（旧地址 `gt9147@14` 必须为 0）。`-i` 这一路的字节等价性另由 `-@` 解释：现场不带
`-@`，带上会多出 `__symbols__` 节、体积 +8975 字节。

> **踩过的坑**：第一版脚本拿 40275 字节对真实的 31300 字节，结论是「不等价」。
> 其实只是复刻时多带了 `-@`（`CONFIG_HAS_DT_OVERLAY_SUPPORT` 未开，现场不带）。
> `-@` 会多出 `__symbols__` 节、体积 +8975 字节。**体积差一眼可见时，先查参数集合。**

### 与旧固件做 A/B（可选，用来确认判据本身可信）

上面这些命令都只依赖系统工具，可以直接指到任意固件。如果你手上还留着
旧工程编出的固件，把 5.1–5.6 对它再跑一遍：

```bash
IMG=$(echo ~/imx6ull_openwrt/bin/targets/imx/cortexa7/*combined.bin)
file "$IMG" && fdisk -l "$IMG" && xxd -s 1024 -l 32 "$IMG"
```

已知参照值（来自那块已在板上跑通的旧固件）：
MBR 签名 `0x55AA`、boot 分区 @2048 / rootfs @36864、IVT tag `0xD1`、
entry `0x87800000`、内核 `arch=2 (ARM)`、dtb 哈希 `3632108c...`、
203 个软件包。

**判读要点**：上列各项里，分区布局 / IVT / entry / 内核 arch 这些是「重构是否等价」
的证据 —— 新固件应当一致。而 **dtb 哈希 `3632108c...` 与包数 `203` 会变**：
前者因为 B 阶段往设备树里加了屏与触摸、又按板上实测改了触摸地址（当前为
`9538354f...`），后者因为补丁从 18 条增到 21 条。
把这两项当成「必须相等」会得出错误结论 —— **变是预期的，不变才要查**。

---

## 阶段 6 —— 上板（最终判定）

烧 SD 卡（balenaEtcher 最省事，或 `dd` 前先 `lsblk` 确认设备名）：

```bash
sudo dd if=out/targets/imx/cortexa7/*combined.bin \
        of=/dev/sdX bs=4M conv=fsync status=progress
```

串口 115200 8N1，拨码开关切到 SD 卡启动，上电。看三件事：

| 观察点 | 通过标准 |
|---|---|
| U-Boot 版本行 | `U-Boot 2022.01-OpenWrt-r23796-ec3b0d4684` |
| **SD 卡初始化** | **不出现** `mmc0: error -110 whilst initialising SD card` |
| SD 卡识别 | `mmc0: new high speed SDHC card` → `mmcblk0: ... GiB` |
| rootfs | `VFS: Mounted root (squashfs filesystem)` |

进入系统后先复验**显示与触摸**（B 阶段的目标）：

```bash
ls /dev/fb0                              # 显示屏帧缓冲
ls /dev/input/                           # 触摸的 eventX
cat /sys/class/backlight/*/brightness    # 背光可调
dmesg | grep -i goodix                   # 只该有 "Goodix-TS 1-005d: ID 911, version: 1060"
```

判据：

- `/dev/fb0` 存在，`dmesg` 有 `mxsfb-drm ... fb0: mxsfb-drmdrmfb frame buffer device`。
- `/dev/input/event0` 应**开机几秒内**就出现。**若要等约 60 秒**，说明板子上跑的
  内核还是没打 403 补丁的那一版（回到 5.6 查内核树里的 `goodix.c`，并确认构建前跑过
  `./scripts/build.sh target/linux/clean` 让内核重新解包重放补丁）。
- `dmesg` 里**不该**出现 `Direct firmware load for goodix_911_cfg.bin failed with error -2`，
  也不该有 `Goodix-TS 1-0014`（那是误采信的地址，正确是 `1-005d`）。
- 触摸是否真上报坐标：`cat /dev/input/event0 | hexdump -C` 边摸边看 ——
  `03 00 39` = ABS_MT_POSITION_X、`03 00 35` = ABS_MT_POSITION_Y、
  `03 00 36` = ABS_MT_TRACKING_ID、`01 00 4a 01` = BTN_TOUCH 按下、
  `00 00` = SYN_REPORT；抬起时 X 会是 `ff ff ff ff`（-1）。

进入系统后复验三个模块：

```bash
ip link show                     # br-lan / eth1 / (WiFi: phy0-ap0)
iw dev                           # 应有 phy0-ap0, type AP, txpower > 0
lsmod | grep 8188eu              # WiFi 驱动已加载
dmesg | grep -i option | tail    # 4G: ttyUSB0~3
```

预期：`wifi config` 自动生成 `/etc/config/wireless`（SSID `OpenWrt`，无密码）。
建议立刻设密码：

```bash
uci set wireless.default_radio0.ssid='ATK-OpenWrt'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='12345678'
uci commit wireless && wifi reload
```

4G 的 `wan_4g` 只有插上 SIM 卡后才能拨号验证。没有卡时，模块侧仍可验证到「链路正常」：

```bash
cat /dev/ttyUSB2 &
printf 'AT\r\n' > /dev/ttyUSB2        # 期望 OK
printf 'ATI\r\n' > /dev/ttyUSB2       # 期望 Quectel EC20F
printf 'AT+CPIN?\r\n' > /dev/ttyUSB2  # 无卡回 +CME ERROR: 10
kill %1
```

---

## 排查速查

| 现象 | 原因与处理 |
|---|---|
| `bootstrap.sh` 报 `upstream 已存在但不是 Git Submodule` | 目录是历史上 `git clone` 生成的（`.git` 是目录）。先 `mv upstream upstream.old`，再重新运行；其 `dl/` 可在引导后播种（脚本会提示命令） |
| `git submodule update` 报找不到某个 commit | 基线是历史提交，不在默认分支 tip 上。`bootstrap.sh` 已处理（`git fetch --depth 1 origin <sha>`）。手工：`git -C upstream fetch --depth 1 origin 0844937947ec1c9124dbb332b5fb5d1e3616b1e2` |
| submodule 目录是空的 | 克隆后未初始化。`git submodule update --init` |
| `setup.sh` 报「补丁无法应用」 | 上游文件已变。`cd upstream && git apply --check -v ../project/patches/0100-*.patch` 看具体 hunk |
| `setup.sh` 报「设备未被选中」 | `cortexa7.mk` 里 `define Device/<name>` 与 defconfig 中的名字不一致 —— 这正是本工程要防的事故类型 |
| `fetch.sh` 报 404 后又 Permission denied | 镜像未收录该包（正常），回退到 git 时源地址是 `git@`（SSH）。检查该包的 `PKG_SOURCE_URL` 是否为 `https://` |
| `fetch.sh` 报「下载未完成」 | 残留 `.dl`/`.hash`。直接重跑，已成功的包不会重复下载 |
| 编译报 `find: The relative path 'Files' is insecure` | 未通过 `build.sh` 直接 `make`。用 `./scripts/build.sh`，或自行清理 PATH |
| 编译跑到最后但 `out/` 没有镜像 | 设备未被选中。重跑 `setup.sh`，确认它打印「设备已选中」 |
| 路径不像预期 | `cd upstream && make val.DL_DIR && make val.OUTPUT_DIR && make val.BIN_DIR` 直接回读 |
| 编出的 dtb 与镜像 boot 分区里的 dtb 哈希不一致 | **最危险的一类**：构建只编了内核没重建设备树。跑 `bash industrial_control/tools/wsl_dtb_image_check.sh`，它会指出断在哪一层 |
| dtb 哈希变了，但你没改设备树 | 先 `./scripts/check-patches.sh`（补丁是否被改坏），再 `git -C upstream diff --stat` 看内核配置是否漂移 |
| 改了 `project/dts/*.dts` 或 `*.dtsi` 后没生效 | ① 改的是 **Windows 侧**的副本？必须以工程里的 `~/atk-imx6ull-openwrt/project/dts/` 为准；② 时间戳未变不会重编，`rm -f upstream/build_dir/target-*/linux-imx_cortexa7/image-*.dtb` 后再构建；③ `./scripts/build.sh target/linux/compile` **只编内核、不重建设备树**，要么用 `target/linux/dtb`，要么跑 `target/install` |

## 日常改设备树（这就是工程化的收益）

```bash
vim ~/atk-imx6ull-openwrt/project/dts/imx6ull-atk-mmc.dts
cd ~/atk-imx6ull-openwrt && ./scripts/build.sh
```

不需要编辑 28 KB 的补丁、不需要同步 hunk 计数、不需要清内核树重解压 ——
因为 DTS 现在是一个普通文件，不在补丁里。屏与触摸在
`project/dts/lcd_touch.dtsi`，由板级 dts 里一行 `#include "lcd_touch.dtsi"` 引入。

**只改设备树时不要编内核**（内核编一次十几分钟，设备树只要几秒）：

```bash
cd ~/atk-imx6ull-openwrt
./scripts/build.sh target/linux/dtb      # 只重建设备树，报文快，适合反复迭代
./scripts/build.sh target/install        # 重新打包镜像并安装到 out/
```

> **三个 target 的分工**（本阶段踩得最久的一个坑）：
> `target/linux/compile` 只跑内核的 `Build/Compile`，**不重建设备树**；
> dtb 由 `compile-dtb` 目标生成（`include/image.mk` 的 `Device/Build/dtb`）；
> **只有 `target/install` 才会把新 dtb 打进 `out/` 里的镜像**。
> 只跑 `compile` 的结果是「改了 DTS、构建全绿、镜像没换」。

改完补丁（`project/patches/`）后跑一次自检：

```bash
./scripts/check-patches.sh
```

它逐个 hunk 比对 `@@` 声明行数与实际行数 —— 历史上那次 DTS 被静默截断
（`@@ -0,0 +1,466 @@` 却写了 468 行）就是这类问题。
