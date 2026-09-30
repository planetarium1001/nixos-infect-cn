# nixos-infect-cn

使用**国内镜像源**，把 Debian / Ubuntu 云主机原地转换为 NixOS。

[elitak/nixos-infect](https://github.com/elitak/nixos-infect) 的中文 fork。单文件、免构建，
安装器、channel、二进制缓存全部走国内镜像，无需额外网络配置。

- 版本：v1.0.0
- 参考：[lzc256/nixos-infect-cn](https://github.com/lzc256/nixos-infect-cn)、
  [kidonng/nixos-infect-tuna](https://gist.github.com/kidonng/852ea559816420acaf33017c6e7ccf8b)

## 警告

- **会清空服务器磁盘**，只在新机器上运行。
- **必须先配置好 SSH 公钥登录**，转换后 root 没有密码。
- 不支持 OpenVZ / LXC 等共享内核虚拟化。

## 已验证平台

| 平台 | 原始系统 | 引导 | 结果 |
| --- | --- | --- | --- |
| 腾讯云 Lighthouse | Debian 12 | BIOS | 通过 |
| 腾讯云 Lighthouse | Ubuntu 20.04 LTS | BIOS | 通过 |
| 腾讯云 Lighthouse | Ubuntu 22.04 LTS | BIOS | 通过 |
| 腾讯云 Lighthouse | Ubuntu 26.04 LTS | BIOS | 通过 |

均为 KVM 实例，转换到 NixOS 25.11：DHCP 正常、SSH 可登录、host key 保留，
安装后 `nix-channel --update` / `nixos-rebuild` 均走国内镜像。

**建议使用上表中已验证的系统版本。** Ubuntu 24.04、Debian 13 未经验证；
上游的经验是 LTS 版本稳定，非 LTS（如 22.10、23.10）失败。EFI 引导尚未实测。

## 快速开始

```bash
# 1. 先确保能用密钥登录（转换后 root 没有密码）
ssh-copy-id root@<服务器IP>

# 2. 一键转换（中文输出，全自动）
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh | bash -s -- --lang=zh
```

脚本会自动探测国内镜像、生成配置、安装 NixOS，完成后自动重启。

### 下载源

| 源 | 地址 |
| --- | --- |
| jsDelivr（推荐） | `https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh` |
| Gitee 镜像 | `https://gitee.com/planetarium1001/nixos-infect-cn/raw/master/nixos-infect.sh` |
| GitHub 加速 | `https://gh-proxy.com/https://raw.githubusercontent.com/planetarium1001/nixos-infect-cn/master/nixos-infect.sh` |
| GitHub 原始 | `https://raw.githubusercontent.com/planetarium1001/nixos-infect-cn/master/nixos-infect.sh` |

- jsDelivr 会缓存分支引用，`master` 的更新最长可能延迟数小时生效。
- **GitHub 原始地址在国内不稳定**，实测经常超时，不建议直接用。
- Gitee 镜像自动同步自 GitHub，但它会对中文内容较多的文件做风控，`raw` 访问可能返回
  `451`。遇到时换用上面其他源。
- 管道执行时没有终端，无法交互，所有提问都取默认值。

## 常用示例

快速开始里那条管道命令就是推荐用法。需要改参数时，追加到 `bash -s --` 后面即可：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh | bash -s -- --lang=zh --no-probe
```

下面这些例子假设脚本已经下载到本地。**交互模式必须下载到本地再用**，管道执行时没有终端。

**先下载再执行**

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh -o nixos-infect.sh
bash nixos-infect.sh --lang=zh
```

**英文输出**

```bash
bash nixos-infect.sh --lang=en
```

**交互模式，自己挑镜像**（需要终端，可编辑生成的配置）

```bash
bash nixos-infect.sh --interactive --lang=zh
```

**不探测，直接用保底顺序**（最快，TUNA → NJU → BFSU → USTC → SJTUG）

```bash
bash nixos-infect.sh --no-probe --lang=zh
```

**指定优先镜像**

```bash
bash nixos-infect.sh --prefer=NJU --lang=zh
```

**先安装不重启，检查无误再重启**

```bash
bash nixos-infect.sh --no-reboot --lang=zh
```

**用外部模板覆盖配置**

```bash
bash nixos-infect.sh --lang=zh \
  --template=configuration:/root/my-configuration.nix \
  --template=networking:/root/my-networking.nix
```

**换用其他下载源**

```bash
# 例：走 GitHub 加速代理
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/planetarium1001/nixos-infect-cn/master/nixos-infect.sh | bash -s -- --lang=zh
```

## 重启之后

```bash
ssh root@<服务器IP>          # 用原来的密钥即可，host key 会保留
nixos-version                # 预期 25.11 (Xantusia)
nix-channel --list           # 应指向国内镜像，而不是 channels.nixos.org
nix config show | grep substituters
```

确认一切正常后，清理旧系统残留（会交互确认删除 `/old-root`，可释放数 GB）：

```bash
bash /root/nixos-infect-cleanup.sh
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `--lang=en\|zh` | 输出语言，默认 `en` |
| `--interactive` | 交互模式：挑镜像、编辑配置。需要终端 |
| `--auto` | 全自动，默认 |
| `--yes` | 跳过确认提示（仅交互模式下有提示） |
| `--verbose` | 打印 debug 日志，并原样输出安装器与 Nix 的完整过程 |
| `--no-color` | 关闭颜色 |
| `--skip-probe` | 复用 1 小时内的探测缓存，无缓存时询问是否重测 |
| `--no-probe` | 不探测，直接用保底顺序 |
| `--fast` | 快速探测，每个镜像只测 1 轮（默认 3 轮取中位数） |
| `--prefer=NAME` | 优先镜像：`TUNA` `NJU` `BFSU` `USTC` `SJTUG` |
| `--channel=CHANNEL` | 指定 NixOS channel，默认自动探测最新稳定版 |
| `--template=TYPE:PATH` | 用外部模板覆盖内置模板，可重复。`TYPE` = `configuration` / `hardware` / `networking` |
| `--networking` | 强制生成 `networking.nix`（静态 IP） |
| `--no-networking` | 禁止生成 `networking.nix` |
| `--dry-run` | 只探测 + 生成配置，不安装，输出到 `/tmp/nixos-infect-dryrun` |
| `--no-infect` | 只做准备，不安装 |
| `--no-reboot` | 安装后不重启 |
| `--no-swap` | 不创建临时 swap |

完整说明见 `bash nixos-infect.sh --help`。

## 环境变量

显式设置的值优先级高于探测结果。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `NIX_INSTALL_URL` | 自动探测 | Nix 安装器 URL |
| `NIX_CHANNEL` | 自动探测 | NixOS channel，如 `nixos-25.11` |
| `NIX_CHANNEL_URL` | 自动探测 | channel tarball URL |
| `NIX_SUBSTITUTERS` | 自动探测 | 空格分隔，自动去重并过滤 `cache.nixos.org` |
| `CONFIG_DIR` | `/etc/nixos` | 配置输出目录 |
| `LOG_FILE` | `/var/log/nixos-infect.log` | 日志文件，不可写时自动关闭 |
| `NO_REBOOT` / `NO_SWAP` / `NO_INFECT` | 空 | 非空则生效，含义同同名参数 |

## 镜像与探测

保底顺序：**TUNA → NJU → BFSU → USTC → SJTUG**。

| 镜像 | 安装器 | channel | 二进制缓存 |
| --- | --- | --- | --- |
| TUNA（清华） | 有 | 有 | 有 |
| NJU（南大） | 有 | 有 | 有 |
| BFSU（北外） | 有 | 有 | 有 |
| USTC（中科大） | 无 | 有 | 有 |
| SJTUG（上交） | 无 | 有 | 有 |

安装器、channel、二进制缓存三个维度独立探测，按实测速度排序。
探测结果缓存在 `/tmp/nixos-infect-cn.probe`，TTL 1 小时。

生成的配置里**不会写入 `cache.nixos.org`**（Nix 会自动追加在最后作为兜底）。

## 模板自定义

内置四份模板（`configuration`、EFI / BIOS 的 `hardware`、`networking`），
占位符为 `@@NAME@@`。两种改法：

- 用 `--template=TYPE:PATH` 指定外部文件，占位符可保留（会被替换）也可删掉写成静态内容
- 直接编辑脚本的 `SECTION 11`

`configuration` 可用占位符：`@@HOSTNAME@@` `@@DOMAIN@@` `@@ZRAM@@` `@@NETWORK_IMPORT@@`
`@@SUBSTITUTERS_BLOCK@@` `@@DEFAULT_CHANNEL@@` `@@AUTHORIZED_KEYS@@`

## 已知限制

- 管道执行（`curl | bash`）时无法交互，所有提问自动取默认值。
- EFI 引导未实测，目前只在 BIOS + GRUB 上验证过。
- Ubuntu 24.04 及更新的版本未测试。
- 清理脚本的 `/old-root` 需要手动确认删除。

## 排障

安装前脚本会自检并打印引导模式、根设备、`NIXOS_LUSTRATE` 内容等。
若 `NIXOS_LUSTRATE` 为空或缺失会直接中止、不重启，避免重启后半死不活。

首次在新机器上建议分两步：

```bash
# 第一步：只安装、不重启，检查产物
bash nixos-infect.sh --no-reboot --lang=zh
cat /etc/NIXOS_LUSTRATE
cat /etc/nixos/configuration.nix
ls -l /nix/var/nix/profiles/system

# 第二步：确认无误后重启
reboot
```

重启后若无法 SSH，请提供 VNC / 串口引导日志。日志在 `/var/log/nixos-infect.log`，
加 `--verbose` 可同时打印到屏幕。

## 致谢

- [elitak/nixos-infect](https://github.com/elitak/nixos-infect) —— 上游项目
- [lzc256/nixos-infect-cn](https://github.com/lzc256/nixos-infect-cn) —— 参考实现
- [kidonng/nixos-infect-tuna](https://gist.github.com/kidonng/852ea559816420acaf33017c6e7ccf8b) —— TUNA 补丁思路
- TUNA、NJU、BFSU、USTC、SJTUG 镜像站

上游原始 README 见 [README.upstream.md](./README.upstream.md)。

## License

[GNU General Public License v3.0](./LICENSE)，与上游保持一致。
