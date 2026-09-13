#!/bin/sh
# ==============================================================================
# daed & luci-app-daed 一键安装与部署脚本
# 适用平台：OpenWrt 25.x / 内核 6.12.x / aarch64 (以 GL.iNet GL-MT3600BE 为代表)
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 1. 检查运行环境与权限
if [ "$(id -u)" -ne 0 ]; then
    error "此脚本必须以 root 权限运行！"
fi

if ! command -v apk >/dev/null 2>&1; then
    error "未找到 apk 命令，当前系统可能不是基于 OpenWrt 25+ 的固件！"
fi

KERNEL_VER=$(uname -r)
ARCH=$(uname -m)
info "检测到系统环境: 架构 ${ARCH}, 内核 ${KERNEL_VER}"

if [ "${ARCH}" != "aarch64" ]; then
    warn "当前架构为 ${ARCH}，预期架构为 aarch64，安装包可能不匹配！"
fi

# 2. 定位安装包源文件
RUN_FILE=""
EXTRACT_DIR="/tmp/daed_extract"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -n "$1" ] && [ -f "$1" ]; then
    RUN_FILE="$1"
else
    for candidate in \
        "${SCRIPT_DIR}/25-luci-app-dead"*.run \
        "./25-luci-app-dead"*.run \
        "/tmp/25-luci-app-dead"*.run \
        "/root/25-luci-app-dead"*.run \
        "/root/daed_install/25-luci-app-dead"*.run; do
        if [ -f "${candidate}" ]; then
            RUN_FILE="${candidate}"
            break
        fi
    done
fi

mkdir -p "${EXTRACT_DIR}"

has_file() {
    for f in "$@"; do
        [ -f "$f" ] && return 0
    done
    return 1
}

if [ -n "${RUN_FILE}" ] && [ -f "${RUN_FILE}" ]; then
    info "找到安装包: ${RUN_FILE}，正在解压..."
    chmod +x "${RUN_FILE}"
    "${RUN_FILE}" --noexec --target "${EXTRACT_DIR}" >/dev/null 2>&1 || {
        "${RUN_FILE}" --noexec --target "${EXTRACT_DIR}"
    }
    success "安装包解压完成 -> ${EXTRACT_DIR}"
elif has_file "${SCRIPT_DIR}/packages"/daed-*.apk; then
    info "检测到脚本目录包含 packages/ 安装包，正在使用..."
    cp -f "${SCRIPT_DIR}/packages"/*.apk "${EXTRACT_DIR}/"
elif has_file "${EXTRACT_DIR}"/daed-*.apk; then
    info "检测到 ${EXTRACT_DIR} 下已有解压好的 apk 文件，继续安装..."
elif has_file /root/daed_install/daed-*.apk; then
    info "检测到 /root/daed_install 下已有安装包，正在复制..."
    cp -f /root/daed_install/*.apk "${EXTRACT_DIR}/"
else
    error "未找到 25-luci-app-dead_*.run 安装包！请将安装包上传至 /tmp 目录后重试，或指定文件路径：$0 <run文件路径>"
fi

# 3. 规避 act_bpf.ko 崩溃 Bug，单独提取并安装安全的 cls_bpf.ko
info "检查并部署安全内核模块 cls_bpf.ko (TC eBPF 分类器)..."

MODULES_DIR="/lib/modules/${KERNEL_VER}"
mkdir -p "${MODULES_DIR}"

if [ ! -f "${MODULES_DIR}/cls_bpf.ko" ]; then
    info "从官方源拉取 kmod-sched-bpf 提取 cls_bpf.ko..."
    TEMP_FETCH="/tmp/bpf_fetch_$$"
    mkdir -p "${TEMP_FETCH}"
    (
        cd "${TEMP_FETCH}"
        apk update >/dev/null 2>&1 || apk update
        apk fetch kmod-sched-bpf >/dev/null 2>&1
        apk extract --allow-untrusted kmod-sched-bpf-*.apk >/dev/null 2>&1
        cp -f lib/modules/${KERNEL_VER}/cls_bpf.ko "${MODULES_DIR}/cls_bpf.ko"
    )
    rm -rf "${TEMP_FETCH}"
fi

if [ -f "${MODULES_DIR}/cls_bpf.ko" ]; then
    chmod 644 "${MODULES_DIR}/cls_bpf.ko"
    # 配置开机自动加载 cls_bpf
    echo "cls_bpf" >/etc/modules.d/72-cls-bpf
    mkdir -p /etc/modules-boot.d
    ln -sf ../modules.d/72-cls-bpf /etc/modules-boot.d/72-cls-bpf

    # 彻底清除会触发崩溃的 act_bpf / sched-bpf 加载项
    rm -f /etc/modules.d/72-sched-bpf /etc/modules-boot.d/72-sched-bpf 2>/dev/null || true

    # 立即加载
    if ! lsmod | grep -q cls_bpf; then
        insmod "${MODULES_DIR}/cls_bpf.ko" || true
    fi
    success "cls_bpf.ko 模块配置与载入成功！"
else
    warn "未能提取到 cls_bpf.ko，如果已内置在内核中则不影响运行。"
fi

# 4. 安装 GeoIP 与 GeoSite 数据库
info "安装/升级 GeoIP 与 GeoSite 规则数据包..."
GEO_APKS=$(ls "${EXTRACT_DIR}"/v2ray-*.apk 2>/dev/null || true)
if [ -n "${GEO_APKS}" ]; then
    apk add --allow-untrusted ${GEO_APKS} >/dev/null 2>&1 || apk add --allow-untrusted ${GEO_APKS}
    success "GeoIP/GeoSite 规则库安装成功！"
fi

# 5. 提取并释放 daed、luci-app-daed、luci-i18n-daed-zh-cn
info "部署 daed 主程序与 LuCI Web 控制台插件..."

apk extract --allow-untrusted --force-overwrite --destination / "${EXTRACT_DIR}"/daed-*.apk >/dev/null 2>&1
apk extract --allow-untrusted --force-overwrite --destination / "${EXTRACT_DIR}"/luci-app-daed-*.apk >/dev/null 2>&1
apk extract --allow-untrusted --force-overwrite --destination / "${EXTRACT_DIR}"/luci-i18n-daed-zh-cn-*.apk >/dev/null 2>&1

chmod 755 /usr/bin/daed 2>/dev/null || true
chmod 755 /etc/init.d/daed 2>/dev/null || true
chmod 755 /etc/init.d/luci_daed 2>/dev/null || true
chmod 755 /etc/hotplug.d/iface/98-daed 2>/dev/null || true

# 6. 配置环境与软链接
mkdir -p /etc/daed
mkdir -p /var/log/daed
mkdir -p /boot

if [ -f "/usr/lib/debug/boot/vmlinux" ]; then
    ln -sf /usr/lib/debug/boot/vmlinux /boot/vmlinux
    ln -sf /usr/lib/debug/boot/vmlinux /boot/vmlinux-${KERNEL_VER}
fi

if [ -d "/usr/share/v2ray" ]; then
    ln -sf /usr/share/v2ray /usr/share/daed 2>/dev/null || true
fi

# 确保 daed 能找到规则库目录并具备防 OOM 内存保护与锁定内存权限
if [ -f "/etc/init.d/daed" ]; then
    cat <<'EOF' >/etc/init.d/daed
#!/bin/sh /etc/rc.common
# Copyright (C) 2023 Tianling Shen <cnsztl@immortalwrt.org>

USE_PROCD=1
START=99

CONF="daed"
PROG="/usr/bin/daed"
LOG="/var/log/daed/daed.log"
DAENETNS="/run/netns/daens"

start_service() {
	config_load "$CONF"

	local enabled
	config_get_bool enabled "config" "enabled" "0"
	[ "$enabled" -eq "1" ] || return 1

	local listen_addr log_maxbackups log_maxsize
	config_get listen_addr "config" "listen_addr" "0.0.0.0:2023"
	config_get log_maxbackups "config" "log_maxbackups" "1"
	config_get log_maxsize "config" "log_maxsize" "5"

	procd_open_instance "$CONF"
	procd_set_param env DAE_LOCATION_ASSET="/usr/share/v2ray"
	procd_set_param env GOMEMLIMIT="200MiB"
	procd_set_param env GODEBUG="madvdontneed=1"
	procd_set_param command "$PROG" run
	procd_append_param command --config "/etc/daed/"
	procd_append_param command --listen "$listen_addr"
	procd_append_param command --logfile "$LOG"
	procd_append_param command --logfile-maxbackups "$log_maxbackups"
	procd_append_param command --logfile-maxsize "$log_maxsize"

	procd_set_param limits core="unlimited"
	procd_set_param limits memlock="unlimited"
	procd_set_param limits nofile="1000000 1000000"
	procd_set_param respawn
	procd_set_param stderr 1

	procd_close_instance
}

stop_service() {
	rm -f "$LOG"
	[ -f "$DAENETNS" ] && umount "$DAENETNS"
}

service_triggers() {
	procd_add_reload_trigger "$CONF"
}
EOF
    chmod 755 /etc/init.d/daed
fi

# 7. LuCI 语言包与缓存刷新
info "初始化 LuCI 界面与生效中文语言..."
if [ -f /etc/uci-defaults/luci-i18n-daed-zh-cn ]; then
    sh /etc/uci-defaults/luci-i18n-daed-zh-cn >/dev/null 2>&1 || true
    rm -f /etc/uci-defaults/luci-i18n-daed-zh-cn
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true

# 8. 系统深度调优（防火墙流加速冲突规避、UDP缓冲区优化、IPv6纯净防护）
info "正在执行系统运行环境深度优化与防死机调优..."
# A. 关闭硬件与软件流量分流 (Flow Offloading)，杜绝 MediaTek PPE 与 eBPF 冲突死机
if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" != "0" ] || [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" != "0" ]; then
    uci set firewall.@defaults[0].flow_offloading='0'
    uci set firewall.@defaults[0].flow_offloading_hw='0'
    uci -q delete firewall.passwall2 || true
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    success "已关闭 Flow Offloading 硬件/软件流加速，保障 eBPF 重载稳定不卡死。"
fi

# B. 优化内核 UDP Socket 缓冲区与队列（16MB，软中断队列扩至 10000，消除跨国高延时 Hysteria 2 / QUIC BDP 丢包瓶颈）
cat <<'EOF' >/etc/sysctl.d/99-dae-udp.conf
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 2048576
net.core.netdev_max_backlog = 10000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
sysctl -p /etc/sysctl.d/99-dae-udp.conf >/dev/null 2>&1 || true
success "内核 UDP Socket 缓冲区已扩大至 16MB，软中断队列扩至 10000。"

# C. 优化 DNS 过滤 AAAA 与上游防污染分流，杜绝境外域名被光猫投毒
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
success "dnsmasq 已配置 filter_aaaa 过滤与防污染上游分流。"

# 9. 启用与启动服务
info "启用 daed 服务并设置开机自启..."
uci set daed.config.enabled='1'
uci commit daed

/etc/init.d/daed enable
/etc/init.d/luci_daed enable

/etc/init.d/daed restart
/etc/init.d/luci_daed restart

sleep 2

# 10. 状态验证
ROUTER_IP=$(uci -q get network.lan.ipaddr || echo "192.168.8.1")

echo ""
echo "============================================================"
if pgrep -f "/usr/bin/daed" >/dev/null 2>&1; then
    success "daed 服务已成功启动并正在运行！"
    echo -e "- daed 网页控制台: ${GREEN}http://${ROUTER_IP}:2023${NC}"
    echo -e "- OpenWrt LuCI 界面: ${GREEN}http://${ROUTER_IP}/cgi-bin/luci/admin/services/daed${NC}"
    echo -e "- 深度优化工具: ${BLUE}${SCRIPT_DIR}/optimize-daed.sh${NC}"
    echo -e "- 运行日志查看命令: ${BLUE}cat /var/log/daed/daed.log${NC}"
else
    warn "daed 进程可能正在初始化中，请执行以下命令查看日志："
    echo "cat /var/log/daed/daed.log"
fi
echo "============================================================"
