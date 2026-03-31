# proxy_panel

基于 [shoes](https://github.com/cfal/shoes)（Rust 高性能多协议代理）衍生的 Bash 管理面板，适配 Debian/Ubuntu VPS，一键部署。

## 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/utada1stlove/proxy_panel/main/panel.sh | bash
```

> 需要 root 权限，建议在 `sudo -i` 或 `su -` 环境下执行。

## 功能

- 自动下载并安装 shoes 二进制（自动识别 x86_64 / aarch64）
- 若未安装 shoes，在添加协议或管理服务前会先提示安装
- 自动写入 systemd 服务，开机自启
- 交互式菜单管理代理协议：添加 / 删除 / 查看
- 变更后会先执行 `shoes --dry-run` 验证配置，失败则自动回滚
- 添加协议后立即显示分享链接
- 查看协议列表时同步展示分享链接，便于直接导入 Shadowrocket 等客户端
- 内置证书管理：
  - 在 `/etc/shoes/certs/` 生成自签证书
  - 用 `acme.sh` 的 standalone 模式申请 Let's Encrypt 证书
  - 添加 TLS / QUIC 协议时可直接复用托管证书
- 内置 UDP 防火墙菜单：
  - 可封禁任意 UDP 端口或端口范围
  - 支持 `input` / `output` / `both`
  - 托管规则会落到 `/etc/shoes/proxy-panel-firewall.nft`
- 内置 `journalctl` 日志查看
- 一键卸载（删除二进制、服务文件及配置目录）
- 托管监听器按文件拆分存放在 `/etc/shoes/listeners.d/`，再自动汇总到 `/etc/shoes/config.yaml`
- 支持以下协议：
  - HTTP
  - SOCKS5
  - Shadowsocks（aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305）
  - Shadowsocks 2022（blake3-aes-128-gcm / blake3-aes-256-gcm / blake3-chacha20-ietf-poly1305）
  - Trojan（TLS）
  - VMess
  - VLESS（TLS）
  - VLESS-Reality（自动生成 X25519 密钥对，显示公钥与短 ID 供客户端使用）
  - ShadowTLS v3（封装 Shadowsocks，伪装成真实 TLS 服务器）
  - Hysteria2（QUIC）
  - TUIC v5（QUIC）

## 文件说明

| 文件 | 说明 |
|------|------|
| `panel.sh` | 主脚本，负责安装 shoes、管理监听器、证书、UDP 防火墙、验证配置和查看日志 |

## 依赖

目标系统需具备：`curl`、`tar`、`systemctl`（Debian/Ubuntu 默认已有）

---

[English](README.MD)
