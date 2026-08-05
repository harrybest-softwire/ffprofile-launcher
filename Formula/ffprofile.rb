class Ffprofile < Formula
  desc "Manage and launch Firefox profiles on macOS"
  homepage "https://github.com/harrybest-softwire/ffprofile-launcher"
  url "https://github.com/harrybest-softwire/ffprofile-launcher/archive/refs/tags/v0.3.3.tar.gz"
  sha256 "4462a616ef27c387344518bcd529d0033870038099cdb12feeb3afee4e454e40"
  license "MIT"

  depends_on :macos

  def install
    # Release tarballs have no .git, so pass the version instead of letting
    # the Makefile fall back to `git describe`.
    system "make", "VERSION=v#{version}"
    bin.install "ffprofile"
    zsh_completion.install "completions/zsh/_ffprofile"
    bash_completion.install "completions/bash/ffprofile"
  end

  # No post_install: brew's post-install sandbox can't touch ~/Applications
  # (it even denies reading $HOME), so the binary refreshes the installed
  # apps itself on first use after an upgrade (syncIfUpgraded).
  def caveats
    <<~EOS
      Run `ffprofile install` once to set up the Spotlight apps and
      link-picker helper in ~/Applications; after upgrades they refresh
      themselves on first use. It also offers to make ffprofile the default
      browser (macOS asks for confirmation), which routes every link click
      through the profile picker.

      Before `brew uninstall`, run `ffprofile uninstall` to remove the
      installed apps — Homebrew doesn't track them.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ffprofile version")
  end
end
