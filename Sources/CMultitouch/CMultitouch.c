#include "CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

_Static_assert(sizeof(MTFinger) == 96, "MTFinger layout mismatch");

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(void *, MTContactCallback);
typedef void (*MTDeviceStartFn)(void *, int);

static void *framework(void) {
    static void *handle = NULL;
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    }
    return handle;
}

static CFArrayRef device_list(void) {
    static CFArrayRef list = NULL; // 生存させ続ける（解放するとコールバックが止まる）
    if (list) return list;
    void *h = framework();
    if (!h) return NULL;
    MTDeviceCreateListFn create = (MTDeviceCreateListFn)dlsym(h, "MTDeviceCreateList");
    if (!create) return NULL;
    list = create();
    return list;
}

int cmt_device_count(void) {
    CFArrayRef list = device_list();
    return list ? (int)CFArrayGetCount(list) : -1;
}

int cmt_start(MTContactCallback callback) {
    CFArrayRef list = device_list();
    if (!list) return -1;
    void *h = framework();
    MTRegisterContactFrameCallbackFn reg = (MTRegisterContactFrameCallbackFn)dlsym(h, "MTRegisterContactFrameCallback");
    MTDeviceStartFn start = (MTDeviceStartFn)dlsym(h, "MTDeviceStart");
    if (!reg || !start) return -1;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        void *device = (void *)CFArrayGetValueAtIndex(list, i);
        reg(device, callback);
        start(device, 0);
    }
    return (int)n;
}
