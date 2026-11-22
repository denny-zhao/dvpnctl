/* GPL-3.0-or-later with the OpenFortiVPN exception in LICENSE.OpenSSL. */
#include "macos-vpn-dns.h"
#include "ipv4-dns.h"

#include <arpa/inet.h>
#include <net/if.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct macos_ipv4_dns {
    SCDynamicStoreRef store;
    struct ipv4_dns *resolver;
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
                                            const char *interface, const char *suffixes)
{
    CFMutableArrayRef domains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef orders = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFStringRef ifname = CFStringCreateWithCString(NULL, interface, kCFStringEncodingASCII);
    // Lower orders take precedence over the standard default resolver (200000).
    int order = 10000;
    CFNumberRef priority = CFNumberCreate(NULL, kCFNumberIntType, &order);
    CFDictionaryRef configuration = NULL;

    if (domains != NULL && orders != NULL && ifname != NULL && priority != NULL) {
        append_domains(domains, suffixes);
        for (CFIndex i = 0; i < CFArrayGetCount(domains); i++)
            CFArrayAppendValue(orders, priority);
        const void *keys[] = {
            kSCPropNetDNSServerAddresses, kSCPropNetDNSSupplementalMatchDomains,
            kSCPropNetDNSSupplementalMatchOrders, kSCPropInterfaceName,
            // configd uses this state field to honor InterfaceName for VPN DNS.
            CFSTR("ConfirmedServiceID"),
        };
        const void *values[] = {servers, domains, orders, ifname, service};
        configuration = CFDictionaryCreate(NULL, keys, values, sizeof(keys) / sizeof(keys[0]),
                                           &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    }
    if (priority != NULL)
        CFRelease(priority);
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

enum macos_vpn_dns_result macos_vpn_dns_register(SCDynamicStoreRef *session,
                                                const char *interface, struct in_addr primary,
                                                struct in_addr secondary, const char *suffixes)
{
    if (*session != NULL)
        return MACOS_VPN_DNS_ERROR;
    if (!is_server_address(primary) && !is_server_address(secondary))
        return MACOS_VPN_DNS_NO_SERVERS;
    unsigned int interface_index = if_nametoindex(interface);
    if (interface_index == 0)
        return MACOS_VPN_DNS_NO_ROUTE;

    enum macos_vpn_dns_result result = MACOS_VPN_DNS_ERROR;
    CFMutableArrayRef servers = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
    CFStringRef service = NULL;
    CFDictionaryRef configuration = NULL;

    if (servers == NULL || !append_server(servers, interface_index, primary) ||
        !append_server(servers, interface_index, secondary))
        goto done;
    if (CFArrayGetCount(servers) == 0) {
        result = MACOS_VPN_DNS_NO_ROUTE;
        goto done;
    }

    service = create_service_id();
    if (service == NULL)
        goto done;
    configuration = create_configuration(servers, service, interface, suffixes);
    if (configuration == NULL)
        goto done;
    *session = publish_dns(service, configuration);
    if (*session != NULL)
        result = MACOS_VPN_DNS_REGISTERED;

done:
    if (configuration != NULL)
        CFRelease(configuration);
    if (service != NULL)
        CFRelease(service);
    if (servers != NULL)
        CFRelease(servers);
    return result;
}

void macos_vpn_dns_unregister(SCDynamicStoreRef *session)
{
    if (*session != NULL) {
        // configd removes the temporary value when this session closes.
        CFRelease(*session);
        *session = NULL;
    }
}

static CFDictionaryRef create_ipv4_configuration(uint16_t local_port)
{
    CFMutableArrayRef domains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef orders = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    const void *loopback[] = {CFSTR("127.0.0.1")};
    CFArrayRef servers = CFArrayCreate(NULL, loopback, 1, &kCFTypeArrayCallBacks);
    int order = 1000;
    int no_search = 1;
    int port = local_port;
    CFNumberRef priority = CFNumberCreate(NULL, kCFNumberIntType, &order);
    CFNumberRef skip_search = CFNumberCreate(NULL, kCFNumberIntType, &no_search);
    CFNumberRef port_number = CFNumberCreate(NULL, kCFNumberIntType, &port);
    CFDictionaryRef configuration = NULL;
    if (domains == NULL || orders == NULL || servers == NULL || priority == NULL ||
        skip_search == NULL || port_number == NULL)
        goto done;

    for (size_t i = 0; ipv4_dns_domains[i] != NULL; i++) {
        CFStringRef domain = CFStringCreateWithCString(NULL, ipv4_dns_domains[i], kCFStringEncodingASCII);
        if (domain == NULL)
            goto done;
        CFArrayAppendValue(domains, domain);
        CFArrayAppendValue(orders, priority);
        CFRelease(domain);
    }
    const void *keys[] = {
        kSCPropNetDNSServerAddresses, kSCPropNetDNSSupplementalMatchDomains,
        kSCPropNetDNSSupplementalMatchOrders, CFSTR("ServerPort"),
        CFSTR("SupplementalMatchDomainsNoSearch"),
    };
    const void *values[] = {servers, domains, orders, port_number, skip_search};
    configuration = CFDictionaryCreate(NULL, keys, values, sizeof(keys) / sizeof(keys[0]),
                                       &kCFTypeDictionaryKeyCallBacks,
                                       &kCFTypeDictionaryValueCallBacks);
done:
    if (port_number != NULL)
        CFRelease(port_number);
    if (skip_search != NULL)
        CFRelease(skip_search);
    if (priority != NULL)
        CFRelease(priority);
    if (servers != NULL)
        CFRelease(servers);
    if (orders != NULL)
        CFRelease(orders);
    if (domains != NULL)
        CFRelease(domains);
    return configuration;
}

struct macos_ipv4_dns *macos_ipv4_dns_register(const char *interface, struct in_addr primary,
                                               struct in_addr secondary)
{
    unsigned int interface_index = if_nametoindex(interface);
    if (interface_index == 0)
        return NULL;
    struct in_addr addresses[] = {primary, secondary};
    for (size_t i = 0; i < 2; i++)
        if (!is_server_address(addresses[i]) || !can_route_to_server(interface_index, addresses[i]))
            addresses[i].s_addr = INADDR_ANY;
    if (addresses[1].s_addr == addresses[0].s_addr)
        addresses[1].s_addr = INADDR_ANY;
    if (addresses[0].s_addr == INADDR_ANY && addresses[1].s_addr == INADDR_ANY)
        return NULL;

    struct macos_ipv4_dns *session = calloc(1, sizeof(*session));
    if (session == NULL)
        return NULL;
    uint16_t port;
    session->resolver = ipv4_dns_start(interface_index, addresses, 53, &port);
    if (session->resolver == NULL)
        goto fail;
    CFStringRef service = create_service_id();
    if (service == NULL)
        goto fail;
    CFDictionaryRef configuration = create_ipv4_configuration(port);
    if (configuration != NULL) {
        session->store = publish_dns(service, configuration);
        CFRelease(configuration);
    }
    CFRelease(service);
    if (session->store != NULL)
        return session;

fail:
    macos_ipv4_dns_unregister(session);
    return NULL;
}

void macos_ipv4_dns_unregister(struct macos_ipv4_dns *session)
{
    if (session == NULL)
        return;
    macos_vpn_dns_unregister(&session->store);
    if (session->resolver != NULL)
        ipv4_dns_stop(session->resolver);
    free(session);
}
