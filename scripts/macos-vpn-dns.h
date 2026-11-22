/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#ifndef DFORTICLIENT_MACOS_VPN_DNS_H
#define DFORTICLIENT_MACOS_VPN_DNS_H

#include <netinet/in.h>
#include <SystemConfiguration/SystemConfiguration.h>

enum macos_vpn_dns_result {
    MACOS_VPN_DNS_REGISTERED,
    MACOS_VPN_DNS_NO_SERVERS,
    MACOS_VPN_DNS_NO_ROUTE,
    MACOS_VPN_DNS_ERROR,
};

enum macos_vpn_dns_result macos_vpn_dns_register(SCDynamicStoreRef *session,
                                                const char *interface, struct in_addr primary,
                                                struct in_addr secondary, const char *suffixes);
void macos_vpn_dns_unregister(SCDynamicStoreRef *session);

struct macos_ipv4_dns;
struct macos_ipv4_dns *macos_ipv4_dns_register(const char *interface, struct in_addr primary,
                                               struct in_addr secondary);
void macos_ipv4_dns_unregister(struct macos_ipv4_dns *session);

#endif
