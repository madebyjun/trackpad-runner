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
// 末尾の2つの float は波形計算に渡される（s0 = 倍率、s1 = 長さ）。BTT の呼び出しでは 0 になっている
typedef int (*MTActuationActuateFn)(CFTypeRef, CFTypeRef, uint32_t, float, float);

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

// MTRegisterButtonStateCallback のコールバックは (device?, state) を受け取るが、第1引数の意味は保証がない
// （BTT も使っていない）。デバイスごとに別の関数を登録して、どのトラックパッドかを確実に区別する。
#define MAX_BUTTON_DEVICES 8
static CMTButtonCallback button_callback = NULL;
static void *button_devices[MAX_BUTTON_DEVICES];

#define BUTTON_TRAMPOLINE(i) \
    static int button_trampoline_##i(void *unused, int state) { \
        (void)unused; \
        if (button_callback) button_callback(button_devices[i], state); \
        return 0; \
    }
BUTTON_TRAMPOLINE(0) BUTTON_TRAMPOLINE(1) BUTTON_TRAMPOLINE(2) BUTTON_TRAMPOLINE(3)
BUTTON_TRAMPOLINE(4) BUTTON_TRAMPOLINE(5) BUTTON_TRAMPOLINE(6) BUTTON_TRAMPOLINE(7)

typedef int (*MTButtonStateCallback)(void *, int);
static const MTButtonStateCallback button_trampolines[MAX_BUTTON_DEVICES] = {
    button_trampoline_0, button_trampoline_1, button_trampoline_2, button_trampoline_3,
    button_trampoline_4, button_trampoline_5, button_trampoline_6, button_trampoline_7,
};

typedef void (*MTRegisterButtonStateCallbackFn)(void *, MTButtonStateCallback);

int cmt_start(MTContactCallback callback, CMTButtonCallback button) {
    CFArrayRef list = device_list();
    if (!list) return -1;
    void *h = framework();
    MTRegisterContactFrameCallbackFn reg = (MTRegisterContactFrameCallbackFn)dlsym(h, "MTRegisterContactFrameCallback");
    MTRegisterButtonStateCallbackFn regButton = (MTRegisterButtonStateCallbackFn)dlsym(h, "MTRegisterButtonStateCallback");
    MTDeviceStartFn start = (MTDeviceStartFn)dlsym(h, "MTDeviceStart");
    if (!reg || !start || (button && !regButton)) return -1;
    button_callback = button;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        void *device = (void *)CFArrayGetValueAtIndex(list, i);
        reg(device, callback);
        if (button && i < MAX_BUTTON_DEVICES) {
            button_devices[i] = device;
            regButton(device, button_trampolines[i]);
        }
        start(device, 0);
    }
    return (int)n;
}

#define MAX_ACTUATORS 8

static struct { void *device; CFTypeRef actuator; } actuators[MAX_ACTUATORS];
static int actuator_count = -1;

// 全デバイスのアクチュエータを一度だけ開いておく。
static int open_actuators(void) {
    if (actuator_count >= 0) return actuator_count;
    CFArrayRef list = device_list();
    void *h = framework();
    if (!list || !h) return -1;
    MTDeviceGetMTActuatorFn get = (MTDeviceGetMTActuatorFn)dlsym(h, "MTDeviceGetMTActuator");
    MTActuatorOpenFn open = (MTActuatorOpenFn)dlsym(h, "MTActuatorOpen");
    if (!get || !open) return -1;
    actuator_count = 0;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n && actuator_count < MAX_ACTUATORS; i++) {
        void *device = (void *)CFArrayGetValueAtIndex(list, i);
        CFTypeRef actuator = get(device);
        if (!actuator) continue; // Force Touch 非対応のトラックパッド
        if (open(actuator) != 0) continue;
        CFRetain(actuator);
        actuators[actuator_count].device = device;
        actuators[actuator_count].actuator = actuator;
        actuator_count++;
    }
    return actuator_count;
}

CFTypeRef cmt_actuation_create(CFDictionaryRef waveform) {
    void *h = framework();
    if (!h) return NULL;
    MTActuationCreateFromDictionaryFn create = (MTActuationCreateFromDictionaryFn)dlsym(h, "MTActuationCreateFromDictionary");
    return create ? create(waveform, 0) : NULL;
}

int cmt_actuation_play(CFTypeRef actuation, void *device) {
    static MTActuationActuateFn actuate = NULL;
    void *h = framework();
    if (!h || !actuation) return -1;
    if (!actuate) actuate = (MTActuationActuateFn)dlsym(h, "MTActuationActuate");
    if (!actuate || open_actuators() < 0) return -1;
    int count = 0;
    for (int i = 0; i < actuator_count; i++) {
        if (device && actuators[i].device != device) continue;
        // 6 は Medium を選ぶフラグ。float 2つは BTT と同じく 0
        if (actuate(actuation, actuators[i].actuator, 6, 0.0f, 0.0f) == 0) count++;
    }
    return count;
}
