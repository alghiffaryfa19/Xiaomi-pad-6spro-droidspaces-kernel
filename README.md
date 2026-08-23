# Xiaomi Pad 6S Pro Droidspaces Kernel

为小米平板 6S Pro（`sheng`）、Android 16 `OS3.0.304.0.WNXCNXM` 构建带
Droidspaces 和 ReSukiSU 的 GKI 内核。

## 快速开始

在原生 Linux x86_64 文件系统上准备至少 8 GiB 内存和 13 GiB 可用空间：

```bash
./build.sh sync /path/to/aosp   # 首次同步锁定的 AOSP 源码
./build.sh deps                 # 首次获取锁定的 ReSukiSU 与 AnyKernel3
./build.sh release /path/to/aosp
```

`release` 不会执行 `repo sync`。它校验输入、复用 `.cache/` 中的依赖、准备
源码、执行正式 GKI/KMI 构建，并在 `releases/` 中生成 AnyKernel3 ZIP 和
`SHA256SUMS` 文件。需要排查时可单独执行 `check`、`verify`、`prepare`、`build`
或 `package`；运行 `./build.sh` 可查看完整说明。

## GitHub Actions

`.github/workflows/build.yml` 在标准 GitHub-hosted Linux runner 上从零同步并
构建，不使用源码缓存或持久化工作区。manifest 只保留发布流程实际读取的六个
项目，且每个项目锁定到单一提交并使用浅克隆；发布构建只生成 AnyKernel 所需的
`Image`，不构建模块、测试或 GKI boot 镜像。`repo` 的 `clone-depth` 用于限制
检出的历史深度，见 [repo manifest format](https://gerrit.googlesource.com/git-repo/+/HEAD/docs/manifest-format.md#element-project)。

## 目录约定

| 路径 | 用途 |
| --- | --- |
| `build.sh` | 唯一构建入口。 |
| `build/` | 所有受版本控制的构建输入：版本锁、manifest、补丁、配置片段和 AnyKernel 脚本。 |
| `.cache/` | 本地可重建的 ReSukiSU 与 AnyKernel3 checkout，不提交。 |
| `releases/` | 本地发布产物，不提交。 |
| `backups/` | 用户设备备份，不提交也不由脚本删除。 |

GKI 配置遵循 [Droidspaces 内核配置指南](https://github.com/ravindu644/Droidspaces-OSS/blob/b9def52e86f70c4c2f63778d71502f0e5fa70885/Documentation/zh-CN/Kernel-Configuration.md)。
