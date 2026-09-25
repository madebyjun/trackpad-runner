#include "CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>

_Static_assert(sizeof(MTFinger) == 96, "MTFinger layout mismatch");

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(void *, MTContactCallback);
typedef void (*MTDeviceStartFn)(void *, int);
typedef int (*MTDeviceGetDeviceIDFn)(void *, uint64_t *);
typedef CFTypeRef (*MTActuatorCreateFromDeviceIDFn)(uint64_t);
typedef int (*MTActuatorOpenFn)(CFTypeRef);
typedef int (*MTActuatorActuateFn)(CFTypeRef, int32_t, uint32_t, float, float);

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

#define MAX_ACTUATORS 8

int cmt_actuate(int actuationID) {
    static CFTypeRef actuators[MAX_ACTUATORS];
    static int opened = -1;
    static MTActuatorActuateFn actuate = NULL;

    CFArrayRef list = device_list();
    if (!list) return -1;
    void *h = framework();

    if (opened < 0) {
        MTDeviceGetDeviceIDFn getID = (MTDeviceGetDeviceIDFn)dlsym(h, "MTDeviceGetDeviceID");
        MTActuatorCreateFromDeviceIDFn create = (MTActuatorCreateFromDeviceIDFn)dlsym(h, "MTActuatorCreateFromDeviceID");
        MTActuatorOpenFn open = (MTActuatorOpenFn)dlsym(h, "MTActuatorOpen");
        actuate = (MTActuatorActuateFn)dlsym(h, "MTActuatorActuate");
        if (!getID || !create || !open || !actuate) return -1;
        opened = 0;
        CFIndex n = CFArrayGetCount(list);
        for (CFIndex i = 0; i < n && opened < MAX_ACTUATORS; i++) {
            uint64_t deviceID = 0;
            if (getID((void *)CFArrayGetValueAtIndex(list, i), &deviceID) != 0) continue;
            CFTypeRef actuator = create(deviceID);
            if (!actuator) continue; // Force Touch 非対応のトラックパッド
            if (open(actuator) != 0) { CFRelease(actuator); continue; }
            actuators[opened++] = actuator;
        }
    }

    int count = 0;
    for (int i = 0; i < opened; i++) {
        // 引数の 0 / 1.0 / 2.0 は HapticKey などで使われている値
        if (actuate(actuators[i], actuationID, 0, 1.0f, 2.0f) == 0) count++;
    }
    return count;
}
