PREFIX ?= $(HOME)/.local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man
BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions
ZSHCOMPDIR ?= $(PREFIX)/share/zsh/site-functions
FISHCOMPDIR ?= $(PREFIX)/share/fish/vendor_completions.d
BASH ?= bash
VERSION ?= $(shell sed -n 's/^VERSION="\(.*\)"/\1/p' organize.sh)

.PHONY: all install uninstall test fuzz bench lint check deb

all:
	@echo "Targets: install uninstall test fuzz bench lint check deb"

install:
	install -Dm755 organize.sh "$(DESTDIR)$(BINDIR)/organize"
	install -Dm644 man/organize.1 "$(DESTDIR)$(MANDIR)/man1/organize.1"
	install -Dm644 completions/organize.bash "$(DESTDIR)$(BASHCOMPDIR)/organize"
	install -Dm644 completions/_organize "$(DESTDIR)$(ZSHCOMPDIR)/_organize"
	install -Dm644 completions/organize.fish "$(DESTDIR)$(FISHCOMPDIR)/organize.fish"
	if command -v python3 >/dev/null 2>&1; then install -Dm755 tui/organize-tui.py "$(DESTDIR)$(BINDIR)/organize-tui"; fi
	@echo "Installed $(DESTDIR)$(BINDIR)/organize"
	@echo "Installed $(DESTDIR)$(MANDIR)/man1/organize.1"
	@echo "Installed shell completions"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/organize"
	rm -f "$(DESTDIR)$(MANDIR)/man1/organize.1"
	rm -f "$(DESTDIR)$(BASHCOMPDIR)/organize"
	rm -f "$(DESTDIR)$(ZSHCOMPDIR)/_organize"
	rm -f "$(DESTDIR)$(FISHCOMPDIR)/organize.fish"
	rm -f "$(DESTDIR)$(BINDIR)/organize-tui"
	@echo "Uninstalled"

test:
	$(BASH) tests/test.sh

fuzz:
	$(BASH) tests/fuzz.sh

bench:
	$(BASH) tests/bench.sh $(COUNT)

lint:
	$(BASH) -n organize.sh
	$(BASH) -n tests/test.sh
	$(BASH) -n tests/fuzz.sh
	$(BASH) -n completions/organize.bash
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck --severity=warning organize.sh tests/test.sh tests/fuzz.sh completions/organize.bash; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

check: lint test fuzz

deb:
	VERSION=$(VERSION) packaging/build-deb.sh
