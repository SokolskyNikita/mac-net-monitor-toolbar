cask "netmenu" do
  version "1.8.1"
  sha256 "9c30385f390ff43ec892643266c5aaa6972864cfd941243f9e9b115fc4e75bcc"

  url "https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/download/v#{version}/NetMenu-#{version}.zip"
  name "NetMenu"
  desc "Menu bar WAN latency and throughput monitor"
  homepage "https://github.com/SokolskyNikita/mac-net-monitor-toolbar"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "NetMenu.app"

  zap trash: [
    "~/Library/Application Support/NetMenu",
  ]

  caveats <<~EOS
    NetMenu may be ad-hoc signed until a Developer ID certificate is used.
    If macOS blocks the first launch: System Settings → Privacy & Security →
    Open Anyway, or:

      xattr -dr com.apple.quarantine /Applications/NetMenu.app

    First launch may prompt for Location and Local Network access.
  EOS
end
