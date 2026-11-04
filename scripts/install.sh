#!/bin/zsh
# Builds a Release copy of MyTime and installs it to /Applications, then relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate -q
xcodebuild -project MyTime.xcodeproj -scheme MyTime -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build -quiet

pkill -x MyTime 2>/dev/null && sleep 1 || true
rm -rf /Applications/MyTime.app
cp -R build/Build/Products/Release/MyTime.app /Applications/
open /Applications/MyTime.app
echo "Installed /Applications/MyTime.app"

# The Claude Code / Cursor hook lives at a fixed path so tool settings don't depend on where this repo is.
hooks="$HOME/Library/Application Support/MyTime/Hooks"
mkdir -p "$hooks"
cp scripts/activity-hook.sh "$hooks/activity-hook.sh"
chmod +x "$hooks/activity-hook.sh"

# The /mytime skill tells Claude Code how to log a label for its work.
mkdir -p "$HOME/.claude/skills/mytime"
cp scripts/claude-skill/mytime/SKILL.md "$HOME/.claude/skills/mytime/SKILL.md"

# Keep a copy of the built app next to the data backups, so a new Mac can run it without Xcode.
icloud="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [[ -d "$icloud" ]]; then
  dest="$icloud/MyTime Backups/App"
  mkdir -p "$dest"
  ditto -c -k --norsrc --keepParent /Applications/MyTime.app "$dest/MyTime.app.zip"
  echo "Copied app to iCloud Drive › MyTime Backups › App"
fi
