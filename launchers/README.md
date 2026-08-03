# 微读设备启动器

`wereaddesktop.koplugin` 是通用的 KOReader 插件；这里仅存放不同设备系统进入完整 KOReader 的启动层。各平台路径和注册机制不同，因此启动器不能共用。

- `kindle/`：一键安装 ZIP 通过 KOL Booklet 在 Kindle 首页创建「微信读书」入口，并保留 KUAL 兜底入口；
- `kobo/`：一个一键安装 ZIP 内提供 NickelMenu 菜单启动和 KFMon 书籍封面启动两种可选模式。

启动器都不捆绑 KOReader，也不保存微信读书登录信息。先安装适合设备的完整 KOReader 和本项目插件，再安装一种启动器。
