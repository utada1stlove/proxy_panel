# proxy_panel

基于 [shoes](https://github.com/cfal/shoes)（Rust 高性能多协议代理）衍生的 Bash 管理面板，适配 Debian/Ubuntu VPS，一键部署。

> 本仓库代码 100% 由 [Claude](https://claude.ai) 生成。

## 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/utada1stlove/proxy_panel/main/panel.sh | bash
```

> 需要 root 权限，建议在 `sudo -i` 或 `su -` 环境下执行。

## 功能

- 自动下载并安装 shoes 二进制（自动识别 x86_64 / aarch64）
- 自动写入 systemd 服务，开机自启
- 交互式菜单管理代理协议：添加 / 删除 / 查看
- 添加协议后立即显示分享链接
- 查看协议列表时同步展示分享链接
- 一键卸载（删除二进制、服务文件及配置目录）
- 支持以下协议：
  - HTTP
  - SOCKS5
  - Shadowsocks（aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305）
  - Shadowsocks 2022（blake3-aes-128-gcm / blake3-aes-256-gcm / blake3-chacha20-ietf-poly1305）
  - Trojan（TLS）
  - VMess
  - VLESS（TLS）
  - Hysteria2（QUIC）
  - TUIC v5（QUIC）

## 文件说明

| 文件 | 说明 |
|------|------|
| `panel.sh` | 主脚本，所有功能均在此文件中 |

## 依赖

目标系统需具备：`curl`、`tar`、`systemctl`（Debian/Ubuntu 默认已有）

---

[English](README.MD)
