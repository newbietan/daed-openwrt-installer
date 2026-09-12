# daed-openwrt-installer

[![OpenWrt 25.x](https://img.shields.io/badge/OpenWrt-25.x-blue.svg)](https://openwrt.org/)
[![Kernel 6.12](https://img.shields.io/badge/Linux_Kernel-6.12+-green.svg)](https://kernel.org/)
[![Architecture](https://img.shields.io/badge/Arch-aarch64_cortex--a53-orange.svg)](https://github.com/newbietan/daed-openwrt-installer)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

针对 **OpenWrt 25.x**（基于 `apk` 包管理器与 Linux 内核 6.12+，以 GL.iNet GL-MT3600BE 等联发科 Wi-Fi 7 路由器为代表）的 **daed**（基于 eBPF 的高性能透明代理）及其 LuCI 网页控制界面的一键安装与部署工具。

---

## 🌟 核心特性与解决的痛点

- **完美适配 OpenWrt 25+ 的 `apk-tools 3.0`**：针对新一代 OpenWrt 彻底废弃 `opkg` 的架构，自动化处理 APK 安装、解包与环境依赖。
- **自动解决 `zoneinfo-asia` 缺失**：绕过官方软件源中缺少 `zoneinfo-asia` 导致的安装阻断。
- **修复内核 Panic 崩溃重大隐患**：
  - 官方源 `kmod-sched-bpf` 中的 `act_bpf.ko` 模块在联发科 Wi-Fi 7 (MT7988/Filogic) 内核中加载时会引发 **Kernel Panic 瞬间死机重启**。
  - 本工具深入跟踪 `daed` 启动逻辑，仅精准提取并加载安全的 **`cls_bpf.ko`（TC BPF 流量分类器）**，彻底避免系统崩溃与循环重启。
- **一键开箱即用**：自动配置 eBPF BTF 符号软链接、配置 GeoIP/GeoSite 规则数据包、初始化 LuCI 中文语言与索引缓存，自动配置开机自启。

---

## 📦 支持平台与环境

- **测试路由器**：GL.iNet GL-MT3600BE
- **系统固件**：OpenWrt 25.12.5 (r33051)
- **内核版本**：Linux `6.12.94`
- **CPU 架构**：`aarch64_cortex-a53` (理论上通用适用于 aarch64 平台且内核 6.1+ 支持 eBPF 的 OpenWrt 25 设备)
- **安装包来源**：本项目的整合安装包（`.run` 安装包及解包后的 `.apk` 组件）由 **wkccd** 大佬在开源仓库 [wkccd/luci-app-daed-runfiles](https://github.com/wkccd/luci-app-daed-runfiles) 编译打包提供，特此致谢！

---

## 🚀 快速开始

### 方式一：Git Clone 安装（推荐）

在路由器终端中直接克隆并运行安装脚本：

```bash
cd /tmp
git clone --depth=1 https://github.com/newbietan/daed-openwrt-installer.git
cd daed-openwrt-installer
chmod +x install-daed.sh
./install-daed.sh
```

### 方式二：手动上传安装包配合脚本执行

如果你已经在电脑端下载了本仓库或安装包：

1. 将 `install-daed.sh` 以及 `packages/`（或 `25-luci-app-dead_*.run`）上传至路由器的 `/tmp` 目录。
2. SSH 登录路由器执行：

   ```bash
   chmod +x /tmp/install-daed.sh
   /tmp/install-daed.sh
   ```

---

## 🖥 访问与管理

安装成功后，控制台会输出服务状态与访问地址：

1. **daed 专属 Web 控制台**：
   - 访问地址：`http://192.168.8.1:2023`
   - 初次访问按向导设置管理员账号密码即可。
2. **OpenWrt LuCI 管理界面**：
   - 登录路由器后台 `http://192.168.8.1`
   - 进入顶部导航栏：**服务 (Services)** -> **DAED**

---

## 📂 项目结构

```text
daed-openwrt-installer/
├── install-daed.sh              # 一键自动安装与部署脚本
├── DAED_OPENWRT_INSTALL_GUIDE.md # 深度技术排障与手动安装全过程文档
├── README.md                    # 项目说明
├── LICENSE                      # 开源许可协议 (MIT)
└── packages/                    # 核心安装包集合 (apk)
    ├── daed-2026.05.26-r1.apk
    ├── luci-app-daed-1.4-r1-openwrt-25.12.apk
    ├── luci-i18n-daed-zh-cn-*.apk
    ├── v2ray-geoip-*.apk
    ├── v2ray-geosite-*.apk
    └── vmlinux-btf-6.12.91.apk
```

---

## 🛠 服务控制与排错命令

```bash
# 查看 daed 进程状态
ps | grep daed

# 查看实时运行日志
cat /var/log/daed/daed.log
# 或动态跟踪
tail -f /var/log/daed/daed.log

# 手动重启/停止服务
/etc/init.d/daed restart
/etc/init.d/daed stop
```

---

## 📄 鸣谢与开源许可证

本项目采用 [MIT License](LICENSE) 开源。

特别鸣谢以下优秀开源项目与开发者：

- **安装包打包与集成**：特别感谢大佬 **wkccd** 维护的打包仓库 [wkccd/luci-app-daed-runfiles](https://github.com/wkccd/luci-app-daed-runfiles)，提供了便捷的整合安装包支持！
- **上游核心项目**：
  - [daeuniverse/daed](https://github.com/daeuniverse/daed) - dae 核心与网页仪表盘
  - [OpenWrt](https://openwrt.org/) - 开源嵌入式 Linux 操作系统
  - [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) - 强大的 OpenWrt 分支
  - [QiuSimons/luci-app-daed](https://github.com/QiuSimons/luci-app-daed) - LuCI 支持插件
