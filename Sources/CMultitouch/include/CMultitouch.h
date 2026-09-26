#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <CoreFoundation/CoreFoundation.h>

// MultitouchSupport.framework (private) の最小限の宣言。
// 公開ヘッダが無いため、広く知られているレイアウトに合わせている。

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;      // 4 = makeTouch, 5 = touching, 6 = breakTouch など
    int fingerId;
    int handId;
    MTVector normalized; // 0..1、原点は左下
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int zero2[2];
    float density;
} MTFinger;

typedef int (*MTContactCallback)(void *device, MTFinger *fingers, int count, double timestamp, int frame);

// MultitouchSupport を読み込み、全トラックパッドにコールバックを登録して開始する。
// 戻り値: 開始したデバイス数。フレームワークが読み込めない場合は -1。
int cmt_start(MTContactCallback callback);

// デバイス数を返す（開始はしない）。フレームワークが読み込めない場合は -1。
int cmt_device_count(void);

// 波形の辞書から振動オブジェクトを作る（MTActuationCreateFromDictionary）。失敗時は NULL。
// 辞書の形式は BTT のカスタムハプティックと同じ（ActuationID / BaseWaveform / BaseMultipliers / Tones / ToneMultipliers）。
CFTypeRef cmt_actuation_create(CFDictionaryRef waveform);

// 振動オブジェクトを1回鳴らす（MTActuationActuate）。
// device にはフレームのコールバックで受け取ったデバイスを渡す（BTT と同じく、直前に触っていたトラックパッドだけを鳴らす）。
// NULL なら全トラックパッドで鳴らす。
// 戻り値: 鳴らしたデバイス数。フレームワークが読み込めない場合は -1。
int cmt_actuation_play(CFTypeRef actuation, void *device);

#endif
