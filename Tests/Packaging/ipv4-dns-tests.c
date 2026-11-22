#include "ipv4-dns.h"

#include <arpa/inet.h>
#include <assert.h>
#include <net/if.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const unsigned char chatgpt_question[] = {
    0xAB, 0xCD, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    2, 'W', 's', 7, 'C', 'h', 'a', 't', 'G', 'P', 'T', 3, 'c', 'o', 'm', 0,
    0, 1, 0, 1,
};

static int open_udp(uint16_t port, struct sockaddr_in *address)
{
    *address = (struct sockaddr_in) {
        .sin_len = sizeof(*address), .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK), .sin_port = htons(port),
    };
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);
    struct timeval timeout = {3, 0};
    assert(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    return fd;
}

static void *upstream(void *opaque)
{
    int fd = *(int *)opaque;
    struct sockaddr_in from;
    socklen_t length = sizeof(from);
    unsigned char packet[512];
    static const unsigned char answer[] = {
        0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1,
    };
    ssize_t count = recvfrom(fd, packet, sizeof(packet), 0, (struct sockaddr *)&from, &length);
    assert(count == sizeof(chatgpt_question));
    assert(memcmp(packet, chatgpt_question, sizeof(chatgpt_question)) == 0);
    packet[2] = 0x81;
    packet[3] = 0x82;
    assert(sendto(fd, packet, count, 0, (struct sockaddr *)&from, length) == count);

    length = sizeof(from);
    count = recvfrom(fd, packet, sizeof(packet), 0, (struct sockaddr *)&from, &length);
    assert(count == sizeof(chatgpt_question));
    assert(memcmp(packet, chatgpt_question, sizeof(chatgpt_question)) == 0);
    packet[2] = 0x81;
    packet[3] = 0x80;
    packet[7] = 1;
    memcpy(packet + count, answer, sizeof(answer));
    assert(sendto(fd, packet, count + sizeof(answer), 0, (struct sockaddr *)&from, length) ==
           count + (ssize_t)sizeof(answer));
    return NULL;
}

int main(void)
{
    struct sockaddr_in server, proxy;
    int server_fd = open_udp(0, &server);
    assert(bind(server_fd, (struct sockaddr *)&server, sizeof(server)) == 0);
    socklen_t size = sizeof(server);
    assert(getsockname(server_fd, (struct sockaddr *)&server, &size) == 0);
    unsigned int loopback = if_nametoindex("lo0");
    assert(loopback != 0);
    struct in_addr addresses[] = {server.sin_addr, server.sin_addr};
    uint16_t port;
    struct ipv4_dns *session = ipv4_dns_start(loopback, addresses, ntohs(server.sin_port), &port);
    assert(session != NULL && port != 0);

    int client = open_udp(port, &proxy);
    assert(connect(client, (struct sockaddr *)&proxy, sizeof(proxy)) == 0);
    int idle_tcp = socket(AF_INET, SOCK_STREAM, 0);
    assert(idle_tcp >= 0 && connect(idle_tcp, (struct sockaddr *)&proxy, sizeof(proxy)) == 0);
    usleep(100000);
    struct timeval timeout = {0, 600000};
    assert(setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    unsigned char request[sizeof(chatgpt_question)], response[512];
    memcpy(request, chatgpt_question, sizeof(request));
    for (size_t i = 0; i < 3; i++) {
        const unsigned char filtered[] = {28, 64, 65};
        request[sizeof(request) - 3] = filtered[i];
        assert(send(client, request, sizeof(request), 0) == sizeof(request));
        assert(recv(client, response, sizeof(response), 0) == sizeof(request));
        assert(response[0] == 0xAB && response[1] == 0xCD);
        assert(response[2] == 0x81 && response[3] == 0x80 && response[7] == 0);
        assert(memcmp(request + 12, response + 12, sizeof(request) - 12) == 0);
    }
    close(idle_tcp);

    // A different name with the same length must not be forwarded.
    request[16] = 'X';
    assert(send(client, request, sizeof(request), 0) == sizeof(request));
    assert(recv(client, response, sizeof(response), 0) == sizeof(request));
    assert((response[3] & 0x0F) == 5);

    pthread_t responder;
    assert(pthread_create(&responder, NULL, upstream, &server_fd) == 0);
    unsigned char extended[sizeof(chatgpt_question) + 11] = {0};
    memcpy(extended, chatgpt_question, sizeof(chatgpt_question));
    extended[11] = 1;
    extended[sizeof(chatgpt_question) + 2] = 41;
    assert(send(client, extended, sizeof(extended), 0) == sizeof(extended));
    assert(recv(client, response, sizeof(response), 0) == sizeof(chatgpt_question) + 16);
    assert(response[7] == 1);
    assert(response[sizeof(chatgpt_question) + 12] == 192);
    assert(pthread_join(responder, NULL) == 0);

    for (size_t i = 0; i < 2; i++) {
        int tcp = socket(AF_INET, SOCK_STREAM, 0);
        assert(tcp >= 0);
        timeout = (struct timeval){3, 0};
        assert(setsockopt(tcp, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
        assert(connect(tcp, (struct sockaddr *)&proxy, sizeof(proxy)) == 0);
        unsigned char frame[2 + sizeof(chatgpt_question)] = {0, sizeof(chatgpt_question)};
        memcpy(frame + 2, chatgpt_question, sizeof(chatgpt_question));
        frame[sizeof(frame) - 3] = i == 0 ? 28 : 252;
        assert(send(tcp, frame, sizeof(frame), 0) == sizeof(frame));
        assert(recv(tcp, response, sizeof(frame), MSG_WAITALL) == sizeof(frame));
        assert(response[0] == 0 && response[1] == sizeof(chatgpt_question));
        assert(response[4] == 0x81 && response[5] == (i == 0 ? 0x80 : 0x85) && response[9] == 0);
        close(tcp);
    }

    // An invalid compression pointer in the question receives no answer.
    memcpy(request, chatgpt_question, sizeof(request));
    request[12] = 0xc0;
    timeout = (struct timeval){0, 100000};
    assert(setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    assert(send(client, request, sizeof(request), 0) == sizeof(request));
    assert(recv(client, response, sizeof(response), 0) == -1);

    ipv4_dns_stop(session);
    int reuse = open_udp(port, &proxy);
    assert(bind(reuse, (struct sockaddr *)&proxy, sizeof(proxy)) == 0);
    close(reuse);
    close(client);
    close(server_fd);
    puts("Verified domain-scoped IPv4 DNS forwarding and listener cleanup");
    return 0;
}
