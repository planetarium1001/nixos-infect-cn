# 镜像与探测

本文说明脚本如何在五个国内镜像之间选择安装器、channel 与二进制缓存，以及探测结果、缓存和手动覆盖怎么用。

## 内置镜像

| 镜像 | 代号 | 安装器 | channel | 二进制缓存 | 备注 |
| --- | --- | :---: | :---: | :---: | --- |
| 清华 TUNA | `TUNA` | 支持 | 支持 | 支持 | 三类齐全，保底首位 |
| 南大 NJU | `NJU` | 支持 | 支持 | 支持 | 三类齐全 |
| 北外 BFSU | `BFSU` | 支持 | 支持 | 支持 | 三类齐全 |
| 中科大 USTC | `USTC` | 不支持 | 支持 | 支持 | 未提供 `/nix/latest/install` |
| 上交 SJTUG | `SJTUG` | 不支持 | 支持 | 支持 | 未提供 `/nix/latest/install` |

- 判定依据是 `MIRRORS` 数组第三列：USTC、SJTUG 该列为空，脚本只尝试 `/nix/...` 下的三个安装器变体；实测均不可用。
- 保底顺序为 `TUNA → NJU → BFSU → USTC → SJTUG`，只用于 `--no-probe` 与探测失败兜底。

## 三类资源

### 安装器（install）

- 作用：下载 Nix 安装脚本，再以 `sh <installer> --no-channel-add` 执行。
- 首选地址：`<base>/nix/latest/install`，如 `https://mirrors.tuna.tsinghua.edu.cn/nix/latest/install`。
- 候选变体：`/nix/install`、`/nix/nix-installer/latest/install`。
- 官方兜底：`https://nixos.org/nix/install`。

### channel（nix-channels）

- 作用：作为 `nix-channel --add` 的地址，决定 `nixpkgs` 从哪下载。
- 地址形态：`<base>/nix-channels/<channel>`，如 `https://mirror.nju.edu.cn/nix-channels/nixos-25.11`。
- 探测方式：请求 `<channel>/nixexprs.tar.xz` 的 HEAD 状态码。

### 二进制缓存（substituters / store）

- 作用：构建时复用预编译包，写入 `nix.settings.substituters`。
- 地址形态：`<base>/nix-channels/store`，如 `https://mirrors.bfsu.edu.cn/nix-channels/store`。
- 探测方式：请求 `nix-cache-info` 的 HEAD 状态码。

## 探测流程

```text
解析 channel
  → 逐镜像 HEAD 检查三类资源
  → 1MB range 测速 3 轮取中位数
  → 按速度排序
  → 生成 install / channel / substituters 并写缓存
```

1. 解析 channel：请求 `https://nixos.org/channels/`，抓取 `nixos-X.Y` 并取最新；失败回退 `nixos-25.11`。`--no-probe` 直接返回 `nixos-25.11`。
2. 逐镜像检查：脚本按 `MIRRORS` 顺序**串行**遍历，每个镜像依次检查安装器、channel、二进制缓存；单次请求连接超时 5 秒、总超时 30 秒。
3. 失败重试：状态码为 `000` / `500` / `502` / `503` / `504` 时 `sleep 1` 后重试一次；`200` / `301` / `302` / `307` / `308` 视为可用。
4. 测速：对 `/nix-channels/nixpkgs-unstable/nixexprs.tar.xz` 发起 1MB range 请求，测 3 轮取中位数；`--fast` 只测 1 轮；有效下载小于 256KB 记为失败。
5. 测速回退：该路径不可用时依次退回 channel 的 `nixexprs.tar.xz`、镜像根路径。
6. 排序：安装器与 channel 各取速度最高者；二进制缓存把全部可用镜像按速度降序排列。
7. 生成最终 URL 与 substituters，写入探测缓存。

- 探测是串行而非并发，镜像多、网络差时总耗时约为各次超时之和。

## 探测缓存

| 项目 | 值 |
| --- | --- |
| 路径 | `/tmp/nixos-infect-cn.probe`（可用 `PROBE_CACHE` 覆盖） |
| TTL | 3600 秒（1 小时） |
| 内容 | 注释头 + `NIX_INSTALL_URL`、`NIX_CHANNEL`、`NIX_CHANNEL_URL`、`NIX_SUBSTITUTERS` 四个赋值行 |
| 写入时机 | 探测完成后、放弃重测改用保底顺序后、交互选择镜像后 |

- `--skip-probe`：缓存新鲜且未指定 `--prefer` 时直接复用，并恢复用户预设的环境变量。
- 缓存过期或缺失时脚本询问「现在跑一次新的测速？」，非 TTY 环境默认取 `y`，即照常重测。
- 指定 `--prefer` 时缓存必然被忽略：缓存只有上一轮的最终 URL，没有完整测速表，无法据此重新排序。
- 复用缓存时不会重新打印探测汇总表，也不会进入镜像选择菜单。
- 安装结束的清理阶段刻意保留缓存，供之后的 `--skip-probe` 复用。

## 手动指定镜像

### 环境变量（最直接）

| 变量 | 作用 |
| --- | --- |
| `NIX_INSTALL_URL` | 固定安装器 URL，跳过安装器探测 |
| `NIX_CHANNEL` | 固定 channel 名，跳过 channel 解析 |
| `NIX_CHANNEL_URL` | 固定 channel tarball 地址 |
| `NIX_SUBSTITUTERS` | 固定缓存列表，空格分隔；自动去重并剔除 `cache.nixos.org` |

- `NIX_INSTALL_URL`、`NIX_CHANNEL`、`NIX_CHANNEL_URL` 三个变量都显式设置时，脚本完全跳过探测。

### --prefer=NAME

- 只接受 `TUNA` `NJU` `BFSU` `USTC` `SJTUG`，拼错会直接退出。
- 只影响安装器与 channel 的首选，且要求该镜像对应资源可用，否则回退到测速最优者。
- 不改变二进制缓存的顺序，缓存列表仍按测速降序排列。

### --no-probe

- 安装器固定为 TUNA，channel 固定为 TUNA 的 `nixos-25.11`。
- substituters 按 TUNA、NJU、BFSU、USTC、SJTUG 全量写入，由 Nix 依次尝试。
- 不发起任何测速请求，也不再询问是否重新测速。

## 官方源兜底

- 没有任何镜像提供安装器时，回退 `https://nixos.org/nix/install`。
- channel 同理回退 `https://nixos.org/channels/<channel>`。
- 交互模式的安装器与 channel 菜单里始终有 `official` 选项，可主动选择官方源。
- 生成的配置不写入 `cache.nixos.org`：脚本在 `normalize_substituters` 中剔除它；按 README 的说明，官方缓存由 Nix 自身在末尾兜底。

## 速度结果怎么看

- 汇总表列依次为 `Mirror`、`Install`、`Channels`、`Store`，单元格显示该镜像的实测速度。
- 单位：不低于 1 MiB/s 显示 `MB/s`，不低于 1 KiB/s 显示 `KB/s`，更低显示 `B/s`；速度为 0 显示 `—`。
- 颜色：绿色 ≥1 MB/s，黄色 ≥300 KB/s，红色更低，暗色表示无数据。
- `NOT_FOUND`（红色）：该类资源不可用，不会被选中。
- `OK`（黄色，通常出现在 Store 列）：镜像可达但无法测速（大文件被拒绝或不存在），仍会写入 substituters 并排在测速镜像之后。
- 表格下方脚注会提示测速方法与 `--fast` 的作用。
- 想快速对比多个镜像：加 `--fast` 只测 1 轮；要强制重测可先删除缓存文件，或用 `--prefer` 触发重新探测。

## 新增镜像的方法

- 编辑 `nixos-infect.sh` 的 `MIRRORS` 数组，格式为 `NAME|base_url|known_install_path`。
- 没有 `/nix/latest/install` 的镜像第三列留空，脚本会自动尝试 `INSTALL_VARIANTS` 里的三个变体。
- 新增前必须实测三类资源：安装器可下载、`/nix-channels/<channel>/nixexprs.tar.xz` 可用、`/nix-channels/store/nix-cache-info` 可用。
- 同步更新 `probe_fallback` 中的保底顺序、`--prefer` 的帮助文案与本文档。
- `--prefer` 的合法性校验直接遍历 `MIRRORS`，新代号无需额外注册。

## 相关文档

- [参数与环境变量参考](./cli.md)
- [排障指南](./troubleshooting.md)
- [项目规范与贡献](./development.md)
