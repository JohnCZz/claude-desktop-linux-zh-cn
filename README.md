# Claude Desktop Linux 简体中文 Overlay

这是一个面向 Ubuntu/Debian 的 Claude Desktop 本地汉化脚本。它把官方安装目录复制到用户目录，在副本里加入 `zh-CN` 资源和前端文本替换，然后通过用户级启动器运行。官方 `/usr/lib/claude-desktop` 和其中的 `resources/app.asar` 不会被改写。

这个项目针对 **Claude Desktop**，不是 Claude Code CLI。

## 已验证环境

本仓库在以下环境做过一次完整构建和启动烟测：

- Ubuntu 26.04 LTS，x86_64
- Claude Desktop `1.30096.1`
- Python `3.14.6`
- Node.js `22.22.1`
- 官方 `chrome-sandbox` 为 `root:root`、权限 `4755`
- 上游中文资源 commit：`84f0b6fe60b3a5359a4f5fd9ada1ab7ccfc39447`

Claude Desktop 的前端资源会随版本变化。通过其他版本测试前，请保留回滚目录并检查输出中的完整性校验。

## 安装

先退出正在运行的 Claude Desktop，再执行：

```bash
chmod +x claude_linux_zh_unified.sh
./claude_linux_zh_unified.sh --apply
```

脚本会从 `javaht/claude-desktop-zh-cn` 获取最新中文资源。资源会缓存到 `~/.cache/claude-desktop-zh-cn`，之后可以使用离线模式：

```bash
./claude_linux_zh_unified.sh --apply --offline
```

默认完成后会启动中文版。只构建、不启动：

```bash
./claude_linux_zh_unified.sh --apply --no-launch
```

首次构建需要复制约 540 MB 的官方安装目录。请预留更多空间用于旧 overlay 备份。

## 命令

| 命令 | 作用 |
| --- | --- |
| `--apply` | 从当前官方版本重建中文 overlay（默认） |
| `--status` | 查看官方版本、overlay 状态和 SHA256 |
| `--offline` | 只使用已有中文资源缓存 |
| `--rollback` | 恢复最近一次完整 overlay 备份 |
| `--no-launch` | 完成后不启动 Claude Desktop |
| `--upgrade` | 通过 `sudo apt` 升级 `claude-desktop` 后再汉化 |

官方包更新后，重新运行：

```bash
~/.local/bin/claude-desktop-zh-maintain --apply
```

## 文件位置

- overlay：`~/.local/share/claude-desktop-plus/claude-overlay`
- 维护脚本：`~/.local/bin/claude-desktop-zh-maintain`
- 启动器：`~/.local/bin/claude-desktop-zh-cn`
- 桌面入口：`~/.local/share/applications/claude-desktop-zh-cn.desktop`
- 状态文件：`~/.local/share/claude-desktop-plus/unified-state.json`
- 日志：`~/.local/state/claude-desktop-zh-cn/`

每次构建都会把 `app.asar` 的 SHA256 写入状态文件。脚本还会检查 overlay 中的 `app.asar` 是否与官方文件完全相同；检查失败会停止切换。

## 脚本会做什么

1. 检查官方 Claude Desktop 目录、`app.asar`、前端资源和 sandbox 权限。
2. 同步或读取缓存的中文 JSON 资源。
3. 复制官方目录到用户 overlay，保留官方 `chrome-sandbox` 的 root-owned `4755` 文件。
4. 合并 i18n 资源，替换一部分硬编码前端文本，并注入一个带 guard 的 DOM 翻译运行时。
5. 验证 `app.asar` 未变化后，原子切换 overlay 并保留有限数量的备份。

脚本只在用户目录写入 overlay、缓存、启动器、桌面入口和日志。`--upgrade` 是例外，它会执行 `sudo apt update` 和 `sudo apt install --only-upgrade claude-desktop`。

## 回滚

```bash
~/.local/bin/claude-desktop-zh-maintain --rollback --no-launch
```

如果官方应用更新后资源结构发生变化，先回滚，再恢复或重新安装官方包，然后使用最新脚本重新构建。在确认新 overlay 可用前，不要删除最后一个可用备份。

## 验证

仓库内的静态测试不需要联网，也不会修改系统：

```bash
bash tests/test_static.sh
```

真实安装后可检查：

```bash
~/.local/bin/claude-desktop-zh-maintain --status
sha256sum /usr/lib/claude-desktop/resources/app.asar
sha256sum ~/.local/share/claude-desktop-plus/claude-overlay/resources/app.asar
```

两个 SHA256 应该相同。脚本不会修改官方 `app.asar`，但会结束与目标 overlay 或官方路径匹配的 Claude Desktop 进程；运行 `--apply` 前请先保存会话。

## 许可和上游资源

本仓库中的维护脚本和文档使用 MIT License。运行时下载的中文资源来自 [javaht/claude-desktop-zh-cn](https://github.com/javaht/claude-desktop-zh-cn)，该项目同样使用 MIT License；本项目不重新分发其资源文件。详见 [NOTICE.md](NOTICE.md) 和 [LICENSE](LICENSE)。

Claude Desktop 是 Anthropic 的产品。本项目与 Anthropic 无关，也不是官方发行版。使用前请自行评估第三方补丁和动态下载资源的风险。
