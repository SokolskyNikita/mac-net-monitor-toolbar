# Setup

For downloads and Homebrew installation, see [Install NetMenu](../README.md#install). Requires macOS 14 (Sonoma) or later on Apple silicon or Intel.

## First launch

Releases are currently signed ad hoc, not notarized by Apple, so macOS blocks NetMenu the first time you open it. This applies to Homebrew and manual installations alike, and again after every update. To allow it, try to open the app once, then click **Open Anyway** in **System Settings → Privacy & Security**. Or run:

```bash
xattr -dr com.apple.quarantine /Applications/NetMenu.app
```

macOS may also ask for two optional permissions:

| Permission | Used only for | If denied |
| --- | --- | --- |
| Location | Reading the Wi‑Fi network name and access point (SSID/BSSID) | The log may use a generic network label and omit the access point |
| Local Network (macOS 15+) | Checking your router’s health and latency | Local router health and latency may be unavailable |

## Update or uninstall

```bash
brew update && brew upgrade --cask netmenu      # update
brew uninstall --cask netmenu                   # uninstall
rm -rf ~/Library/Application\ Support/NetMenu   # optional: delete stats history
rm -rf ~/Library/Logs/NetMenu                   # optional: delete diagnostic logs
```

After an update, two more steps are needed:

1. Allow the new version to open, as in [First launch](#first-launch). Each update is a new download, so macOS blocks it again.
2. Quit NetMenu from its menu and open it again from Applications. Until then the menu bar keeps running the previous version.

macOS may also ask for the Location and Local Network permissions again.

For a manual installation, replace `/Applications/NetMenu.app` with the app from the [latest release](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest). To uninstall a manual installation, quit NetMenu and move the app to the Trash. Removing the app keeps your local history and logs; the optional cleanup commands above delete them.
