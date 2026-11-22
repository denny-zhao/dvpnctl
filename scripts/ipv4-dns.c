/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#include "ipv4-dns.h"

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

const char *const ipv4_dns_domains[] = {
    "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com", NULL,
};

enum {
    DNS_HEADER_SIZE = 12,
    DNS_MAX_PACKET = UINT16_MAX,
    DNS_IO_TIMEOUT_MS = 1200,
    DNS_TYPE_A = 1,
    DNS_TYPE_AAAA = 28,
    DNS_TYPE_SVCB = 64,
    DNS_TYPE_HTTPS = 65,
    DNS_TYPE_ANY = 255,
    DNS_SERVFAIL = 2,
    DNS_REFUSED = 5,
};

struct ipv4_dns {
    int udp;
    int tcp;
    int stop[2];
    pthread_t udp_thread;
    pthread_t tcp_thread;
    unsigned int interface_index;
    struct in_addr servers[2];
    uint16_t upstream_port;
};

struct dns_question {
    size_t end;
    uint16_t type;
    bool allowed;
};

static uint16_t read_u16(const unsigned char *bytes)
{
    return (uint16_t)((bytes[0] << 8) | bytes[1]);
}

static bool matched_domain(const char *name, size_t length)
{
    for (size_t i = 0; ipv4_dns_domains[i] != NULL; i++) {
        size_t suffix_length = strlen(ipv4_dns_domains[i]);
        if (length < suffix_length)
            continue;
        size_t offset = length - suffix_length;
        if ((offset == 0 || name[offset - 1] == '.') &&
            strncasecmp(name + offset, ipv4_dns_domains[i], suffix_length) == 0)
            return true;
    }
    return false;
}

static bool parse_question(const unsigned char *packet, size_t size, struct dns_question *question)
{
    if (size < DNS_HEADER_SIZE || (packet[2] & 0xf8) != 0 || read_u16(packet + 4) != 1)
        return false;

    char name[253];
    size_t offset = DNS_HEADER_SIZE;
    size_t length = 0;
    while (offset < size && packet[offset] != 0) {
        size_t label = packet[offset++];
        if (label > 63 || label > size - offset || length + (length != 0) + label > sizeof(name))
            return false;
        if (length != 0)
            name[length++] = '.';
        for (size_t i = 0; i < label; i++) {
            unsigned char byte = packet[offset++];
            if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                  (byte >= '0' && byte <= '9') || byte == '-' || byte == '_'))
                return false;
            name[length++] = (char)byte;
        }
    }

    if (size - offset < 5 || read_u16(packet + offset + 3) != 1)
        return false;
    question->end = offset + 5;
    question->type = read_u16(packet + offset + 1);
    question->allowed = matched_domain(name, length);
    return true;
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

static bool ready(const struct ipv4_dns *resolver, int fd, short events, int64_t deadline)
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

static bool transfer(const struct ipv4_dns *resolver, int fd, unsigned char *buffer, size_t size,
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

static size_t read_frame(const struct ipv4_dns *resolver, int fd, unsigned char *buffer,
                         int64_t deadline)
{
    unsigned char prefix[2];
    if (!transfer(resolver, fd, prefix, sizeof(prefix), POLLIN, deadline))
        return 0;
    size_t size = read_u16(prefix);
    return transfer(resolver, fd, buffer, size, POLLIN, deadline) ? size : 0;
}

static bool write_frame(const struct ipv4_dns *resolver, int fd, unsigned char *buffer,
                        size_t size, int64_t deadline)
{
    unsigned char prefix[] = {(unsigned char)(size >> 8), (unsigned char)size};
    return transfer(resolver, fd, prefix, sizeof(prefix), POLLOUT, deadline) &&
           transfer(resolver, fd, buffer, size, POLLOUT, deadline);
}

static bool connect_upstream(const struct ipv4_dns *resolver, int fd, struct in_addr address,
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

static size_t query_upstream(const struct ipv4_dns *resolver, struct in_addr server, int type,
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

static size_t answer_query(const struct ipv4_dns *resolver, int type, unsigned char *request,
                           size_t size, unsigned char *response)
{
    struct dns_question question;
    if (!parse_question(request, size, &question))
        return 0;
    if (!question.allowed)
        return empty_response(request, &question, response, DNS_REFUSED);
    // HTTPS/SVCB can advertise IPv6 addresses even when AAAA returns no data.
    if (question.type == DNS_TYPE_AAAA || question.type == DNS_TYPE_HTTPS ||
        question.type == DNS_TYPE_SVCB || question.type == DNS_TYPE_ANY)
        return empty_response(request, &question, response, 0);
    if (question.type != DNS_TYPE_A)
        return empty_response(request, &question, response, DNS_REFUSED);

    // Forward only the parsed question. Extra records and query options stay local.
    request[2] &= 1;
    request[3] &= 0x10;
    memset(request + 6, 0, 6);
    size = question.end;

    for (size_t i = 0; i < 2; i++) {
        if (resolver->servers[i].s_addr == INADDR_ANY)
            continue;
        size_t count = query_upstream(resolver, resolver->servers[i], type, request, size, response);
        if (count < DNS_HEADER_SIZE || count < question.end || read_u16(response) != read_u16(request) ||
            (response[2] & 0xf8) != 0x80 || read_u16(response + 4) != 1 ||
            memcmp(request + DNS_HEADER_SIZE, response + DNS_HEADER_SIZE,
                   question.end - DNS_HEADER_SIZE) != 0)
            continue;
        unsigned char rcode = response[3] & 0x0f;
        if (rcode != DNS_SERVFAIL && rcode != DNS_REFUSED)
            return count;
    }
    return empty_response(request, &question, response, DNS_SERVFAIL);
}

static void handle_udp(const struct ipv4_dns *resolver, unsigned char *request,
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

static void handle_tcp(const struct ipv4_dns *resolver, unsigned char *request,
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

static void serve(const struct ipv4_dns *resolver, int fd, bool tcp)
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
    const struct ipv4_dns *resolver = context;
    serve(resolver, resolver->udp, false);
    return NULL;
}

static void *serve_tcp(void *context)
{
    const struct ipv4_dns *resolver = context;
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

struct ipv4_dns *ipv4_dns_start(unsigned int interface_index, const struct in_addr servers[2],
                               uint16_t upstream_port, uint16_t *local_port)
{
    struct ipv4_dns *resolver = calloc(1, sizeof(*resolver));
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
        fcntl(resolver->stop[1], F_SETFD, FD_CLOEXEC) != 0 ||
        pthread_create(&resolver->udp_thread, NULL, serve_udp, resolver) != 0)
        goto fail_pipe;
    if (pthread_create(&resolver->tcp_thread, NULL, serve_tcp, resolver) != 0) {
        close(resolver->stop[1]);
        pthread_join(resolver->udp_thread, NULL);
        goto fail_stop_reader;
    }
    *local_port = ntohs(address.sin_port);
    return resolver;

fail_pipe:
    close(resolver->stop[1]);
fail_stop_reader:
    close(resolver->stop[0]);
fail_tcp:
    close(resolver->tcp);
fail_udp:
    close(resolver->udp);
fail:
    free(resolver);
    return NULL;
}

void ipv4_dns_stop(struct ipv4_dns *resolver)
{
    close(resolver->stop[1]);
    pthread_join(resolver->udp_thread, NULL);
    pthread_join(resolver->tcp_thread, NULL);
    close(resolver->stop[0]);
    close(resolver->tcp);
    close(resolver->udp);
    free(resolver);
}
