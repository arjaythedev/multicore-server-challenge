/* Real sockets exercise bounded writes, backpressure, disconnects and accept
 * fairness without PostgreSQL. Test callbacks do not implement application IO. */
#define main nc_transport_program_main
#include "../src/transport.c"
#undef main
#include <assert.h>

int conduit_lane(nc_request *request) { (void)request; return 0; }
void conduit_batch(nc_request **requests,int count,nc_db *db)
{ (void)requests;(void)count;(void)db;abort(); }

typedef struct receiver {
    int fd;
    char header[192];
    size_t header_length,body_length;
    const char *expected;
} receiver;

static void *receive_all(void *argument)
{
    receiver *r=argument;
    size_t size=r->header_length+r->body_length, used=0;
    char *wire=malloc(size+1);
    assert(wire);
    while (used<size) {
        ssize_t n=read(r->fd,wire+used,size-used);
        if (n<0 && errno==EINTR) continue;
        assert(n>0);
        used+=(size_t)n;
    }
    assert(memcmp(wire,r->header,r->header_length)==0);
    assert(memcmp(wire+r->header_length,r->expected,r->body_length)==0);
    assert(read(r->fd,wire,1)==0);
    free(wire);close(r->fd);
    return NULL;
}

static nc_connection *stream(const char *body,size_t length,receiver *r)
{
    int sockets[2];
    assert(socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sockets)==0);
    assert(fcntl(sockets[0],F_SETFL,O_NONBLOCK)==0);
    int send_buffer=1024*1024;
    assert(setsockopt(sockets[0],SOL_SOCKET,SO_SNDBUF,&send_buffer,sizeof(send_buffer))==0);
    nc_connection *c=calloc(1,sizeof(*c));
    assert(c);
    c->fd=sockets[0]; c->stage=NC_READING;
    c->next=server.connections;
    if (c->next) c->next->previous=c;
    server.connections=c;
    struct epoll_event event={.events=EPOLLOUT|EPOLLONESHOT,.data.ptr=c};
    assert(epoll_ctl(server.epoll_fd,EPOLL_CTL_ADD,c->fd,&event)==0);
    static const char request[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    c->request=nc_request_create(request,sizeof(request)-1);
    assert(c->request);
    nc_write_n(nc_begin(c->request,200),body,length);
    size_t rendered;
    const char *output=nc_response_data(c->request,&rendered);
    assert(nc_status(c->request)==200 && rendered==length);
    assert(nc_output_start(c,200,output,rendered,false));
    *r=(receiver){.fd=sockets[1],.header_length=c->output->header_length,
                  .body_length=length,.expected=body};
    memcpy(r->header,c->output->header,r->header_length);
    return c;
}

static void test_send(void)
{
    size_t size=2U*1024U*1024U;
    char *payload=malloc(size);
    assert(payload);
    for (size_t i=0;i<size;++i) payload[i]=(char)(i%251);
    receiver big_reader,small_reader;
    nc_connection *big=stream(payload,size,&big_reader);
    pthread_t thread;
    assert(pthread_create(&thread,NULL,receive_all,&big_reader)==0);
    nc_flush(big);
    if (NC_NET_FAIR) {
        assert(big->stage==NC_WRITING);
        assert(big->output->sent<=NC_SEND_QUANTUM);
    }
    static const char small_body[]="{\"ok\":true}";
    nc_connection *small=stream(small_body,sizeof(small_body)-1,&small_reader);
    nc_flush(small);
    assert(small->stage==NC_RETIRED);
    receive_all(&small_reader);
    unsigned turns=1;
    while (big->stage==NC_WRITING) {
        struct epoll_event event;
        int count=epoll_wait(server.epoll_fd,&event,1,5000);
        assert(count==1 && event.data.ptr==big);
        size_t before=big->output->sent;
        nc_flush(big);
        size_t after=big->output?big->output->sent:big_reader.header_length+size;
        assert(after>=before);
        if (NC_NET_FAIR) assert(after-before<=NC_SEND_QUANTUM);
        ++turns;
    }
    assert(big->stage==NC_RETIRED);
    assert(pthread_join(thread,NULL)==0);
    if (NC_NET_FAIR) assert(turns>=9); /* body plus header */
    nc_collect();
    receiver closed_reader;
    nc_connection *closed=stream(payload,size,&closed_reader);
    close(closed_reader.fd);
    nc_flush(closed);
    assert(closed->stage==NC_RETIRED);
    nc_collect();free(payload);
    printf("PASS: network fair=%d small reply precedes large completion when enabled; "
           "2 MiB byte-exact transfer, %u turns, backpressure and closed peer\n",NC_NET_FAIR,turns);
}

static void test_accept(void)
{
    server.listener_fd=nc_listener("127.0.0.1","0");
    assert(server.listener_fd>=0);
    struct sockaddr_in address;
    socklen_t length=sizeof(address);
    assert(getsockname(server.listener_fd,(struct sockaddr *)&address,&length)==0);
    int clients[150];
    for (unsigned i=0;i<150;++i) {
        clients[i]=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);
        assert(clients[i]>=0);
        assert(connect(clients[i],(struct sockaddr *)&address,length)==0);
    }
    size_t count=0;
    assert(nc_accept());
    for (nc_connection *c=server.connections;c;c=c->next) {
        ++count;
        int enabled=0;socklen_t option_length=sizeof(enabled);
        assert(getsockopt(c->fd,IPPROTO_TCP,TCP_NODELAY,&enabled,&option_length)==0 && enabled);
    }
    assert(count==(NC_NET_FAIR?NC_ACCEPT_QUANTUM:150));
    assert(nc_accept());assert(nc_accept());
    count=0;
    for (nc_connection *c=server.connections;c;c=c->next) ++count;
    assert(count==150);
    for (unsigned i=0;i<150;++i) close(clients[i]);
    while (server.connections) nc_close(server.connections);
    nc_collect();close(server.listener_fd);
    printf("PASS: accept fair=%d 150 connections drained without losing backlog; TCP_NODELAY verified\n",NC_NET_FAIR);
}

int main(void)
{
    server.epoll_fd=epoll_create1(EPOLL_CLOEXEC);
    server.reserve_fd=-1;
    assert(server.epoll_fd>=0);
    test_send();test_accept();
    close(server.epoll_fd);
}
