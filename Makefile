PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
ZSHDIR  = $(PREFIX)/share/zsh/site-functions
BASHDIR = $(PREFIX)/share/bash-completion/completions

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

build:
	printf 'let version = "%s"\n' "$(VERSION)" > version.swift
	swiftc main.swift version.swift -o ffprofile -framework Cocoa -framework ApplicationServices

install: build
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

.PHONY: build install install-completions uninstall clean
