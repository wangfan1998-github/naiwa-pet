#!/bin/bash
# 卸载：撤掉 Claude Code 接入、关掉奶蛙，删掉 App、命令行链接、登录自启和偏好设置
set -uo pipefail

DEST=~/Applications/Naiwa.app
BIN=~/.local/bin/naiwa
AGENT=~/Library/LaunchAgents/com.nwverse.naiwa.plist

if [ -x "$DEST/Contents/MacOS/naiwa" ]; then
    "$DEST/Contents/MacOS/naiwa" hooks uninstall
    "$DEST/Contents/MacOS/naiwa" quit 2>/dev/null
fi
launchctl bootout "gui/$(id -u)/com.nwverse.naiwa" 2>/dev/null
rm -f "$AGENT"
# 只删指向 Naiwa.app 的那个链接，不碰别人放在这里的同名文件
if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$DEST/Contents/MacOS/naiwa" ]; then
    rm -f "$BIN"
fi
rm -rf "$DEST"
defaults delete com.nwverse.naiwa 2>/dev/null
echo "已卸载奶蛙"
