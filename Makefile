PREFIX ?= $(HOME)/.local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man
BASH ?= bash

.PHONY: all install uninstall test fuzz lint check

all:
	@echo "Targets: install uninstall test fuzz lint check"

install:
	install -Dm755 organize.sh "$(DESTDIR)$(BINDIR)/organize"
	install -Dm644 man/organize.1 "$(DESTDIR)$(MANDIR)/man1/organize.1"
	@echo "Installed $(DESTDIR)$(BINDIR)/organize"
	@echo "Installed $(DESTDIR)$(MANDIR)/man1/organize.1"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/organize"
	rm -f "$(DESTDIR)$(MANDIR)/man1/organize.1"
	@echo "Uninstalled"

test:
	$(BASH) tests/test.sh

fuzz:
	$(BASH) tests/fuzz.sh

lint:
	$(BASH) -n organize.sh
	$(BASH) -n tests/test.sh
	$(BASH) -n tests/fuzz.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck --severity=warning organize.sh tests/test.sh tests/fuzz.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

check: lint test fuzz
