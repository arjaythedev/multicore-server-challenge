# Builds the NIFs (native/) into priv/; run by mix through elixir_make, which sets ERTS_INCLUDE_DIR and
# MIX_APP_PATH. CFLAGS comes from build.sh.
PRIV := $(MIX_APP_PATH)/priv
NIFS := $(PRIV)/conduit_bcrypt.so $(PRIV)/conduit_render.so
CFLAGS ?= -O3
NIF_CFLAGS = $(CFLAGS) -std=gnu11 -fPIC -shared -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter \
	-I"$(ERTS_INCLUDE_DIR)" -Inative

all: $(NIFS)

$(PRIV)/conduit_bcrypt.so: native/conduit_bcrypt_nif.c native/bcrypt-batch.c native/bcrypt-batch-impl.h \
		native/crypt-bcrypt.c native/crypt-port.h native/byteorder.h
	@mkdir -p $(PRIV)
	$(CC) $(NIF_CFLAGS) native/conduit_bcrypt_nif.c -o $@

$(PRIV)/conduit_render.so: native/conduit_render_nif.c
	@mkdir -p $(PRIV)
	$(CC) $(NIF_CFLAGS) native/conduit_render_nif.c -o $@

clean:
	rm -f $(NIFS)

.PHONY: all clean
