class Ffprofile < Formula
  desc "Manage and launch Firefox profiles on macOS"
  homepage "https://github.com/harrybest-softwire/ffprofile-launcher"
  url "https://github.com/harrybest-softwire/ffprofile-launcher/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "2a7fb889b2353b348be5f8de2e942510ab9d81347bf3ab3af61ed85f1fc99aa4"
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

  def caveats
    <<~EOS
      Run `ffprofile install` to set up the Spotlight apps, right-click
      Services, and default-browser link routing.

      Before `brew uninstall`, run `ffprofile uninstall` to remove those
      apps and Services — Homebrew doesn't track them.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ffprofile version")
  end
end
