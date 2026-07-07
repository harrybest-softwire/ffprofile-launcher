# ffprofile

> [!WARNING]
> **Disclaimer:** this project is entirely vibe coded. It has had no rigorous review, comes with no guarantees of correctness or safety, and may break at any time. Use at your own risk.

A macOS command-line tool for managing and launching Firefox profiles. Supports fuzzy profile matching, focusing existing windows, installing per-profile Spotlight apps with generated icons, and a default-browser profile picker for opening links in a specific profile.

## Usage

```
ffprofile list              List available profiles
ffprofile launch <profile>  Launch or focus a profile
ffprofile install           Install per-profile apps
ffprofile uninstall         Remove installed apps
ffprofile version           Print the version
```

`launch` accepts fuzzy input — exact, prefix, substring, and fuzzy character matches are all tried in order. Pipe a URL to open it in the launched profile:

```sh
echo "https://example.com" | ffprofile launch personal
```

If the profile is already running its window is focused; otherwise a new instance is started. Either way the URL opens in the correct profile.

## Install

### Homebrew

The repo doubles as a Homebrew tap:

```sh
brew tap harrybest-softwire/ffprofile-launcher https://github.com/harrybest-softwire/ffprofile-launcher
brew trust harrybest-softwire/ffprofile-launcher   # newer Homebrew versions only
brew install ffprofile
```

Shell completions are installed automatically. Run `ffprofile install` once to set up the Spotlight apps and link-picker helper; after upgrades they refresh themselves on first use. Before `brew uninstall`, run `ffprofile uninstall` to remove the installed apps — Homebrew doesn't track them.

### From source

```sh
make
sudo make install
```

Builds, then installs to `/usr/local/bin`. The install step deliberately doesn't build, so running it under `sudo` leaves no root-owned files in the working tree. Override the prefix to skip `sudo`, e.g. to install to `~/.local/bin`:

```sh
make
make install PREFIX=~/.local
```

If using a custom prefix, ensure the bin directory is on your `$PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### Shell completions

Installs completion scripts for zsh and bash:

```sh
make install-completions PREFIX=~/.local
```

For zsh, ensure the install directory is on your `fpath` (e.g. `~/.local/share/zsh/site-functions`):

```sh
fpath=(~/.local/share/zsh/site-functions $fpath)
autoload -Uz compinit && compinit
```

For bash, source the file in your `.bashrc`:

```sh
source ~/.local/share/bash-completion/completions/ffprofile
```

### Spotlight apps

`ffprofile install` creates a `.app` bundle in `~/Applications` for each Firefox profile, each with a generated icon. These show up in Spotlight and the Dock. It also installs a shared helper, `~/Applications/ffprofile.app`, which the per-profile apps and link clicks route through — macOS prompts once to grant Accessibility to "ffprofile", and that single grant covers window focusing for every profile.

After the first install, the apps and Services refresh themselves: when Firefox's profile list changes, the next `launch` regenerates the bundles and removes ones for deleted profiles.

### Routing link clicks (default browser)

`ffprofile install` offers to make ffprofile the default browser — macOS shows its standard confirmation dialog, and nothing changes unless you approve it there. (To do it later or by hand: the helper registers as an http/https handler, so it appears in System Settings → Desktop & Dock → Default web browser.)

Links clicked in other apps then open a profile picker menu at the mouse cursor — click a profile (or press 1–9) and the link opens there, instead of landing in whichever Firefox instance happened to start first. Pressing Escape or clicking away drops the link.

## Requirements

- macOS
- Firefox installed at `/Applications/Firefox.app`
- Accessibility permissions for window focusing — granted once to the `ffprofile` helper app for Spotlight/Service launches, and to your terminal app for CLI use
