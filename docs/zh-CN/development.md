# 项目规范与贡献指南

本文说明 nixos-infect-cn 的目录、代码/注释/i18n/日志规范，以及检查、测试和提交流程。  
目标是让单文件脚本保持可读、可验证，并让 README 与双语文档同步。

## 目录结构

```text
nixos-infect-cn/
├── nixos-infect.sh        # 单文件安装脚本，含内置模板
├── nixos-infect.en.sh     # 英文注释版，代码与主脚本完全一致
├── README.md              # 中文说明，项目事实来源之一
├── README.en.md           # 英文说明，与中文同步
├── README.upstream.md     # 上游原始说明
├── LICENSE                # GPLv3
├── .editorconfig          # 编辑器格式约定
├── screenshots/           # README 与文档共用截图
│   ├── screenshot.png
│   ├── quickstart.png
│   ├── interactive_0.png
│   ├── interactive_1.png
│   ├── interactive_2.png
│   └── cleanup.png
├── scripts/
│   └── verify-comment-parity.sh  # 校验两份脚本的代码一致性
└── docs/
    ├── README.md          # 文档索引
    ├── zh-CN/             # 中文文档
    └── en/                # 英文文档，文件名与 zh-CN 一一对应
```

| 条目 | 用途 |
| --- | --- |
| `nixos-infect.sh` | 唯一可执行产物；行为改动只改这里 |
| `nixos-infect.en.sh` | 英文注释副本；代码必须与主脚本一致 |
| `README.md` / `README.en.md` | 警告、平台矩阵、快速开始、参数总表 |
| `README.upstream.md` | 保留上游说明，便于对照行为差异 |
| `screenshots/` | 文档引用路径为 `../../screenshots/xxx.png` |
| `docs/zh-CN/` | 中文长文档；命令、参数、路径保留英文 |
| `docs/en/` | 英文文档；标题层级与中文树一致 |
| `scripts/` | 维护用校验脚本，不参与安装流程 |

## 代码规范

- 统一用 Bash（关联数组需要 Bash 4+），shebang 固定 `#!/usr/bin/env bash`，不要用 `sh` 运行。
- 主脚本只开 `set -o pipefail`，不用 `set -e`：探测、`grep`、`read` 等大量命令允许失败，需要显式判断并走兜底。
- 清理脚本相反，使用 `set -euo pipefail`：它由用户手动执行，步骤之间必须失败即停。
- `pipefail` 不是 POSIX，因此所有文档中的运行方式都写成 `bash` 或 `| bash`。
- 变量引用一律加引号：`"$var"`、`"${arr[@]}"`；可能未定义的用 `"${var:-}"`。
- 函数内变量用 `local` 声明；函数名用 `snake_case`，动词开头，如 `probe_run`、`write_nix_conf`。
- 索引数组用于有序列表（`MIRRORS`、`INSTALL_VARIANTS`），关联数组用于查表（`MSG_EN`、`R_STORE_URL`）。
- 判断优先用 `[ ]`，多分支用 `case`；需要 Bash 特性时不要伪装成 POSIX。
- 编辑器统一遵循 `.editorconfig`：UTF-8、LF、2 空格缩进；Markdown 不裁剪行尾空格（用于换行）。

## 注释规范

- 文件头：版本、用途、用法、上游来源；改版本号时同步日期。
- 分区标题：`# SECTION N: 职责` 加分隔线；新函数放进职责匹配的分区，不跨区堆代码。
- 函数头：写清用途、用法、输出、副作用；有写文件、改全局变量或 `exit` 的必须标明。
- 行内注释：只解释「为什么」，不复述代码；平台差异、非 TTY、安全兜底必须留注释。
- 英文注释版：`nixos-infect.en.sh` 面向英文读者，只翻译注释，不改代码与字符串；代码改动先落在 `nixos-infect.sh`，再同步到英文版。

正例：

```bash
# 用法: run_quiet "描述" cmd [args...]
# 输出: 终端一行进度；完整输出追加到 LOG_FILE
# 返回: 被执行命令的退出码
run_quiet() {
  ...
}
```

反例：

```bash
# 设置变量
local x=1
# 循环 10 次
for i in $(seq 1 10); do
```

- 注释用中文；面向用户的文案不要写死在函数里，走 i18n。
- 平台相关的「为什么」优先留在代码旁，例如宿主机缓存、管道执行时不能读 stdin。
- 不要提交大段被注释掉的旧实现；需要保留历史用 git。

## 文案与 i18n 规范

- 新增文案必须同时加到 `MSG_EN` 与 `MSG_ZH`，key 保持一致；中文缺失时 `msg` 会回退英文。
- key 用 `lower_snake_case`，按场景加前缀：`probe_`、`config_`、`install_`、`cleanup_`。
- 带变量时用 `%s` 占位，调用 `msg_fmt key args...`，不要手工拼接整句。
- 模板可能以 `-` 开头，`msg_fmt` 用 `printf --`，并保留 `SC2059` 抑制注释。
- 非 TTY 时 `ui_can_prompt` 返回假：菜单不读 stdin，`confirm` 取默认值，`enter_shell` 返回 1。
- 菜单、提示、警告写 stderr；stdout 只放结果，避免被 `$(...)` 捕获后污染返回值。

## 日志与输出规范

| 函数 | 用途 | 输出去向 |
| --- | --- | --- |
| `log_info` | 正常进度与成功信息 | stdout + 日志 |
| `log_step` | 阶段标题 | stdout + 日志 |
| `log_warn` | 可恢复问题 | stderr + 日志 |
| `log_error` | 失败与中止原因 | stderr + 日志 |
| `log_debug` | 排障细节，仅 `--verbose` | stdout + 日志 |

- 一条日志只表达一件事，不要把多行命令输出直接塞进 `log_info`。
- 耗时命令统一走 `run_quiet`：终端一行进度，完整输出进日志，失败时打印末尾 30 行。
- `LOG_FILE` 不可写时 `_log_write` 自动关闭文件日志，不能因此中断安装。

## 静态检查

```bash
bash -n nixos-infect.sh
shellcheck -x nixos-infect.sh
```

- `SC2034`：模板变量通过 `${!var}` 间接引用，保留 `# shellcheck disable=SC2034` 并写明原因。
- `SC1090`：`source` 的是运行时生成文件（探测缓存、nix profile），用行内抑制。
- `SC2059`：`msg_fmt` 的格式串来自 i18n，属于有意为之，加抑制注释。
- 新增告警不要全局关闭；先判断是否真实问题，再决定修代码还是局部抑制。

校验英文注释版与主脚本是否只有注释不同：

```bash
bash scripts/verify-comment-parity.sh
```

- 输出 `OK` 才算通过；它也能发现英文版误改代码。

确认「只改注释、不改行为」：

```bash
git diff -U0 -- nixos-infect.sh \
  | grep -E '^[+-][^+-]' \
  | grep -vE '^[+-][[:space:]]*(#|$)'
```

- 输出为空，说明改动只有注释和空行，等价于去掉注释后 diff 完全一致。
- 有输出时逐行确认为何需要改代码，不要借格式化工具重排整个文件。

## 测试策略

- 没有额外服务器时，先用 `--dry-run`：只生成配置到 `/tmp/nixos-infect-dryrun`，不改系统。
- `--no-infect`：走到写 `/etc/nix/nix.conf` 就停，可验证依赖与预检，不安装 Nix。
- `--no-reboot`：完整安装但不重启，检查 `/etc/NIXOS_LUSTRATE`、profile 和配置后再手动重启。
- 本地容器只跑到探测/配置阶段（`--dry-run`），不要在容器里验证引导和磁盘接管。
- 用 `curl ... | bash -s -- --lang=zh` 验证非 TTY 不读 stdin；交互路径用真实终端。
- 行为改动至少在一台 KVM + BIOS 云主机验证，并把结果回填 README「已验证平台」表。
- 未验证的平台（EFI、共享内核虚拟化）明确标注，不声称支持。

```bash
bash nixos-infect.sh --dry-run --lang=zh
grep -R '@@' /tmp/nixos-infect-dryrun || echo "no placeholders"
```

## 文档规范

- 中文为主、英文为辅；`docs/zh-CN/` 与 `docs/en/` 文件名、标题层级一一对应。
- 一个文件只有一个 `#`；`##` 章节、`###` 小节，不跳级。
- 禁止长段落：每段最多 3 行；并列信息用 `-` 列表，参数/矩阵/对照用表格。
- 命令用 bash 代码块（围栏标注 `bash`），Nix 配置用 `nix`，目录树/流程用 `text`。
- 开头 1~2 行说明「解决什么问题」，文末固定 `## 相关文档`。
- 同目录链接写 `./xxx.md`，截图写 `../../screenshots/xxx.png`，README 写 `../../README.md`。
- 截图统一为 `png`，宽度 ≤2000px、单张 ≤100KB；用 256 色调色板量化压缩，README 中以表格并列展示并链接原图。
- 每篇控制在 80~200 行；不要复制 README 大段内容，改为概述加链接。
- 行为变化同步更新 README、CLI 文档和相关指南；界面变化同时更新 `screenshots/`。

## 提交与发布

- commit 前缀：`docs:` 文档、`fix:` 修复、`feat:` 功能、`chore:` 杂项；例如 `fix: invalidate the host boot cache`。
- 版本号等于日期（如 `2026-10-01`），同时出现在脚本常量、`--help` 首行和 README 表格。
- 发布前检查清单：
  - `bash -n` 与 `shellcheck` 无新增告警。
  - 英文注释版已同步，`bash scripts/verify-comment-parity.sh` 输出 OK。
  - `--dry-run` 产物无 `@@` 占位符，`configuration.nix` 可被 `nix-instantiate --parse` 解析。
  - 影响安装或引导的改动已在真实 KVM 主机验证，并更新平台表。
  - README、`docs/zh-CN`、`docs/en` 的参数、默认值、路径一致。
  - `LICENSE` 保持 GPLv3，上游来源与致谢未丢失。
  - 截图与实际界面一致。

## 如何扩展

| 扩展类型 | 位置 | 需要同步 |
| --- | --- | --- |
| 新增镜像 | `SECTION 6` 的 `MIRRORS` 与探测路径 | README 镜像表、保底顺序、`--prefer` 校验 |
| 新增参数 | `SECTION 10` 的 `parse_args` 与 `show_help`（默认值在 `SECTION 1`） | README 完整参数、`cli.md` |
| 修改注释 | `nixos-infect.sh` 与 `nixos-infect.en.sh` | 两份同步，跑 `scripts/verify-comment-parity.sh` |
| 新增语言文案 | `SECTION 2` 的 `MSG_EN` / `MSG_ZH` | 所有调用点、非 TTY 默认值 |
| 修改默认配置 | `SECTION 11` 内置模板 | `SECTION 7` 的 `cfg_render` 参数、占位符文档 |
| 新增占位符 | `SECTION 11` 模板 + `SECTION 7` 渲染调用 | README 占位符表、配置文档 |

- 新增镜像先确认三类资源：安装器、channel、二进制缓存；缺安装器的镜像只能参与后两类。
- 新增参数要同时考虑环境变量（如适用）和 `--help`，并保证非 TTY 下有确定默认值。

## 相关文档

- [README](../../README.md)
- [工作原理](./how-it-works.md)
- [配置定制](./configuration.md)
