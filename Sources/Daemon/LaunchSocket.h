#include <launch.h>
#include <stdlib.h>
#include <unistd.h>

static inline int take_vpn_listener(void) {
    int *descriptors;
    size_t count;
    if (launch_activate_socket("VPNControl", &descriptors, &count) != 0) {
        return -1;
    }
    int listener = -1;
    if (count == 1) {
        listener = descriptors[0];
    } else {
        for (size_t index = 0; index < count; index++) {
            close(descriptors[index]);
        }
    }
    free(descriptors);
    return listener;
}
