# NetSurf offscreen render helper for the goodreadskosync plugin.
#
# The host-side pieces (CLI, PGM writer, JSON hitmap writer, libnsfb memory
# surface) have no dependencies beyond libnsfb. NetSurf core objects are linked
# in from a NetSurf checkout via NETSURF_OBJDIR (see README).
#
# Usage:
#   make NETSURF_OBJDIR=/path/to/netsurf/build CC=gcc
#
# Targets: all (default), clean, install

CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?=

NETSURF_OBJDIR ?=
NETSURF_SRC    ?=

PKG_CFLAGS := $(shell pkg-config --cflags libnsfb 2>/dev/null)
PKG_LIBS   := $(shell pkg-config --libs libnsfb 2>/dev/null)
ifeq ($(PKG_LIBS),)
PKG_LIBS := -lnsfb
endif

BIN := out/netsurf_render

SRCS := netsurf_render.c

.PHONY: all clean install

all: $(BIN)

$(BIN): $(SRCS)
	@mkdir -p out
	$(CC) $(CFLAGS) $(PKG_CFLAGS) \
		-I$(NETSURF_SRC) -I$(NETSURF_OBJDIR) \
		$(SRCS) -o $@ \
		-L$(NETSURF_OBJDIR) -lnetsurf_core \
		$(PKG_LIBS) $(LDFLAGS)

clean:
	rm -rf out

install: $(BIN)
	install -D $(BIN) $(DESTDIR)/usr/bin/netsurf_render
