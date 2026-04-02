# ffprofile

A macOS command-line tool for managing and launching Firefox profiles. Supports fuzzy profile matching, focusing existing windows, and installing per-profile Spotlight apps with generated icons.

## Usage

```
ffprofile list              List available profiles
ffprofile launch <profile>  Launch or focus a profile
ffprofile install           Install per-profile apps to ~/Applications
ffprofile uninstall         Remove installed apps
```

`launch` accepts fuzzy input — exact, prefix, substring, and fuzzy character matches are all tried in order.

## Install

Compile with:

```sh
swiftc main.swift -o ffprofile -framework Cocoa -framework ApplicationServices
```

Move the binary somewhere on your `$PATH`, e.g. `/usr/local/bin/ffprofile`.

### Spotlight apps

`ffprofile install` creates a `.app` bundle in `~/Applications` for each Firefox profile, each with a generated icon. These show up in Spotlight and the Dock and invoke `ffprofile launch <name>` when opened.

## Requirements

- macOS
- Firefox installed at `/Applications/Firefox.app`
- Accessibility permissions (for window focusing via AX API)
