PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
ZSHDIR  = $(PREFIX)/share/zsh/site-functions
BASHDIR = $(PREFIX)/share/bash-completion/completions

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

build: ffprofile

# Regenerate version.swift only when its content changes, so an unchanged
# tree doesn't relink.
version.swift: FORCE
	@printf 'let version = "%s"\n' "$(VERSION)" > version.swift.tmp; \
	if cmp -s version.swift.tmp version.swift; then rm -f version.swift.tmp; else mv version.swift.tmp version.swift; fi

ffprofile: main.swift version.swift
	swiftc main.swift version.swift -o ffprofile -framework Cocoa -framework ApplicationServices

# Deliberately doesn't build: building under sudo leaves root-owned files
# in the working tree. Run make first.
install:
	@test -x ffprofile || { echo "error: no built binary; run 'make' first" >&2; exit 1; }
	@if [ main.swift -nt ffprofile ]; then echo "error: ffprofile is older than main.swift; run 'make' first" >&2; exit 1; fi
	install -d $(BINDIR)
	install -m 755 ffprofile $(BINDIR)/ffprofile

install-completions:
	install -d $(ZSHDIR)
	install -m 644 completions/zsh/_ffprofile $(ZSHDIR)/_ffprofile
	install -d $(BASHDIR)
	install -m 644 completions/bash/ffprofile $(BASHDIR)/ffprofile

uninstall:
	rm -f $(BINDIR)/ffprofile
	rm -f $(ZSHDIR)/_ffprofile
	rm -f $(BASHDIR)/ffprofile

clean:
	rm -f ffprofile version.swift

FORCE:

.PHONY: build install install-completions uninstall clean FORCE
