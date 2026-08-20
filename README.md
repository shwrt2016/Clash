# Clash Claude SG

给 **macOS + Clash Verge Rev** 用的安装脚本：把 Claude / Anthropic 相关流量走你自己的新加坡 HTTP 代理（`SG-Team`），其它流量仍跟订阅原策略走。

这不是 Clash 客户端，也不提供代理账号。你需要已经装好 Clash Verge，并自备 SG 代理。

完整环境要求和失败对照见 [`使用说明.txt`](./使用说明.txt)。

## 环境

| 需要 | 不需要 |
| --- | --- |
| macOS | Windows / Linux |
| Clash Verge Rev（或旧版 Clash Verge） | Homebrew / Node / Python |
| 已启动过一次 App、已导入订阅、已创建全局扩展脚本 | 把密码写进仓库 |
| 自备 SG HTTP 代理账号 | |

系统自带 `bash` 即可。有 Node 时安装前会多做一次语法检查；没有也能装。

## 快速安装

1. 打开一次 Clash Verge：导入订阅，并创建/保存一次「全局扩展脚本」，然后 **完全退出**（含菜单栏图标）。
2. 获取本仓库后执行：

```bash
chmod +x install-mac-optimized.sh
./install-mac-optimized.sh
```

3. 按提示输入 `SG_SERVER` / `SG_PORT` / `SG_USERNAME` / `SG_PASSWORD`。
4. 再打开 Clash Verge：Rule 模式、打开 TUN、对当前订阅重新加载。系统网络建议关闭 IPv6。

非交互：

```bash
SG_SERVER=... \
SG_PORT=443 \
SG_USERNAME=... \
SG_PASSWORD=... \
./install-mac-optimized.sh --non-interactive
```

验证：

```bash
./install-mac-optimized.sh --verify
```

## 仓库里有什么

| 文件 | 作用 |
| --- | --- |
| `install-mac-optimized.sh` | 唯一入口（安装 + 验证），增强脚本模板内嵌其中 |
| `使用说明.txt` | 环境、依赖、步骤和常见失败 |
| `test-optimized.mjs` | 开发用测试，使用本仓库不需要跑 |

安装脚本会把生成的增强脚本写入 Clash Verge 配置目录，并在同目录做私密备份。仓库内不含真实代理密码。

## License

[木兰宽松许可证，第2版](./LICENSE)
