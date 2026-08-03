# 代码库最终审查报告

审查日期：2026-08-03

## 高风险

### 1. 账号切换后可能跨账号上传旧阅读数据

相关位置：

- [`wereaddesktop.koplugin/wereadbridge.lua:150`](wereaddesktop.koplugin/wereadbridge.lua#L150)
- [`wereaddesktop.koplugin/main.lua:1165`](wereaddesktop.koplugin/main.lua#L1165)

`Bridge:logout` 会清理认证、书架缓存和完成状态队列，但保留书籍记录中的待同步进度及阅读时长。重新登录其他账号后，同步流程只检查当前是否已登录，没有校验待同步数据所属的 `user_vid`。

位置上传主要影响两个账号共有且新账号可访问的书籍；阅读时长队列没有账号归属检查，跨账号污染路径更直接。

建议在书籍状态和待同步队列中记录账号标识；同步前校验当前账号，账号不一致时隔离队列，同时保留本地 EPUB。

### 2. HTTP 成功响应中的业务错误可能覆盖有效缓存

相关位置：

- [`wereaddesktop.koplugin/weread/lib/client.lua:211`](wereaddesktop.koplugin/weread/lib/client.lua#L211)
- [`wereaddesktop.koplugin/weread/lib/client.lua:478`](wereaddesktop.koplugin/weread/lib/client.lua#L478)
- [`wereaddesktop.koplugin/wereadbridge.lua:328`](wereaddesktop.koplugin/wereadbridge.lua#L328)

`decode_http_json` 对非零 `errcode` 只记录日志，不会抛错。书架网关若返回 HTTP 200 业务错误且缺少 `books`，`fetchShelf` 会将其解释为空书架并持久化；该网关是否真实返回这种结构尚未通过线上样本确认，但代码缺少必要防护。

进度接口对非 `-2012` 业务错误会生成空进度映射，使保留旧进度的失败分支不生效，这条路径的响应模式在同类 web 接口中已有代码级佐证。

建议统一校验业务成功状态及必要字段；未知错误或结构异常时返回失败并保留旧缓存。

## 中风险

### 3. 二维码登录失败或取消后可能残留认证方法替换

相关位置：

- [`wereaddesktop.koplugin/wereadbridge.lua:114`](wereaddesktop.koplugin/wereadbridge.lua#L114)
- [`wereaddesktop.koplugin/weread/lib/qr_login.lua:323`](wereaddesktop.koplugin/weread/lib/qr_login.lua#L323)

`Bridge:startLogin` 临时替换实例上的 `settings.update_auth`。初始请求失败、离线返回和普通取消路径都没有统一恢复该方法；之后 `renew_cookie()` 等认证更新可能触发陈旧闭包，产生错误的登录成功回调。

建议由二维码登录对象提供显式且只执行一次的成功、失败、取消回调，并在统一 finalizer 中恢复临时状态。

### 4. 下载收尾阶段的异常可能被静默吞掉

相关位置：

- [`wereaddesktop.koplugin/weread/lib/downloader.lua:139`](wereaddesktop.koplugin/weread/lib/downloader.lua#L139)
- [`wereaddesktop.koplugin/weread/lib/downloader.lua:518`](wereaddesktop.koplugin/weread/lib/downloader.lua#L518)

`_scheduleGuarded` 仅在 `dl.standby_guard` 仍存在时处理异常。正常收尾先释放 guard，之后的 `save_book`、`flush`、`refresh_shelf`、打开文件或完成 UI 若抛错，会绕过失败回调和用户提示。

建议将错误收尾与待机 guard 解耦；guard 只做条件释放，所有异常都进入统一完成通知。

### 5. 整本下载保留全部正文和图片，峰值内存缺少约束

相关位置：

- [`wereaddesktop.koplugin/weread/lib/downloader.lua:196`](wereaddesktop.koplugin/weread/lib/downloader.lua#L196)
- [`wereaddesktop.koplugin/weread/lib/downloader.lua:277`](wereaddesktop.koplugin/weread/lib/downloader.lua#L277)
- [`wereaddesktop.koplugin/weread/lib/content.lua:871`](wereaddesktop.koplugin/weread/lib/content.lua#L871)

下载状态持续保留全部 `dl.bodies` 和 `dl.assets`，构建 EPUB 时还会创建 entries 等结构。parts 虽已写入磁盘，内存副本没有随章节完成释放；配置中的 `cache.max_size_mb` 也未用于限制该流程。

普通文字书风险有限，但大型图文书可能在低内存 Kindle 上造成明显内存压力甚至 OOM。

建议构建时从 parts 流式读取，释放已落盘的章节内存，并限制单资源及累计下载大小。

### 6. 章节 parts 缓存写入失败可能留下截断文件

相关位置：

- [`wereaddesktop.koplugin/weread/lib/content.lua:223`](wereaddesktop.koplugin/weread/lib/content.lua#L223)
- [`wereaddesktop.koplugin/weread/lib/content.lua:267`](wereaddesktop.koplugin/weread/lib/content.lua#L267)

parts 缓存的 `write_file` 直接写目标文件，不检查 `file:write` 和 `file:close` 的返回结果，也不使用临时文件原子替换。`list_missing_chapters` 只检查文件是否存在，空文件或截断文件会被视为完整。

建议写入同目录临时文件，验证写入和关闭结果后原子重命名；读取时增加最基本的完整性校验。

### 7. 书架刷新锁释放过早，旧回调可能覆盖新状态

相关位置：

- [`wereaddesktop.koplugin/main.lua:2974`](wereaddesktop.koplugin/main.lua#L2974)
- [`wereaddesktop.koplugin/main.lua:2996`](wereaddesktop.koplugin/main.lua#L2996)

`weread_refreshing` 在 fetch 回调入口即被清除，但封面下载、`saveShelf` 和界面刷新尚未结束。此时后续刷新可以进入，前一次刷新较晚完成的封面或保存回调可能覆盖较新的结果；登出或切换账号也不会使旧回调失效。

建议将锁保持到整个流程结束，并为每轮刷新绑定 generation 和账号标识，丢弃过期回调。

### 8. 旋转操作会关闭桌面且不会恢复

相关位置：

- [`wereaddesktop.koplugin/main.lua:2127`](wereaddesktop.koplugin/main.lua#L2127)
- [`wereaddesktop.koplugin/desktop.lua:651`](wereaddesktop.koplugin/desktop.lua#L651)

`cycleRotation` 在广播旋转事件前关闭并清空 `desktop_widget`，之后没有重建逻辑，用户会返回文件管理器。注释声称桌面没有尺寸变化处理器，但 `BookshelfWidget:onSetDimensions` 实际存在。

如果产品预期旋转后继续停留在微读桌面，应保留 widget 让其重排，或在旋转完成后重新调用 `showDesktop()`。

### 9. 桌面刷新会全量读取全部书籍状态

相关位置：

- [`wereaddesktop.koplugin/main.lua:3122`](wereaddesktop.koplugin/main.lua#L3122)
- [`wereaddesktop.koplugin/wereadbridge.lua:252`](wereaddesktop.koplugin/wereadbridge.lua#L252)
- [`wereaddesktop.koplugin/weread/lib/settings.lua:166`](wereaddesktop.koplugin/weread/lib/settings.lua#L166)
- [`wereaddesktop.koplugin/weread/lib/book_store.lua:125`](wereaddesktop.koplugin/weread/lib/book_store.lua#L125)

`collectData` 每次都会调用无缓存的 `getPendingUploadSummary`，其内部 `settings:get("books")` 会为每本书读取 `metadata.json` 和 `reading_state.json`。书架较大时，一次界面刷新会产生大量小文件读取；实际卡顿程度仍需真机测量。

建议缓存汇总结果，并在书籍待同步状态发生变化时精确失效。

### 10. fill-missing 在 EPUB 缺失时可能误报“已完整”

相关位置：

- [`wereaddesktop.koplugin/weread/lib/downloader.lua:159`](wereaddesktop.koplugin/weread/lib/downloader.lua#L159)

`fill_missing` 在 `#missing == 0` 时直接报告成功并返回 `book.cached_file`，没有验证该字段非空且文件存在。所有 parts 已落盘但 EPUB 构建失败、进程中断或文件被删除时，用户会收到错误的完整提示。

建议在该分支验证 EPUB 文件；文件缺失时直接使用现有 parts 重新打包。

### 11. 封面响应没有大小限制

相关位置：

- [`wereaddesktop.koplugin/wereadbridge.lua:545`](wereaddesktop.koplugin/wereadbridge.lua#L545)
- [`wereaddesktop.koplugin/weread/lib/client.lua:230`](wereaddesktop.koplugin/weread/lib/client.lua#L230)

`ensureCover` 通过 `get_binary` 将完整响应收集并拼接成字符串，没有 Content-Length 或流式字节上限。异常大的云端响应会扩大内存占用。

建议使用有上限的 sink，并同时校验响应头和实际接收字节数。

## 低风险与健壮性

### 12. 长时间阅读时长补报与桌面生命周期耦合

相关位置：

- [`wereaddesktop.koplugin/desktop.lua:1622`](wereaddesktop.koplugin/desktop.lua#L1622)
- [`wereaddesktop.koplugin/main.lua:3386`](wereaddesktop.koplugin/main.lua#L3386)

桌面实际关闭时，`on_close` 会取消用户手动启动的离线阅读时长补报。空白区域 tap-to-close 是明确设计；补报期间的模态对话框通常会阻止触摸直接落到桌面，因此不能断言普通空白误触必然中断任务，但其他关闭路径仍会终止长时间补报。

建议明确产品行为：允许任务脱离桌面继续运行，或在关闭前提示用户会暂停补报。

### 13. 设置子页重建缺少确定性资源释放

相关位置：

- [`wereaddesktop.koplugin/desktop.lua:1322`](wereaddesktop.koplugin/desktop.lua#L1322)
- [`wereaddesktop.koplugin/desktop.lua:1627`](wereaddesktop.koplugin/desktop.lua#L1627)

`openSettingsPage` 和设置子页返回分支直接调用 `buildUI()` 覆盖 `self[1]`，没有像其他重建路径一样先调用 `self[1]:free()`。当前设置页几乎不含图片，实际资源量较小，不能据此断言存在大量或持续内存泄漏；但显式释放不一致会延迟部分 widget/C 资源回收，并为未来新增图片留下风险。

建议在两条路径中统一先释放旧根 widget，再重建 UI。

### 14. 重复按秒播种全局 PRNG 可能重置随机序列

相关位置：

- [`wereaddesktop.koplugin/main.lua:77`](wereaddesktop.koplugin/main.lua#L77)
- [`wereaddesktop.koplugin/weread/lib/protocol.lua:208`](wereaddesktop.koplugin/weread/lib/protocol.lua#L208)
- [`wereaddesktop.koplugin/weread/lib/protocol.lua:253`](wereaddesktop.koplugin/weread/lib/protocol.lua#L253)

每个插件实例初始化都执行 `math.randomseed(os.time())`。同秒重新初始化可能把进程级全局 PRNG 重置到相同序列，使协议的 `r`、`ts`、`rn` 字段更容易重复；是否实际碰撞仍取决于重置后的调用顺序。

建议每个进程只播种一次，或使用更高精度且不会被实例重复重置的随机来源。

### 15. `Updater.repo()` 直接依赖全局设置对象

相关位置：

- [`wereaddesktop.koplugin/updater.lua:74`](wereaddesktop.koplugin/updater.lua#L74)

`Updater.repo()` 直接访问 `G_reader_settings`，不像同文件的 `get_update_channel()` 使用 `rawget` 和受保护调用。KOReader 正常上下文通常存在该全局，但模块独立调用或测试环境不完整时会抛错。

建议复用 `get_update_channel()` 的安全读取方式，并在缺少全局时回退默认仓库。

### 16. 旧缓存目录迁移失败会被静默忽略

相关位置：

- [`wereaddesktop.koplugin/wereadbridge.lua:79`](wereaddesktop.koplugin/wereadbridge.lua#L79)

`Bridge:new` 使用 `pcall(os.rename, ...)`，但不检查 `os.rename` 返回的 `nil, err`。目标目录已存在且非空时，迁移可能失败并永久留下旧 `kodesktop` 目录。

建议在迁移前检查源、目标状态，处理合并或冲突，并记录失败原因。

### 17. 封面逐本串行下载导致首刷耗时线性增长

相关位置：

- [`wereaddesktop.koplugin/main.lua:2955`](wereaddesktop.koplugin/main.lua#L2955)
- [`wereaddesktop.koplugin/weread/lib/client.lua:251`](wereaddesktop.koplugin/weread/lib/client.lua#L251)

`downloadCovers` 每次只处理一本，单次阻塞完成后才调度下一本，因此未缓存封面越多，首刷总耗时越长。默认 15 秒是 block timeout，total timeout 为 `-1`，不是单请求硬性总时限。

建议优先采用延迟加载、限制首刷数量、总任务截止时间和可取消机制；在没有验证 KOReader 执行模型及资源成本前，不直接假定并行下载是安全方案。
