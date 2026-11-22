/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#ifndef DFORTICLIENT_IPV4_DNS_H
#define DFORTICLIENT_IPV4_DNS_H

#include <netinet/in.h>
#include <stdint.h>

struct ipv4_dns;
extern const char *const ipv4_dns_domains[];

struct ipv4_dns *ipv4_dns_start(unsigned int interface_index, const struct in_addr servers[2],
                               uint16_t upstream_port, uint16_t *local_port);
void ipv4_dns_stop(struct ipv4_dns *resolver);

#endif
