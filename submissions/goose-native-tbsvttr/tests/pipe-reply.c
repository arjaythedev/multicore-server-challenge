/* Regression checks for bcrypt reply delivery. No server, database or load. */
#define _GNU_SOURCE
#include "json_fast.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int64_t native_write_atomic_reply(int32_t, bytes);
ssize_t __real_write(int, const void *, size_t);
int __real_poll(struct pollfd *, nfds_t, int);

static unsigned checks, cases;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s (errno=%d)\n",__LINE__,#x,errno); exit(1); } } while (0)
enum { NONE, WRITE_EINTR, WRITE_SHORT, WRITE_ZERO, POLL_EINTR, POLL_ERROR, POLL_INVALID, POLL_BROKEN, POLL_HANGUP };
static atomic_int hook_fd = ATOMIC_VAR_INIT(INT_MIN);
static atomic_int write_mode, poll_mode, write_calls, poll_calls;
static atomic_int injected_write_eintr, injected_poll_eintr, real_poll_eintr, signal_calls;

ssize_t __wrap_write(int fd, const void *data, size_t n) {
    if (fd == atomic_load(&hook_fd)) {
        atomic_fetch_add(&write_calls,1);
        int mode=atomic_exchange(&write_mode,NONE);
        if (mode==WRITE_EINTR) { atomic_fetch_add(&injected_write_eintr,1); errno=EINTR; return -1; }
        if (mode==WRITE_SHORT) return n > 1 ? (ssize_t)n-1 : 0;
        if (mode==WRITE_ZERO) return 0;
    }
    return __real_write(fd,data,n);
}

int __wrap_poll(struct pollfd *fds, nfds_t n, int timeout) {
    int hooked=n==1 && fds[0].fd==atomic_load(&hook_fd);
    if (hooked) {
        atomic_fetch_add(&poll_calls,1);
        int mode=atomic_exchange(&poll_mode,NONE);
        if (mode==POLL_EINTR) { atomic_fetch_add(&injected_poll_eintr,1); errno=EINTR; return -1; }
        if (mode==POLL_ERROR) { errno=EBADF; return -1; }
        if (mode==POLL_INVALID) { fds[0].revents=POLLNVAL; return 1; }
        if (mode==POLL_BROKEN) { fds[0].revents=POLLERR; return 1; }
        if (mode==POLL_HANGUP) { fds[0].revents=POLLHUP; return 1; }
    }
    int result=__real_poll(fds,n,timeout);
    if (hooked && result<0 && errno==EINTR) atomic_fetch_add(&real_poll_eintr,1);
    return result;
}

static void interrupt_poll(int signal_number) {
    (void)signal_number;
    atomic_fetch_add(&signal_calls,1);
}

static void millisecond(void) {
    struct timespec delay={0,1000000};
    while (nanosleep(&delay,&delay)<0 && errno==EINTR) {}
}

static void await_at_least(atomic_int *value,int minimum) {
    for (int i=0;i<5000;++i) {
        if (atomic_load(value)>=minimum) return;
        millisecond();
    }
    CHECK(atomic_load(value)>=minimum);
}

static size_t fill_pipe(int fd) {
    uint8_t filler[4096];memset(filler,0xa5,sizeof(filler));
    size_t filled=0;
    for (;;) {
        ssize_t n=__real_write(fd,filler,sizeof(filler));
        if (n>0) { filled+=(size_t)n; continue; }
        if (n<0 && errno==EINTR) continue;
        CHECK(n==-1 && (errno==EAGAIN || errno==EWOULDBLOCK));
        CHECK(filled>=sizeof(filler));
        return filled;
    }
}

struct Delivery { int fd; uint8_t record[72]; int64_t result; int error; atomic_int done; };
static void *deliver(void *arg) {
    struct Delivery *d=arg;
    d->result=native_write_atomic_reply(d->fd,(bytes){d->record,sizeof(d->record)});
    d->error=errno;
    atomic_store(&d->done,1);
    return NULL;
}

static void backpressure_and_interrupts(void) {
    ++cases;
    int p[2];CHECK(pipe2(p,O_NONBLOCK|O_CLOEXEC)==0);
    size_t filled=fill_pipe(p[1]);
    struct sigaction action={0},old_action;
    action.sa_handler=interrupt_poll;sigemptyset(&action.sa_mask);
    CHECK(sigaction(SIGUSR1,&action,&old_action)==0);
    struct Delivery delivery={.fd=p[1],.done=ATOMIC_VAR_INIT(0)};
    for (size_t i=0;i<sizeof(delivery.record);++i) delivery.record[i]=(uint8_t)(i*17+9);
    atomic_store(&hook_fd,p[1]);atomic_store(&write_mode,WRITE_EINTR);atomic_store(&poll_mode,POLL_EINTR);
    atomic_store(&write_calls,0);atomic_store(&poll_calls,0);
    pthread_t thread;CHECK(pthread_create(&thread,NULL,deliver,&delivery)==0);
    await_at_least(&poll_calls,2);
    CHECK(atomic_load(&delivery.done)==0); /* Full pipe must keep the job pending. */
    /* Interrupt a real blocked poll, as well as the deterministic injected
       syscall EINTRs. Repeating the signal closes the enter-poll race. */
    for (int i=0;i<5000 && atomic_load(&real_poll_eintr)==0;++i) {
        CHECK(pthread_kill(thread,SIGUSR1)==0);
        millisecond();
    }
    CHECK(atomic_load(&real_poll_eintr)>=1);
    CHECK(atomic_load(&signal_calls)>=1);
    CHECK(atomic_load(&delivery.done)==0);
    uint8_t block[4096];size_t remaining=filled;
    while (remaining) {
        size_t want=remaining<sizeof(block)?remaining:sizeof(block);
        ssize_t n=read(p[0],block,want);
        if (n<0 && errno==EINTR) continue;
        CHECK(n>0);
        for (ssize_t i=0;i<n;++i) CHECK(block[i]==0xa5);
        remaining-=(size_t)n;
    }
    await_at_least(&delivery.done,1);
    CHECK(pthread_join(thread,NULL)==0);
    CHECK(delivery.result==72);
    CHECK(atomic_load(&injected_write_eintr)==1);
    CHECK(atomic_load(&injected_poll_eintr)==1);
    CHECK(atomic_load(&write_calls)>=3);
    CHECK(atomic_load(&poll_calls)>=3);
    uint8_t received[72];CHECK(read(p[0],received,sizeof(received))==72);
    CHECK(memcmp(received,delivery.record,72)==0);
    CHECK(read(p[0],block,sizeof(block))==-1 && (errno==EAGAIN || errno==EWOULDBLOCK));
    atomic_store(&hook_fd,INT_MIN);
    CHECK(sigaction(SIGUSR1,&old_action,NULL)==0);
    close(p[0]);close(p[1]);
}

static void error_checks(void) {
    uint8_t record[72]={0};
    const int64_t bad_lengths[]={-1,0,PIPE_BUF+1};
    for (size_t i=0;i<sizeof(bad_lengths)/sizeof(bad_lengths[0]);++i) {
        ++cases;errno=0;
        CHECK(native_write_atomic_reply(-1,(bytes){record,bad_lengths[i]})==-1 && errno==EINVAL);
    }
    ++cases;errno=0;
    CHECK(native_write_atomic_reply(-1,(bytes){record,72})==-1 && errno==EBADF);
    int p[2];CHECK(pipe2(p,O_NONBLOCK|O_CLOEXEC)==0);
    close(p[0]);
    struct sigaction ignore={0},old_pipe;
    ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);
    CHECK(sigaction(SIGPIPE,&ignore,&old_pipe)==0);
    ++cases;errno=0;
    CHECK(native_write_atomic_reply(p[1],(bytes){record,72})==-1 && errno==EPIPE);
    CHECK(sigaction(SIGPIPE,&old_pipe,NULL)==0);close(p[1]);
    CHECK(pipe2(p,O_NONBLOCK|O_CLOEXEC)==0);
    atomic_store(&hook_fd,p[1]);
    const int short_modes[]={WRITE_SHORT,WRITE_ZERO};
    for (size_t i=0;i<sizeof(short_modes)/sizeof(short_modes[0]);++i) {
        ++cases;atomic_store(&write_mode,short_modes[i]);errno=0;
        CHECK(native_write_atomic_reply(p[1],(bytes){record,72})==-1 && errno==EIO);
    }
    fill_pipe(p[1]);
    const int modes[]={POLL_ERROR,POLL_INVALID,POLL_BROKEN,POLL_HANGUP};
    const int expected[]={EBADF,EBADF,EPIPE,EPIPE};
    for (size_t i=0;i<sizeof(modes)/sizeof(modes[0]);++i) {
        ++cases;atomic_store(&poll_mode,modes[i]);errno=0;
        CHECK(native_write_atomic_reply(p[1],(bytes){record,72})==-1 && errno==expected[i]);
    }
    atomic_store(&hook_fd,INT_MIN);close(p[0]);close(p[1]);
}

int main(void) {
    _Static_assert(ATOMIC_INT_LOCK_FREE==2,"signal counter must be lock-free");
    alarm(20); /* A broken retry loop must fail instead of hanging CI. */
    backpressure_and_interrupts();error_checks();alarm(0);
    printf("{\"status\":\"PASS\",\"cases\":%u,\"checks\":%u,\"reply_bytes\":72,\"write_eintr_injected\":%d,\"poll_eintr_injected\":%d,\"real_poll_eintr\":%d,\"real_signals\":%d}\n",cases,checks,atomic_load(&injected_write_eintr),atomic_load(&injected_poll_eintr),atomic_load(&real_poll_eintr),atomic_load(&signal_calls));
    return 0;
}
