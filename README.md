# 微读 (WeRead Desktop)

把微信读书搬到 KOReader 桌面：启动即是你的微信书架，支持扫码登录、书城浏览、全书下载和双向阅读进度/时长云同步。适用于 Kindle 及其他运行 KOReader 的设备。

## 功能

- **微信读书书架桌面**：启动和退出书籍时直接显示微信书架（封面、已读标记），而不是 KOReader 文件管理器
- **扫码登录**：与微信读书官方 App 相同的二维码登录方式
- **书城**：浏览书城推荐、搜索书籍
- **全书下载**：把书架上的书打包成单个 EPUB 下载到本地阅读
- **双向进度同步**：
  - 上传：阅读中每 60 秒、打开/关闭书籍时自动上报进度和阅读时长
  - 下载：打开书时自动拉取云端进度，比本地新就跳转到最新位置（在手机微信读书上读的进度可以无缝接续）
- **状态栏**：时间、Wi-Fi 状态、设置和退出入口
- **定时熄屏**：设置标签页可调整无操作自动休眠时长（关 / 5 / 15 / 30 / 60 分钟，复用 KOReader 内置 autosuspend 插件，默认 15 分钟）
- **设备快捷设置**：设置标签页提供前光（亮度/色温）、夜间模式、Wi-Fi、屏幕旋转、屏保类型、时钟格式（12/24 小时制）开关，全部走 KOReader 官方公开接口；顶部显示电量和存储状态
- **检查更新**：设置标签页可检查微读自身的新版本（GitHub Releases），发现新版本可一键下载安装（发布流程见下文「发布」）

## 截图

<p align="center">
  <img src="screenshots/shelf.png" width="32%" alt="书架">
  <img src="screenshots/search.png" width="32%" alt="书城搜索">
  <img src="screenshots/settings.png" width="32%" alt="设置">
</p>
<p align="center">
  <img src="screenshots/download.png" width="32%" alt="下载">
  <img src="screenshots/login.png" width="32%" alt="登录">
</p>

## 安装

1. 安装 [KOReader](https://github.com/koreader/koreader)（已在 2026.07 版本测试；插件使用了 `UIManager._window_stack` 内部接口修正菜单层级，过旧版本可能不兼容）。
2. 把 `wereaddesktop.koplugin` 目录复制到 KOReader 的 `plugins/` 目录下。
3. 重启 KOReader，首次启动会弹出微信读书扫码登录。

启动时是否显示桌面取决于「启动时显示」设置：「历史记录」「收藏」「文件夹快捷方式」模式下不显示，其余模式（含默认的「文件管理器」）显示；退出书籍时始终回到桌面（可在「微读」菜单关闭）。

## 使用

- **书架**：点封面打开已下载的书；未下载的书会提示下载整本 EPUB；长按封面弹出下载选项（补齐缺失章节 / 重新下载整本）
- **书城**：底部「书城」标签浏览推荐和搜索，搜索到的书同样可以下载
- **下载补齐**：整本下载时部分章节失败，完成提示里可直接「补齐缺失章节」——只重下失败的章节并重新打包，已下载的章节来自本地缓存
- **设置**：底部「设置」标签或右上角齿轮打开 KOReader 设置菜单；「微读」菜单项在 KOReader 主菜单的「工具」分类下，可开关自动桌面、进度同步、登录/退出
- **进度同步**：默认开启，可在「微读」菜单中关闭

## 开发

项目结构：

```
wereaddesktop.koplugin/
├── main.lua              -- 插件入口：桌面生命周期、菜单、进度同步接线
├── desktop.lua           -- 书架桌面 widget（书架/书城/设置三个标签页）
├── wereadbridge.lua      -- UI 与微信读书客户端库之间的桥接层
├── progressuploader.lua  -- 阅读进度双向同步（阅读器上下文）
├── weread/               -- 微信读书协议/下载客户端库（衍生自 weread.koplugin，见 NOTICE）
└── spec/                 -- 无头测试（luajit 直接运行）
```

运行测试（需要一个 KOReader 源码 checkout 提供前端模块）：

```sh
cd wereaddesktop.koplugin
KOREADER_DIR=/path/to/koreader luajit spec/smoke_settings_merge.lua
luajit spec/test_progress_sync.lua
luajit spec/test_posupdate_wiring.lua
```

`spec/e2e_real_upload.lua`、`spec/e2e_cloud_pull.lua` 和 `spec/e2e_read_time.lua` 是针对真实账号的端到端脚本，会读写真实服务器数据，仅供手动调试使用，用法见文件头注释。

## 发布

版本号唯一来源是 `wereaddesktop.koplugin/wereaddesktop_version.lua`。发布新版本：

1. 更新 `wereaddesktop_version.lua` 中的版本号。
2. 运行 `sh tools/release.sh` 生成 `dist/wereaddesktop.koplugin-v<版本>.tar.gz`。
3. 在 GitHub 上打 `v<版本>` 标签并创建 Release，把该 tar.gz 作为附件上传（插件的「检查更新」只认 `.tar.gz` 附件，且压缩包根目录必须是 `wereaddesktop.koplugin/`）。
4. 发布仓库已配置在 `wereaddesktop.koplugin/updater.lua` 的 `GITHUB_REPO` 常量（当前为 `zhangweiii/wereaddesktop.koplugin`）；如需临时指向其它仓库（测试 fork），可通过 KOReader 设置 `wereaddesktop_update_repo` 覆盖。

## 许可证与致谢

本项目以 [GNU Affero General Public License v3](LICENSE) 发布。

`wereaddesktop.koplugin/weread/` 目录衍生自 [weread.koplugin](https://github.com/finlater/weread.koplugin) 项目（作者 finlater，AGPL-3.0），详见 [NOTICE](NOTICE)。在此向原作者致谢。

## 免责声明

本项目是非官方第三方工具，与微信读书、腾讯及 KOReader 官方无任何隶属关系。插件通过与官方阅读器相同的网关访问 weread.qq.com，仅供个人阅读使用。使用者应自行承担账号、数据和设备相关风险。
