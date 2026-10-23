PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SCRIPTS = bin/keyswitch bin/keyswitch-check-http

.PHONY: install uninstall test lint

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 $(SCRIPTS) "$(DESTDIR)$(BINDIR)/"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/keyswitch" "$(DESTDIR)$(BINDIR)/keyswitch-check-http"

test:
	tests/run.sh

lint:
	shellcheck -x $(SCRIPTS) tests/run.sh
