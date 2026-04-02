PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin

build:
	swiftc main.swift -o ffprofile -framework Cocoa -framework ApplicationServices

install: build
	install -d $(BINDIR)
	install -m 755 ffprofile $(BINDIR)/ffprofile

uninstall:
	rm -f $(BINDIR)/ffprofile

clean:
	rm -f ffprofile

.PHONY: build install uninstall clean
