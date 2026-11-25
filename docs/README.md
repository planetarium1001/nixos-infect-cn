# 文档索引 / Documentation Index

**中文** | [English](#english)

## 中文文档

| 文档 | 内容 | English |
| --- | --- | --- |
| [快速开始](./zh-CN/quickstart.md) | 5 分钟完成首次安装，含预期输出 | [Quick start](./en/quickstart.md) |
| [安装教程](./zh-CN/installation.md) | 四种安装方式、特殊场景、安装后验证 | [Installation](./en/installation.md) |
| [配置定制](./zh-CN/configuration.md) | 三种改配置方式、占位符、示例 | [Configuration](./en/configuration.md) |
| [参数与环境变量](./zh-CN/cli.md) | 全部参数、环境变量、组合示例 | [CLI reference](./en/cli.md) |
| [镜像与探测](./zh-CN/mirrors.md) | 镜像能力、探测算法、缓存 | [Mirrors](./en/mirrors.md) |
| [工作原理](./zh-CN/how-it-works.md) | 阶段流程、关键机制、脚本结构 | [How it works](./en/how-it-works.md) |
| [安装后清理](./zh-CN/cleanup.md) | 清理脚本行为、手动清理 | [Cleanup](./en/cleanup.md) |
| [排障指南](./zh-CN/troubleshooting.md) | 症状速查表与典型故障 | [Troubleshooting](./en/troubleshooting.md) |
| [常见问题](./zh-CN/faq.md) | 数据、兼容性、网络、安全 | [FAQ](./en/faq.md) |
| [项目规范与贡献](./zh-CN/development.md) | 代码 / 注释 / 文档规范 | [Development](./en/development.md) |

## 阅读建议

- **第一次使用**：先读[快速开始](./zh-CN/quickstart.md)，再看[安装教程](./zh-CN/installation.md)。
- **需要改配置**：直接看[配置定制](./zh-CN/configuration.md)与[参数与环境变量](./zh-CN/cli.md)。
- **安装出问题**：先查[排障指南](./zh-CN/troubleshooting.md)，再看[常见问题](./zh-CN/faq.md)。
- **想了解实现**：读[工作原理](./zh-CN/how-it-works.md)，配合脚本 `SECTION` 分区注释。
- **参与维护**：务必先读[项目规范与贡献](./zh-CN/development.md)。

## 文档约定

- 中文为主、英文为辅，两棵目录的文件与章节一一对应。
- 禁止长段落：每段不超过 3 行，并列信息用列表或表格。
- 命令放代码块，参数、路径、命令保留英文原文。
- 相对链接；截图统一放在 `screenshots/`。
- 修改一篇文档时，请同步更新对应语言的版本。

---

## English

English documentation mirrors the Chinese tree, file by file.

| Document | Contents |
| --- | --- |
| [Quick start](./en/quickstart.md) | First install in 5 minutes, expected output |
| [Installation](./en/installation.md) | Four install modes, special cases, post-install checks |
| [Configuration](./en/configuration.md) | Three ways to customize, placeholders, examples |
| [CLI reference](./en/cli.md) | Flags, environment variables, combinations |
| [Mirrors](./en/mirrors.md) | Mirror matrix, probing algorithm, cache |
| [How it works](./en/how-it-works.md) | Pipeline stages, key mechanisms, script map |
| [Cleanup](./en/cleanup.md) | Cleanup script behavior, manual cleanup |
| [Troubleshooting](./en/troubleshooting.md) | Symptom table and detailed cases |
| [FAQ](./en/faq.md) | Data, compatibility, network, security |
| [Development](./en/development.md) | Code / comment / docs conventions |

### Reading paths

- **First time here**: read [quick start](./en/quickstart.md), then [installation](./en/installation.md).
- **Customizing config**: see [configuration](./en/configuration.md) and [CLI reference](./en/cli.md).
- **Install failed**: check [troubleshooting](./en/troubleshooting.md), then [FAQ](./en/faq.md).
- **Understanding internals**: read [how it works](./en/how-it-works.md) alongside the script section comments.
- **Contributing**: start with [development](./en/development.md).

### Conventions

- Chinese is primary, English is the auxiliary translation; both trees mirror each other.
- No long paragraphs: at most 3 lines per paragraph, parallel items go into lists or tables.
- Commands live in code fences; flags, paths and commands stay in English.
- Use relative links; screenshots live in `screenshots/`.
- When editing one document, update its counterpart in the other language.
