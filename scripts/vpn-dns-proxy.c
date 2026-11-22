/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#include "vpn-dns-proxy.h"

#include <arpa/nameser.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum {
    DNS_HEADER_SIZE = 12,
    DNS_MAX_PACKET = UINT16_MAX,
    DNS_IO_TIMEOUT_MS = 1200,
    DNS_UDP_WORKERS = 4,
    DNS_SERVFAIL = 2,
    DNS_REFUSED = 5,
};

struct vpn_dns_proxy {
    int udp;
    int tcp;
    int stop[2];
    pthread_t udp_threads[DNS_UDP_WORKERS];
    size_t udp_count;
    pthread_t tcp_thread;
    unsigned int interface_index;
    struct in_addr servers[2];
    uint16_t upstream_port;
};

struct dns_question {
    size_t end;
    uint16_t type;
    uint16_t class;
};

static uint16_t read_u16(const unsigned char *bytes)
{
    return (uint16_t)((bytes[0] << 8) | bytes[1]);
}

static bool parse_question(const unsigned char *packet, size_t size, struct dns_question *question)
{
    if (size < DNS_HEADER_SIZE || (packet[2] & 0xf8) != 0 || read_u16(packet + 4) != 1)
        return false;

    size_t offset = DNS_HEADER_SIZE;
    while (offset < size && packet[offset] != 0) {
        size_t label = packet[offset++];
        if (label > 63 || label > size - offset || offset + label - DNS_HEADER_SIZE >= 255)
            return false;
        offset += label;
    }

    if (size - offset < 5)
        return false;
    question->end = offset + 5;
    question->type = read_u16(packet + offset + 1);
    question->class = read_u16(packet + offset + 3);
    return true;
}

static bool is_plain_address_query(const unsigned char *packet, size_t size,
                                   const struct dns_question *question)
{
    // Forward queries requesting DNSSEC or carrying authentication untouched.
    if (question->type != ns_t_aaaa || question->class != ns_c_in || (packet[3] & 0x30))
        return false;
    ns_msg message;
    if (ns_initparse(packet, (int)size, &message) != 0 || ns_msg_count(message, ns_s_an) != 0 ||
        ns_msg_count(message, ns_s_ns) != 0)
        return false;
    for (int i = 0; i < ns_msg_count(message, ns_s_ar); i++) {
        ns_rr record;
        if (ns_parserr(&message, ns_s_ar, i, &record) != 0 ||
            ns_rr_type(record) != ns_t_opt || (ns_rr_ttl(record) & 0x8000))
            return false;
    }
    return true;
}

static bool has_address_answer(const unsigned char *packet, size_t size, ns_type type)
{
    ns_msg message;
    ns_rr question;
    // Do not prefer an address based on truncated, authenticated or negative data.
    if (ns_initparse(packet, (int)size, &message) != 0 ||
        (packet[2] & 0x02) || (packet[3] & 0x2f) ||
        ns_parserr(&message, ns_s_qd, 0, &question) != 0)
        return false;
    int count = ns_msg_count(message, ns_s_an);
    char name[NS_MAXDNAME];
    strlcpy(name, ns_rr_name(question), sizeof(name));
    // Follow the answer's CNAME chain and ignore addresses for unrelated names.
    for (int redirects = 0; redirects < 8; redirects++) {
        char alias[NS_MAXDNAME] = "";
        for (int i = 0; i < count; i++) {
            ns_rr record;
            if (ns_parserr(&message, ns_s_an, i, &record) != 0)
                return false;
            if (ns_rr_class(record) != ns_c_in || strcasecmp(ns_rr_name(record), name) != 0)
                continue;
            if (ns_rr_type(record) == type && ns_rr_rdlen(record) == (type == ns_t_a ? 4 : 16))
                return true;
            if (ns_rr_type(record) == ns_t_cname &&
                ns_name_uncompress(packet, packet + size, ns_rr_rdata(record),
                                   alias, sizeof(alias)) != ns_rr_rdlen(record))
                return false;
        }
        if (alias[0] == '\0' || strcasecmp(alias, name) == 0)
            return false;
        strlcpy(name, alias, sizeof(name));
    }
    return false;
}

static size_t empty_response(const unsigned char *request, const struct dns_question *question,
                             unsigned char *response, unsigned char rcode)
{
    memcpy(response, request, question->end);
    response[2] = 0x80 | (request[2] & 1);
    response[3] = 0x80 | (request[3] & 0x10) | rcode;
    memset(response + 6, 0, 6);
    return question->end;
}

static int64_t now_ms(void)
{
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static bool ready(const struct vpn_dns_proxy *resolver, int fd, short events, int64_t deadline)
{
    struct pollfd sockets[] = {
        {.fd = resolver->stop[0], .events = POLLIN},
        {.fd = fd, .events = events},
    };
    for (;;) {
        int64_t remaining = deadline - now_ms();
        if (remaining <= 0)
            return false;
        int result = poll(sockets, 2, (int)remaining);
        if (result < 0 && errno == EINTR)
            continue;
        return result > 0 && sockets[0].revents == 0 && (sockets[1].revents & events) != 0;
    }
}

static bool prepare_socket(int fd, int type)
{
    int flags = fcntl(fd, F_GETFL);
    int enabled = 1;
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
           fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 &&
           (type != SOCK_STREAM ||
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) == 0);
}

static bool transfer(const struct vpn_dns_proxy *resolver, int fd, unsigned char *buffer, size_t size,
                     short events, int64_t deadline)
{
    while (size != 0 && ready(resolver, fd, events, deadline)) {
        ssize_t count = events == POLLIN ? recv(fd, buffer, size, 0) : send(fd, buffer, size, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (count <= 0)
            return false;
        buffer += count;
        size -= (size_t)count;
    }
    return size == 0;
}

static size_t read_frame(const struct vpn_dns_proxy *resolver, int fd, unsigned char *buffer,
                         int64_t deadline)
{
    unsigned char prefix[2];
    if (!transfer(resolver, fd, prefix, sizeof(prefix), POLLIN, deadline))
        return 0;
    size_t size = read_u16(prefix);
    return transfer(resolver, fd, buffer, size, POLLIN, deadline) ? size : 0;
}

static bool write_frame(const struct vpn_dns_proxy *resolver, int fd, unsigned char *buffer,
                        size_t size, int64_t deadline)
{
    unsigned char prefix[] = {(unsigned char)(size >> 8), (unsigned char)size};
    return transfer(resolver, fd, prefix, sizeof(prefix), POLLOUT, deadline) &&
           transfer(resolver, fd, buffer, size, POLLOUT, deadline);
}

static bool connect_upstream(const struct vpn_dns_proxy *resolver, int fd, struct in_addr address,
                             int64_t deadline)
{
    struct sockaddr_in peer = {
        .sin_len = sizeof(peer), .sin_family = AF_INET,
        .sin_port = htons(resolver->upstream_port), .sin_addr = address,
    };
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &resolver->interface_index,
                   sizeof(resolver->interface_index)) != 0)
        return false;
    if (connect(fd, (const struct sockaddr *)&peer, sizeof(peer)) == 0)
        return true;
    if (errno != EINPROGRESS || !ready(resolver, fd, POLLOUT, deadline))
        return false;
    int error;
    socklen_t length = sizeof(error);
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
}

static size_t query_upstream(const struct vpn_dns_proxy *resolver, struct in_addr server, int type,
                             unsigned char *request, size_t size, unsigned char *response)
{
    size_t result = 0;
    int fd = socket(AF_INET, type, 0);
    if (fd < 0)
        return 0;
    int64_t deadline = now_ms() + DNS_IO_TIMEOUT_MS;
    if (!prepare_socket(fd, type) || !connect_upstream(resolver, fd, server, deadline))
        goto done;

    if (type == SOCK_STREAM) {
        if (write_frame(resolver, fd, request, size, deadline))
            result = read_frame(resolver, fd, response, deadline);
    } else if (send(fd, request, size, 0) == (ssize_t)size &&
               ready(resolver, fd, POLLIN, deadline)) {
        ssize_t count = recv(fd, response, DNS_MAX_PACKET, 0);
        if (count > 0)
            result = (size_t)count;
    }
done:
    close(fd);
    return result;
}

static bool matches_question(const unsigned char *request, const struct dns_question *question,
                             const unsigned char *response, size_t count)
{
    return count >= question->end && read_u16(response) == read_u16(request) &&
           (response[2] & 0xf8) == 0x80 && read_u16(response + 4) == 1 &&
           memcmp(request + DNS_HEADER_SIZE, response + DNS_HEADER_SIZE,
                  question->end - DNS_HEADER_SIZE) == 0;
}

static bool a_record_exists(const struct vpn_dns_proxy *resolver, struct in_addr server, int type,
                            const unsigned char *request, size_t size,
                            const struct dns_question *question)
{
    unsigned char answer[DNS_MAX_PACKET], lookup[DNS_MAX_PACKET];
    memcpy(lookup, request, size);
    arc4random_buf(lookup, 2);
    lookup[question->end - 4] = 0;
    lookup[question->end - 3] = ns_t_a;
    size_t count = query_upstream(resolver, server, type, lookup, size, answer);
    return matches_question(lookup, question, answer, count) &&
           has_address_answer(answer, count, ns_t_a);
}

static size_t answer_query(const struct vpn_dns_proxy *resolver, int type, unsigned char *request,
                           size_t size, unsigned char *response)
{
    struct dns_question question;
    if (!parse_question(request, size, &question))
        return 0;
    for (size_t i = 0; i < 2; i++) {
        if (resolver->servers[i].s_addr == INADDR_ANY)
            continue;
        size_t count = query_upstream(resolver, resolver->servers[i], type, request, size, response);
        if (!matches_question(request, &question, response, count))
            continue;
        unsigned char rcode = response[3] & 0x0f;
        if (rcode == DNS_SERVFAIL || rcode == DNS_REFUSED)
            continue;
        if (is_plain_address_query(request, size, &question) &&
            has_address_answer(response, count, ns_t_aaaa) &&
            a_record_exists(resolver, resolver->servers[i], type, request, size, &question))
            return empty_response(request, &question, response, 0);
        return count;
    }
    return empty_response(request, &question, response, DNS_SERVFAIL);
}

static void handle_udp(const struct vpn_dns_proxy *resolver, unsigned char *request,
                       unsigned char *response)
{
    struct sockaddr_in peer;
    socklen_t length = sizeof(peer);
    ssize_t size = recvfrom(resolver->udp, request, DNS_MAX_PACKET, 0,
                            (struct sockaddr *)&peer, &length);
    if (size <= 0)
        return;
    size_t count = answer_query(resolver, SOCK_DGRAM, request, (size_t)size, response);
    if (count != 0)
        sendto(resolver->udp, response, count, 0, (const struct sockaddr *)&peer, length);
}

static void handle_tcp(const struct vpn_dns_proxy *resolver, unsigned char *request,
                       unsigned char *response)
{
    int client = accept(resolver->tcp, NULL, NULL);
    if (client < 0)
        return;
    if (prepare_socket(client, SOCK_STREAM)) {
        size_t size = read_frame(resolver, client, request, now_ms() + DNS_IO_TIMEOUT_MS);
        size_t count = answer_query(resolver, SOCK_STREAM, request, size, response);
        if (count != 0)
            write_frame(resolver, client, response, count, now_ms() + DNS_IO_TIMEOUT_MS);
    }
    close(client);
}

static void serve(const struct vpn_dns_proxy *resolver, int fd, bool tcp)
{
    unsigned char request[DNS_MAX_PACKET], response[DNS_MAX_PACKET];
    struct pollfd sockets[] = {
        {.fd = resolver->stop[0], .events = POLLIN},
        {.fd = fd, .events = POLLIN},
    };
    for (;;) {
        int result = poll(sockets, 2, -1);
        if (result < 0 && errno == EINTR)
            continue;
        if (result <= 0 || sockets[0].revents != 0 || (sockets[1].revents & POLLIN) == 0)
            return;
        if (tcp)
            handle_tcp(resolver, request, response);
        else
            handle_udp(resolver, request, response);
    }
}

static void *serve_udp(void *context)
{
    const struct vpn_dns_proxy *resolver = context;
    serve(resolver, resolver->udp, false);
    return NULL;
}

static void *serve_tcp(void *context)
{
    const struct vpn_dns_proxy *resolver = context;
    serve(resolver, resolver->tcp, true);
    return NULL;
}

static int listen_on_loopback(int type, struct sockaddr_in *address)
{
    int fd = socket(AF_INET, type, 0);
    if (fd < 0)
        return -1;
    socklen_t length = sizeof(*address);
    if (prepare_socket(fd, type) && bind(fd, (const struct sockaddr *)address, length) == 0 &&
        getsockname(fd, (struct sockaddr *)address, &length) == 0 &&
        (type != SOCK_STREAM || listen(fd, 8) == 0))
        return fd;
    close(fd);
    return -1;
}

struct vpn_dns_proxy *vpn_dns_proxy_start(unsigned int interface_index, const struct in_addr servers[2],
                               uint16_t upstream_port, uint16_t *local_port)
{
    struct vpn_dns_proxy *resolver = calloc(1, sizeof(*resolver));
    if (resolver == NULL)
        return NULL;
    resolver->interface_index = interface_index;
    resolver->upstream_port = upstream_port;
    memcpy(resolver->servers, servers, sizeof(resolver->servers));
    struct sockaddr_in address = {
        .sin_len = sizeof(address), .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    resolver->udp = listen_on_loopback(SOCK_DGRAM, &address);
    if (resolver->udp < 0)
        goto fail;
    resolver->tcp = listen_on_loopback(SOCK_STREAM, &address);
    if (resolver->tcp < 0)
        goto fail_udp;
    if (pipe(resolver->stop) != 0)
        goto fail_tcp;
    if (fcntl(resolver->stop[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(resolver->stop[1], F_SETFD, FD_CLOEXEC) != 0)
        goto fail_workers;
    for (; resolver->udp_count < DNS_UDP_WORKERS; resolver->udp_count++) {
        if (pthread_create(&resolver->udp_threads[resolver->udp_count], NULL, serve_udp, resolver) != 0)
            goto fail_workers;
    }
    if (pthread_create(&resolver->tcp_thread, NULL, serve_tcp, resolver) != 0)
        goto fail_workers;
    *local_port = ntohs(address.sin_port);
    return resolver;

fail_workers:
    close(resolver->stop[1]);
    for (size_t i = 0; i < resolver->udp_count; i++)
        pthread_join(resolver->udp_threads[i], NULL);
    close(resolver->stop[0]);
fail_tcp:
    close(resolver->tcp);
fail_udp:
    close(resolver->udp);
fail:
    free(resolver);
    return NULL;
}

void vpn_dns_proxy_stop(struct vpn_dns_proxy *resolver)
{
    close(resolver->stop[1]);
    for (size_t i = 0; i < resolver->udp_count; i++)
        pthread_join(resolver->udp_threads[i], NULL);
    pthread_join(resolver->tcp_thread, NULL);
    close(resolver->stop[0]);
    close(resolver->tcp);
    close(resolver->udp);
    free(resolver);
}
