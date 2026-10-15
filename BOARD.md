# 板级接口与默认配置

本文记录正点原子 i.MX6ULL 阿尔法开发板（`imx6ull-atk-mmc`）在固件里的接口分配与
出厂默认配置。全部内容取自本工程源码（含补丁改过的上游文件），不是推测。

---

## 网口：哪个是 WAN，哪个是 LAN

`target/linux/imx/cortexa7/base-files/etc/board.d/02_network`：

```sh
imx6ull-atk-mmc)
	ucidef_set_interfaces_lan_wan "eth1" "eth0"
	;;
```

即 **LAN = `eth1`，WAN = `eth0`**。

对应到 SoC 与设备树：

| Linux 网卡 | SoC 控制器 | DTS 节点 | 角色 | 地址 | 板上位置 |
|---|---|---|---|---|---|
| `eth0` | `20b4000.ethernet` | `&fec1` | **WAN** | DHCP 客户端 | **靠 RS232 串口那一侧** |
| `eth1` | `2188000.ethernet` | `&fec2` | **LAN** | 192.168.1.1 | **靠 USB 那一侧** |

> 物理位置是 2026-10-15 在本板上实测确认的：**`eth0`（WAN）在 RS232 串口那一侧，
> `eth1`（LAN）在 USB 那一侧**。别只按 `eth0`/`eth1` 的名字去找口。

两个口都是 RMII 接 PHY（`ethphy0` 地址 2、`ethphy1` 地址 1），各自带一个 PHY 复位 GPIO
（`gpio5 7` / `gpio5 8`）。

### 坑：U-Boot 里的 eth0/eth1 编号与 Linux 相反

启动时的 U-Boot 输出：

```
Warning: ethernet@20b4000 (eth1) using random MAC address - da:a4:c3:5c:e5:a1
Warning: ethernet@2188000 (eth0) using random MAC address - f2:fa:34:69:6d:cd
```

而 Linux 里 `20b4000` 是 `eth0`：

```
fec 20b4000.ethernet eth0: registered PHC device 0
fec 2188000.ethernet eth1: registered PHC device 1
```

所以在 U-Boot 里 `setenv ethaddr` 设的是 Linux 的 **eth1（LAN）**，
`setenv eth1addr` 设的是 Linux 的 **eth0（WAN）**。按 MAC 的值反查最稳妥。

---

## 无线：默认就是一个无密码热点

`/etc/config/wireless` 在**首次启动时**由 `mac80211.sh` 生成，模板写死在脚本里
（`package/kernel/mac80211/files/lib/wifi/mac80211.sh:208-213`）：

| 项 | 默认值 |
|---|---|
| 段名 | `radio0`（wifi-device）+ `default_radio0`（wifi-iface） |
| 模式 | `ap` —— 板子自己当热点 |
| SSID | `OpenWrt` |
| 加密 | `none` —— **完全开放，谁都能连** |
| 挂到哪个网络 | `lan` —— 桥进 `br-lan`，与 LAN 口同一个二层网络 |
| 信道 | 按识别到的 phy 默认（实测 channel 1 / 2412 MHz / HT20） |

连上后手机拿到的是 LAN 地址段（192.168.1.x）。

**默认没有密码，第一次进系统就该改掉**：

```bash
uci set wireless.default_radio0.ssid='ATK-OpenWrt'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='12345678'
uci commit wireless
wifi reload
```

`option path` 与 USB 物理口绑定，见下面「USB」一节。

---

## 4G 接口：`wan_4g`，按 RNDIS 模式预置

首次启动时由 `config_generate` 的 `generate_4g_network()` 生成
（`package/base-files/files/bin/config_generate:228`）：

```
network.wan_4g.proto  = dhcp
network.wan_4g.device = usb0
network.wan_4g.metric = 1
```

含义：

- 就是一个**「插上就能用」的 DHCP 网卡**，网卡名写死为 `usb0`；
- `usb0` 这个名字只在模块处于 **RNDIS 模式**时才出现；
- `metric=1` 大于有线 WAN 的 `metric=0`（`generate_network` 里把 `network.wan.metric`
  设为 0），所以**有线上网优先，4G 是备份** —— 这就是「有线/4G 自动切换」的实现。

### 模块在 QMI 模式下会起不来

EC20 出厂常见默认是 QMI 模式，此时网卡叫 `wwan0`、设备节点是 `/dev/cdc-wdm0`，
与预置的 `usb0` 对不上，`wan_4g` 拿不到 IP。两条路：

**方案 A —— 改用 QMI 协议（不动模块）**。固件自带 `qmi.sh`：

```bash
uci set network.wan_4g.proto='qmi'
uci set network.wan_4g.device='/dev/cdc-wdm0'
uci commit network && /etc/init.d/network restart
```

**方案 B —— 把模块切成 RNDIS**，让 `usb0` 出现（AT 通道在 `/dev/ttyUSB2`）：

```
AT+QCFG="usbnet"        # 先查当前模式：0=QMI 1=ECM 2=MBIM 3=RNDIS
AT+QCFG="usbnet",3      # 改成 RNDIS
AT+CFUN=1,1             # 复位模块，等 10~20 秒重新枚举
```

> 补丁 `0100` 最初预置的是 `network.qmi`（`proto=qmi` / `/dev/cdc-wdm0` / `qpn=cmnet`），
> 补丁 `0113` 把它改成了现在的 `wan_4g`（`proto=dhcp` / `usb0`）。
> 所以**最终生效的是 RNDIS 方案**。

---

## USB：两个模块插在哪儿

DTS 里两个 USB 控制器的分工（`project/dts/imx6ull-atk-mmc.dts:419,429`）：

```dts
&usbotg1 { dr_mode = "otg";  ... };   /* 2184000.usb —— OTG */
&usbotg2 { dr_mode = "host"; ... };   /* 2184200.usb —— 主机模式 */
```

两个模块都挂在 **USB_OTG2（`2184200.usb`，host 模式）** 这一路。启动日志给出的完整链路：

```
ci_hdrc.1: EHCI Host Controller        ← 2184200.usb
hub 1-0:1.0: 1 port detected           ← SoC 自己的根集线器只有 1 个口
usb 1-1: new high-speed USB device     ← 接了一个 4 口 HUB
hub 1-1:1.0: 4 ports detected
usb 1-1.1: ...                         ← WiFi 网卡（RTL8188EU）
usb 1-1.4: ...                         ← 4G 模块（Quectel EC20）
```

| 设备 | 位置 | 换口有影响吗 |
|---|---|---|
| RTL8188EU（WiFi） | `1-1.1` —— HUB 的 1 号口 | **有**，见下 |
| EC20（4G） | `1-1.4` —— HUB 的 4 号口 | 没有 |

### 回答「WiFi 插哪个口」

两个模块接的**不是** SoC 直出的口，而是同一个 4 口 HUB 后面。

- **4G**：插哪个口都行。内核靠 `option` / `qmi_wwan` 驱动认设备，与物理位置无关。
- **WiFi**：第一次被认出来时在 1 号口，而 `/etc/config/wireless` 里把**这个物理位置写死了**：

  ```
  option path 'platform/soc/2100000.bus/2184200.usb/ci_hdrc.1/usb1/1-1/1-1.1/1-1.1:1.0'
  ```

  **换到别的 USB 口，这个 path 就对不上，`radio0` 起不来。** 换口后执行
  `wifi config` 重新生成配置，或手工改 `option path`。

### 供电

4G 模块峰值电流较大，与 WiFi 网卡共用一个总线供电的 HUB 时容易枚举失败或反复掉线，
建议用带独立供电的 HUB。

日志里的 `imx_usb 2184000.usb: No over current polarity defined` 是 OTG1 口的提示，
不影响功能。

---

## 默认地址与 DHCP

| 项 | 值 | 来源 |
|---|---|---|
| LAN 地址 | `192.168.1.1/24` | `config_generate:165`（`lan` 的默认值硬编码于此） |
| DHCP 池 | `192.168.1.100` 起，150 个（至 .249） | `package/network/services/dnsmasq/files/dhcp.conf` |
| 租期 | 12h | 同上 |
| 域名 | `.lan` | 同上 |
| WAN | DHCP 客户端，`metric=0` | `generate_network` |
| WAN 侧的 DHCP 服务 | 关闭（`option ignore 1`） | 同上 |

---

## 默认防火墙

来自 `package/network/config/firewall/files/firewall.config`（补丁 `0100` 改过）。

| 区域 | 包含接口 | input | output | forward | 其它 |
|---|---|---|---|---|---|
| `lan` | `lan` | ACCEPT | ACCEPT | ACCEPT | —— |
| `wan` | `wan`、`wan6` | **ACCEPT**（上游默认是 REJECT） | ACCEPT | REJECT | `masq 1`、`mtu_fix 1` |

- 转发规则：`lan → wan`（内网可以出去）
- 全局默认：`input REJECT`、`output ACCEPT`、`forward REJECT`，开启 `syn_flood` 防护

> 补丁把 `wan` 区域的 `input` 从上游默认的 `REJECT` 改成了 `ACCEPT` ——
> 意味着 WAN 口可被外部主动连接。便于调试，但比默认宽松。

### `wan_4g` 不在任何 zone 里

这是默认配置的一个缺口。后果：4G 拨通后

- 板子自己能上网（`output` 放行）
- **LAN 上的设备不能用 4G 上网**

要让 LAN 共享 4G：

```bash
uci add_list firewall.@zone[1].network='wan_4g'
uci commit firewall && /etc/init.d/firewall restart
```

---

## Web 管理界面（LuCI）

**镜像里就有，中文界面，开箱可用。** 浏览器打开 `192.168.1.1`（LAN 口 `eth1` 或默认
WiFi 都到得了），含「状态 / 系统 / 网络 / 防火墙 / 软件包」五组页面；另有 `ttyd`
网页终端（LuCI「服务 → 终端」）。首次登录 `root` **无密码**，登录后请立刻在
「系统 → 管理权」设一个。

它随固件一起来，不需要联网安装。与本机相关的只有两点：

- 本工程 defconfig 启用了 `luci=y` 等 26 个 luci 包（含中文）+ `ttyd`；
- **LuCI 不在 OpenWrt 核心仓库里，而在 feeds 里** —— 所以**自己从头构建**时必须先跑
  `./scripts/feeds.sh`，否则这些符号会被 `make defconfig` 静默丢弃，编出的固件只剩
  核心仓库自带的 `uhttpd` + `rpcd`，`192.168.1.1` 打不开管理页面：

  ```bash
  ./scripts/feeds.sh    # 拉取 feeds（首次约 200 MB）
  ./scripts/setup.sh    # 重跑，让 luci 符号进入 .config
  ./scripts/build.sh
  ```

  详见 README 的「已知坑与排查」。

---

## 速查

| 问题 | 答案 |
|---|---|
| LAN 是哪个网口 | `eth1`（`2188000.ethernet`） |
| WAN 是哪个网口 | `eth0`（`20b4000.ethernet`） |
| LAN 口在板子哪一侧 | 靠 **USB** 那一侧（`eth1`，板上实测） |
| WAN 口在板子哪一侧 | 靠 **RS232** 串口那一侧（`eth0`，板上实测） |
| 板子默认 IP | `192.168.1.1` |
| 默认 WiFi | SSID `OpenWrt`，**无密码**，AP 模式，桥进 LAN |
| WiFi 走哪路 USB | USB_OTG2（host），HUB 的 1 号口（`1-1.1`） |
| 4G 走哪路 USB | USB_OTG2（host），HUB 的 4 号口（`1-1.4`） |
| 4G 接口叫什么 | `wan_4g`（`proto=dhcp`、`device=usb0`、`metric=1`） |
| 有线 / 4G 谁优先 | 有线（`metric=0` < 4G 的 `1`），4G 自动接管 |
| 4G 能给 LAN 用吗 | 默认不能，`wan_4g` 没进防火墙 zone |
| 防火墙 WAN 入站 | `ACCEPT`（被补丁放宽过） |
| 有 LuCI 吗 | **有**，中文界面：浏览器开 `192.168.1.1`（`root` 首次无密码） |
