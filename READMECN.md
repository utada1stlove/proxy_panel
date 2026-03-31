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
- 协议列表改成了带边框的表格显示，不再是一行一行散着输出
- 表格现在只负责总览，完整导入链接会在下方再输出成独立的 “Share Details” 分享块
- 变更后会先执行 `shoes --dry-run` 验证配置，失败则自动回滚
- 添加协议后会立即用独立分享块展示生成链接
- 长分享链接不再按固定宽度生硬截断，而是优先按 `@`、`?`、`&`、`#` 这些分隔符换行
- 某些协议会同时保存多条兼容导入链接，例如 `hysteria2://` + `hy2://`
- 分享块里的链接现在会按单行原始串输出，方便直接复制，不再把真正的 URL 人工切断
- 分享链接目前优先针对 `Shadowrocket`、`v2rayN`、`dae` 调整；自签证书场景可以直接把 `allowInsecure` / `insecure` 带进链接
- `ShadowTLS` 现在会先询问你是否需要独立的 SS2022 后端端口，再决定走 `shoes` 原生单端口模式，还是走 Shadowrocket 风格的 standalone 模式
- SIP002 导出也收紧了：普通 Shadowsocks 改用 Base64URL userinfo，AEAD-2022 则按明文 `method:password` 百分号编码导出
- “删除协议” 现在使用 `fzf` 多选：按 `Tab` 勾选多个监听器，再按回车批量删除
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
| `docs/client-regression.md` | 当前 Shadowrocket / v2rayN / dae 的目标矩阵与手工回归清单 |

## 依赖

目标系统需具备：`curl`、`tar`、`systemctl`（Debian/Ubuntu 默认已有）。`fzf` 为可选依赖，使用多选删除时 panel 会提示安装；`qrencode` 也是可选依赖，安装后新增协议时会额外输出二维码。

## 客户端说明

- 当前分享链接优先按 `Shadowrocket`、`v2rayN`、`dae` 这三个客户端做兼容
- `dae` 只纳入它文档里明确支持的协议，`ShadowTLS` 不在 `dae` 兼容目标内
- 对自签证书场景，panel 可以直接把 `allowInsecure` / `insecure` 写进生成链接
- `Hysteria2` 现在使用官方推荐的 `/?query` 形式，`TUIC` 则保留 `allow_insecure` 以兼顾 dae 风格导入，同时输出 `insecure`

---

[English](README.MD)
