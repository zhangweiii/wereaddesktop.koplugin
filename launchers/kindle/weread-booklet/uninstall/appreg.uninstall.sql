BEGIN TRANSACTION;
DELETE FROM "handlerIds" WHERE handlerId='com.github.zhangweiii.wereadlauncher';
DELETE FROM "properties" WHERE handlerId='com.github.zhangweiii.wereadlauncher';
DELETE FROM "associations" WHERE handlerId='com.github.zhangweiii.wereadlauncher';

DELETE FROM "mimetypes" WHERE ext='weread';
DELETE FROM "extenstions" WHERE ext='weread';
DELETE FROM "properties" WHERE handlerId='archive.displaytags.mimetypes' AND name='image/x.weread';
DELETE FROM "associations" WHERE contentId='GL:*.weread';
COMMIT;
