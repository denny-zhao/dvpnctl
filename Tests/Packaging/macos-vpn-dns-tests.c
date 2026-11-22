#include "macos-vpn-dns.h"
#include "vpn-dns-proxy.h"

#include <arpa/inet.h>
#include <assert.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

static CFStringRef saved_key;
static CFDictionaryRef saved_configuration;
static SCDynamicStoreRef created_store;
static int create_count;
static int add_count;
static Boolean reject_registration;
static struct in_addr unrouted_server;
static struct vpn_dns_proxy { int placeholder; } proxy;
static bool reject_proxy_start;
static int proxy_attempts;
static int proxy_stops;

struct vpn_dns_proxy *vpn_dns_proxy_start(unsigned int interface_index,
                                           const struct in_addr servers[2],
                                           uint16_t upstream_port, uint16_t *local_port)
{
    assert(interface_index == 7 && upstream_port == 53);
    assert(servers[0].s_addr != INADDR_ANY || servers[1].s_addr != INADDR_ANY);
    proxy_attempts++;
    if (reject_proxy_start) return NULL;
    *local_port = 49152;
    return &proxy;
}

void vpn_dns_proxy_stop(struct vpn_dns_proxy *instance)
{
    assert(instance == &proxy);
    proxy_stops++;
}

unsigned int test_if_nametoindex(const char *interface)
{
    assert(strcmp(interface, "ppp0") == 0 || strcmp(interface, "ppp1") == 0);
    return 7;
}

int test_setsockopt(int socket, int level, int option, const void *value, socklen_t length)
{
    assert(socket >= 0);
    assert((level == IPPROTO_IP && option == IP_BOUND_IF) ||
           (level == IPPROTO_IPV6 && option == IPV6_BOUND_IF));
    assert(length == sizeof(unsigned int) && *(const unsigned int *)value == 7);
    return 0;
}

int test_connect(int socket, const struct sockaddr *peer, socklen_t length)
{
    assert(socket >= 0);
    if (peer->sa_family == AF_INET6) {
        assert(length == sizeof(struct sockaddr_in6));
        const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)peer;
        assert(ntohs(ipv6->sin6_port) == 53 && ipv6->sin6_scope_id == 7);
        return 0;
    }
    assert(length == sizeof(struct sockaddr_in));
    const struct sockaddr_in *server = (const struct sockaddr_in *)peer;
    assert(server->sin_family == AF_INET && ntohs(server->sin_port) == 53);
    return server->sin_addr.s_addr == unrouted_server.s_addr ? -1 : 0;
}

SCDynamicStoreRef test_store_create(CFAllocatorRef allocator, CFStringRef name,
                                   SCDynamicStoreCallBack callback,
                                   SCDynamicStoreContext *context)
{
    assert(name != NULL && callback == NULL && context == NULL);
    create_count++;
    // A real CF object lets the production teardown use CFRelease.
    created_store = (SCDynamicStoreRef)CFStringCreateMutable(allocator, 0);
    return created_store;
}

Boolean test_store_add(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
    assert(store == created_store);
    add_count++;
    if (reject_registration)
        return false;
    if (saved_key != NULL) {
        CFRelease(saved_key);
        CFRelease(saved_configuration);
    }
    saved_key = CFRetain(key);
    saved_configuration = CFRetain(value);
    return true;
}

static struct in_addr address(const char *value)
{
    struct in_addr result;
    assert(inet_pton(AF_INET, value, &result) == 1);
    return result;
}

static CFArrayRef assert_array(CFStringRef key, CFIndex count)
{
    CFArrayRef array = CFDictionaryGetValue(saved_configuration, key);
    assert(array != NULL && CFGetTypeID(array) == CFArrayGetTypeID());
    assert(CFArrayGetCount(array) == count);
    return array;
}

int main(void)
{
    struct in_addr none = {0};
    struct in_addr primary = address("192.0.2.53");
    struct in_addr secondary = address("192.0.2.54");
    struct macos_vpn_dns *session = NULL;
    assert(macos_vpn_dns_register(&session, "ppp0", none, none, NULL, NULL, 0, false) == MACOS_VPN_DNS_NO_SERVERS);
    assert(session == NULL && create_count == 0 && add_count == 0);
    macos_vpn_dns_unregister(&session);
    unrouted_server = primary;
    assert(macos_vpn_dns_register(&session, "ppp0", primary, none, NULL, NULL, 0, false) == MACOS_VPN_DNS_NO_ROUTE);
    assert(session == NULL && create_count == 0 && add_count == 0);
    unrouted_server = none;

    assert(macos_vpn_dns_register(&session, "ppp0", primary, secondary,
                                  "example.test;  branch.test\texample.test", NULL, 0, false) ==
           MACOS_VPN_DNS_REGISTERED);
    assert(session != NULL && create_count == 1 && add_count == 1);
    CFStringRef service = CFDictionaryGetValue(saved_configuration, CFSTR("ConfirmedServiceID"));
    assert(service != NULL);
    CFStringRef expected_key = SCDynamicStoreKeyCreateNetworkServiceEntity(
        NULL, kSCDynamicStoreDomainState, service, kSCEntNetDNS);
    assert(CFEqual(saved_key, expected_key));
    CFRelease(expected_key);
    assert(CFEqual(CFDictionaryGetValue(saved_configuration, kSCPropInterfaceName), CFSTR("ppp0")));

    CFArrayRef servers = assert_array(kSCPropNetDNSServerAddresses, 2);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("192.0.2.53")));
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 1), CFSTR("192.0.2.54")));
    CFArrayRef domains = assert_array(kSCPropNetDNSSupplementalMatchDomains, 3);
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 0), CFSTR("")));
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 1), CFSTR("example.test")));
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 2), CFSTR("branch.test")));
    CFArrayRef orders = assert_array(kSCPropNetDNSSupplementalMatchOrders, 3);
    for (CFIndex index = 0; index < CFArrayGetCount(orders); index++) {
        int order;
        assert(CFNumberGetValue(CFArrayGetValueAtIndex(orders, index), kCFNumberIntType, &order));
        assert(order > 0 && order < 200000);
    }
    CFStringRef previous_key = CFRetain(saved_key);
    macos_vpn_dns_unregister(&session);
    assert(session == NULL);
    macos_vpn_dns_unregister(&session);

    reject_registration = true;
    assert(macos_vpn_dns_register(&session, "ppp1", primary, secondary, NULL, NULL, 0, false) == MACOS_VPN_DNS_ERROR);
    assert(session == NULL && create_count == 2 && add_count == 2);
    reject_registration = false;

    unrouted_server = primary;
    assert(macos_vpn_dns_register(&session, "ppp1", primary, secondary, NULL, NULL, 0, false) ==
           MACOS_VPN_DNS_REGISTERED);
    assert(!CFEqual(saved_key, previous_key));
    assert(CFEqual(CFDictionaryGetValue(saved_configuration, kSCPropInterfaceName), CFSTR("ppp1")));
    servers = assert_array(kSCPropNetDNSServerAddresses, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("192.0.2.54")));
    assert_array(kSCPropNetDNSSupplementalMatchDomains, 1);
    macos_vpn_dns_unregister(&session);
    assert(session == NULL);

    struct in6_addr ipv6_server;
    assert(inet_pton(AF_INET6, "fe80::53", &ipv6_server) == 1);
    assert(macos_vpn_dns_register(&session, "ppp1", none, none, NULL, &ipv6_server, 1, true) ==
           MACOS_VPN_DNS_REGISTERED);
    servers = assert_array(kSCPropNetDNSServerAddresses, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("fe80::53%ppp1")));
    macos_vpn_dns_unregister(&session);

    assert(macos_vpn_dns_register(&session, "ppp1", secondary, none,
                                  "example.test", &ipv6_server, 1, true) == MACOS_VPN_DNS_REGISTERED);
    servers = assert_array(kSCPropNetDNSServerAddresses, 2);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("192.0.2.54")));
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 1), CFSTR("fe80::53%ppp1")));
    domains = assert_array(kSCPropNetDNSSupplementalMatchDomains, 2);
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 0), CFSTR("")));
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 1), CFSTR("example.test")));
    assert(!CFDictionaryContainsKey(saved_configuration, CFSTR("ServerPort")));
    macos_vpn_dns_unregister(&session);
    assert(session == NULL);

    assert(proxy_attempts == 0);
    assert(macos_vpn_dns_register(&session, "ppp1", secondary, none, NULL, NULL, 0, true) ==
           MACOS_VPN_DNS_IPV4_PREFERRED);
    servers = assert_array(kSCPropNetDNSServerAddresses, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("127.0.0.1")));
    domains = assert_array(kSCPropNetDNSSupplementalMatchDomains, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 0), CFSTR("")));
    int port;
    CFNumberRef port_value = CFDictionaryGetValue(saved_configuration, CFSTR("ServerPort"));
    assert(port_value && CFNumberGetValue(port_value, kCFNumberIntType, &port) && port == 49152);
    assert(!CFDictionaryContainsKey(saved_configuration, kSCPropInterfaceName));
    macos_vpn_dns_unregister(&session);
    macos_vpn_dns_unregister(&session);
    assert(proxy_attempts == 1 && proxy_stops == 1);

    reject_proxy_start = true;
    assert(macos_vpn_dns_register(&session, "ppp1", secondary, none, NULL, NULL, 0, true) ==
           MACOS_VPN_DNS_REGISTERED);
    servers = assert_array(kSCPropNetDNSServerAddresses, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("192.0.2.54")));
    assert(proxy_attempts == 2 && proxy_stops == 1);
    macos_vpn_dns_unregister(&session);

    CFRelease(previous_key);
    CFRelease(saved_key);
    CFRelease(saved_configuration);
    puts("Verified temporary macOS VPN DNS registration and reconnect handling");
    return 0;
}
