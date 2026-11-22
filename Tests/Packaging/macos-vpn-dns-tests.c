#include "macos-vpn-dns.h"
#include "ipv4-dns.h"

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
static int resolver_starts;
static int resolver_stops;
static struct ipv4_dns { int unused; } test_resolver;

const char *const ipv4_dns_domains[] = {"chatgpt.com", "openai.com", NULL};

struct ipv4_dns *ipv4_dns_start(unsigned int interface, const struct in_addr servers[2],
                               uint16_t upstream_port, uint16_t *local_port)
{
    assert(interface == 7 && upstream_port == 53);
    assert(servers[0].s_addr == INADDR_ANY && servers[1].s_addr != INADDR_ANY);
    *local_port = 49152;
    resolver_starts++;
    return &test_resolver;
}

void ipv4_dns_stop(struct ipv4_dns *resolver)
{
    assert(resolver == &test_resolver);
    resolver_stops++;
}

unsigned int test_if_nametoindex(const char *interface)
{
    assert(strcmp(interface, "ppp0") == 0 || strcmp(interface, "ppp1") == 0);
    return 7;
}

int test_setsockopt(int socket, int level, int option, const void *value, socklen_t length)
{
    assert(socket >= 0 && level == IPPROTO_IP && option == IP_BOUND_IF);
    assert(length == sizeof(unsigned int) && *(const unsigned int *)value == 7);
    return 0;
}

int test_connect(int socket, const struct sockaddr *peer, socklen_t length)
{
    assert(socket >= 0 && length == sizeof(struct sockaddr_in));
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
    SCDynamicStoreRef session = NULL;
    assert(macos_vpn_dns_register(&session, "ppp0", none, none, NULL) == MACOS_VPN_DNS_NO_SERVERS);
    assert(session == NULL && create_count == 0 && add_count == 0);
    macos_vpn_dns_unregister(&session);
    unrouted_server = primary;
    assert(macos_vpn_dns_register(&session, "ppp0", primary, none, NULL) == MACOS_VPN_DNS_NO_ROUTE);
    assert(session == NULL && create_count == 0 && add_count == 0);
    unrouted_server = none;

    assert(macos_vpn_dns_register(&session, "ppp0", primary, secondary,
                                  "example.test;  branch.test\texample.test") ==
           MACOS_VPN_DNS_REGISTERED);
    assert(session == created_store && create_count == 1 && add_count == 1);
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
    assert(macos_vpn_dns_register(&session, "ppp1", primary, secondary, NULL) == MACOS_VPN_DNS_ERROR);
    assert(session == NULL && create_count == 2 && add_count == 2);
    reject_registration = false;

    unrouted_server = primary;
    assert(macos_vpn_dns_register(&session, "ppp1", primary, secondary, NULL) ==
           MACOS_VPN_DNS_REGISTERED);
    assert(!CFEqual(saved_key, previous_key));
    assert(CFEqual(CFDictionaryGetValue(saved_configuration, kSCPropInterfaceName), CFSTR("ppp1")));
    servers = assert_array(kSCPropNetDNSServerAddresses, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("192.0.2.54")));
    assert_array(kSCPropNetDNSSupplementalMatchDomains, 1);
    macos_vpn_dns_unregister(&session);
    assert(session == NULL);

    struct macos_ipv4_dns *ipv4 = macos_ipv4_dns_register("ppp1", primary, secondary);
    assert(ipv4 != NULL && resolver_starts == 1 && resolver_stops == 0);
    servers = assert_array(kSCPropNetDNSServerAddresses, 1);
    assert(CFEqual(CFArrayGetValueAtIndex(servers, 0), CFSTR("127.0.0.1")));
    domains = assert_array(kSCPropNetDNSSupplementalMatchDomains, 2);
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 0), CFSTR("chatgpt.com")));
    assert(CFEqual(CFArrayGetValueAtIndex(domains, 1), CFSTR("openai.com")));
    orders = assert_array(kSCPropNetDNSSupplementalMatchOrders, 2);
    int port, order, no_search;
    assert(CFNumberGetValue(CFDictionaryGetValue(saved_configuration, CFSTR("ServerPort")),
                            kCFNumberIntType, &port) && port == 49152);
    assert(CFNumberGetValue(CFArrayGetValueAtIndex(orders, 0), kCFNumberIntType, &order));
    assert(order > 0 && order < 10000);
    assert(CFNumberGetValue(CFDictionaryGetValue(saved_configuration, CFSTR("SupplementalMatchDomainsNoSearch")),
                            kCFNumberIntType, &no_search) && no_search == 1);
    assert(!CFDictionaryContainsKey(saved_configuration, kSCPropInterfaceName));
    macos_ipv4_dns_unregister(ipv4);
    assert(resolver_stops == 1);

    reject_registration = true;
    assert(macos_ipv4_dns_register("ppp1", primary, secondary) == NULL);
    assert(resolver_starts == 2 && resolver_stops == 2);
    macos_ipv4_dns_unregister(NULL);

    CFRelease(previous_key);
    CFRelease(saved_key);
    CFRelease(saved_configuration);
    puts("Verified temporary macOS VPN DNS registration and reconnect handling");
    return 0;
}
