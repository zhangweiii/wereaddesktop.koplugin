# Kindle「微信读书」直启 Booklet

这个启动器基于 [KOL Booklet](https://github.com/yparitcher/KUAL_Booklet) 的直启机制：

1. Kindle 首页显示一个独立的「微信读书」条目；
2. 点击后直接执行完整 KOReader 的 `/mnt/us/koreader/koreader.sh --kual --asap`；
3. `wereaddesktop.koplugin` 按现有启动设置显示微信书架；
4. 启动过程中不显示 KUAL 菜单。

KUAL 不会被替换或删除。安装包还会添加一个 KUAL 顶层「微信读书」按钮，供首页 Booklet 无法启动时排障和兜底。

## 前置条件

- Kindle 已越狱，并安装 MRPI；
- 已安装 KUAL（用于在设备端执行 MRPI）；
- 完整 KOReader 位于 `/mnt/us/koreader`；
- 安装完成后，插件的「启动时显示」保持开启，KOReader 的启动页使用默认文件管理器模式。

一键安装包会安装或升级微读插件，但不会捆绑或裁剪 KOReader，也不会修改 KOReader 设置、微信读书登录数据或 KUAL 本体。

## 安装

GitHub Release 只提供一个用户需要下载的文件：

- `WeRead_Kindle_Installer_v<版本>.zip`

使用步骤：

1. 把 ZIP 完整解压到电脑本地磁盘（不要解压到 Kindle），并通过 USB 连接 Kindle；
2. 只运行解压目录中的一个脚本：
   - macOS / Linux：`sh install.sh`
   - Windows：在 Git Bash 中运行 `sh install.sh`
3. 脚本会自动寻找 Kindle，并询问安装/卸载及固件范围；选择安装时，它会同时更新微读插件，并把正确的 MRPI 包复制到 `mrpackages/`；
4. 文件复制完成后脚本会自动安全弹出 Kindle；然后在 KUAL → Helper+ → Install MR Packages 中执行一次，框架重新启动并完成内容扫描后，首页会出现「微信读书」。

自动弹出支持 macOS、Windows Git Bash/WSL 和常见 Linux 桌面环境；若系统拒绝弹出，脚本会保留成功的安装结果并提示手动安全弹出。Windows 原生不包含 POSIX shell，因此需要 Git for Windows 附带的 Git Bash，或 WSL；不需要 Python、Node.js。安装器内部仍包含普通安装包、hotfix 安装包和卸载包，因为 MRPI 最终只能执行 `.bin`，但用户不需要手动选择或运行这些文件。

如果 Booklet 入口暂时不可用，可打开 KUAL，直接点击顶层的「微信读书」；该入口执行相同的完整 KOReader 启动命令。

## 构建

在仓库根目录只运行统一发布命令：

```sh
sh tools/release.sh
```

根脚本会自动下载并校验固定版本的 KOL 和 KindleTool，再生成通用、Kindle、Kobo 三个最终发布文件。此目录下的 `tools/build.sh` 只是根脚本使用的内部实现，不是发布入口。两种固件格式的安装 `.bin` 和卸载 `.bin` 只在临时目录生成并封入 Kindle payload，构建结束后自动清理。

## 卸载与恢复

再次运行同一个 `install.sh`，选择「只卸载 Kindle 首页入口」，然后按提示通过 MRPI 执行。它只会删除本启动器注册的 Booklet、首页触发文件和 KUAL 兜底入口，不会删除 KUAL、KOReader、微信读书插件、书籍或登录数据。

如果 Booklet 启动失败，先通过 KUAL 的「微信读书」入口确认 KOReader 本身可以启动，再查看 `/var/tmp/weread-launcher.log`。

## 兼容性边界

Booklet/appreg 属于 Kindle 非公开接口，最终兼容性取决于具体机型、固件、越狱和 hotfix 状态。安装包沿用 KOL v1.5 的普通包/hotfix 包划分；目前只在用户已测试的 Kindle 环境确认可用，不能据此宣称支持全部 Kindle 型号。
