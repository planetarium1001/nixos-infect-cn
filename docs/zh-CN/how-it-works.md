# 工作原理

本文按执行顺序拆解 `nixos-infect.sh` 的 7 个阶段，说明每步的输入、产物和失败行为。  
读完可以知道脚本改了哪些文件，以及为什么重启后能进入 NixOS。

## 总览

```text
[1] 探测         HEAD 检查 + 1MB 测速，选 install / channel / store
     ↓
[2] 配置         渲染 /etc/nixos/*.nix，交互模式下可编辑
     ↓
[3] 预检         检查 root、依赖、swap，写 /etc/nix/nix.conf
     ↓
[4] 安装 Nix     从国内镜像下载安装器，装到 /nix
     ↓
[5] 构建系统     配置 channel，构建 system profile
     ↓
[6] 接管引导     写 LUSTRATE，装 GRUB，使宿主机缓存失效
     ↓
[7] 重启清理     reboot；首次启动把旧系统移到 /old-root
```

## 各阶段详解

### 1. 探测

- 输入：`curl`、网络，以及 `--prefer`、`--fast`、`--skip-probe`、`--no-probe`。
- 动作：对每个镜像分别探测安装器、channel、二进制缓存；用 1MB range 请求测速，3 轮取中位数。
- 产物：`NIX_INSTALL_URL`、`NIX_CHANNEL`、`NIX_CHANNEL_URL`、`NIX_SUBSTITUTERS`，缓存到 `/tmp/nixos-infect-cn.probe`，TTL 1 小时。
- 失败：测速失败不阻断，按可达性排序；`--no-probe` 或用户拒绝重新测速时走 TUNA → NJU → BFSU → USTC → SJTUG 保底。
- 兜底：三类资源都没有可用镜像时，install 与 channel 回退 `nixos.org` 官方地址。

### 2. 配置

- 输入：探测结果、主机名/域名、`/root/.ssh/authorized_keys`、静态网络检测结果。
- 动作：用 `SECTION 11` 内置模板渲染，默认继承原系统主机名；`--template` 可替换单个模板。
- 产物：`/etc/nixos/configuration.nix`、`hardware-configuration.nix`，静态 IP 时额外生成 `networking.nix`。
- 失败：模板不可读、强制 `--networking` 却取不到网卡/IP 时立即退出，不生成半成品。
- 交互：`--interactive` 下可进 shell 修改，摘要会重新读文件；非 TTY 不提供编辑。
- 复用：已存在 `configuration.nix` 时自动模式直接沿用，不覆盖用户改动。

### 3. 预检

- 输入：当前系统环境、`/etc/nix/nix.conf`。
- 动作：确认 root 与 `curl`/`bzcat`/`xzcat`/`ip`/`tar` 等依赖，修正 host key 权限，按需创建 1GB 临时 swap。
- 产物：`/etc/nix/nix.conf` 写入国内 substituters 与官方签名公钥，保留用户其他配置行。
- 失败：缺依赖或非 root 直接退出；此时还没改写引导，机器仍可按原系统启动。
- dry-run：在预检前结束，只留下配置，不动系统。

### 4. 安装 Nix

- 输入：`NIX_INSTALL_URL` 指向的安装器脚本。
- 动作：已安装 Nix 则跳过；否则创建 `nixbld` 组与构建用户，下载安装器后执行 `--no-channel-add`。
- 产物：`/nix` 与 `~/.nix-profile`，后续构建所需的环境。
- 失败：下载失败或安装器返回非零即退出；镜像问题可换 `--prefer` 重跑。
- 兼容：没有 `curl` 时尝试用 `wget` 伪造 `curl` 函数，仍失败才报错。

### 5. 构建系统

- 输入：`NIX_CHANNEL_URL`、`/etc/nixos/*.nix`。
- 动作：`nix-channel --add/--update`，先 `nix-instantiate --parse` 检查语法，再构建 system profile。
- 产物：`/nix/var/nix/profiles/system`，新 NixOS 的完整系统闭包。
- 失败：语法或构建错误会进 shell 重试；非 TTY 直接退出并提示修配置。
- 进度：`run_quiet` 在终端显示一行进度，完整输出写入日志。

### 6. 接管引导

- 输入：构建好的 system profile、分区信息（`grubdev` 或 ESP）。
- 动作：写 `/etc/NIXOS` 与清理脚本，把关键路径追加到 `/etc/NIXOS_LUSTRATE`，执行 `switch-to-configuration boot`。
- EFI：先把旧 `/boot` 备份为 `/boot.bak`，再挂载 ESP 并清理旧内容。
- 缓存失效：`touch /boot/vmlinuz-*` 与 `/boot/initrd.img-*`，让自行解析引导的宿主机重新读取。
- 落盘：`sync` 后才允许重启；GRUB 安装失败或 `/boot` 备份失败会中止。

### 7. 重启清理

- 输入：`NO_REBOOT`、当前根文件系统。
- 动作：移除临时 swap、清理 dry-run 残留，保留探测缓存；默认执行 `reboot`。
- 首次启动：NixOS 消费 `/etc/NIXOS_LUSTRATE`，把旧系统移入 `/old-root`，并保留清单中的路径。
- 产物：可登录的 NixOS；旧系统在 `/old-root`，清理脚本在 `/root`。
- 失败：未进 NixOS 时清理脚本拒绝执行；卡关机见排障文档。
- 手动收尾：确认无误后运行 `bash /root/nixos-infect-cleanup.sh`。

## 关键机制

### NIXOS_LUSTRATE 接管

- 为什么需要：覆盖安装不能直接格式化根分区，必须让新系统先把旧根“挪走”。
- `finalize_nixos` 向清单追加 `etc/nixos`、`etc/resolv.conf`、channel 链接、清理脚本和 SSH host key。
- 首次启动时 NixOS 读取该清单，旧根内容进入 `/old-root`，清单中的路径留在新系统。
- 当前版本没有独立的「清单为空即中止」检查；用 `--no-reboot` 安装时，请自行确认清单非空再重启。

### /etc/NIXOS 幂等标记

- 为什么需要：脚本可能因网络或构建失败被重跑，接管不能重复执行。
- `finalize_nixos` 开头检查 `/etc/NIXOS`，存在即跳过整段并把结果视为已完成。
- 该标记只用于安装阶段判断；重跑时已生成的 `/etc/nixos` 配置也会被检测并复用。

### 宿主机引导缓存失效

- 为什么需要：部分云厂商宿主机自行解析 `/boot/grub/grub.cfg` 并缓存，磁盘上的 GRUB 改了也不生效。
- 现象：VNC 看不到 GRUB 菜单；重启后仍进原系统，但磁盘上的引导配置看起来完全正确。
- 处理：装完引导后 `touch` `/boot/vmlinuz-*` 与 `/boot/initrd.img-*`，用时间戳变化触发重读。
- 无害：靠磁盘 GRUB 引导的平台不受影响，文件内容也不需要真的变化。

### host key 保留

- 为什么需要：避免 `ssh` 报 host key 变更，客户端 `known_hosts` 可以继续使用。
- 实现：`/etc/NIXOS_LUSTRATE` 列出 `etc/ssh/ssh_host_*_key*`，旧 host key 不会被移入 `/old-root`。
- 安装前还会 `chmod 600` 这些私钥，避免 NixOS 侧的权限告警。
- NixOS 的 SSH 服务发现 key 已存在时不会重新生成，指纹保持不变。

### substituters 注入

- 为什么需要：默认走 `cache.nixos.org`，国内下载和构建会很慢甚至失败。
- `normalize_substituters` 会去重并过滤 `cache.nixos.org`。
- 同时写两处：`/etc/nix/nix.conf` 用于安装期，`configuration.nix` 的 `nix.settings.substituters` 用于重启后。
- Nix 仍可能自行把官方缓存追加到末尾兜底，但生成的配置不主动写入。

## 生成的文件

| 路径 | 作用 | 何时生成 | 重启后是否保留 |
| --- | --- | --- | --- |
| `/etc/nixos/*.nix` | 目标系统配置 | 配置阶段 | 保留（在 LUSTRATE 清单中） |
| `/etc/nix/nix.conf` | 安装期 substituters 与签名公钥 | 预检阶段 | 由 NixOS 按 `configuration.nix` 重新生成 |
| `/etc/NIXOS_LUSTRATE` | 接管清单 | 接管阶段 | 首次启动消费后不再存在 |
| `/root/nixos-infect-cleanup.sh` | 重启后清理脚本 | 接管阶段 | 保留到清理完成 |
| `/old-root` | 原系统根文件系统 | 首次启动 NixOS 时 | 保留到手动清理 |
| `/boot.bak` | EFI 下旧 `/boot` 备份 | 接管阶段（仅 EFI） | 保留到清理脚本删除 |
| `/var/log/nixos-infect.log` | 安装日志 | 运行期 | 通常随旧系统移到 `/old-root/var/log/` |
| `/tmp/nixos-infect-cn.probe` | 镜像探测缓存 | 探测阶段 | 不保留（`boot.tmp.cleanOnBoot`） |

## 脚本结构

行号由 `grep -n "SECTION" nixos-infect.sh` 得到，是约数，改动后会变化。

| SECTION | 职责 | 约行号 |
| --- | --- | --- |
| 1 | 常量、默认值、路径、运行时状态 | 41–92 |
| 1.1 | 颜色定义 | 93–108 |
| 2 | 日志函数与 `MSG_EN` / `MSG_ZH` | 110–341 |
| 3 | UI 原语：菜单、确认、shell、进度 | 343–532 |
| 4 | 通用工具：进度压缩、`run_quiet`、substituters、channel | 534–691 |
| 5 | 系统探测：EFI、根设备、swap、静态网络 | 693–818 |
| 6 | 镜像探测、测速、缓存、交互选择 | 820–1376 |
| 7 | 模板渲染、配置生成、摘要与编辑流程 | 1378–1693 |
| 8 | 依赖检查、Nix 安装、构建、接管引导 | 1695–2033 |
| 9 | 重启前清理与清理脚本生成 | 2035–2132 |
| 10 | `main`、参数解析、帮助文本 | 2134–2341 |
| 11 | 内置模板：configuration / hardware / networking | 2343–2468 |

## 设计取舍

- 幂等优先：重跑不重复接管，已有配置默认保留，失败后可以原地再试。
- 尽量少改上游业务逻辑：改动集中在镜像探测、国内文案与引导接管。
- 单文件、免构建：模板内置，`curl | bash` 即可运行，不引入打包步骤。
- 非 TTY 不读 stdin：管道执行时 `read` 会吞掉脚本自身，菜单和确认一律取默认值。
- 容错优于中断，但安全点例外：探测失败可回退；`/boot` 备份失败与 GRUB 失败必须中止。
- 不做额外自检：接管前不会主动校验 `NIXOS_LUSTRATE`，需要时用 `--no-reboot` 自行检查。
- 显式配置优先：环境变量和参数高于探测结果，用户指定值不会被探测覆盖。
- 国内网络优先：过滤 `cache.nixos.org`，自动测速并缓存结果，减少重复探测。

## 相关文档

- [安装教程](./installation.md)
- [配置定制](./configuration.md)
- [安装后清理](./cleanup.md)
- [项目规范与贡献](./development.md)
