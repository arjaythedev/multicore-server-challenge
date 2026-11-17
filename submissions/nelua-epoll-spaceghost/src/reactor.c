/* Stackful continuations preserve the Nelua/C handler ABI. Only database waits
 * yield: parsing, authentication and rendering run to completion on this thread.
 * No request owns a thread, PGconn, or continuation while idle on HTTP. */
#define _GNU_SOURCE
#include "reactor.h"
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include "owned_memory.h"

#define NC_REACTOR_STACK (512U*1024U)

typedef struct nc_reactor nc_reactor;
typedef struct nc_fiber {
    ucontext_t continuation;
    nc_reactor *reactor;
    nc_db *db;
    void *stack, *mapping, *work;
    size_t mapping_size;
    uint64_t deadline;
    int fd, ready, error;
    bool waiting;
} nc_fiber;

struct nc_reactor {
    ucontext_t dispatcher;
    nc_fiber *fibers;
    int count, epoll_fd;
    const nc_reactor_hooks *hooks;
    void *context;
};

static _Thread_local nc_reactor *current_reactor;

static uint64_t nc_reactor_now(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now)!=0) abort();
    return (uint64_t)now.tv_sec*1000000U+(uint64_t)now.tv_nsec/1000U;
}

static int nc_reactor_wait(void *context,int fd,short events,int timeout)
{
    nc_fiber *fiber=context;
    struct epoll_event event={0};
    if (timeout<=0) return 0;
    event.events=EPOLLIN|EPOLLRDHUP;
    if (events&POLLOUT) event.events|=EPOLLOUT;
    event.data.ptr=fiber;
    if (epoll_ctl(fiber->reactor->epoll_fd,EPOLL_CTL_ADD,fd,&event)!=0) return -1;
    fiber->fd=fd;
    fiber->deadline=nc_reactor_now()+(uint64_t)(unsigned)timeout*1000U;
    fiber->waiting=true;
    if (swapcontext(&fiber->continuation,&fiber->reactor->dispatcher)!=0) abort();
    errno=fiber->error;
    return fiber->ready;
}

static void nc_reactor_resume(nc_fiber *fiber,int ready,int error)
{
    if (fiber->waiting) {
        epoll_ctl(fiber->reactor->epoll_fd,EPOLL_CTL_DEL,fiber->fd,NULL);
        fiber->waiting=false;
    }
    fiber->ready=ready;
    fiber->error=error;
    if (swapcontext(&fiber->reactor->dispatcher,&fiber->continuation)!=0) abort();
}

static void nc_reactor_entry(int index)
{
    nc_fiber *fiber=&current_reactor->fibers[index];
    for (;;) {
        fiber->reactor->hooks->execute(fiber->work,fiber->db);
        fiber->reactor->hooks->complete(fiber->reactor->context,fiber->work);
        fiber->work=NULL;
        if (swapcontext(&fiber->continuation,&fiber->reactor->dispatcher)!=0) abort();
    }
}

/* getcontext is returns_twice on some toolchains; isolate its local state. */
static bool nc_reactor_fiber_init(nc_fiber *fiber,int index)
{
    long page=sysconf(_SC_PAGESIZE);
    if (page<=0) return false;
    fiber->mapping_size=NC_REACTOR_STACK+2U*(size_t)page;
    fiber->mapping=mmap(NULL,fiber->mapping_size,PROT_NONE,
                        MAP_PRIVATE|MAP_ANONYMOUS|MAP_STACK,-1,0);
    if (fiber->mapping==MAP_FAILED) { fiber->mapping=NULL; return false; }
    fiber->stack=(char *)fiber->mapping+page;
    if (mprotect(fiber->stack,NC_REACTOR_STACK,PROT_READ|PROT_WRITE)!=0 ||
        getcontext(&fiber->continuation)!=0) return false;
    fiber->continuation.uc_stack.ss_sp=fiber->stack;
    fiber->continuation.uc_stack.ss_size=NC_REACTOR_STACK;
    fiber->continuation.uc_link=&fiber->reactor->dispatcher;
    makecontext(&fiber->continuation,(void (*)(void))nc_reactor_entry,1,index);
    return true;
}

void nc_reactor_run(const char *url,int slots,int wake_fd,
                    const nc_reactor_hooks *hooks,void *context)
{
    nc_reactor reactor={.count=slots,.epoll_fd=-1,.hooks=hooks,.context=context};
    bool good=false;
    if (slots<1 || slots>93) goto started;
    reactor.fibers=calloc((size_t)slots,sizeof(*reactor.fibers));
    reactor.epoll_fd=epoll_create1(EPOLL_CLOEXEC);
    if (!reactor.fibers || reactor.epoll_fd<0) goto started;
    struct epoll_event wake={.events=EPOLLIN,.data.ptr=NULL};
    if (epoll_ctl(reactor.epoll_fd,EPOLL_CTL_ADD,wake_fd,&wake)!=0) goto started;
    for (int i=0;i<slots;++i) {
        nc_fiber *fiber=&reactor.fibers[i];
        fiber->reactor=&reactor;
        fiber->db=nc_db_open(url);
        if (!fiber->db || !nc_reactor_fiber_init(fiber,i)) goto started;
        nc_db_set_wait(fiber->db,nc_reactor_wait,fiber);
    }
    good=true;
started:
    hooks->started(context,good);
    if (!good) goto cleanup;
    current_reactor=&reactor;
    for (;;) {
        uint64_t deadline=0;
        int active=0;
        bool completed_inline=false;
        bool stopping=hooks->stopping(context);
        for (int i=0;i<slots;++i) {
            nc_fiber *fiber=&reactor.fibers[i];
            if (!fiber->work && !stopping) {
                uint64_t collection=0;
                fiber->work=hooks->take(context,&collection);
                if (fiber->work) {
                    nc_reactor_resume(fiber,1,0);
                    if (!fiber->work) completed_inline=true;
                }
                else if (collection && (!deadline || collection<deadline)) deadline=collection;
            }
            if (fiber->work) ++active;
            if (fiber->waiting && (!deadline || fiber->deadline<deadline)) deadline=fiber->deadline;
        }
        if (!active && (stopping || hooks->stopping(context))) break;
        uint64_t now=nc_reactor_now();
        int64_t timeout=deadline?(deadline>now?(int64_t)(deadline-now):0):-1;
        /* A validation-only batch can finish without yielding. Look for more
         * queued work even if its enqueue eventfd has already been consumed. */
        if (completed_inline) timeout=0;
        struct epoll_event events[96];
        struct timespec until={0};
        if (timeout>=0) { until.tv_sec=timeout/1000000; until.tv_nsec=(timeout%1000000)*1000; }
        int count=epoll_pwait2(reactor.epoll_fd,events,96,timeout<0?NULL:&until,NULL);
        if (count<0 && (errno==ENOSYS || errno==EPERM))
            count=epoll_wait(reactor.epoll_fd,events,96,timeout<0?-1:(int)((timeout+999)/1000));
        if (count<0) {
            if (errno==EINTR) continue;
            /* Wake every owner with an error so it releases its batch once. */
            for (int i=0;i<slots;++i)
                if (reactor.fibers[i].waiting) nc_reactor_resume(&reactor.fibers[i],-1,EIO);
            break;
        }
        for (int i=0;i<count;++i) {
            nc_fiber *fiber=events[i].data.ptr;
            if (!fiber) {
                uint64_t value;
                while (read(wake_fd,&value,sizeof(value))<0 && errno==EINTR) {}
            } else if (fiber->waiting) {
                uint32_t flags=events[i].events;
                bool error=(flags&EPOLLERR) || ((flags&EPOLLHUP) && !(flags&EPOLLIN));
                nc_reactor_resume(fiber,error?-1:1,error?EIO:0);
            }
        }
        now=nc_reactor_now();
        for (int i=0;i<slots;++i) {
            nc_fiber *fiber=&reactor.fibers[i];
            if (fiber->waiting && fiber->deadline<=now) nc_reactor_resume(fiber,0,0);
        }
    }
    current_reactor=NULL;
cleanup:
    if (reactor.fibers) {
        for (int i=0;i<slots;++i) {
            nc_db_close(reactor.fibers[i].db);
            if (reactor.fibers[i].mapping)
                munmap(reactor.fibers[i].mapping,reactor.fibers[i].mapping_size);
        }
        free(reactor.fibers);
    }
    if (reactor.epoll_fd>=0) close(reactor.epoll_fd);
}
