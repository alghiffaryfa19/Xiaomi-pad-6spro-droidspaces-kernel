# Xiaomi Pad 6S Pro Droidspaces Kernel

适用于小米平板 6S Pro（`sheng`）Android 16 `OS3.0.304.0.WNXCNXM`，包含
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 所需内核支持与
[KernelSU](https://github.com/tiann/KernelSU)。

在 Linux x86_64 上执行：

```bash
./build.sh /path/to/aosp-workspace
```

脚本会同步固定版本的精简 AOSP 源码、构建 Thin LTO 内核，并将 AnyKernel3 ZIP
及其 SHA-256 校验文件写入 `releases/`。GitHub Actions 仅支持手动触发，产物只保留
在对应的 Actions artifact 中，不创建 GitHub Release。
