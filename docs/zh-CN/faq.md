# 常见问题

本文汇总转换前后最常被问到的数据安全、兼容性、网络、维护与安全问题，回答均以当前脚本行为为准。

## 数据与回滚

### 会清空磁盘吗？

- 会覆盖系统盘上的原系统，脚本按「整机接管」设计，请只在新机器上运行。
- 原系统文件会被搬到 `/old-root`，但引导已改为 NixOS，不能当双系统使用。
- 删除 `/old-root` 后旧数据不可恢复。

### 能否保留原系统？

- 可以暂时保留：清理脚本询问是否删除 `/old-root`，只有输入 `y` / `yes` 才删，回车默认保留。
- 不能保留可引导的原系统：转换会改写引导程序，磁盘上最终只有一个可启动系统。
- 保留期间 `/old-root` 只是文件树，无法直接启动回原发行版。

### 失败后还能救吗？

- 未重启前：修正配置或换镜像重跑；Nix 已安装时会跳过安装器下载。
- 引导阶段失败（脚本退出 1）：**不要重启**，先看日志和云厂商 VNC / 串口输出。
- 重启后进不去系统：进入救援模式修复，或用云厂商控制台「重装系统」。

### 如何回滚到原系统？

- 没有自动回滚机制；`/old-root` 是文件备份，不是可引导系统。
- 需要原发行版时，用云厂商控制台重装对应系统镜像。
- 因此运行前请确认没有需要保留的数据，并已配置好 SSH 公钥。

## 兼容性

### 支持哪些发行版？

- 已实测：OpenCloudOS 8/9、Ubuntu 20.04/22.04/24.04/26.04、Debian 10.2/11.1/12.0/13.2。
- 测试环境为腾讯云 Lighthouse（KVM + BIOS），结果均为 NixOS 25.11，DHCP / SSH / host key 正常。
- 未列出的版本未经验证；上游经验是 LTS 稳定，非 LTS 版本容易失败。

### 支持 ARM 吗？

- 脚本仅对 x86_64 追加 `vmw_pvscsi` 内核模块，其余流程与架构无关。
- 已验证平台中没有 ARM 记录，ARM 未实测，不建议直接用于生产。
- 可先用 `--dry-run` 检查生成的 `hardware-configuration.nix` 是否合理。

### 为什么 OpenVZ / LXC 不行？

- 这类是共享内核虚拟化，容器内不能安装和引导自己的内核。
- 脚本需要写 MBR / GRUB、替换内核并重启，容器里没有这些权限。
- 脚本没有针对共享内核做适配，也不在支持范围内。

### EFI 支持情况？

- 脚本有 EFI 分支：探测 ESP、把旧 `/boot` 备份为 `/boot.bak`、配置 `efiSupport` 与 `efiInstallAsRemovable`。
- README 明确说明「EFI 引导尚未实测」。
- EFI 机器上建议先用 `--dry-run` 或测试实例验证。

### 支持哪些 NixOS 版本？

- 默认自动探测最新稳定版，探测失败回退 `nixos-25.11`；内置配置 `system.stateVersion = "25.11"`。
- 可用 `--channel=` 或环境变量 `NIX_CHANNEL` 固定版本。
- 当前实测结果为 NixOS 25.11。

## 网络与镜像

### 内网 / 无外网怎么办？

- 必须能访问镜像站或自建镜像，完全离线跑不通。
- 用 `NIX_INSTALL_URL`、`NIX_CHANNEL_URL`、`NIX_SUBSTITUTERS` 指向内网镜像。
- 不想测速时加 `--no-probe`，直接用保底顺序。

### 镜像测速结果异常？

- 全部显示 `—`：可能是大文件被中间设备拦截，试试 `--fast` 或 `--prefer=`。
- 结果可疑：删除 `/tmp/nixos-infect-cn.probe` 后重跑，或等待 1 小时 TTL 过期。
- `OK` 但无速度：镜像可达但测不到速度，仍会写入 substituters 并排在测速镜像之后。

### 能否完全用官方源？

- 可以：设置 `NIX_INSTALL_URL=https://nixos.org/nix/install` 与 `NIX_CHANNEL_URL=https://nixos.org/channels/nixos-25.11`。
- 注意 `cache.nixos.org` 会被过滤，不会写进生成的配置。
- 官方源在国内通常较慢；交互模式的镜像菜单也可直接选 `official`。

### 公司代理怎么配？

- 脚本没有代理参数；`curl` 会读取 `http_proxy` / `https_proxy` 环境变量。
- 转换完成后，Nix 由 daemon 下载，代理需在 NixOS 配置里另行设置。
- 更省事的做法是改用网络可达的国内镜像。

## 使用与维护

### 转换后如何升级？

```bash
nix-channel --update
nixos-rebuild switch
```

- channel 已指向国内镜像，升级无需额外配置。
- 换版本：`nix-channel --add <channel URL> nixos && nix-channel --update`。

### host key 为什么保留？

- `finalize_nixos` 把 `etc/ssh/ssh_host_*_key*` 写进 `/etc/NIXOS_LUSTRATE`，NixOS 沿用原 host key。
- 好处是客户端 `known_hosts` 不会报冲突，登录体验连续。
- 脚本还会对 host key 私钥执行 `chmod 600`。

### 旧系统占多少空间？

- `/old-root` 是原系统的完整文件树，通常可释放数 GB，具体取决于原系统占用。
- 用 `du -sh /old-root` 查看；确认 NixOS 正常后跑清理脚本删除。

### 能否重复执行脚本？

- 不建议。脚本按一次性转换设计，只有部分步骤有幂等守卫：
  - 已安装 Nix → 跳过安装器下载
  - `/etc/NIXOS` 已存在 → 跳过 finalize
  - `/etc/nixos/configuration.nix` 已存在 → 自动模式沿用
- 需要从头再来，请用云厂商控制台重装系统。

### 能否在已有 NixOS 上跑？

- 不需要也不支持：它做的是从其他发行版接管系统。
- 已有 NixOS 想改配置，直接编辑 `/etc/nixos/configuration.nix` 后执行 `nixos-rebuild switch`。

## 安全

### root 无密码有什么风险？

- 转换后 root 没有密码，SSH 公钥是唯一登录方式。
- 运行前必须 `ssh-copy-id root@<服务器IP>`，或确认云厂商已注入公钥。
- 配置摘要会显示公钥条数，为 0 时请先补公钥再安装。

### 公钥丢失怎么办？

- 公钥是唯一登录方式，丢失后无法直接 SSH；优先尝试云厂商的「重置密码 / 注入公钥」功能。
- 也可以用救援模式挂载系统盘，把新公钥写入 `/root/.ssh/authorized_keys`。
- 恢复后立即补一份备用公钥，避免再次失去访问权限。

### 日志会记录什么？

- `/var/log/nixos-infect.log` 记录带时间戳的步骤日志、镜像 URL 与错误信息。
- 安装器与 `nix-env` 构建的完整输出也会按块追加，可能包含下载地址与包名。
- 不记录 SSH 私钥；配置摘要只显示公钥条数。

### License 是什么？

- GPLv3，与上游 `elitak/nixos-infect` 保持一致。
- 详见仓库根目录的 `LICENSE`。

## 相关文档

- [快速开始](./quickstart.md)
- [排障指南](./troubleshooting.md)
- [镜像与探测](./mirrors.md)
- [安装后清理](./cleanup.md)
- [工作原理](./how-it-works.md)
