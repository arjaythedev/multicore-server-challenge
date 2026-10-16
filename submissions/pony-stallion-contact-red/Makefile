PONYC ?= ponyc
FETCH ?= corral fetch
CC ?= cc
AR ?= ar
CFLAGS ?= -O3 -std=c11

.PHONY: build test test-integration clean
build: native/libconduit_password.a
	$(FETCH)
	mkdir -p bin
	corral run -- $(PONYC) -Dopenssl_3.0.x app -o bin -b conduit -p native

native/libconduit_password.a: native/crypt_blowfish.o native/password.o
	$(AR) rcs $@ $^

native/crypt_blowfish.o: native/crypt_blowfish.c native/crypt_blowfish.h
	$(CC) $(CFLAGS) -c $< -o $@

native/password.o: native/password.c native/crypt_blowfish.h
	$(CC) $(CFLAGS) -c $< -o $@

native/password_test: native/password_test.c native/libconduit_password.a
	$(CC) $(CFLAGS) $< native/libconduit_password.a -lcrypto -o $@

test: build native/password_test
	./native/password_test
	./bin/conduit --self-test

test-integration: build
	python3 test/integration.py

clean:
	rm -rf bin native/target _corral native/*.o native/libconduit_password.a native/password_test
