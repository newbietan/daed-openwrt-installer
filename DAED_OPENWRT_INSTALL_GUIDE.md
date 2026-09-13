# GL-MT3600BE (OpenWrt 25.x / 内核 6.12.x) 安装 daed 与 LuCI 插件完整指南

本文详细记录了在基于 OpenWrt 25 的联发科 Wi-Fi 7 路由器（以 GL.iNet GL-MT3600BE 为例）上安装部署 **daed**（基于 eBPF 的高性能透明代理）及其 LuCI 网页控制界面的完整过程、遇到的深层问题分析与终极解决方案。

---

## 一、 设备与系统环境说明

- **硬件型号**：GL.iNet GL-MT3600BE (MediaTek Filogic / aarch64_cortex-a53)
- **固件架构**：基于 OpenWrt 25.12.5 (r33051)
- **Linux 内核**：`6.12.94`
- **默认包管理器**：`apk` (apk-tools 3.0，OpenWrt 25+ 已全面替换传统 `opkg`)
- **安装目标**：
  - `daed` 核心服务 (dae eBPF 后端 + 前端 Web UI)
  - `luci-app-daed` & `luci-i18n-daed-zh-cn` (LuCI 管理插件及简体中文)
  - `v2ray-geoip` & `v2ray-geosite` (规则路由数据包)
  - **安装包来源**：测试所用的整合安装包 `25-luci-app-dead_1.28-aarch64_cortex-a53.run` 来自大佬 **wkccd** 维护的开源项目 [wkccd/luci-app-daed-runfiles](https://github.com/wkccd/luci-app-daed-runfiles)。

---

## 二、 安装核心难点与根本原因深度剖析

在原始通过 `25-luci-app-dead_1.28-aarch64_cortex-a53.run` 或原生脚本安装时，通常会遇到以下致命问题：

### 1. 包管理器变更为 apk-tools v3

OpenWrt 25 彻底移除了 `opkg`，改用 Alpine 风格的 `apk`（v3 版本采用 ADB 二进制数据结构）。传统的 `.ipk` 包和针对 `opkg` 设计的脚本均无法直接使用。虽然解压出的包是 `.apk`，但在执行 `apk add` 时依然会遭遇依赖断裂。

### 2. 软件源缺失 `zoneinfo-asia` 依赖

`luci-app-daed` 声明依赖 `zoneinfo-asia`。然而，GL.iNet 官方软件源中仅提供了 `zoneinfo-core`（该包其实已经包含北京/上海/PRC等常用时区信息），并未发布 `zoneinfo-asia` 独立包，导致直接通过 `apk add` 安装时报错：

```text
ERROR: unable to select packages:
  zoneinfo-asia (no such package):
    required by: luci-app-daed-1.4-r1[zoneinfo-asia]
```

### 3. 【最致命】官方源 `kmod-sched-bpf` 引发 Kernel Panic 瞬间死机重启

`daed` 声明依赖官方源的 `kmod-sched-bpf`，该包包含两个内核模块：

- `cls_bpf.ko`（TC BPF 流量分类器）
- `act_bpf.ko`（TC BPF 动作模块）

当执行 `apk add kmod-sched-bpf` 时，其 post-install 脚本会运行 `kmodloader` 自动将这两个模块全部加载。在联发科该型号内核驱动下，**执行 `insmod act_bpf.ko` 会立即触发内核崩溃（Kernel Panic / Crash），导致路由器瞬间断网重启**。路由器重启后，由于 `/tmp` 处于内存虚拟盘（tmpfs），先前上传和解压的文件会全部丢失。

### 4. 关键突破：daed 的真实内核依赖

通过跟踪 `daed` 启动时的系统调用及源代码架构发现：

- `daed` 采用 eBPF direct-action 挂载模式，只需要挂载 `clsact` Qdisc 以及 **`cls_bpf.ko`（Classifier）**。
- `daed` **完全不依赖 `act_bpf.ko`（Action）**。
- 经单独隔离测试：在内核中加载 `cls_bpf.ko` 极其稳定，无任何兼容性问题；只要避开加载 `act_bpf.ko`，`daed` 即可顺利完成 eBPF 程序注入与路由表构建（打印 `Ready`）。

---

## 三、 手动安装与配置全步骤

### 步骤 1：解压 Makeself 安装包

将安装包 `25-luci-app-dead_1.28-aarch64_cortex-a53.run` 上传到路由器 `/tmp/` 或持久目录（建议 `/root/daed_install/`），执行仅解压命令：

```bash
mkdir -p /tmp/daed_extract
/tmp/25-luci-app-dead_1.28-aarch64_cortex-a53.run --noexec --target /tmp/daed_extract
```

### 步骤 2：安全提取并配置 `cls_bpf.ko` 模块

切勿直接 `apk add kmod-sched-bpf`！使用 `apk fetch` 单独拉取安装包并提取 `cls_bpf.ko`：

```bash
mkdir -p /tmp/bpf_temp && cd /tmp/bpf_temp
apk fetch kmod-sched-bpf
apk extract --allow-untrusted kmod-sched-bpf-*.apk

# 将安全的 cls_bpf.ko 拷贝至内核模块目录
mkdir -p /lib/modules/$(uname -r)
cp -f lib/modules/$(uname -r)/cls_bpf.ko /lib/modules/$(uname -r)/cls_bpf.ko
chmod 644 /lib/modules/$(uname -r)/cls_bpf.ko

# 配置开机自启（仅加载 cls_bpf，坚决不包含 act_bpf）
echo "cls_bpf" > /etc/modules.d/72-cls-bpf
ln -sf ../modules.d/72-cls-bpf /etc/modules-boot.d/72-cls-bpf

# 清除可能残留的有隐患的旧配置
rm -f /etc/modules.d/72-sched-bpf /etc/modules-boot.d/72-sched-bpf 2>/dev/null || true

# 立即加载 cls_bpf 模块
if ! lsmod | grep -q cls_bpf; then
    insmod /lib/modules/$(uname -r)/cls_bpf.ko
fi

# 清理临时目录
cd /root && rm -rf /tmp/bpf_temp
```

### 步骤 3：升级安装 GeoIP 与 GeoSite 数据库

`v2ray-geoip` 与 `v2ray-geosite` 不依赖崩溃模块，可直接通过 `apk add` 安装：

```bash
apk add --allow-untrusted /tmp/daed_extract/v2ray-geoip-*.apk /tmp/daed_extract/v2ray-geosite-*.apk
```

### 步骤 4：解包部署 daed 核心及 LuCI 插件

使用 `apk extract` 搭配 `--force-overwrite` 直接将文件释放至根目录 `/`，完美规避 `zoneinfo-asia` 与 `kmod-sched-bpf` 的依赖阻断：

```bash
apk extract --allow-untrusted --force-overwrite --destination / /tmp/daed_extract/daed-*.apk
apk extract --allow-untrusted --force-overwrite --destination / /tmp/daed_extract/luci-app-daed-*.apk
apk extract --allow-untrusted --force-overwrite --destination / /tmp/daed_extract/luci-i18n-daed-zh-cn-*.apk

# 修正执行权限
chmod 755 /usr/bin/daed
chmod 755 /etc/init.d/daed
chmod 755 /etc/init.d/luci_daed
chmod 755 /etc/hotplug.d/iface/98-daed

# 创建必备配置与日志目录
mkdir -p /etc/daed
mkdir -p /var/log/daed
ln -sf /usr/share/v2ray /usr/share/daed 2>/dev/null || true
```

### 步骤 5：环境适配与 BTF 链接修正

1. 保证 `daed` 启动能找到内核 BTF 符号文件：

   ```bash
   mkdir -p /boot
   ln -sf /usr/lib/debug/boot/vmlinux /boot/vmlinux
   ln -sf /usr/lib/debug/boot/vmlinux /boot/vmlinux-$(uname -r)
   ```

2. 确保规则库环境变量注入：

   ```bash
   if ! grep -q "DAE_LOCATION_ASSET" /etc/init.d/daed; then
       sed -i '/procd_open_instance/a\ procd_set_param env DAE_LOCATION_ASSET="/usr/share/v2ray"' /etc/init.d/daed
   fi
   ```

### 步骤 6：刷新 LuCI 缓存与生效中文语言

```bash
# 执行语言包初始化
if [ -f /etc/uci-defaults/luci-i18n-daed-zh-cn ]; then
    sh /etc/uci-defaults/luci-i18n-daed-zh-cn || true
    rm -f /etc/uci-defaults/luci-i18n-daed-zh-cn
fi

# 重建 LuCI 索引缓存并重载 RPC 服务
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd restart
```

### 步骤 7：启用服务并开机自启

```bash
# 启用 UCI 配置
uci set daed.config.enabled='1'
uci commit daed

# 设置开机自启
/etc/init.d/daed enable
/etc/init.d/luci_daed enable

# 启动服务
/etc/init.d/daed restart
/etc/init.d/luci_daed restart
```

---

## 四、 服务检验与日常使用

1. **查看运行进程**：

   ```bash
   ps | grep daed
   ```

   应能看到类似 `/usr/bin/daed run --config /etc/daed/ --listen 0.0.0.0:2023` 的守护进程。

2. **查看运行日志**：

   ```bash
   cat /var/log/daed/daed.log
   ```

   看到末尾输出 `Ready` 即表示 eBPF 模块、Netkit/veth 接口与路由策略均已顺利载入。

3. **管理后台访问**：
   - **daed 专属 Web 控制台**：`http://192.168.8.1:2023`（首次访问设置管理员账号和密码）
   - **OpenWrt LuCI 界面**：登录 `http://192.168.8.1` -> 点击顶部菜单 **服务 (Services)** -> **DAED**。

---

## 五、 关键性能调优与稳定性排障（重载死机 / Hy2低速根治）

在实际使用过程中，若直接使用默认系统参数和基础配置，往往会遭遇两类严重影响使用体验的核心痛点。以下提供针对性的深层机制分析与一键优化方案：

### 1. 面板修改配置重载导致路由器死机、断网与面板拒绝访问

- **故障表象**：在 Web 仪表盘（`http://192.168.8.1:2023`）修改节点或分流规则后，点击重载/启用，网络瞬间断开，Web 界面拒绝访问，SSH 超时，必须拔电源重启路由器才能恢复。
- **深层根因**：
  1. **硬件流量加速（PPE Flow Offloading）冲突**：OpenWrt 防火墙默认启用了 `flow_offloading_hw`（联发科硬件流量转发加速）。当硬件流表激活时，数据包会直接绕过 Netfilter 与内核网络协议栈。而 `daed` 核心严重依赖挂载在网卡（`br-lan`/`eth0`）上的 TC eBPF 钩子与连接追踪。在配置重载瞬间，新旧规则交替触发网卡 TC 过滤器重载，与硬件流表产生不可恢复的死锁与丢包风暴，导致网卡入站流量彻底瘫痪。
  2. **锁定内存限制（Locked Memory / memlock）过低**：OpenWrt 系统默认 `ulimit -l` 仅为 8MB。重载时新旧 eBPF Maps 同时在内核中驻留，瞬间突破 8MB 上限，导致内核报错拒绝分配。
  3. **Go 运行时的内存峰值引发 OOM**：512MB 内存设备在解析庞大的 GeoIP/GeoSite 规则树时瞬时申请上百兆内存。若未配置 `GOMEMLIMIT`，双份实例在重载时会直接撑爆可用物理内存。
- **解决对策**：
  - 关闭防火墙的硬件与软件流量分流加速：

    ```bash
    uci set firewall.@defaults[0].flow_offloading='0'
    uci set firewall.@defaults[0].flow_offloading_hw='0'
    uci commit firewall && /etc/init.d/firewall reload
    ```

  - 加固 `/etc/init.d/daed`，设置 `procd_set_param limits memlock="unlimited"`，并注入环境变量 `GOMEMLIMIT="200MiB"` 和 `GODEBUG="madvdontneed=1"`。

---

### 2. Hysteria 2 / QUIC 协议跨国节点带宽受限、丢包严重

- **故障表象**：同一 Hysteria 2 节点在电脑端测速可达数百兆，而在路由器 daed 中跑满甚至不足 10-20 Mbps，延迟抖动剧烈。
- **深层根因**：
  1. **Linux 默认 Socket 缓冲区限制（BDP 瓶颈）**：系统默认的 `net.core.rmem_max` 和 `net.core.wmem_max` 仅约 208KB。跨国代理节点通常存在 150-250ms 的往返延迟（RTT）。在 BBR 拥塞控制下，BDP（带宽时延积）容量远超 208KB，极小的内核缓冲区瞬间被填满，导致内核级 UDP 频繁丢包（Packet Drop），引发剧烈降速。
  2. **国内运营商（如中国移动）QoS 与 Bufferbloat（缓冲区膨胀）调优**：
     - **下行带宽 (`bandwidth_max_rx`)**：对于千兆家宽，不宜盲目填写 10Gbps 等超大数值。建议设定为 **`800 mbps` ~ `900 mbps`**，保留约 10%~20% 的余量（Headroom），避免触碰运营商省网/国际出口的硬限速丢包阈值。
     - **上行带宽 (`bandwidth_max_tx`)**：中国移动等千兆宽带签约上行普遍仅为 **30Mbps ~ 50Mbps**。若上行不设限，大流量或握手发包时会瞬间打满光猫上行队列，引发严重的 **Bufferbloat**，导致整网 Ping 暴增至 1000ms+ 且丢包断流。建议严格限制为 **`40 mbps` ~ `50 mbps`**。
     - **节点检测容忍度 (`check_tolerance`)**：默认 `0s` 只要单次丢包立刻判定节点阵亡，对于跨国 UDP 极易引发频繁误判。建议设置为 **`2000ms`**，增强抗抖动能力。
  3. **跨协议栈 IPv6 探测异常**：当路由器禁用 IPv6 时，若探测地址仍包含 IPv6，会造成频繁的连接超时与节点状态震荡重选。
- **解决对策**：
  - 扩大 Linux 内核 UDP Socket 缓冲区至 16MB：

    ```bash
    cat << 'EOF' > /etc/sysctl.d/99-dae-udp.conf
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
    net.core.rmem_default = 1048576
    net.core.wmem_default = 1048576
    net.core.optmem_max = 2048576
    net.core.netdev_max_backlog = 10000
    net.ipv4.udp_rmem_min = 16384
    net.ipv4.udp_wmem_min = 16384
    EOF
    sysctl -p /etc/sysctl.d/99-dae-udp.conf
    ```

  - **解除流媒体 QUIC 误伤阻断**：将 YouTube / 流媒体路由规则置于 `l4proto(udp) && dport(443) -> block` 之前，允许客户端原生走 HTTP/3 (QUIC) 访问 YouTube，消除握手降级超时与断流。
  - 根据实际网络环境科学设定带宽（如移动千兆设置下行 800M、上行 50M），并将 `check_tolerance` 设为 `2000ms`，同时开启 dnsmasq 的 `filter_aaaa` 阻断 IPv6 干扰。

---

### 3. 一键优化脚本推荐（即跑即用）

本项目已提供自动化优化脚本 `optimize-daed.sh`，可一键完成上述所有系统调优与数据库修复：

```bash
# 进入项目目录或上传脚本后执行
chmod +x optimize-daed.sh
./optimize-daed.sh
```

---

## 六、 维护与卸载指南

如需彻底停止或卸载 daed：

```bash
# 停止并禁用自启
/etc/init.d/daed stop
/etc/init.d/luci_daed stop
/etc/init.d/daed disable
/etc/init.d/luci_daed disable

# 清理残留网络命名空间与接口（如有）
umount -f /run/netns/daens 2>/dev/null || true
rm -f /run/netns/daens 2>/dev/null || true
ip link del dae0 2>/dev/null || true
rm -rf /sys/fs/bpf/daed 2>/dev/null || true

# 删除安装文件与模块启动配置
rm -f /usr/bin/daed
rm -f /etc/init.d/daed /etc/init.d/luci_daed
rm -rf /usr/lib/lua/luci/controller/daed.lua /usr/lib/lua/luci/model/cbi/daed /usr/lib/lua/luci/view/daed
rm -f /etc/modules.d/72-cls-bpf /etc/modules-boot.d/72-cls-bpf
rm -f /tmp/luci-indexcache.* && /etc/init.d/rpcd restart
```
