# Builds priv/arduino_router_ex_tty with the toolchain elixir_make passes in.

PREFIX = $(MIX_APP_PATH)/priv

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11

all: $(PREFIX)/arduino_router_ex_tty

$(PREFIX)/arduino_router_ex_tty: c_src/arduino_router_ex_tty.c | $(PREFIX)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(PREFIX):
	mkdir -p $@

clean:
	$(RM) $(PREFIX)/arduino_router_ex_tty

.PHONY: all clean
