微读 Kobo 一键安装器
====================

前置条件：Kobo 已安装完整 KOReader，以及 NickelMenu 或 KFMon。

1. 把这个 ZIP 完整解压到电脑本地磁盘，不要解压到 Kobo，也不要只打开压缩包内的 install.sh。
2. 用 USB 连接 Kobo，等待 KOBOeReader 磁盘出现。
3. 只运行一个脚本：
   - macOS / Linux：在解压目录运行 sh install.sh
   - Windows：用 Git Bash 打开解压目录，运行 sh install.sh
4. 根据提示选择 NickelMenu、KFMon 或卸载启动入口。
5. 操作完成后，脚本会自动安全弹出 Kobo；拔线后重启设备。

自动弹出支持 macOS、Windows Git Bash/WSL 和常见 Linux 桌面环境。若系统拒绝
弹出，安装结果仍然有效；脚本会明确提示改为手动安全弹出，不要直接拔线。

Windows 本身不能原生执行 POSIX shell；需要 Git for Windows 附带的 Git Bash，
或者 WSL。脚本不需要 Python、Node.js 或其它项目依赖。

安装器会安装或升级微读插件，并只保留所选的一种启动入口。切换模式时会删除
另一个模式由微读创建的配置，避免出现重复入口；不会删除其它 NickelMenu/KFMon
配置、KOReader settings 中的登录数据、已下载书籍或其它插件。

Kobo 一键安装器尚未在真实 Kobo 设备上验证。
