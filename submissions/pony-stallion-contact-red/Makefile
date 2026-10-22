PONYC ?= ponyc
FETCH ?= corral fetch
CC ?= cc
AR ?= ar
CFLAGS ?= -O3 -std=c11
LIBPQ_LIBDIR ?= /usr/lib/x86_64-linux-gnu

.PHONY: build build-diagnostic build-password-test test test-integration \
	test-password-native test-password-async test-password-integration clean
CONDUIT_VARIANT ?= ordinary
ifeq ($(CONDUIT_VARIANT),diagnostic)
CONDUIT_BINARY := conduit-diagnostic
CONDUIT_DEFINE := -Dconduit_diagnostic
else ifeq ($(CONDUIT_VARIANT),ordinary)
CONDUIT_BINARY := conduit
CONDUIT_DEFINE :=
else
$(error CONDUIT_VARIANT must be ordinary or diagnostic)
endif

build: native/libconduit_password.a
	$(FETCH)
	mkdir -p bin
	corral run -- $(PONYC) -Dopenssl_3.0.x $(CONDUIT_DEFINE) app -o bin -b $(CONDUIT_BINARY) -p native -L $(LIBPQ_LIBDIR)

build-diagnostic:
	$(MAKE) CONDUIT_VARIANT=diagnostic build

build-password-test: native/crypt_blowfish.o native/password.o \
	native/password_test_bridge.c
	$(FETCH)
	mkdir -p bin native/password-test-build
	$(CC) $(CFLAGS) -c native/password_test_bridge.c \
		-o native/password-test-build/bridge.o
	$(AR) rcs native/password-test-build/libconduit_password.a \
		native/crypt_blowfish.o native/password.o \
		native/password-test-build/bridge.o
	corral run -- $(PONYC) -Dopenssl_3.0.x $(CONDUIT_DEFINE) \
		-Dconduit_password_test app -o bin -b $(CONDUIT_BINARY)-password-test \
		-p native/password-test-build \
		-L $(LIBPQ_LIBDIR)

native/libconduit_password.a: native/crypt_blowfish.o native/password.o
	$(AR) rcs $@ $^

native/crypt_blowfish.o: native/crypt_blowfish.c native/crypt_blowfish.h \
	native/bcrypt_batch.h native/bcrypt_batch_impl.h
	$(CC) $(CFLAGS) -c $< -o $@

native/password.o: native/password.c native/crypt_blowfish.h native/password.h
	$(CC) $(CFLAGS) -c $< -o $@

native/password_test: native/password_test.c native/libconduit_password.a
	$(CC) $(CFLAGS) $< native/libconduit_password.a -lcrypto -o $@

native/password_batch_test: native/password_batch_test.c native/password.c \
	native/crypt_blowfish.c native/crypt_blowfish.h native/bcrypt_batch.h \
	native/bcrypt_batch_impl.h native/password.h
	$(CC) $(CFLAGS) $< -lcrypto -o $@

test-password-native: native/password_batch_test
	./native/password_batch_test $(PASSWORD_CASE)

test-password-async: build-password-test
	python3 test/passwords.py \
		$(if $(PASSWORD_CASE),$(PASSWORD_CASE),PasswordActors PasswordOptions)

test-password-integration: build-password-test
	python3 test/passwords.py $(if $(PASSWORD_CASE),$(PASSWORD_CASE),PasswordHTTP)

test: build native/password_test
	./native/password_test
	./bin/$(CONDUIT_BINARY) --self-test
	./bin/$(CONDUIT_BINARY) --test-diag-arithmetic
	./bin/$(CONDUIT_BINARY) --test-csv-tick

test-integration: build
	python3 test/integration.py

clean:
	rm -rf bin native/target native/password-test-build _corral native/*.o \
		native/libconduit_password.a native/password_test native/password_batch_test
