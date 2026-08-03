# Kobo「微信读书」启动器

Kobo 版使用完整 KOReader，并提供两种互斥的启动方式：

1. **NickelMenu 模式**：从 Kobo 主菜单的 NickelMenu 中点击「微信读书」；配置简单，适合作为默认方案。
2. **KFMon 模式**：书库和首页显示一张「微信读书」PNG，点击后直接进入微读；体验更接近普通书籍入口。

> **未测试声明：Kobo 启动器尚未在真实 Kobo 设备上验证。** 当前配置依据 KOReader、NickelMenu 和 KFMon 上游实现编写；具体兼容性仍取决于机型、固件和启动器版本。

## 前置条件

- 完整 KOReader 位于 `/mnt/onboard/.adds/koreader`；
- 安装完成后，插件的「启动时显示」保持开启，KOReader 的启动页使用默认文件管理器模式；
- 根据所选模式，事先安装 [NickelMenu](https://github.com/pgaskin/NickelMenu) 或 [KFMon](https://github.com/NiLuJe/kfmon)。

一键安装包会安装或升级微读插件，但不捆绑、不升级也不卸载 KOReader、NickelMenu 或 KFMon。NickelMenu 上游目前明确说明尚不支持 Kobo 固件 5.x；使用这类固件时不要假定菜单模式可用。

## 安装

GitHub Release 只提供一个 Kobo 用户需要下载的文件：

- `WeRead_Kobo_Installer_v<版本>.zip`

使用步骤：

1. 把 ZIP 完整解压到电脑本地磁盘（不要解压到 Kobo），并通过 USB 连接 Kobo；
2. 只运行解压目录中的一个脚本：
   - macOS / Linux：`sh install.sh`
   - Windows：在 Git Bash 中运行 `sh install.sh`
3. 脚本会自动寻找 Kobo，并询问 NickelMenu、KFMon 或卸载入口；
4. 操作完成后脚本会自动安全弹出 Kobo；拔线后重启设备。

自动弹出支持 macOS、Windows Git Bash/WSL 和常见 Linux 桌面环境；若系统拒绝弹出，脚本会保留成功的安装结果并提示手动安全弹出。Windows 原生不包含 POSIX shell，因此需要 Git for Windows 附带的 Git Bash，或 WSL；不需要 Python、Node.js。

### NickelMenu 模式

脚本检查 `.adds/nm/` 确认 NickelMenu 已安装，然后写入微读菜单配置。重启后打开 NickelMenu，点击「微信读书」。

### KFMon 书籍封面模式

脚本检查 `.adds/kfmon/config/` 确认 KFMon 已安装，然后写入 watch 配置和 `微信读书.png`。重启并等待 Nickel 完成书库扫描后，从首页或书库点击封面。

新封面第一次被 Nickel 处理时，KFMon 上游提示首次动作可能发生在关闭封面而非打开封面时；再次点击通常才会按预期启动。

两种模式互斥：切换时脚本只删除另一个模式由微读创建的配置，避免重复入口，不会删除其它 NickelMenu/KFMon 配置。

## 卸载启动入口

再次运行同一个 `install.sh` 并选择「只卸载微读启动入口」。该操作保留微读插件、KOReader settings 中的登录数据、书籍和其它插件。

## 构建

在仓库根目录只运行统一发布命令：

```sh
sh tools/release.sh
```

它会在 `dist/` 一次生成通用、Kindle、Kobo 三个最终发布文件。此目录下的 `tools/build.sh` 只是根脚本使用的内部实现，不是发布入口。

## 兼容性边界

两种入口最终都调用 `/mnt/onboard/.adds/koreader/koreader.sh`，不会使用裁剪版 KOReader。启动器不改变微读的 KOReader 兼容范围；插件目前只在 README 所列 KOReader 版本验证过。若启动失败，可查看 `.adds/weread/launcher.log`，该文件只在缺少 KOReader 或插件时产生。
