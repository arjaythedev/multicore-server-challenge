CC      ?= gcc
PGINC   := $(shell pkg-config --cflags libpq)
WARN    := -std=c99 -Wall -Wextra -Werror -Wstrict-prototypes \
           -Wmissing-prototypes -Wshadow -Wformat=2 -Wvla
CFLAGS  := $(WARN) -O2 -pthread -D_GNU_SOURCE -MMD -MP -Isrc $(PGINC)
LDFLAGS :=
LDLIBS  := -lpq -lssl -lcrypto -lcrypt

SRC  := $(shell find src -name '*.c' | sort)
OBJ  := $(SRC:.c=.o)
TEST_SRC := $(filter-out src/main.c,$(SRC))

bin/conduit: $(OBJ) | bin
	$(CC) -o $@ $(OBJ) $(LDFLAGS) $(LDLIBS)

bin:
	mkdir -p bin

-include $(OBJ:.o=.d)

src/%.o: src/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	find src -name '*.o' -o -name '*.d' | xargs -r rm
	rm -rf bin

bin/conduit-tests: tests/*.c $(TEST_SRC) | bin
	$(CC) $(CFLAGS) -o $@ tests/*.c $(TEST_SRC) $(LDFLAGS) $(LDLIBS)

# pure-module unit tests; no postgres
test: bin/conduit-tests
	./bin/conduit-tests

.PHONY: clean test
