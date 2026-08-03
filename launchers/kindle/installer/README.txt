微读 Kindle 一键安装器
=======================

前置条件：Kindle 已越狱，并已安装完整 KOReader、KUAL 和 MRPI。

1. 把这个 ZIP 完整解压到电脑本地磁盘，不要解压到 Kindle，也不要只打开压缩包内的 install.sh。
2. 用 USB 连接 Kindle，等待 Kindle 磁盘出现。
3. 只运行一个脚本：
   - macOS / Linux：在解压目录运行 sh install.sh
   - Windows：用 Git Bash 打开解压目录，运行 sh install.sh
4. 根据提示选择安装/卸载和固件范围。
5. 文件复制完成后，脚本会自动安全弹出 Kindle；然后在 KUAL → Helper+ → Install MR Packages 中执行一次。

自动弹出支持 macOS、Windows Git Bash/WSL 和常见 Linux 桌面环境。若系统拒绝
弹出，安装结果仍然有效；脚本会明确提示改为手动安全弹出，不要直接拔线。

Windows 本身不能原生执行 POSIX shell；需要 Git for Windows 附带的 Git Bash，
或者 WSL。脚本不需要 Python、Node.js 或其它项目依赖。

安装器会替换 KOReader 的微读插件目录，但保留 KOReader settings 中的登录数据、
已下载书籍和其它插件。payload 目录是安装器内部文件，请勿单独选择或执行其中的 bin。
