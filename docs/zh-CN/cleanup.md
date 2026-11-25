# 安装后清理

`nixos-infect-cn` 会把原系统完整保留在 `/old-root`。本文说明何时、如何安全清理这些残留。  
清理只针对安装备份，不会改动 NixOS 本身。

## 为什么要清理

- `/old-root` 是原发行版的完整根文件系统，通常占用数 GB 磁盘。
- `/boot.bak` 只在 EFI 场景生成，是旧 `/boot` 的备份。
- 旧根中保留原系统的 `/root/.ssh`、应用配置和日志，长期保留有泄露风险。
- 新旧两套文件混在一起，排障时容易看错路径。

## 清理前确认

- 已能通过 SSH 密钥登录 NixOS，而不是只能靠云控制台。
- DHCP 或静态网络、SSH、业务服务均正常，至少成功重启过一次；重要数据先做快照。
- 不急着清理：观察几天再删也可以，`/old-root` 不影响系统运行。

## 运行清理脚本

```bash
bash /root/nixos-infect-cleanup.sh
```

脚本先做安全校验，再逐项处理：

| 步骤 | 行为 |
| --- | --- |
| 安全校验 | 要求 `/run/current-system` 存在且 `/etc/os-release` 为 `ID=nixos`，否则拒绝执行 |
| `/old-root` | 询问 `Remove /old-root? [y/N]`，只有 `y` / `yes` 才删除 |
| `/boot.bak` | 存在则直接删除（EFI 旧引导备份） |
| 垃圾回收 | 执行 `nix-collect-garbage -d` |
| 自删除 | 仅当 `/old-root` 已删除时删除脚本自身 |

交互示例：

```text
Old root filesystem detected at /old-root.
...
Remove /old-root? [y/N] y
Removing /old-root ...
Removing /boot.bak ...
Running nix-collect-garbage -d ...
Removing this script ...
=== Cleanup complete ===
```

- 直接回车、输入 `n` / `no` 或无法识别的内容都会保留 `/old-root`。
- 保留时脚本也会保留自身，方便之后重跑。
- `/boot.bak` 不询问，存在即删除；如果还想保留旧引导备份，先手动移走。

## 不删除 /old-root 会怎样

- 旧系统文件继续占用磁盘，其他行为不受影响。
- 清理脚本不会自动删除它，也不会在后台重试。
- 需要时可随时手动执行 `rm -rf /old-root`。
- 手动删除后建议再跑一次清理脚本，让 GC 和自删完成。

## 手动清理

```bash
# 确认已引导进 NixOS
grep '^ID=' /etc/os-release
ls -d /run/current-system

# 删除旧根与 EFI 引导备份
rm -rf /old-root
rm -rf /boot.bak

# 回收 Nix 旧代
nix-collect-garbage -d

# 确认 /old-root 已不存在后再删脚本
rm -f /root/nixos-infect-cleanup.sh
```

- 不要删除 `/nix`：那是 Nix store，删了系统无法启动。
- 不要删除 `/etc/nixos`：那是当前生效的配置。
- `nix-collect-garbage -d` 会删除所有旧 generation，之后无法回滚到它们。
- 手动删除前先确认没有还需要从 `/old-root` 取回的数据。

## 清理后验证

```bash
df -h /
test ! -e /old-root && test ! -e /boot.bak && echo "已清理"
nixos-rebuild switch
```

- `df -h /` 显示可用空间明显增加。
- `test ... && echo "已清理"` 打印 `已清理` 才表示干净；无输出说明仍有残留。
- `nixos-rebuild switch` 能正常完成，说明配置与 channel 未被破坏。
- 再重启一次，确认仍能进入 NixOS 并 SSH 登录。

## 相关文档

- [快速开始](./quickstart.md)
- [排障指南](./troubleshooting.md)
- [工作原理](./how-it-works.md)
