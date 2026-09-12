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

## 五、 维护与卸载指南

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
