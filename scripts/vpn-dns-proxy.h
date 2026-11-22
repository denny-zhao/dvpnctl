/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#ifndef DFORTICLIENT_VPN_DNS_PROXY_H
#define DFORTICLIENT_VPN_DNS_PROXY_H

#include <netinet/in.h>
#include <stdint.h>

struct vpn_dns_proxy;

struct vpn_dns_proxy *vpn_dns_proxy_start(unsigned int interface_index, const struct in_addr servers[2],
                               uint16_t upstream_port, uint16_t *local_port);
void vpn_dns_proxy_stop(struct vpn_dns_proxy *resolver);

#endif
