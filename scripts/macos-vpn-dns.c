/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#include "macos-vpn-dns.h"
#include "vpn-dns-proxy.h"

#include <arpa/inet.h>
#include <net/if.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct macos_vpn_dns {
    SCDynamicStoreRef store;
    struct vpn_dns_proxy *proxy;
};

static Boolean is_server_address(struct in_addr address)
{
    return address.s_addr != INADDR_ANY && address.s_addr != INADDR_NONE;
}

static Boolean can_route_to_server(unsigned int interface_index, struct in_addr address)
{
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0)
        return false;

    struct sockaddr_in peer = {
        .sin_len = sizeof(peer),
        .sin_family = AF_INET,
        .sin_port = htons(53),
        .sin_addr = address,
    };
    // UDP connect checks route selection without sending a DNS request.
    Boolean routed = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interface_index,
                               sizeof(interface_index)) == 0 &&
                     connect(fd, (const struct sockaddr *)&peer, sizeof(peer)) == 0;
    close(fd);
    return routed;
}

static Boolean append_server(CFMutableArrayRef servers, unsigned int interface_index,
                             struct in_addr address)
{
    if (!is_server_address(address) || !can_route_to_server(interface_index, address))
        return true;

    char buffer[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &address, buffer, sizeof(buffer)) == NULL)
        return false;
    CFStringRef server = CFStringCreateWithCString(NULL, buffer, kCFStringEncodingASCII);
    if (server == NULL)
        return false;

    if (!CFArrayContainsValue(servers, CFRangeMake(0, CFArrayGetCount(servers)), server))
        CFArrayAppendValue(servers, server);
    CFRelease(server);
    return true;
}

static Boolean append_ipv6_server(CFMutableArrayRef servers, const char *interface,
                                  unsigned int interface_index, const struct in6_addr *address)
{
    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0)
        return true;

    Boolean link_local = IN6_IS_ADDR_LINKLOCAL(address);
    struct sockaddr_in6 peer = {
        .sin6_len = sizeof(peer),
        .sin6_family = AF_INET6,
        .sin6_port = htons(53),
        .sin6_addr = *address,
        .sin6_scope_id = link_local ? interface_index : 0,
    };
    Boolean routed = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &interface_index,
                               sizeof(interface_index)) == 0 &&
                     connect(fd, (const struct sockaddr *)&peer, sizeof(peer)) == 0;
    close(fd);
    if (!routed)
        return true;

    char buffer[INET6_ADDRSTRLEN];
    if (inet_ntop(AF_INET6, address, buffer, sizeof(buffer)) == NULL)
        return false;
    CFStringRef ip = CFStringCreateWithCString(NULL, buffer, kCFStringEncodingASCII);
    if (ip == NULL)
        return false;
    CFStringRef server = ip;
    if (link_local)
        server = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@%%%s"), ip, interface);
    if (server != NULL) {
        if (!CFArrayContainsValue(servers, CFRangeMake(0, CFArrayGetCount(servers)), server))
            CFArrayAppendValue(servers, server);
        if (server != ip)
            CFRelease(server);
    }
    CFRelease(ip);
    return server != NULL;
}

static void append_domains(CFMutableArrayRef domains, const char *suffixes)
{
    // An empty supplemental match applies to ordinary queries for any domain.
    CFArrayAppendValue(domains, CFSTR(""));
    if (suffixes == NULL)
        return;

    char *copy = strdup(suffixes);
    if (copy == NULL)
        return;
    char *state;
    for (char *suffix = strtok_r(copy, "; \t\r\n", &state); suffix != NULL;
         suffix = strtok_r(NULL, "; \t\r\n", &state)) {
        CFStringRef domain = CFStringCreateWithCString(NULL, suffix, kCFStringEncodingUTF8);
        if (domain == NULL)
            continue;
        if (!CFArrayContainsValue(domains, CFRangeMake(0, CFArrayGetCount(domains)), domain))
            CFArrayAppendValue(domains, domain);
        CFRelease(domain);
    }
    free(copy);
}

static CFDictionaryRef create_configuration(CFArrayRef servers, CFStringRef service,
                                            const char *interface, const char *suffixes,
                                            uint16_t port)
{
    CFMutableArrayRef domains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef orders = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFStringRef ifname = port ? NULL : CFStringCreateWithCString(NULL, interface, kCFStringEncodingASCII);
    int server_port = port;
    CFNumberRef port_number = port ? CFNumberCreate(NULL, kCFNumberIntType, &server_port) : NULL;
    // Lower orders take precedence over the standard default resolver (200000).
    int order = 10000;
    CFNumberRef priority = CFNumberCreate(NULL, kCFNumberIntType, &order);
    CFDictionaryRef configuration = NULL;

    if (domains != NULL && orders != NULL && (ifname || port_number) && priority != NULL) {
        append_domains(domains, suffixes);
        for (CFIndex i = 0; i < CFArrayGetCount(domains); i++)
            CFArrayAppendValue(orders, priority);
        CFMutableDictionaryRef settings = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (settings != NULL) {
            CFDictionarySetValue(settings, kSCPropNetDNSServerAddresses, servers);
            CFDictionarySetValue(settings, kSCPropNetDNSSupplementalMatchDomains, domains);
            CFDictionarySetValue(settings, kSCPropNetDNSSupplementalMatchOrders, orders);
            if (port_number != NULL) {
                // Loopback queries reach the proxy, which binds upstream sockets to the VPN.
                CFDictionarySetValue(settings, CFSTR("ServerPort"), port_number);
            } else {
                CFDictionarySetValue(settings, kSCPropInterfaceName, ifname);
                // configd uses this state field to honor InterfaceName for VPN DNS.
                CFDictionarySetValue(settings, CFSTR("ConfirmedServiceID"), service);
            }
            configuration = settings;
        }
    }
    if (priority != NULL)
        CFRelease(priority);
    if (port_number != NULL)
        CFRelease(port_number);
    if (ifname != NULL)
        CFRelease(ifname);
    if (orders != NULL)
        CFRelease(orders);
    if (domains != NULL)
        CFRelease(domains);
    return configuration;
}

static CFStringRef create_service_id(void)
{
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    if (uuid == NULL)
        return NULL;
    CFStringRef service = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return service;
}

static SCDynamicStoreRef publish_dns(CFStringRef service, CFDictionaryRef configuration)
{
    CFStringRef key = SCDynamicStoreKeyCreateNetworkServiceEntity(
        NULL, kSCDynamicStoreDomainState, service, kSCEntNetDNS);
    if (key == NULL)
        return NULL;
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("dFortiClient VPN DNS"), NULL, NULL);
    if (store != NULL && !SCDynamicStoreAddTemporaryValue(store, key, configuration)) {
        CFRelease(store);
        store = NULL;
    }
    CFRelease(key);
    return store;
}

static bool publish_ipv4_preference(struct macos_vpn_dns *session, CFStringRef service,
                                    const char *interface, unsigned int interface_index,
                                    const char *suffixes, struct in_addr primary,
                                    struct in_addr secondary)
{
    struct in_addr addresses[] = {primary, secondary};
    for (size_t i = 0; i < 2; i++) {
        if (!is_server_address(addresses[i]) || !can_route_to_server(interface_index, addresses[i]))
            addresses[i].s_addr = INADDR_ANY;
    }
    if (addresses[0].s_addr == addresses[1].s_addr)
        addresses[1].s_addr = INADDR_ANY;
    if (!addresses[0].s_addr && !addresses[1].s_addr)
        return false;

    uint16_t port;
    session->proxy = vpn_dns_proxy_start(interface_index, addresses, 53, &port);
    if (session->proxy == NULL)
        return false;
    const void *loopback = CFSTR("127.0.0.1");
    CFArrayRef servers = CFArrayCreate(NULL, &loopback, 1, &kCFTypeArrayCallBacks);
    CFDictionaryRef config = NULL;
    if (servers != NULL) {
        config = create_configuration(servers, service, interface, suffixes, port);
        CFRelease(servers);
    }
    if (config != NULL) {
        session->store = publish_dns(service, config);
        CFRelease(config);
    }
    if (session->store != NULL)
        return true;
    vpn_dns_proxy_stop(session->proxy);
    session->proxy = NULL;
    return false;
}

enum macos_vpn_dns_result macos_vpn_dns_register(struct macos_vpn_dns **session,
                                                const char *interface, struct in_addr primary,
                                                struct in_addr secondary, const char *suffixes,
                                                const struct in6_addr *ipv6, size_t ipv6_count,
                                                bool prefer_ipv4)
{
    if (*session != NULL)
        return MACOS_VPN_DNS_ERROR;
    if (!is_server_address(primary) && !is_server_address(secondary) && ipv6_count == 0)
        return MACOS_VPN_DNS_NO_SERVERS;
    unsigned int interface_index = if_nametoindex(interface);
    if (interface_index == 0)
        return MACOS_VPN_DNS_NO_ROUTE;

    enum macos_vpn_dns_result result = MACOS_VPN_DNS_ERROR;
    CFMutableArrayRef servers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFStringRef service = NULL;
    CFDictionaryRef configuration = NULL;
    struct macos_vpn_dns *dns = calloc(1, sizeof(*dns));

    if (dns == NULL || servers == NULL || !append_server(servers, interface_index, primary) ||
        !append_server(servers, interface_index, secondary))
        goto done;
    for (size_t i = 0; i < ipv6_count; ++i)
        if (!append_ipv6_server(servers, interface, interface_index, &ipv6[i]))
            goto done;
    if (CFArrayGetCount(servers) == 0) {
        result = MACOS_VPN_DNS_NO_ROUTE;
        goto done;
    }

    service = create_service_id();
    if (service == NULL)
        goto done;
    if (prefer_ipv4 && ipv6_count == 0 &&
        publish_ipv4_preference(dns, service, interface, interface_index, suffixes, primary, secondary)) {
        result = MACOS_VPN_DNS_IPV4_PREFERRED;
        goto done;
    }
    configuration = create_configuration(servers, service, interface, suffixes, 0);
    if (configuration == NULL)
        goto done;
    dns->store = publish_dns(service, configuration);
    if (dns->store != NULL)
        result = MACOS_VPN_DNS_REGISTERED;

done:
    if (dns != NULL && dns->store != NULL)
        *session = dns;
    else
        free(dns);
    if (configuration != NULL)
        CFRelease(configuration);
    if (service != NULL)
        CFRelease(service);
    if (servers != NULL)
        CFRelease(servers);
    return result;
}

void macos_vpn_dns_unregister(struct macos_vpn_dns **session)
{
    struct macos_vpn_dns *dns = *session;
    if (dns == NULL)
        return;
    // configd removes the temporary value when this session closes.
    CFRelease(dns->store);
    if (dns->proxy != NULL)
        vpn_dns_proxy_stop(dns->proxy);
    free(dns);
    *session = NULL;
}
