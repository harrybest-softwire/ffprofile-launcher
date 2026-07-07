# ffprofile

> [!WARNING]
> **Disclaimer:** this project is entirely vibe coded. It has had no rigorous review, comes with no guarantees of correctness or safety, and may break at any time. Use at your own risk.

A macOS command-line tool for managing and launching Firefox profiles. Supports fuzzy profile matching, focusing existing windows, installing per-profile Spotlight apps with generated icons, and right-click Services for opening links in a specific profile.

## Usage

```
ffprofile list              List available profiles
ffprofile launch <profile>  Launch or focus a profile
ffprofile install           Install per-profile apps and Services
ffprofile uninstall         Remove installed apps and Services
ffprofile version           Print the version
```

`launch` accepts fuzzy input — exact, prefix, substring, and fuzzy character matches are all tried in order. Pipe a URL to open it in the launched profile:

```sh
echo "https://example.com" | ffprofile launch personal
```

If the profile is already running its window is focused; otherwise a new instance is started. Either way the URL opens in the correct profile.

## Install

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

`ffprofile install` creates a `.app` bundle in `~/Applications` for each Firefox profile, each with a generated icon. These show up in Spotlight and the Dock. It also installs a shared helper, `~/Applications/ffprofile.app`, which the per-profile apps and Services route through — macOS prompts once to grant Accessibility to "ffprofile", and that single grant covers window focusing for every profile.

After the first install, the apps and Services refresh themselves: when Firefox's profile list changes, the next `launch` regenerates the bundles and removes ones for deleted profiles.

### Right-click Services

`ffprofile install` also installs a macOS Service for each profile into `~/Library/Services`. When text is selected (e.g. a URL), right-clicking shows "Open in ProfileName - Firefox" entries under the Services submenu. The selected text is piped to `ffprofile launch` as a URL.

This works in Safari, Mail, and most native apps. Whether the URL or the visible link text is passed depends on the app — most pass the URL when right-clicking a hyperlink.

### Routing link clicks (default browser)

The helper app registers as an http/https handler, so it can be chosen as the default browser in System Settings → Desktop & Dock. Links clicked in other apps then open a profile picker menu at the mouse cursor — click a profile (or press 1–9) and the link opens there, instead of landing in whichever Firefox instance happened to start first. Pressing Escape or clicking away drops the link.

To skip the prompt for sites you've decided on, add rules to `~/Library/Application Support/ffprofile/routes` — one per line, profile name first, URL pattern last. Patterns are shell globs matched against the URL's host, or host+path when the pattern contains a `/`. The first matching rule wins, and links matching no rule fall back to the picker:

```
# ~/Library/Application Support/ffprofile/routes
work      *.atlassian.net
work      github.com/softwire/*
personal  *.youtube.com
```

Note that `*.atlassian.net` matches subdomains only — add a separate `atlassian.net` rule for the bare domain.

## Requirements

- macOS
- Firefox installed at `/Applications/Firefox.app`
- Accessibility permissions for window focusing — granted once to the `ffprofile` helper app for Spotlight/Service launches, and to your terminal app for CLI use
