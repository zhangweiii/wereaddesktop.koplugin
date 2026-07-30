--[[--
Regression checks for publisher footnotes embedded by WeRead as
<img class="qqreader-footnote" alt="...">. The source note.png is only a
solid color marker; generated EPUBs must expose a real, tappable footnote.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_publisher_footnotes.lua
--]]--

package.path = package.path .. ";./?.lua"

package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function() return {} end

local Content = require("weread.lib.content")

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local source = [[
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
<body>
<p>到底要哪能<img alt="哪能：吴语，怎么样。——编者注"
 class="qqreader-footnote" src="../Images/note.png"/>？</p>
<p>十二寸<img src='../Images/note.png' class='other qqreader-footnote'
 alt='寸：1英寸合0.025 4米。'/>的照片</p>
<p><img class="illustration" alt="普通插图" src="../Images/pic.png"/></p>
</body>
</html>
]]

local converted, count = Content.convert_publisher_footnotes(source)

check("both qqreader footnotes are converted", count == 2)
check("solid note images are removed",
    not converted:find("qqreader-footnote", 1, true))
check("normal images remain untouched",
    converted:find('class="illustration"', 1, true) ~= nil)
check("first marker is a standard EPUB noteref",
    converted:find('epub:type="noteref"', 1, true) ~= nil
    and converted:find('href="#wr-footnote-1"', 1, true) ~= nil
    and converted:find("<sup>[1]</sup>", 1, true) ~= nil)
check("footnote targets carry popup semantics",
    converted:find('id="wr-footnote-1"', 1, true) ~= nil
    and converted:find('epub:type="footnote"', 1, true) ~= nil
    and converted:find('role="doc-footnote"', 1, true) ~= nil)
check("the real annotation text is preserved",
    converted:find("哪能：吴语，怎么样。——编者注", 1, true) ~= nil
    and converted:find("寸：1英寸合0.025 4米。", 1, true) ~= nil)
check("footnote targets are appended before the body closes",
    converted:find('class="wr-footnotes"', 1, true)
        < converted:find("</body>", 1, true))

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
