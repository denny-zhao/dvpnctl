#include "vpn-dns-proxy.h"

#include <arpa/inet.h>
#include <assert.h>
#include <net/if.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static const unsigned char question[] = {
    0xde, 0xad, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    4, 'd', 'u', 'a', 'l', 4, 't', 'e', 's', 't', 0, 0, 28, 0, 1,
};
enum { NAME = 13, TYPE = sizeof(question) - 3 };

static void *answer_queries(void *context)
{
    int fd = *(int *)context;
    for (;;) {
        unsigned char packet[512];
        struct sockaddr_in peer;
        socklen_t length = sizeof(peer);
        ssize_t size = recvfrom(fd, packet, sizeof(packet), 0,
                                (struct sockaddr *)&peer, &length);
        assert(size >= (ssize_t)sizeof(question));
        if (packet[NAME] == 's') return NULL;
        unsigned char type = packet[TYPE];
        unsigned char answers = type == 1 && packet[NAME] == 'v' ? 0 : 1;
        size_t rdata = type == 1 ? 4 : type == 28 ? 16 : 1;
        packet[2] = 0x81;
        packet[3] = 0x80;
        packet[7] = answers;
        packet[11] = 0;
        size_t response = sizeof(question);
        if (answers) {
            const unsigned char rr[] = {0xc0, 12, 0, type, 0, 1, 0, 0, 0, 30, 0, rdata};
            memcpy(packet + response, rr, sizeof(rr));
            response += sizeof(rr);
            memset(packet + response, 0x20, rdata);
            response += rdata;
        }
        assert(sendto(fd, packet, response, 0, (struct sockaddr *)&peer, length) ==
               (ssize_t)response);
    }
}

static void exchange(int client, struct sockaddr_in server, char first_letter, int qtype,
                     bool dnssec, unsigned int expected_answers)
{
    unsigned char packet[512];
    memcpy(packet, question, sizeof(question));
    packet[NAME] = first_letter;
    packet[TYPE] = qtype;
    size_t size = sizeof(question);
    if (dnssec) {
        const unsigned char opt[] = {0, 0, 41, 4, 208, 0, 0, 0x80, 0, 0, 0};
        packet[11] = 1;
        memcpy(packet + size, opt, sizeof(opt));
        size += sizeof(opt);
    }
    assert(sendto(client, packet, size, 0, (struct sockaddr *)&server, sizeof(server)) ==
           (ssize_t)size);
    ssize_t received = recv(client, packet, sizeof(packet), 0);
    assert(received >= (ssize_t)sizeof(question));
    assert(packet[0] == question[0] && packet[1] == question[1]);
    assert(packet[TYPE] == qtype && (packet[3] & 15) == 0);
    assert(packet[7] == expected_answers);
}

int main(void)
{
    int upstream = socket(AF_INET, SOCK_DGRAM, 0);
    int client = socket(AF_INET, SOCK_DGRAM, 0);
    assert(upstream >= 0 && client >= 0);
    const struct timeval timeout = {.tv_sec = 3};
    assert(setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    struct sockaddr_in server = {
        .sin_len = sizeof(server), .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    assert(bind(upstream, (struct sockaddr *)&server, sizeof(server)) == 0);
    socklen_t length = sizeof(server);
    assert(getsockname(upstream, (struct sockaddr *)&server, &length) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, answer_queries, &upstream) == 0);

    uint16_t port;
    const struct in_addr servers[] = {server.sin_addr, {0}};
    struct vpn_dns_proxy *proxy = vpn_dns_proxy_start(if_nametoindex("lo0"), servers,
                                                       ntohs(server.sin_port), &port);
    assert(proxy != NULL);
    struct sockaddr_in local = server;
    local.sin_port = htons(port);
    exchange(client, local, 'd', 28, false, 0); // dual stack
    exchange(client, local, 'v', 28, false, 1); // no corresponding A record
    exchange(client, local, 'd', 28, true, 1);  // DNSSEC request
    exchange(client, local, 'd', 1, false, 1);  // A unchanged
    exchange(client, local, 'd', 65, false, 1); // HTTPS records unchanged

    vpn_dns_proxy_stop(proxy);
    unsigned char stop[sizeof(question)];
    memcpy(stop, question, sizeof(stop));
    stop[NAME] = 's';
    assert(sendto(client, stop, sizeof(stop), 0, (struct sockaddr *)&server, sizeof(server)) ==
           (ssize_t)sizeof(stop));
    pthread_join(thread, NULL);
    close(client);
    close(upstream);
    puts("Verified generic IPv4 preference, IPv6-only, and DNS passthrough");
    return 0;
}
