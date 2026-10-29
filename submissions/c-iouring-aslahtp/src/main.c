/* Reads the configuration, then forks the worker processes. The parent only watches: if any worker exits it
 * kills the rest and exits too, so a crash shows up as a dead server rather than a half-working one (the box
 * never restarts it, and restarting would break rule 9's spirit). */
#include <errno.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

#include "drain.h"
#include "ipc.h"
#include "jwt.h"
#include "sha256.h"
#include "worker.h"

#define MAX_WORKERS 64

static pid_t children[MAX_WORKERS];
static int nchildren;

static int env_int(const char *name, int def, int lo, int hi) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    char *end;
    long n = strtol(v, &end, 10);
    if (*end || n < lo || n > hi) die("%s must be an integer in [%d, %d]", name, lo, hi);
    return (int)n;
}

static const char *env_str(const char *name, const char *def) {
    const char *v = getenv(name);
    return v && *v ? v : def;
}

static void kill_children(void) {
    for (int i = 0; i < nchildren; i++)
        if (children[i] > 0) kill(children[i], SIGKILL);
}

static void on_term(int sig) {
    (void)sig;
    kill_children();
    _exit(0);
}

int main(int argc, char **argv) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "--sql") == 0) {
        /* Every prepared statement, for EXPLAIN work: name<TAB>parameter types<TAB>SQL */
        for (int i = 0; i < S_COUNT; i++) {
            printf("%s\t", stmt_names[i]);
            for (int j = 0; j < stmts[i].nparams; j++) printf("%s%u", j ? "," : "", stmts[i].params[j]);
            printf("\t%s\n", stmts[i].sql);
        }
        return 0;
    }
    const char *url = getenv("DATABASE_URL");
    const char *secret = getenv("JWT_SECRET");
    if (!url || !*url) die("DATABASE_URL is not set");
    if (!secret || !*secret) die("JWT_SECRET is not set");
    if (!pg_url_parse(url, &cfg.pg)) die("DATABASE_URL is not a postgres:// URL");

    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (cpus < 1) cpus = 1;
    cfg.host = env_str("HOST", "0.0.0.0");
    cfg.port = env_str("PORT", "3000");
    cfg.workers = env_int("WORKERS", cpus >= 2 ? (int)(cpus / 2) : 1, 1, MAX_WORKERS);
    cfg.read_conns = env_int("READ_CONNS", 12, 1, 64);
    cfg.write_conns = env_int("WRITE_CONNS", 1, 1, 8);
    cfg.bcrypt_threads = env_int("BCRYPT_THREADS", 1, 1, 64);
    cfg.bcrypt_wait_ms = env_int("BCRYPT_WAIT_MS", 1000, 0, 5000);
    cfg.bcrypt_batch = env_int("BCRYPT_BATCH", 4, 1, 8);
    cfg.bcrypt_nice = env_int("BCRYPT_NICE", 10, 0, 19);
    cfg.pg_pipeline = (uint32_t)env_int("PG_PIPELINE", 16, 1, 1024);
    cfg.write_group = (uint32_t)env_int("WRITE_GROUP", 128, 1, 4096);
    cfg.plan_max = (uint32_t)env_int("PLAN_MAX", 4096, 1, 65536);
    cfg.plan_wait_us = env_int("PLAN_WAIT_US", 20000, 0, 1000000);
    cfg.planner = env_int("PLANNER", 1, 0, 1);
    cfg.plan_pace = env_int("PLAN_PACE", 1, 0, 1);
    session_tune = env_int("PG_TUNE", 0, 0, 1);
    cfg.direct_fds = env_int("DIRECT_FDS", 0, 0, 1);
    if (cfg.read_conns + cfg.workers * cfg.write_conns > 95) die("more than 95 postgres connections");

    sha256_select();
    jwt_init(secret, strlen(secret));
    signal(SIGPIPE, SIG_IGN);

    ipc_setup(cfg.workers, (size_t)env_int("RING_MB", 32, 1, 1024) << 20);

    /* Process 0 is the drain; then the workers. */
    pid_t parent = getpid();
    for (int i = -1; i < cfg.workers; i++) {
        pid_t pid = fork();
        if (pid < 0) die("fork: %s", strerror(errno));
        if (pid == 0) {
            prctl(PR_SET_PDEATHSIG, SIGKILL);
            if (getppid() != parent) _exit(1);
            if (i < 0) drain_run();
            else worker_run(i);
            _exit(1);
        }
        children[nchildren++] = pid;
    }

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    for (;;) {
        int status;
        pid_t pid = wait(&status);
        if (pid < 0) {
            if (errno == EINTR) continue;
            die("wait: %s", strerror(errno));
        }
        if (WIFSIGNALED(status))
            fprintf(stderr, "worker process %d killed by signal %d; stopping\n", pid, WTERMSIG(status));
        else
            fprintf(stderr, "worker process %d exited with status %d; stopping\n", pid, WEXITSTATUS(status));
        kill_children();
        return 1;
    }
}
