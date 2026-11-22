/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#ifndef DFORTICLIENT_MACOS_VPN_DNS_H
#define DFORTICLIENT_MACOS_VPN_DNS_H

#include <stdbool.h>
#include <netinet/in.h>
#include <SystemConfiguration/SystemConfiguration.h>

enum macos_vpn_dns_result {
    MACOS_VPN_DNS_REGISTERED,
    MACOS_VPN_DNS_IPV4_PREFERRED,
    MACOS_VPN_DNS_NO_SERVERS,
    MACOS_VPN_DNS_NO_ROUTE,
    MACOS_VPN_DNS_ERROR,
};

struct macos_vpn_dns;

enum macos_vpn_dns_result macos_vpn_dns_register(struct macos_vpn_dns **session,
                                                const char *interface, struct in_addr primary,
                                                struct in_addr secondary, const char *suffixes,
                                                const struct in6_addr *ipv6, size_t ipv6_count,
                                                bool prefer_ipv4);
void macos_vpn_dns_unregister(struct macos_vpn_dns **session);

#endif
