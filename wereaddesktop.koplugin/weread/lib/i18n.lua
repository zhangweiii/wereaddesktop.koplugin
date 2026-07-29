local I18n = {}

local zh = {
    ["QR login"] = "扫码登录",
    ["Getting login QR code..."] = "正在获取登录二维码……",
    ["QR login cancelled."] = "扫码登录已取消。",
    ["QR login failed:\n%1"] = "扫码登录失败：\n%1",
    ["The QR code has expired. Please try again."] = "二维码已失效，请重新扫码。",
    ["The verification code has expired. Please try again."] = "验证码已失效，请重新扫码。",
    ["Incorrect verification code."] = "验证码不正确。",
    ["Unknown login response"] = "未知登录响应",
    ["Enter the four-digit verification code shown on your phone."] = "请输入手机上显示的四位验证码。",
    ["Verification code required"] = "需要验证码",
    ["Verify"] = "验证",
    ["The verification code must contain four digits."] = "验证码必须为四位数字。",
    ["Verifying login..."] = "正在验证登录……",
    ["Verification timed out. Please try again."] = "验证请求超时，请重试。",
    ["Completing WeRead login..."] = "正在完成微信读书登录……",
    ["Unknown account"] = "未知账号",
    ["WeRead login successful.\n\nAccount: %1\nCookie: %2\nOfficial API key: %3"] = "微信读书登录成功。\n\n账号：%1\nCookie：%2\n官方 API Key：%3",
    ["No official API key was returned. This account has not enabled WeRead Skill.\n\nOpen WeRead app → Me → Settings → WeRead Skill → Get API Key, then scan again."] = "未返回官方 API Key，说明当前账号尚未开通微信读书 Skill。\n\n请打开微信读书 App → 我 → 设置 → 微信读书 Skill → 获取 API Key，生成后重新扫码登录。此次登录未保存任何凭证。",
    ["Cancel"] = "取消",
    ["configured"] = "已配置",
    ["Download chapter and read"] = "下载本章并阅读",
    ["Download full book"] = "下载全书",
    ["Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"] = "已下载 %1 章。\n\n书籍已保存：\n%2\n\n现在阅读？",
    ["Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"] = "已下载 %1 章，%2 章失败。\n\n书籍已保存：\n%3\n\n现在阅读？",
    ["Close"] = "关闭",
    ["Download failed:\n%1"] = "下载失败：\n%1",
    ["No chapters were downloaded."] = "没有成功下载任何章节。",
    ["Read now"] = "立即阅读",
    ["Downloading: %1"] = "正在下载：%1",
    ["Downloading chapter %1/%2: %3"] = "正在下载章节 %1/%2：%3",
    ["Downloading underlines · chapter %1/%2"] = "正在下载划线 · 章节 %1/%2",
    ["Downloading thoughts %1/%2 · chapter %3/%4"] = "正在下载想法 %1/%2 · 章节 %3/%4",
    ["Retrying thoughts %1/%2 · attempt %3"] = "正在重试想法 %1/%2 · 第 %3 次",
    ["Processing underlines and thoughts · chapter %1/%2"] = "正在处理划线和想法 · 章节 %1/%2",
    ["Downloading images · chapter %1/%2"] = "正在下载图片 · 章节 %1/%2",
    ["Processing chapter %1/%2"] = "正在处理章节 %1/%2",
    ["Building EPUB..."] = "正在生成 EPUB……",
    ["%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."] = "%1 批想法重试后仍失败；EPUB 已包含其余成功下载的想法。",
    ["Download cancelled"] = "下载已取消",
    ["Cancel download"] = "取消下载",
}

function I18n.language()
    local lang
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language")
    end
    return lang or "en"
end

function I18n.is_zh()
    return tostring(I18n.language()):lower():match("^zh") ~= nil
end

function I18n.tr(text)
    if I18n.is_zh() then
        return zh[text] or text
    end
    return text
end

return I18n
