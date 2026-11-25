# 排障指南

本文覆盖 nixos-infect-cn 安装失败、重启不进 NixOS、SSH 失联等常见问题。  
先按「症状速查表」定位，再进入对应小节处理。

## 先收集信息

- 日志：`/var/log/nixos-infect.log`；加 `--verbose` 会把 debug 和完整过程也写进去。
- 屏幕：云控制台的 VNC / 串口输出，尤其是引导菜单和内核日志。
- 命令：完整命令、参数、发生时间，以及失败发生在哪个阶段。

```bash
bash nixos-infect.sh --lang=zh --verbose
tail -n 100 /var/log/nixos-infect.log
```

| 类别 | 内容 |
| --- | --- |
| 环境 | 云厂商与实例类型、原系统版本、BIOS/EFI、`uname -m`、虚拟化类型 |
| 过程 | 完整命令、日志尾部、失败阶段、是否用过 `--no-reboot` |
| 现场 | VNC/串口截图、`/etc/NIXOS_LUSTRATE`、`/proc/cmdline`、SSH 报错 |

已重启进 NixOS 时，旧日志通常在 `/old-root/var/log/nixos-infect.log`。

## 症状速查表

| 症状 | 最可能原因 | 跳转 |
| --- | --- | --- |
| 重启后仍是原系统 | 宿主机缓存了 `/boot` 解析结果 | [重启后仍是原系统](#重启后仍是原系统) |
| 重启后 SSH 超时或拒绝 | 卡在关机、公钥缺失、host key 变化 | [重启后 SSH 连不上](#重启后-ssh-连不上) |
| 脚本中途退出，未重启 | 配置错误、缺依赖、镜像不可达 | [安装中途退出](#安装中途退出) |
| `configuration.nix failed to parse` | 手改配置语法错误 | [configuration.nix 语法错误](#configurationnix-语法错误) |
| 下载安装器或构建失败 | 镜像不可达、磁盘或内存不足 | [下载或构建失败](#下载或构建失败) |
| 下载脚本得到 451 或旧版本 | Gitee 审核 / jsDelivr 缓存 | [Gitee 返回 451 / jsDelivr 缓存旧版](#gitee-返回-451--jsdelivr-缓存旧版) |
| 清理脚本拒绝执行 | 还没引导进 NixOS | [清理脚本拒绝执行](#清理脚本拒绝执行) |
| 安装后完全无法引导 | OpenVZ / LXC 共享内核 | [虚拟机/VPS 不支持](#虚拟机vps-不支持) |

## 重启后仍是原系统

**现象**：安装完成并重启，`uname -a` 仍是原发行版，VNC 可能看不到 GRUB；**原因**：宿主机自行解析并缓存 `/boot/grub/grub.cfg`，改了 GRUB 仍按旧引导项启动。  
**处理**：

```bash
cat /etc/NIXOS_LUSTRATE
tr ' ' '\n' < /proc/cmdline | grep BOOT_IMAGE
touch /boot/vmlinuz-* /boot/initrd.img-* && reboot
```

- 清单仍存在 = NixOS 从未启动；`BOOT_IMAGE` 指向原内核 = 宿主机用了旧引导项。
- `touch` 内核文件后重启，强制宿主机重新读取 `/boot`；能看到 GRUB 时也可手动选 NixOS。

**如何确认**：`BOOT_IMAGE` 变为 `/nix/store/.../kernel`，且 `/etc/NIXOS_LUSTRATE` 消失。

## 重启后 SSH 连不上

**现象**：`ssh root@<服务器IP>` 超时、`Connection refused`，或提示 host key 已变更；**原因**：卡在关机、公钥缺失、host key 冲突，或静态网络配置有误。  
**处理**：

- 先用 VNC 查看，若停在关机画面，手动重启一次。
- 配置摘要中 `SSH authorized keys` 为 `0` 时，先回原系统补公钥再重装。
- host key 冲突时删除旧记录后重连：

```bash
ssh-keygen -R <服务器IP>
ssh -o StrictHostKeyChecking=accept-new root@<服务器IP>
```

- 静态 IP 场景检查 `/etc/nixos/networking.nix` 的地址与网关。

**如何确认**：能登录，`nixos-version` 为 `25.11`，`systemctl status sshd` 正常。

## 安装中途退出

**现象**：脚本以非零状态退出，机器没有重启，仍运行原系统。
**原因**：配置语法错误、缺关键依赖、镜像不可达、构建失败，或主动使用了 `--no-infect`。
**处理**：

```bash
tail -n 50 /var/log/nixos-infect.log
cat /etc/NIXOS_LUSTRATE 2>/dev/null || echo "not staged yet"
ls -l /nix/var/nix/profiles/system 2>/dev/null
```

- 日志最后一条 `[ERROR]` 指出失败阶段，按下面「下载或构建失败」「configuration.nix 语法错误」继续处理。
- 重跑脚本是安全的：已安装的 Nix、已生成的配置、已完成的接管都会被跳过。
- 当前版本没有独立的「`NIXOS_LUSTRATE` 为空即中止」检查；用 `--no-reboot` 安装后，请自行确认清单非空再重启。

**如何确认**：日志出现 `Installation complete`，且 `/etc/NIXOS_LUSTRATE` 内容完整。

## configuration.nix 语法错误

**现象**：出现 `configuration.nix failed to parse`，或构建阶段报 Nix 语法错误；**原因**：手改配置少了分号/括号，或外部模板替换占位符后不是合法 Nix 表达式。  
**处理**：

```bash
nix-instantiate --parse /etc/nixos/configuration.nix
```

- 有 TTY 时脚本会打开 shell，改完 `exit` 自动重试；无 TTY 直接中止。
- 无 TTY 改用下载后的 `--interactive`，或 `--template=configuration:/root/fixed.nix`。
- 仍不行就先下载脚本，编辑 `SECTION 11` 内置模板；`--no-reboot` 可先修配置再重启。

**如何确认**：`--parse` 无输出，重跑后构建成功，`/nix/var/nix/profiles/system` 生成。

## 下载或构建失败

**现象**：`Failed to download the Nix installer`、channel 下载失败，或构建 system 闭包失败；**原因**：镜像不可达或过慢、磁盘不足、内存不足、临时网络抖动。  
**处理**：

- 换镜像：`--prefer=TUNA`，或 `--no-probe` 使用保底顺序，`--fast` 缩短测速。
- 加 `--verbose`，检查日志和失败命令的末尾 30 行。
- 内存不足时先扩 swap（默认建 1GB，`--no-swap` 会关闭）；磁盘检查 `df -h / /nix /tmp`。

```bash
bash nixos-infect.sh --lang=zh --prefer=TUNA --verbose
free -h
```

**如何确认**：日志出现 `Installation complete` 且无 `[ERROR]`；system profile 指向有效闭包。

## Gitee 返回 451 / jsDelivr 缓存旧版

**现象**：`curl` 下载脚本得到 451、空文件，或运行后发现版本不是最新；**原因**：Gitee 对内容较多的文件做审核，`raw` 可能返回 `451`，jsDelivr 缓存分支引用。  
**处理**：

- Gitee 451：换 jsDelivr 或 GitHub 加速地址，不要把 Gitee 作为唯一来源。
- jsDelivr 旧版：把 `@master` 换成具体 commit id，或主动清缓存。

```bash
curl -fsSL https://purge.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh
```

**如何确认**：`bash nixos-infect.sh --help | head -1` 显示 `nixos-infect-cn 2026-10-01`。

## 清理脚本拒绝执行

**现象**：运行 `/root/nixos-infect-cleanup.sh` 时报 `this does not look like a booted NixOS system`；**原因**：脚本要求 `/run/current-system` 存在且 `/etc/os-release` 为 `ID=nixos`。  
**处理**：

```bash
grep '^ID=' /etc/os-release
ls -d /run/current-system
```

- 任一不满足说明还没引导进 NixOS，重启后再执行。
- 已经进入 NixOS 仍报错，检查 `/etc/os-release` 是否被手工改过。

**如何确认**：`ID=nixos` 且 `/run/current-system` 存在，重跑能看到 `/old-root` 询问。

## 虚拟机/VPS 不支持

**现象**：安装后无法引导，或安装阶段无法写入引导器/内核；**原因**：OpenVZ、LXC 等共享内核虚拟化没有独立内核和引导器，NixOS 无法接管。  
**处理**：

```bash
systemd-detect-virt
cat /proc/1/cgroup
ls -d /proc/vz 2>/dev/null
```

- 输出 `openvz`、`lxc`，或 `/proc/vz` 存在，均属于共享内核，应换 KVM / Xen HVM 实例。
- 脚本不会主动拦截这类环境，运行前需自行确认。

**如何确认**：新实例 `systemd-detect-virt` 输出 `kvm` 或 `none`；EFI 尚未实测，优先 BIOS。

## 仍然无法解决

- 脚本版本：`bash nixos-infect.sh --help | head -1`。
- 环境：云厂商、实例规格、原系统版本、`uname -a`、`systemd-detect-virt`、BIOS/EFI。
- 完整命令与参数，失败发生在哪个阶段。
- `/var/log/nixos-infect.log` 尾部（或 `/old-root/var/log/nixos-infect.log`）。
- VNC / 串口截图，包含 GRUB 菜单和内核报错。
- 重启后的 `/etc/NIXOS_LUSTRATE` 与 `tr ' ' '\n' < /proc/cmdline | grep BOOT_IMAGE`。
- SSH 完整报错，以及是否已配置公钥登录。

## 相关文档

- [安装教程](./installation.md)
- [安装后清理](./cleanup.md)
- [工作原理](./how-it-works.md)
- [参数与环境变量参考](./cli.md)
