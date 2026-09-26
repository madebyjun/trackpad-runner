#!/usr/bin/env python3
# e2e/fixtures/*.json を生成する。ケースを増やすときはここに追記して
#   python3 e2e/gen_fixtures.py e2e/fixtures
# を実行する。実機の入力は `trackpad-runner --record` で記録して fixtures に置いてもよい。
import json, os, sys
OUT = sys.argv[1]
STEP = 0.01

def finger(id, x, y, on, off, dx=0.0, dy=0.0, device=0, state=5):
    # dx,dy: on→off の間に線形に動く量
    return dict(id=id, x=x, y=y, on=on, off=off, dx=dx, dy=dy, device=device, state=state)

def build(fingers, mouse, end=None):
    end = end or max(f["off"] for f in fingers) + 0.05
    events = []
    devices = sorted({f["device"] for f in fingers})
    n = int(round(end / STEP))
    for i in range(n + 1):
        t = round(i * STEP, 4)
        for d in devices:
            touches = []
            for f in fingers:
                if f["device"] != d or not (f["on"] <= t < f["off"]):
                    continue
                p = (t - f["on"]) / max(f["off"] - f["on"], 1e-9)
                touches.append(dict(id=f["id"], x=round(f["x"] + f["dx"] * p, 4), y=round(f["y"] + f["dy"] * p, 4), state=f["state"]))
            e = dict(t=t, touches=touches)
            if d: e["device"] = d
            events.append(e)
    for t, kind in mouse:
        events.append(dict(t=t, mouse=kind))
    events.sort(key=lambda e: (e["t"], "mouse" in e))
    return events

cases = []
def case(file, name, fms, fingers, mouse, actions, decisions=None, events=None, triggers=(), timeline=None):
    exp = dict(actions=actions, triggers=list(triggers))
    if timeline is not None: exp["timeline"] = timeline
    if decisions is not None: exp["mouse"] = decisions
    cases.append((file, dict(name=name, failureModes=fms, events=events or build(fingers, mouse), expect=exp)))

P, C, S = "passThrough", "convertToMiddle", "swallow"
click = lambda a, b: [(a, "down"), (b, "up")]
anchors = lambda on=0.0, off=1.0, dx=0.0, dy=0.0: [finger(1, 0.55, 0.4, on, off, dx, dy), finger(2, 0.7, 0.4, on, off, dx, dy)]

# クリック系
case("click-1finger", "1本指クリックは素通り", [1], [finger(1, .5, .5, 0, .5)], click(.2, .3), [], [P, P])
case("click-2finger", "2本指クリックは素通り", [1], [finger(1, .45, .5, 0, .5), finger(2, .55, .5, 0, .5)], click(.2, .3), [], [P, P])
case("click-3finger", "3本指クリック → 中クリック（ハプティックは離したとき）", [2, 9], [finger(i, .3 + .1 * i, .5, 0, .5) for i in range(1, 4)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"], timeline=["down", "up", "trigger:threeFingerClick"])
case("click-4finger", "4本指クリック → ⇧⌘5（左クリックは握りつぶす。ハプティックと ⇧⌘5 は離したとき）", [3, 9], [finger(i, .2 + .1 * i, .5, 0, .5) for i in range(1, 5)], click(.2, .3), ["screenshotShortcut"], [S, S], triggers=["fourFingerClick"], timeline=["down", "up", "trigger:fourFingerClick", "action:screenshotShortcut"])
case("click-3finger-lift-before-up", "3本で押し、2本で離しても up は中クリックのまま", [4],
     [finger(1, .4, .5, 0, .5), finger(2, .5, .5, 0, .5), finger(3, .6, .5, 0, .25)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"])
case("click-2finger-add-before-up", "2本で押し、4本になってから離しても素通りのまま", [4],
     [finger(1, .4, .5, 0, .5), finger(2, .5, .5, 0, .5), finger(3, .6, .5, .25, .5), finger(4, .7, .5, .25, .5)], click(.2, .35), [], [P, P])
case("click-3finger-drag", "3本指で押したままドラッグ → dragged も中ボタンに", [5],
     [finger(i, .3 + .1 * i, .5, 0, .6, dx=.1) for i in range(1, 4)], [(.2, "down"), (.25, "dragged"), (.3, "dragged"), (.4, "up")], [], [C, C, C, C], triggers=["threeFingerClick"])
case("click-5finger", "5本指クリックは素通り", [6], [finger(i, .1 + .1 * i, .5, 0, .5) for i in range(1, 6)], click(.2, .3), [], [P, P])
case("click-3finger-one-hovering", "触れていない指（ホバー）は数えない", [7],
     [finger(1, .4, .5, 0, .5), finger(2, .5, .5, 0, .5), finger(3, .6, .5, 0, .5, state=3)], click(.2, .3), [], [P, P])
case("click-multi-device", "2台のトラックパッドに新しい接触がある（3本 + 1本）ときは判定せず素通り", [24, 27],
     [finger(i, .3 + .1 * i, .5, 0, .5) for i in range(1, 4)] + [finger(9, .5, .5, 0, .5, device=1)], click(.2, .3), [], [P, P])

# TipTap左
case("tiptap-left", "TipTap左 → 中クリック", [10], anchors() + [finger(3, .3, .4, .3, .4)], [], ["middleClick"], triggers=["tipTapLeft"])
case("tiptap-right", "右側のタップは発火しない", [11], anchors() + [finger(3, .85, .4, .3, .4)], [], [])
case("tiptap-long-press", "長押し（0.6秒）は発火しない", [12], anchors() + [finger(3, .3, .4, .2, .8)], [], [])
case("tiptap-moving-tap", "タップした指が動いた（スワイプ）場合は発火しない", [13], anchors() + [finger(3, .3, .4, .3, .45, dy=.15)], [], [])
case("tiptap-anchors-scrolling", "2本指スクロール中は発火しない（タップ中に固定側が 0.1 以上動く）", [14],
     [finger(1, .55, .05, 0, 1, dy=.9), finger(2, .7, .05, 0, 1, dy=.9), finger(3, .3, .4, .3, .5)], [], [])
case("tiptap-with-physical-click", "タップ中に物理クリック → 3本指クリックだけが効き、TipTap は発火しない", [15, 2],
     anchors() + [finger(3, .3, .4, .3, .45)], click(.35, .4), [], [C, C], triggers=["threeFingerClick"])
case("tiptap-anchors-jitter", "固定側がわずかに動いていても（0.1 未満）発火する", [14], anchors(dy=.2) + [finger(3, .3, .4, .3, .4)], [], ["middleClick"], triggers=["tipTapLeft"])
case("tiptap-one-anchor", "固定が1本のときは発火しない", [16], [finger(1, .6, .4, 0, 1), finger(3, .3, .4, .3, .4)], [], [])
case("tiptap-three-anchors", "固定が3本のときは発火しない", [16],
     anchors() + [finger(4, .8, .4, 0, 1), finger(3, .3, .4, .3, .4)], [], [])
case("tiptap-anchor-lifts-first", "固定側が先に離れたら発火しない", [17],
     [finger(1, .55, .4, 0, .35), finger(2, .7, .4, 0, 1), finger(3, .3, .4, .3, .4)], [], [])
case("tiptap-simultaneous-three", "3本同時に置いて左だけ離しても発火しない", [18],
     [finger(1, .55, .4, .1, 1), finger(2, .7, .4, .1, 1), finger(3, .3, .4, .1, .2)], [], [])
case("tiptap-anchors-too-young", "固定側を置いた直後（0.1秒未満）のタップは発火しない", [18],
     [finger(1, .55, .4, .1, 1), finger(2, .7, .4, .1, 1), finger(3, .3, .4, .15, .25)], [], [])
case("tiptap-twice", "2回タップすると2回だけ発火する", [19],
     anchors(off=1.2) + [finger(3, .3, .4, .3, .4), finger(4, .3, .4, .7, .8)], [], ["middleClick", "middleClick"], triggers=["tipTapLeft", "tipTapLeft"])
case("tiptap-other-device", "固定とタップが別デバイスなら発火しない", [24],
     anchors() + [finger(3, .3, .4, .3, .4, device=1)], [], [])


# PR #1 レビューの指摘（入力はレビューの再現用ファイルと同じ）
FOUR = [dict(id=i, x=.1 + .1 * i, y=.5) for i in range(1, 5)]
case("review-stale-touch", "4本指フレームが停止した後の通常クリック", [26], None, None, [], [P, P],
     events=[dict(t=0.0, device=0, touches=FOUR), dict(t=10.0, mouse="down"), dict(t=10.1, mouse="up")])
case("review-wrong-device", "片方に4本を置いたまま別のトラックパッドで1本指クリック", [27, 24], None, None, [], [P, P],
     events=[dict(t=0.0, device=0, touches=FOUR), dict(t=0.1, device=1, touches=[dict(id=10, x=.5, y=.5)]),
             dict(t=0.2, mouse="down"), dict(t=0.3, mouse="up")])
THREE = [dict(id=i, x=.3 + .1 * i, y=.5) for i in range(1, 4)]
case("other-device-stale", "別のトラックパッドの最後のフレームが古ければ（コールバック停止）、今触れている方だけで判定する → 中クリック", [26, 24],
     None, None, [], [C, C], triggers=["threeFingerClick"],
     events=[dict(t=0.0, device=1, touches=[dict(id=10, x=.5, y=.5)])]
            + [dict(t=round(.5 + .01 * k, 2), touches=THREE) for k in range(31)]
            + [dict(t=.7, mouse="down"), dict(t=.8, mouse="up")])

# タイムスタンプの巻き戻り
ev = build(anchors() + [finger(3, .3, .4, .3, .4)], [])
for e in ev:
    if e["t"] >= .35: e["t"] = round(e["t"] - .3, 4)
case("tiptap-time-rewind", "タップ中にタイムスタンプが巻き戻ったら発火しない（クラッシュもしない）", [20], None, None, [], events=ev)

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".json"): os.remove(os.path.join(OUT, f))
for i, (file, body) in enumerate(cases, 1):
    with open(os.path.join(OUT, f"{i:02d}-{file}.json"), "w") as fp:
        json.dump(body, fp, ensure_ascii=False, indent=1)
print(len(cases), "fixtures")
