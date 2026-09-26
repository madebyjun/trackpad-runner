#include "CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>

_Static_assert(sizeof(MTFinger) == 96, "MTFinger layout mismatch");

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(void *, MTContactCallback);
typedef void (*MTDeviceStartFn)(void *, int);
typedef CFTypeRef (*MTDeviceGetMTActuatorFn)(void *);
typedef int (*MTActuatorOpenFn)(CFTypeRef);
typedef CFTypeRef (*MTActuationCreateFromDictionaryFn)(CFDictionaryRef, int);
typedef int (*MTActuationActuateFn)(CFTypeRef, CFTypeRef, int);

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

// BTT と同じく、デバイスのアクチュエータを開いて MTActuation を鳴らす。
static int open_actuators(CFTypeRef *out) {
    static CFTypeRef actuators[MAX_ACTUATORS];
    static int opened = -1;
    if (opened < 0) {
        CFArrayRef list = device_list();
        void *h = framework();
        if (!list || !h) return -1;
        MTDeviceGetMTActuatorFn get = (MTDeviceGetMTActuatorFn)dlsym(h, "MTDeviceGetMTActuator");
        MTActuatorOpenFn open = (MTActuatorOpenFn)dlsym(h, "MTActuatorOpen");
        if (!get || !open) return -1;
        opened = 0;
        CFIndex n = CFArrayGetCount(list);
        for (CFIndex i = 0; i < n && opened < MAX_ACTUATORS; i++) {
            CFTypeRef actuator = get((void *)CFArrayGetValueAtIndex(list, i));
            if (!actuator) continue; // Force Touch 非対応のトラックパッド
            if (open(actuator) != 0) continue;
            CFRetain(actuator);
            actuators[opened++] = actuator;
        }
    }
    for (int i = 0; i < opened; i++) out[i] = actuators[i];
    return opened;
}

CFTypeRef cmt_actuation_create(CFDictionaryRef waveform) {
    void *h = framework();
    if (!h) return NULL;
    MTActuationCreateFromDictionaryFn create = (MTActuationCreateFromDictionaryFn)dlsym(h, "MTActuationCreateFromDictionary");
    return create ? create(waveform, 0) : NULL;
}

int cmt_actuation_play(CFTypeRef actuation) {
    void *h = framework();
    if (!h || !actuation) return -1;
    MTActuationActuateFn actuate = (MTActuationActuateFn)dlsym(h, "MTActuationActuate");
    if (!actuate) return -1;
    CFTypeRef actuators[MAX_ACTUATORS];
    int n = open_actuators(actuators);
    if (n < 0) return -1;
    int count = 0;
    for (int i = 0; i < n; i++) {
        // 第3引数の 6 は BTT が渡している値
        if (actuate(actuation, actuators[i], 6) == 0) count++;
    }
    return count;
}
