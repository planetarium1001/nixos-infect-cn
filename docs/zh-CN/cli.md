# 参数与环境变量参考

本文列出 `nixos-infect.sh` 的全部参数、环境变量、输出规则与中止条件，供部署时查表使用。

## 基本用法

### 管道执行（最常用）

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh \
  | bash -s -- --lang=zh
```

- `-s --` 让后续参数传给脚本，而不是被 bash 自己吃掉。
- 管道没有终端，脚本不会提问，所有选项取默认值。

### 下载后运行

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh -o nixos-infect.sh
bash nixos-infect.sh --lang=zh
```

- 需要 `--interactive` 编辑配置时，必须用这种方式。
- 也可以先 `bash nixos-infect.sh --help` 确认当前版本的参数。

### 指定输出语言

```bash
bash nixos-infect.sh --lang=zh   # 中文
bash nixos-infect.sh --lang=en   # English（默认）
```

- `--lang=zh_CN`、`--lang=zh_TW` 与 `zh` 等价。
- `--help` 输出的帮助文本本身固定为英文。

## 参数总表

### 通用

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--lang=CODE` | `en` `zh` | `en` | 输出语言；`zh_CN` / `zh_TW` 也接受 |
| `--interactive` | — | 关闭 | 交互模式：选择镜像、进 shell 编辑配置；需要 TTY |
| `--auto` | — | 开启 | 全自动，不进入编辑流程 |
| `--yes` | — | 关闭 | 跳过多余确认（仅交互流程中会出现提问） |
| `--verbose` | — | 关闭 | 打印 `[DEBUG]`，并原样透传安装器与 Nix 的完整输出 |
| `--no-color` | — | 关闭 | 关闭 ANSI 颜色（等价 `NO_COLOR=1`） |
| `--help` / `-h` | — | — | 打印帮助与版本号后退出 0 |

### 探测

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--skip-probe` | — | 关闭 | 复用 1 小时内的探测缓存；过期或缺失时询问是否重新测速 |
| `--no-probe` | — | 关闭 | 完全不探测，直接用保底顺序，channel 固定 `nixos-25.11` |
| `--fast` | — | 关闭 | 每个镜像只测 1 轮（默认 3 轮取中位数） |
| `--prefer=NAME` | `TUNA` `NJU` `BFSU` `USTC` `SJTUG` | 空 | 优先镜像；名称会转大写校验，非法值直接退出 1 |
| `--channel=CHANNEL` | 如 `nixos-25.11` | 自动探测 | 固定 channel；探测失败回退 `nixos-25.11` |

### 配置

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--template=TYPE:PATH` | `configuration` `hardware` `networking` | 内置模板 | 外部模板覆盖内置模板，可重复；文件不可读则中止 |
| `--networking` | — | 自动判断 | 强制生成 `networking.nix`（静态 IP）；取不到网卡/IP 时中止 |
| `--no-networking` | — | 自动判断 | 禁止生成 `networking.nix`（DHCP 场景） |

### 安装

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--dry-run` | — | 关闭 | 只探测并生成配置到 `/tmp/nixos-infect-dryrun`，不安装 |
| `--no-infect` | — | 关闭 | 只做准备工作（写 `/etc/nix/nix.conf`、临时 swap），跳过安装 |
| `--no-reboot` | — | 关闭 | 安装后不重启，便于先检查产物 |
| `--no-swap` | — | 关闭 | 不创建 1GB 临时 swap；原系统已有 swap 设备时也会自动跳过 |

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NIX_INSTALL_URL` | 自动探测 | Nix 安装器地址 |
| `NIX_CHANNEL` | 自动探测 | NixOS channel，如 `nixos-25.11` |
| `NIX_CHANNEL_URL` | 自动探测 | channel tarball 地址 |
| `NIX_SUBSTITUTERS` | 自动探测 | 空格分隔；自动去重并过滤 `https://cache.nixos.org` |
| `CONFIG_DIR` | `/etc/nixos` | 配置输出目录 |
| `LOG_FILE` | `/var/log/nixos-infect.log` | 日志路径；不可写时自动关闭文件日志 |
| `NO_REBOOT` | 空 | 非空即生效，含义同 `--no-reboot` |
| `NO_SWAP` | 空 | 非空即生效，含义同 `--no-swap` |
| `NO_INFECT` | 空 | 非空即生效，含义同 `--no-infect` |

- 显式设置的环境变量优先于探测结果：探测与缓存都不会覆盖已有值。
- `NIX_INSTALL_URL`、`NIX_CHANNEL_URL`、`NIX_CHANNEL` 三者都设置时，脚本完全跳过探测。
- `NIX_SUBSTITUTERS` 过滤后若为空，生成的配置不写 `substituters` 块。

## 常用组合

**国内快速安装**：默认流程，自动探测并选最快镜像。

```bash
bash nixos-infect.sh --lang=zh --auto
```

**交互改配置**：先选镜像，再进 shell 编辑 `/etc/nixos/configuration.nix`。

```bash
bash nixos-infect.sh --lang=zh --interactive
```

**只演练**：只生成配置，不改系统；产物在 `/tmp/nixos-infect-dryrun`。

```bash
bash nixos-infect.sh --lang=zh --dry-run
```

**指定镜像**：仅当该镜像对应资源可用时生效，否则回退到测速最优者。

```bash
bash nixos-infect.sh --lang=zh --prefer=TUNA
```

**固定 channel**：适合复现问题或对齐版本。

```bash
bash nixos-infect.sh --lang=zh --channel=nixos-25.11
```

**无网络探测**：不测速、启动最快，使用保底顺序与 `nixos-25.11`。

```bash
bash nixos-infect.sh --lang=zh --no-probe
```

## 输出与日志

### 终端输出

- `[INFO]`、`==>` 写 stdout；`[WARN]`、`[ERROR]` 写 stderr。
- 交互菜单写 stderr，stdout 只输出被选中的 key，避免被 `$(...)` 一起捕获。
- 非 TTY（管道执行）不读 stdin，提问一律取默认值并标注「非交互」。
- 颜色仅在 stdout 是终端且未设置 `NO_COLOR` 时启用。
- `run_quiet` 包装的耗时步骤在终端只显示转轮、秒数与最后一行输出。

### 日志文件

- 路径 `/var/log/nixos-infect.log`，每行格式为 `日期 时间 [LEVEL] 内容`。
- 安装器与 `nix-env` 构建的完整输出按 `===== 时间 标签 =====` 分块追加。
- `LOG_FILE` 不可写或置空时关闭文件日志，终端输出不受影响。
- 步骤失败时终端只回显末尾 30 行，完整内容以日志为准。

## 退出与中止

| 触发条件 | 脚本行为 | 如何恢复 |
| --- | --- | --- |
| 非 root | 报 `Must run as root` 并退出 1 | 用 root 重跑 |
| 缺 `curl` 与 `wget` | 先尝试用 wget 兜底或 apt 安装，仍失败则退出 1 | 手动装好 curl 后重跑 |
| 缺 `bzcat` / `xzcat` / `tar` / `ip` / `awk` 等 | 退出 1 | 用 apt/dnf 补齐依赖后重跑 |
| 参数非法（未知参数、`--prefer` 拼错、`--template` 类型错误） | 退出 1 | 按 `--help` 修正参数 |
| 强制 `--networking` 但读不到网卡或 IPv4 | 拒绝生成空配置并退出 1 | 改用 `--no-networking` 或手工写 `networking.nix` |
| `configuration.nix` 语法错误，且无 TTY | 退出 1，错误前 20 行打到 stderr | 修好文件后重跑；有 TTY 时可进 shell 反复修 |
| 系统构建（`nix-env --set`）失败，且无 TTY | 退出 1 | 按日志修正配置后重跑 |
| 下载安装器失败、`nix-channel` 失败 | 退出 1 | 换镜像或设 `NIX_INSTALL_URL` 后重跑 |
| 引导程序安装失败 | 退出 1，提示机器可能无法启动 NixOS | 不要重启，先看 VNC 与日志 |
| EFI 下备份 `/boot` 到 `/boot.bak` 失败 | 退出 1，避免破坏 `/boot` | 手工检查挂载点后重跑 |

- 非 root 的检查在生成配置之后、安装之前执行，报错时 `/etc/nixos` 可能已被写入。
- 当前版本没有「`NIXOS_LUSTRATE` 为空即中止」的检查：清单只在 `finalize_nixos` 中追加。
- 首次使用建议 `--no-reboot` 安装，确认 `cat /etc/NIXOS_LUSTRATE` 非空后再手动重启。

## 相关文档

- [安装教程](./installation.md)
- [镜像与探测](./mirrors.md)
- [配置定制](./configuration.md)
- [排障指南](./troubleshooting.md)
