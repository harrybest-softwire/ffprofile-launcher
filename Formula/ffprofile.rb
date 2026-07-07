class Ffprofile < Formula
  desc "Manage and launch Firefox profiles on macOS"
  homepage "https://github.com/harrybest-softwire/ffprofile-launcher"
  url "https://github.com/harrybest-softwire/ffprofile-launcher/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "04924fccae5b16dee6a80d71fe1a1e1059e4068f7341289975bb2811a4ec550f"
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
      themselves on first use. To route link clicks through the picker,
      choose ffprofile as the default browser in
      System Settings > Desktop & Dock.

      Before `brew uninstall`, run `ffprofile uninstall` to remove the
      installed apps — Homebrew doesn't track them.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ffprofile version")
  end
end
