# Builds priv/arduino_router_ex_tty with the toolchain elixir_make passes in,
# and copies the prebuilt io sketches to priv/sketches.

PREFIX = $(MIX_APP_PATH)/priv

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11

SKETCHES = $(wildcard sketches/io/prebuilt/*.zsk.bin)

all: $(PREFIX)/arduino_router_ex_tty $(SKETCHES:sketches/io/prebuilt/%=$(PREFIX)/sketches/%)

$(PREFIX)/sketches/%: sketches/io/prebuilt/%
	mkdir -p $(dir $@)
	cp $< $@

$(PREFIX)/arduino_router_ex_tty: c_src/arduino_router_ex_tty.c | $(PREFIX)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(PREFIX):
	mkdir -p $@

clean:
	$(RM) -r $(PREFIX)/arduino_router_ex_tty $(PREFIX)/sketches

.PHONY: all clean
