# goodreadskosync - Goodreads Sync for KOReader
#
# Targets:
#   make check      - luacheck static analysis
#   make test       - unit tests (Lua 5.1 / LuaJIT)
#   make package    - build dist/goodreadskosync-<version>.zip
#   make checksum   - package + SHA-256
#   make clean

LUA ?= lua
LUACHECK ?= luacheck

PLUGIN := goodreadskosync.koplugin
DIST := dist
VERSION := $(shell sed -n 's/.*VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(PLUGIN)/goodreadskosync/constants.lua | head -n 1)
ZIP := $(DIST)/goodreadskosync-$(VERSION).zip

.PHONY: all check test package checksum clean

all: check test

check:
	$(LUACHECK) $(PLUGIN) tests

test:
	$(LUA) tests/run.lua

package:
	@mkdir -p $(DIST)
	@rm -f $(ZIP)
	zip -r $(ZIP) $(PLUGIN) -x '*.git*' >/dev/null
	@echo "built $(ZIP)"

checksum: package
	@cd $(DIST) && sha256sum $(notdir $(ZIP)) > $(notdir $(ZIP)).sha256
	@cat $(ZIP).sha256

clean:
	rm -rf $(DIST) tests/.tmp
