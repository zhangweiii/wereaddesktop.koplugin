BEGIN TRANSACTION;
INSERT OR IGNORE INTO "handlerIds" VALUES('com.github.zhangweiii.wereadlauncher');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','lipcId','com.github.zhangweiii.wereadlauncher');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','jar','/opt/amazon/ebook/booklet/WeReadBooklet.jar');

INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','maxUnloadTime','45');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','maxGoTime','60');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','maxPauseTime','60');

INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','default-chrome-style','NH');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','unloadPolicy','unloadOnPause');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','extend-start','Y');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','searchbar-mode','transient');
INSERT OR IGNORE INTO "properties" VALUES('com.github.zhangweiii.wereadlauncher','supportedOrientation','U');

INSERT OR IGNORE INTO "mimetypes" VALUES('weread','MT:image/x.weread');
INSERT OR IGNORE INTO "extenstions" VALUES('weread','MT:image/x.weread');
INSERT OR IGNORE INTO "properties" VALUES('archive.displaytags.mimetypes','image/x.weread','微信读书');
INSERT OR IGNORE INTO "associations" VALUES('com.lab126.generic.extractor','extractor','GL:*.weread','true');
INSERT OR IGNORE INTO "associations" VALUES('com.github.zhangweiii.wereadlauncher','application','MT:image/x.weread','true');
COMMIT;
