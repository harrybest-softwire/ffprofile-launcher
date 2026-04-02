# ffprofile

A macOS command-line tool for managing and launching Firefox profiles. Supports fuzzy profile matching, focusing existing windows, and installing per-profile Spotlight apps with generated icons.

## Usage

```
ffprofile list              List available profiles
ffprofile launch <profile>  Launch or focus a profile
ffprofile install           Install per-profile apps to ~/Applications
ffprofile uninstall         Remove installed apps
```

`launch` accepts fuzzy input — exact, prefix, substring, and fuzzy character matches are all tried in order. Pipe a URL to open it in the launched profile:

```sh
echo "https://example.com" | ffprofile launch personal
```

If the profile is already running its window is focused; otherwise a new instance is started. Either way the URL opens in the correct profile.

## Install

```sh
make install
```

Builds and installs to `/usr/local/bin`. Override the prefix if needed, e.g. to install to `~/.local/bin`:

```sh
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

`ffprofile install` creates a `.app` bundle in `~/Applications` for each Firefox profile, each with a generated icon. These show up in Spotlight and the Dock and invoke `ffprofile launch <name>` when opened.

## Requirements

- macOS
- Firefox installed at `/Applications/Firefox.app`
- Accessibility permissions (for window focusing via AX API)
