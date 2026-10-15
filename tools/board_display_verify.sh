#!/bin/bash
# ============================================================================
#  文件名称 : board_display_verify.sh
#  功能描述 : 在【板子上】验证「屏幕 + 触摸」是否真的起来了（只读）。
#
#  为什么必须是「在板子上跑」：
#    这脚本读的是 /dev/fb0、/proc/device-tree、dmesg、/sys/class/backlight，
#    全是【运行中那台机器】的状态。曾经在 WSL 主机上直接跑过一次，
#    拿到的是 WSL 的 /dev 与 WSL 的内核（6.6.87.2-microsoft-standard-WSL2），
#    输出了 PASS=0 FAIL=5 的假结论 —— 屏幕上那些 FAIL 一个都不代表板子。
#    所以本脚本现在会先做「我是不是在板子上」自检，不是就直接拒绝运行。
#
#  用法：
#    板子串口 shell 里：      sh board_display_verify.sh
#    WSL/PC 侧远程跑：        bash board_display_verify.sh <板子IP>
#                            （走 ssh root@<IP>，WAN 防火墙会 drop，
#                              需先在板子上 /etc/init.d/firewall stop）
#  修改日期 : 2026-10-15
# ============================================================================
set -u

# ---------------------------------------------------------------------------
# 自检：拒绝在非板子环境（WSL / 普通 PC）上跑出假结论
# ---------------------------------------------------------------------------
on_board=1
case "$(uname -r 2>/dev/null)" in
    *microsoft*|*WSL*) on_board=0; why="内核 $(uname -r) 是 WSL 的" ;;
esac
if [ -d /proc/device-tree ] && [ ! -e /proc/device-tree/model ]; then
    on_board=0; why="${why:+$why; }/proc/device-tree 没有 model"
fi

if [ "$on_board" = 0 ] && [ "$#" -eq 0 ]; then
    echo "============================================================"
    echo " 拒绝运行：这里不是 i.MX6ULL 板子"
    echo "   原因：${why:-未检出设备树}"
    echo "   本机：$(uname -sr)"
    echo "============================================================"
    echo
    echo "  本脚本必须在【板子上】执行。两条路："
    echo "    1) 板子串口 shell 里：  sh board_display_verify.sh"
    echo "    2) 从这边远程跑：       bash board_display_verify.sh <板子IP>"
    exit 2
fi

# ---------------------------------------------------------------------------
# 远程模式：把脚本自己丢到板子上跑
# ---------------------------------------------------------------------------
if [ "$#" -ge 1 ]; then
    IP="$1"; PORT="${2:-22}"
    command -v ssh >/dev/null 2>&1 || { echo "本机没有 ssh"; exit 2; }
    echo "==> 远程模式：root@$IP:$PORT"
    ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -p "$PORT" "root@$IP" \
        'cat > /tmp/bdv.sh && sh /tmp/bdv.sh' < "$0"
    exit $?
fi

PASS=0
FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }

echo "============================================================"
echo " 板端显示/触摸验证"
echo " 时间: $(date 2>/dev/null)"
echo " 内核: $(uname -r)"
echo " 机型: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
echo "============================================================"

echo
echo "--- 1. DRM / framebuffer 设备节点 ---"
if [ -e /dev/fb0 ]; then
    ok "/dev/fb0 存在"
    info "尺寸: $(fbset 2>/dev/null | sed -n 's/.*geometry \([0-9x]*\).*/\1/p' | head -1)"
else
    bad "/dev/fb0 不存在"
fi
for d in /dev/fb1 /dev/dri; do
    [ -e "$d" ] && info "$d 存在" || info "$d 不存在"
done
info "/sys/class/graphics/: $(ls /sys/class/graphics/ 2>/dev/null | tr '\n' ' ')"

echo
echo "--- 2. mxsfb / DRM 驱动是否绑定 ---"
mxsfb=$(dmesg 2>/dev/null | grep -iE 'mxsfb|panel-simple|pwm-backlight' | head -12)
if [ -n "$mxsfb" ]; then
    echo "$mxsfb" | sed 's/^/    /'
    ok "dmesg 里有显示相关日志"
else
    bad "dmesg 里没有任何 mxsfb/panel/backlight 日志"
fi
if [ -d /sys/bus/platform/drivers/mxsfb-lcdif ]; then
    info "mxsfb 驱动已注册: $(ls /sys/bus/platform/drivers/mxsfb-lcdif/ 2>/dev/null | tr '\n' ' ')"
fi

echo
echo "--- 3. 背光 ---"
bl=$(ls /sys/class/backlight/ 2>/dev/null | head -1)
if [ -n "$bl" ]; then
    ok "背光设备: $bl"
    info "最大亮度: $(cat /sys/class/backlight/$bl/max_brightness 2>/dev/null)"
    info "当前亮度: $(cat /sys/class/backlight/$bl/brightness 2>/dev/null)"
else
    bad "/sys/class/backlight/ 是空的（背光 pwm-backlight 没起来）"
fi

echo
echo "--- 4. 触摸 input 设备 ---"
n=0
if [ -d /dev/input ]; then
    for e in /dev/input/event*; do
        [ -e "$e" ] || continue
        n=$((n+1))
        nm=$(cat /sys/class/input/$(basename "$e")/device/name 2>/dev/null)
        info "$e -> ${nm:-未知}"
    done
fi
if [ "$n" -gt 0 ]; then
    ok "找到 $n 个 input event 设备"
else
    bad "/dev/input/ 下没有 event 设备"
fi
if grep -qi goodix /proc/bus/input/devices 2>/dev/null; then
    ok "input 设备列表里有 Goodix"
    grep -i -A2 -B2 goodix /proc/bus/input/devices | sed 's/^/    /'
else
    bad "没有 Goodix 设备（goodix 驱动没 probe 成功）"
fi
dmesg 2>/dev/null | grep -i goodix | head -12 | sed 's/^/    /'

echo
echo "--- 5. I2C：适配器、引脚复用、哪些总线上有器件 ---"
info "内核注册的 i2c 适配器（/sys/class/i2c-dev 与 /dev/i2c-*）:"
for a in /sys/bus/i2c/devices/i2c-*; do
    [ -e "$a" ] || continue
    ab=$(basename "$a")
    printf '      %-8s name=%-24s of_node=%s\n' "$ab" \
        "$(cat "$a/name" 2>/dev/null)" \
        "$(basename "$(readlink -f "$a/of_node" 2>/dev/null)" 2>/dev/null)"
done
info "/dev/ 下的 i2c 字符设备: $(ls /dev/i2c-* 2>/dev/null | tr '\n' ' ')"
info "挂在各总线上的器件:"
for a in /sys/bus/i2c/devices/*-*; do
    [ -e "$a" ] || continue
    printf '      %-10s name=%s\n' "$(basename "$a")" "$(cat "$a/name" 2>/dev/null)"
done
if command -v i2cdetect >/dev/null 2>&1; then
    for b in 0 1 2 3; do
        [ -e "/dev/i2c-$b" ] || continue
        echo "    --- i2cdetect -y $b ---"
        i2cdetect -y "$b" 2>&1 | sed 's/^/      /'
    done
else
    info "没有 i2cdetect（可 opkg install i2c-tools），跳过；下面用设备树反推引脚"
fi

echo
echo "--- 6. 设备树：面板/背光/触摸节点与 I2C 引脚的**实际生效值** ---"
# 取值助手：BusyBox 上 `od` 常常不存在（取值会静默变空，于是"看起来全绿"）。
# hexdump 优先，退到 od，再不济 tr -d '\0' 读可打印属性。
hexof() {
    [ -e "$1" ] || return 0
    if command -v hexdump >/dev/null 2>&1; then
        hexdump -v -e '" " 1/1 "%02x"' "$1" 2>/dev/null
    elif command -v od >/dev/null 2>&1; then
        od -An -tx1 "$1" 2>/dev/null | tr -s ' \n' ' '
    else
        tr -d '\0' < "$1" 2>/dev/null; echo
    fi
}
# 节点定位助手：DT 里节点不在根下（lcdif@21c8000 在 /soc/bus@2100000/ 下、
# pwm@2080000 在 /soc/bus@2000000/ 下），按 basename 全树找才可靠。
dt_find() {   # $1 = 节点名
    for _p in /proc/device-tree/*/*/*/* /proc/device-tree/*/*/* /proc/device-tree/*/* \
              /proc/device-tree/*; do
        [ -e "$_p" ] || continue
        [ "$(basename "$_p")" = "$1" ] && { echo "$_p"; return 0; }
    done
    return 1
}
if [ -d /proc/device-tree ]; then
    for p in panel-dpi backlight-display pwm-backlight lcdif@21c8000 pwm@2080000; do
        np=$(dt_find "$p")
        if [ -n "$np" ]; then
            ok "device-tree 里有 $p  （$np）"
        else
            bad "device-tree 里没有 $p"
        fi
    done

    ts=""
    for c in /proc/device-tree/soc/*/i2c@*/*@* /proc/device-tree/soc/*/*/i2c@*/*@*; do
        [ -e "$c" ] || continue
        case "$(tr '\0' ' ' < "$c/compatible" 2>/dev/null)" in
            *goodix*)
                ts="$c"
                nm=$(basename "$c")
                ok "找到 goodix 节点: $nm"
                info "  compatible = $(tr '\0' ' ' < "$c/compatible")"
                info "  reg(hex)   = $(hexof "$c/reg")"
                for prop in irq-gpios reset-gpios vddio-supply avdd28-supply interrupt-parent interrupts; do
                    [ -e "$c/$prop" ] && info "  $prop = $(hexof "$c/$prop")"
                done
                # 父节点 = 它挂在哪个 i2c 控制器上
                info "  父节点(所属 i2c 控制器) = $(basename "$(dirname "$c")")"
                case "$nm" in
                    *@5d) ok "I2C 地址 0x5d（2026-10-15 板端实测地址，正解）" ;;
                    *@14) bad "I2C 地址是 0x14 —— 板上扫不到器件，probe 会 -EREMOTEIO，需改成 0x5d 重烧 dtb" ;;
                    *)    info "I2C 地址既不是 0x5d 也不是 0x14，核对硬件与 reg 属性" ;;
                esac
                ;;
        esac
    done
    [ -n "$ts" ] || bad "device-tree 里找不到任何 goodix 触摸节点"

    # I2C 控制器的 pinctrl 与 status
    echo "    --- i2c 控制器的 pinctrl / status ---"
    for c in /proc/device-tree/soc/*/i2c@* /proc/device-tree/soc/*/*/i2c@*; do
        [ -e "$c" ] || continue
        cn=$(basename "$c")
        st=$(tr -d '\0' < "$c/status" 2>/dev/null)
        ph=$(ls "$c" 2>/dev/null | grep -i pinctrl | tr '\n' ' ')
        printf '      %-16s status=%-8s pinctrl属性=[%s]\n' "$cn" "${st:-<无>}" "$ph"
        for pp in pinctrl-0 pinctrl-names; do
            [ -e "$c/$pp" ] && printf '          %-14s = %s\n' "$pp" "$(hexof "$c/$pp")"
        done
    done

    # 被引用的 pinctrl 组里到底写了哪几个 pad（这是查「引脚是不是真的复用了」的铁证）
    echo "    --- 与 i2c2 相关的 pinctrl 组内容 ---"
    for g in /proc/device-tree/soc/*/pinctrl@*/*grp* /proc/device-tree/soc/*/*/pinctrl@*/*grp*; do
        [ -e "$g" ] || continue
        gn=$(basename "$g")
        case "$gn" in
            *i2c*|*tsc*|*touch*)
                printf '      %-20s fsl,pins = %s\n' "$gn" "$(hexof "$g/fsl,pins")"
                ;;
        esac
    done

    lc=$(dt_find "lcdif@21c8000")
    st=$(tr -d '\0' < "${lc:-/nonexistent}/status" 2>/dev/null)
    [ -n "$st" ] && info "lcdif status = $st   （$lc）"
else
    info "没有 /proc/device-tree，跳过"
fi

echo
echo "--- 7. 看门狗与重启原因（『屏幕亮着但一直重启』要查这里）---"
info "procd 看门狗超时: $(uci get system.@system[0].watchdog_timeout 2>/dev/null || echo '<未设置>')"
info "watchdog 设备: $(ls /dev/watchdog* 2>/dev/null | tr '\n' ' ')"
for w in /sys/class/watchdog/watchdog*; do
    [ -e "$w" ] || continue
    printf '      %s: identity=%s timeout=%s state=%s\n' "$(basename "$w")" \
        "$(cat "$w/identity" 2>/dev/null)" "$(cat "$w/timeout" 2>/dev/null)" \
        "$(cat "$w/state" 2>/dev/null)"
done
wdt=$(dmesg 2>/dev/null | grep -iE 'watchdog|wdt' | head -8)
[ -n "$wdt" ] && echo "$wdt" | sed 's/^/    /' || info "dmesg 里没有 watchdog 日志"
info "最近一次重启原因: $(cat /sys/class/watchdog/watchdog0/bootstatus 2>/dev/null || echo '<查不到>')"
info "运行时长: $(cut -d. -f1 /proc/uptime 2>/dev/null) 秒"
info "control_center 状态: $(ps w 2>/dev/null | grep -c '[c]ontrol_center') 个进程"
info "内存: $(free -m 2>/dev/null | sed -n 2p | awk '{print "total="$2"M used="$3"M free="$4"M"}')"

echo
echo "============================================================"
echo " 结果: PASS=$PASS FAIL=$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
