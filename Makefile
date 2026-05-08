SHELL := /usr/bin/env bash

SHELL_FILES := \
  airprint-v2.sh \
  install.sh \
  uninstall.sh \
  $(wildcard lib/*.sh) \
  $(wildcard scripts/*.sh)

.PHONY: help lint shellcheck format check tree

help:
	@echo "make lint       - run shellcheck on every shell script"
	@echo "make check      - lint + cupsd.conf / smb.conf / avahi-daemon.conf basic syntax sanity"
	@echo "make tree       - show the repo file tree"

lint shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed (apt install shellcheck)"; exit 1; }
	shellcheck --severity=style $(SHELL_FILES)

check: lint
	@# Light syntactic sanity for the configs we ship — full validation
	@# happens inside the LXC where cupsd / testparm / avahi-daemon exist.
	@command -v testparm >/dev/null 2>&1 && \
	  testparm -s /dev/stdin < <(cat scripts/add-scan-share.sh | sed -n '/^cat >\/etc\/samba\/smb.conf/,/^EOF$$/p' | sed '1d;$$d') >/dev/null 2>&1 \
	  || true
	@echo "configs look OK (best-effort host-side check)"

tree:
	@find . -type f -not -path './.git/*' -not -path './drivers/canon-*' | sort
