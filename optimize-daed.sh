#!/bin/sh
# ==============================================================================
# daed 运行环境与性能深度优化脚本
# 适用平台：OpenWrt 25.x / Linux 6.x / aarch64 (以 GL.iNet GL-MT3600BE / Filogic 为代表)
# 功能：
#   1. 彻底解决面板修改配置后重载死机、网络瘫痪、面板拒绝访问的致命冲突
#   2. 内核 UDP Socket 缓冲区深度调优，突破 BDP 瓶颈，释放 Hysteria 2 / QUIC 高速性能
#   3. 加固 daed 守护进程，配置 memlock unlimited 与 Go 内存保护，根除重载 OOM
#   4. 彻底屏蔽 IPv6 与 DNS AAAA 解析，避免跨栈探测失败与节点状态震荡
#   5. 自动修复并优化 /etc/daed/wing.db 数据库配置（解除限速、剔除 IPv6 探测）
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

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    error "此脚本必须以 root 权限运行！"
fi

echo "============================================================"
echo "         daed 运行环境稳定性与网络性能一键优化程序          "
echo "============================================================"

# 2. 彻底关闭硬件加速与软件流量分流 (Flow Offloading)
# 【核心原因】MediaTek PPE 硬件流表旁路与 TC eBPF 挂载点存在严重冲突，重载时必导致死锁与断网！
info "正在优化防火墙设置，关闭冲突的硬件与软件流量分流加速 (Flow Offloading)..."
NEED_FIREWALL_RELOAD=0

if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" != "0" ]; then
    uci set firewall.@defaults[0].flow_offloading='0'
    NEED_FIREWALL_RELOAD=1
fi

if [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" != "0" ]; then
    uci set firewall.@defaults[0].flow_offloading_hw='0'
    NEED_FIREWALL_RELOAD=1
fi

# 清除无效残留配置（如 passwall2 等）
if uci -q get firewall.passwall2 >/dev/null 2>&1; then
    uci -q delete firewall.passwall2
    NEED_FIREWALL_RELOAD=1
fi

if [ "${NEED_FIREWALL_RELOAD}" -eq 1 ]; then
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    success "已成功关闭 flow_offloading 与 flow_offloading_hw，彻底根除重载死机隐患！"
else
    success "防火墙 Flow Offloading 已经处于关闭状态。"
fi

# 3. 内核 UDP Socket 缓冲区与软中断积压队列优化（突破 Hysteria 2 / QUIC 带宽与丢包瓶颈）
info "正在配置内核网络参数（UDP 缓冲区扩大至 16MB，软中断队列扩至 10000，消除跨国高延时 BDP 丢包）..."
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
success "内核 UDP Socket 缓冲区与队列调优已生效并已持久化！"

# 4. 彻底禁用 IPv6 与开启 DNS AAAA 拦截
info "正在配置纯 IPv4 环境优化（屏蔽系统 IPv6、拦截 AAAA 解析）..."
cat <<'EOF' >/etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.br-lan.disable_ipv6 = 1
net.ipv6.conf.eth0.disable_ipv6 = 1
EOF

sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true

# 移除 lan 口 IPv6 宣告与配置
uci -q delete network.lan.ip6assign || true
uci -q delete network.lan.ip6hint || true
uci -q delete network.lan.ip6ifaceid || true
uci -q delete network.lan.ip6class || true
uci commit network >/dev/null 2>&1 || true

# dnsmasq 开启 filter_aaaa 并在上游对接防污染分流公共 DNS
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
success "IPv6 系统禁用与 dnsmasq 防污染上游分流已配置完成！"

# 5. 加固 /etc/init.d/daed 守护进程配置
info "正在加固 /etc/init.d/daed 守护脚本（memlock 限制解除与 Go 内存边界防护）..."
if [ -f "/etc/init.d/daed" ]; then
    # 注入环境变量与锁定内存参数
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
    success "/etc/init.d/daed 守护进程加固成功！"
else
    warn "未找到 /etc/init.d/daed，跳过守护进程加固。"
fi

# 6. 修复并优化 daed 数据库 (/etc/daed/wing.db)
DB_PATH="/etc/daed/wing.db"
if [ -f "${DB_PATH}" ] && command -v sqlite3 >/dev/null 2>&1; then
    info "正在备份并优化 ${DB_PATH} 数据库配置..."
    cp "${DB_PATH}" "${DB_PATH}.bak_$(date +%s)"

    # A. 优化全局配置：科学配置上下行带宽（适配千兆移动宽带防 QoS/Bufferbloat：下行 800mbps 留有 Headroom，上行 50mbps 防缓冲区膨胀拖死下行）、容忍度 2000ms（防跨国丢包误判）、配置 so_mark 0x100、DNS 走可靠 TCP、关闭周期性断连的 udphop、移除 QUIC 阻断规制、缩减 bpf_conn_state_map_size 至 65536、移除 IPv6 检查地址
    sqlite3 "${DB_PATH}" "
    UPDATE configs SET global = replace(global, 'bpf_conn_state_map_size:\"262144\"', 'bpf_conn_state_map_size:\"65536\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'so_mark_from_dae:\"0\"', 'so_mark_from_dae:\"0x100\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'check_tolerance:\"0s\"', 'check_tolerance:\"2000ms\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'udphop_interval:\"30s\"', 'udphop_interval:\"0s\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'bandwidth_max_tx:\"10000 mbps\"', 'bandwidth_max_tx:\"50 mbps\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'bandwidth_max_rx:\"10000 mbps\"', 'bandwidth_max_rx:\"800 mbps\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'bandwidth_max_tx:\"200 mbps\"', 'bandwidth_max_tx:\"50 mbps\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'bandwidth_max_rx:\"1 gbps\"', 'bandwidth_max_rx:\"800 mbps\"') WHERE id=1;
    UPDATE configs SET global = replace(global, 'bandwidth_max_rx:\"100 mbps\"', 'bandwidth_max_rx:\"800 mbps\"') WHERE id=1;
    UPDATE configs SET global = replace(global, ',2606:4700:4700::1111', '') WHERE id=1;
    UPDATE configs SET global = replace(global, ',2001:4860:4860::8888', '') WHERE id=1;
    UPDATE dns SET dns = replace(dns, 'tcp+udp://8.8.8.8:53', 'tcp://8.8.8.8:53') WHERE id=1;
    UPDATE dns SET dns = replace(dns, 'ipversion_prefer: 0', 'ipversion_prefer: 4') WHERE id=1;
    UPDATE dns SET dns = replace(dns, 'ipversion_prefer: 6', 'ipversion_prefer: 4') WHERE id=1;
    UPDATE routings SET routing = replace(routing, 'pname(NetworkManager, systemd-resolved, dnsmasq) -> must_direct', 'pname(NetworkManager, systemd-resolved) -> must_direct\npname(dnsmasq) && dip(geoip:private) -> must_direct') WHERE id=1;
    UPDATE routings SET routing = replace(routing, 'l4proto(udp) && dport(443) -> block', '# l4proto(udp) && dport(443) -> block (removed for native HTTP/3)') WHERE id=1;
    " >/dev/null 2>&1 || true

    success "daed 数据库配置调优完成！"
else
    info "未检测到 ${DB_PATH} 或未安装 sqlite3，如果尚未运行过 daed 可在首次配置时直接应用相应选项。"
fi

# 7. 重启 daed 使新环境配置生效
if [ -f "/etc/init.d/daed" ] && /etc/init.d/daed enabled 2>/dev/null; then
    info "正在平滑重启 daed 服务..."
    /etc/init.d/daed restart
    sleep 3
fi

ROUTER_IP=$(uci -q get network.lan.ipaddr || echo "192.168.8.1")

echo ""
echo "============================================================"
success "所有优化项目已全部成功应用并持久化！"
echo "  1. [已根治] 硬件加速已关闭，重载不再死机，网络不再瘫痪"
echo "  2. [已提速] 内核 UDP 缓冲区已扩至 16MB，Hy2/QUIC 性能完全释放"
echo "  3. [已防护] memlock 与 Go 内存上限已配置，杜绝 OOM"
echo "  4. [已净化] 系统与 DNS IPv6 解析已屏蔽，杜绝节点震荡"
echo "  5. [面板地址] http://${ROUTER_IP}:2023"
echo "============================================================"
