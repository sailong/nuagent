# Sing-box 极简全能运维脚本 V50.0

![Version](https://img.shields.io/badge/version-V50.0-blue?style=flat-square)
![Language](https://img.shields.io/badge/language-Bash-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)

一个专为 **生产环境、救砖、低配机器 (如 Alpine)** 设计的极简 Sing-box 运维脚本。
剔除冗余 UI，专注于核心功能：**Cloudflare Tunnel 内网穿透**、**Reality/Hysteria2 直连**、**BBR 加速** 以及 **WARP 网络接口**。

## 📥 安装与使用
```bash
bash <(curl -Ls https://sl.bluu.pl/4Ifj)
```

---

## ✨ 核心特性

* **⚡ 极简轻量**：无花哨菜单，资源占用极低，完美适配 Debian/Ubuntu/CentOS 及 **Alpine Linux (OpenRC)**。
* **🌍 网络自适应**：内置 **加速镜像源**（mirror.ghproxy.com），智能解决国内服务器无法下载 GitHub 文件的问题，支持自定义镜像。
* **🛡️ 穿透专用**：专为配合 **Cloudflare Tunnel (Argo)** 设计，支持生成标准的 `security=tls` 格式订阅链接。
* **🚀 协议全能**：
    * **CDN/Tunnel 模式**：VLESS + WS / Trojan + WS (本地明文，链路上 TLS，支持随机 WS 路径)。
    * **直连模式**：VLESS + REALITY (抗封锁)、Hysteria 2 (暴力 UDP，自签证书)。
* **🔧 运维辅助**：一键开启 BBR、一键添加 WARP IPv4/IPv6 双栈网络。

---

## 🖥️ 环境支持

| 架构 | x86_64 (amd64) | arm64 | armv7 |
| :--- | :---: | :---: | :---: |
| **支持状态** | ✅ | ✅ | ✅ |

| 系统 | Debian | Ubuntu | CentOS | Alpine |
| :--- | :---: | :---: | :---: | :---: |
| **进程管理** | Systemd | Systemd | Systemd | **OpenRC** |

---

## 📖 功能菜单详解

进入脚本后，您将看到以下功能菜单：

### `1. 安装 Sing-box`
* **自动部署**：自动检测系统架构 (amd64/arm64/armv7) 并下载对应二进制文件。
* **网络优化**：针对国内机器，提供 **加速镜像源** 选择，支持自定义镜像地址，解决下载失败问题。
* **进程守护**：自动配置 Systemd (Debian/CentOS) 或 OpenRC (Alpine) 并设置开机自启。

### `2. 安装并启动 Cloudflared`
* **内网穿透**：用于配合 Cloudflare Tunnel 将本地服务暴露至公网。
* **自动配置**：输入 Token 后，自动下载对应架构的 `cloudflared` 二进制文件并注册为系统服务。

### `3. 添加节点 (核心功能)`
支持四种协议模式，满足不同网络需求：

| 序号 | 协议类型 | 适用场景 | 说明 |
| :--- | :--- | :--- | :--- |
| **1** | **VLESS + WS** | **CF Tunnel / CDN** | 本地明文监听，配合 Tunnel 使用，支持随机 WS 路径 |
| **2** | **Trojan + WS** | **CF Tunnel / CDN** | 本地明文监听，配合 Tunnel 使用 |
| **3** | **VLESS + REALITY** | **直连 (抗封锁)** | 无需域名/证书，脚本自动生成 Keypair |
| **4** | **Hysteria 2** | **直连 (暴力加速)** | 自动生成自签名证书 (有效期10年)，需开启跳过验证 |

### `4. 查看节点`
* **格式化输出**：针对 VLESS/Trojan 的 WS 节点，脚本会**自动生成**带有 `security=tls`、`sni=您的域名` 的标准链接。
* **优选适配**：默认生成链接中包含 Cloudflare 优选 IP 格式，可直接导入 V2rayN、Shadowrocket 使用。

### `5. 干净卸载`
* **彻底清理**：停止所有服务，移除所有二进制文件、配置文件、日志及开机自启项。
* **重置环境**：适合在重新部署或遇到严重错误时使用，真正做到“入水无痕”。

### `6. 开启/刷新 BBR 加速`
* **智能检测**：自动检测内核版本（需 >= 4.9）。
* **一键开启**：修改 `sysctl.conf` 开启 `BBR + FQ` 算法，显著提升网络吞吐量。
* **状态感知**：菜单实时显示当前开启状态：`[已开启]` 或 `[未开启]`。

### `7. 添加 WARP IPv4`
* **源更新**：集成 **fscarmen** 大佬的 **GitLab** 官方源脚本，抗封锁能力更强。
* **用途**：
    * 为纯 IPv6 机器添加 IPv4 访问能力（解决 GitHub、Docker 拉取失败等问题）。
    * 为 IPv4 机器添加 WARP IP 以解锁 Netflix、Disney+、ChatGPT 等流媒体限制。
## ⚠️ 关键注意事项

1.  **关于 Cloudflare Tunnel 配置**：
    * 添加 VLESS/Trojan (WS) 节点后，请务必在 **Cloudflare Zero Trust** 后台将 Tunnel 的 **Public Hostname** 指向 `localhost:您设置的端口`。
    * 脚本生成的订阅链接默认为 **TLS (HTTPS)** 模式，Tunnel 端必须正确配置 HTTPS 转发或由 CF 边缘节点自动处理加密。

2.  **关于 Hysteria 2 客户端设置**：
    * 由于脚本使用的是自动生成的 **自签名证书 (Self-signed Cert)**，客户端连接时 **必须开启** “允许不安全 (Allow Insecure / Skip Cert Verify)” 选项，否则无法建立连接。

3.  **关于国内服务器**：
    * 脚本运行之初的网络环境选择步骤，请务必选择 **"1. 国内服务器"**。
    * 否则 Sing-box 核心组件或 Cloudflared 二进制文件的下载极大概率会因网络原因失败。

## 🤝 第三方开源项目与致谢

本脚本的诞生离不开以下优秀的开源项目与社区贡献，特此致谢：

* **[SagerNet/sing-box](https://github.com/SagerNet/sing-box)**
    * 本脚本的核心代理组件，新一代通用代理平台。
* **[cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)**
    * Cloudflare Tunnel 的官方守护进程，用于实现内网穿透。
* **[fscarmen/warp](https://gitlab.com/fscarmen/warp)**
    * 提供了强大的 WARP 安装脚本（GitLab 源），用于为 VPS 添加 Cloudflare IPv4/IPv6 双栈网络。
* **[GHProxy](https://ghfast.top/)**
    * 提供了稳定高效的 GitHub 文件加速镜像服务，确保国内服务器能够顺利安装。

---------------------------------------------------------
## 📜 免责声明
本脚本仅供网络技术研究与服务器运维学习使用，请遵守当地法律法规。


