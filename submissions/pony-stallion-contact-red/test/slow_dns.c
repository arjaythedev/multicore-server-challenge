#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
  int (*next)(const char *, const char *, const struct addrinfo *,
              struct addrinfo **) = dlsym(RTLD_NEXT, "getaddrinfo");
  if (node != NULL && strcmp(node, "localhost") == 0) {
    write(STDERR_FILENO, "DNS delay entered\n", 18);
    const char *marker = getenv("CONDUIT_DNS_MARKER");
    if (marker != NULL) {
      int fd = open(marker, O_CREAT | O_WRONLY, 0600);
      if (fd >= 0) close(fd);
      const char *release = getenv("CONDUIT_DNS_RELEASE");
      if (release != NULL) {
        while (access(release, F_OK) != 0) usleep(1000);
      }
    } else {
      sleep(2);
    }
  }
  return next(node, service, hints, result);
}
