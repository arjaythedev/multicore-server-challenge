/*
 * pgserve's launcher: the process challenge.service starts. It owns the port and nothing else.
 *
 * It binds HOST:PORT once per worker (SO_REUSEPORT), opens one Postgres connection whose startup packet sets
 * local_preload_libraries=pgengine and pgengine.http, which starts the engine's HTTP workers as background
 * workers of Postgres, and hands each worker one listening socket and JWT_SECRET over a Unix socket
 * (SCM_RIGHTS). The workers serve every request. On SIGTERM it terminates the workers (a role may terminate
 * its own backends) and exits; Postgres does not stop them when this process goes.
 *
 * Env: HOST, PORT, JWT_SECRET, DATABASE_URL (SPEC's runtime contract); PGSERVE_WORKERS (default 6 of the
 * seven max_worker_processes slots the logical replication launcher leaves), PGSERVE_LIB (default pgengine,
 * the library in $libdir/plugins).
 */
#define _GNU_SOURCE 1
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *env(const char *k, const char *dflt)
{
	const char *v = getenv(k);

	return v != NULL && v[0] != '\0' ? v : dflt;
}

static void die(const char *what)
{
	fprintf(stderr, "pgserve: %s: %s\n", what, strerror(errno));
	exit(1);
}

/* Runs `sql` through psql on DATABASE_URL, with `options` (PGOPTIONS) in the startup packet. */
static int psql(const char *options, const char *sql)
{
	pid_t		pid = fork();
	int			st = 0;

	if (pid < 0)
		die("fork");
	if (pid == 0)
	{
		if (options != NULL)
			setenv("PGOPTIONS", options, 1);
		execlp("psql", "psql", env("DATABASE_URL", ""), "-qAtX", "-o", "/dev/null", "-v", "ON_ERROR_STOP=1", "-c", sql, (char *) NULL);
		_exit(127);
	}
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
		;
	return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

static const char stop_workers[] =
	"SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity "
	"WHERE backend_type = 'pgengine http' AND usename = current_user";

/* HOST is an IPv4 or IPv6 address; an IPv6 one (`::` too) listens dual-stack. */
static int listener(const char *host, int port)
{
	int			v6 = strchr(host, ':') != NULL, one = 1, zero = 0;
	int			fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
	struct sockaddr_in6 a6 = {.sin6_family = AF_INET6, .sin6_port = htons(port)};

	if (fd < 0)
		die("socket");
	if (v6 ? inet_pton(AF_INET6, host, &a6.sin6_addr) != 1 : inet_pton(AF_INET, host, &a.sin_addr) != 1)
	{
		fprintf(stderr, "pgserve: HOST %s is not an IP address\n", host);
		exit(1);
	}
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	if (v6)
		setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));
	if (v6 ? bind(fd, (struct sockaddr *) &a6, sizeof(a6)) < 0 : bind(fd, (struct sockaddr *) &a, sizeof(a)) < 0)
		die("bind HOST:PORT");
	if (listen(fd, 65535) < 0)
		die("listen");
	return fd;
}

/* Sends `secret` with `fd` attached. */
static void hand(int conn, int fd, const char *secret)
{
	char		ctl[CMSG_SPACE(sizeof(int))] = {0};
	struct iovec iov = {.iov_base = (void *) secret, .iov_len = strlen(secret)};
	struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl, .msg_controllen = sizeof(ctl)};
	struct cmsghdr *h = CMSG_FIRSTHDR(&m);

	h->cmsg_level = SOL_SOCKET;
	h->cmsg_type = SCM_RIGHTS;
	h->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(h), &fd, sizeof(int));
	if (sendmsg(conn, &m, MSG_NOSIGNAL) < 0)
		die("sendmsg");
}

static volatile sig_atomic_t stopping = 0;
static void on_term(int sig)
{
	stopping = 1;
}

int main(void)
{
	const char *host = env("HOST", "0.0.0.0"), *secret = env("JWT_SECRET", "");
	int			port = atoi(env("PORT", "80")), n = atoi(env("PGSERVE_WORKERS", "6"));
	char		path[64], options[256];
	struct sockaddr_un ua = {.sun_family = AF_UNIX};
	struct stat pgrun;
	int			us;

	if (secret[0] == '\0' || port <= 0 || n <= 0)
	{
		fprintf(stderr, "pgserve: JWT_SECRET, PORT and PGSERVE_WORKERS must be set\n");
		return 1;
	}
	/* the workers run as the owner of the Postgres socket directory; only they may collect a socket */
	if (stat("/var/run/postgresql", &pgrun) < 0)
		die("stat /var/run/postgresql");
	psql(NULL, stop_workers);	/* workers a previous launcher left */

	snprintf(path, sizeof(path), "/tmp/pgserve-%d.sock", (int) getpid());
	unlink(path);
	strncpy(ua.sun_path, path, sizeof(ua.sun_path) - 1);
	us = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (us < 0 || bind(us, (struct sockaddr *) &ua, sizeof(ua)) < 0 || chmod(path, 0777) < 0 || listen(us, 64) < 0)
		die("launcher socket");
	{
		struct timeval tv = {.tv_sec = 30};	/* a worker that never collects its socket fails the start */

		setsockopt(us, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	}

	snprintf(options, sizeof(options), "-c local_preload_libraries=%s -c pgengine.http=%s:%d",
			 env("PGSERVE_LIB", "pgengine"), path, n);
	if (psql(options, "SELECT 1") != 0)
	{
		fprintf(stderr, "pgserve: starting the workers failed\n");
		return 1;
	}
	for (int i = 0; i < n; i++)
	{
		struct ucred cred;
		socklen_t	len = sizeof(cred);
		int			conn = accept4(us, NULL, NULL, SOCK_CLOEXEC), fd;

		if (conn < 0)
			die("accept on the launcher socket");
		if (getsockopt(conn, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0 || cred.uid != pgrun.st_uid)
		{
			close(conn);
			i--;
			continue;
		}
		fd = listener(host, port);
		hand(conn, fd, secret);
		close(fd);
		close(conn);
	}
	close(us);
	unlink(path);
	fprintf(stderr, "pgserve: %d workers serving %s:%d\n", n, host, port);

	signal(SIGTERM, on_term);
	signal(SIGINT, on_term);
	while (!stopping)
		pause();
	psql(NULL, stop_workers);
	return 0;
}
