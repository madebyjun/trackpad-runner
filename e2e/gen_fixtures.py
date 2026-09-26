#!/usr/bin/env python3
# e2e/fixtures/*.json を生成する。ケースを増やすときはここに追記して
#   python3 e2e/gen_fixtures.py e2e/fixtures
# を実行する。実機の入力は `trackpad-runner --record` で記録して fixtures に置いてもよい。
import json, os, sys
OUT = sys.argv[1]
STEP = 0.01

def finger(id, x, y, on, off, dx=0.0, dy=0.0, device=0, state=5, pressure=None):
    # dx,dy: on→off の間に線形に動く量
    # pressure: 押す力。数値か、時刻 t を受け取る関数。省略時は出力しない（押す力が分からないトラックパッド）
    return dict(id=id, x=x, y=y, on=on, off=off, dx=dx, dy=dy, device=device, state=state, pressure=pressure)

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
                touch = dict(id=f["id"], x=round(f["x"] + f["dx"] * p, 4), y=round(f["y"] + f["dy"] * p, 4), state=f["state"])
                pr = f["pressure"]
                if pr is not None:
                    touch["pressure"] = round(pr(t) if callable(pr) else pr, 1)
                touches.append(touch)
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
case("tiptap-long-press", "長押し（候補になってから 0.25 秒以上）は発火しない", [12], anchors() + [finger(3, .3, .4, .2, .8)], [], [])
case("tiptap-moving-tap", "タップした指が動いても発火する（BTT はタップした指の移動を見ない）", [13], anchors() + [finger(3, .3, .4, .3, .45, dy=.15)], [], ["middleClick"], triggers=["tipTapLeft"])
case("tiptap-anchors-scrolling", "タップ中に固定側の左端が 0.1 を超えて動く（2本指スクロール中）と発火しない", [14],
     [finger(1, .2, .4, 0, 1, dx=.8), finger(2, .35, .4, 0, 1, dx=.8), finger(3, .05, .4, .3, .5)], [], [])
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
case("tiptap-anchors-too-young", "2本を置いた直後の短いタップ（0.2 秒経つ前に離す）は発火しない", [18, 32],
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


# 実機での報告（2本を置いた直後に3本目を置くと反応しない）と BTT の条件
case("tiptap-early-tap-held", "2本を置いた直後に3本目を置いても、0.2 秒経つまで残していれば発火する", [32],
     [finger(1, .55, .4, .1, 1), finger(2, .7, .4, .1, 1), finger(3, .3, .4, .15, .4)], [], ["middleClick"], triggers=["tipTapLeft"])
case("tiptap-early-tap-too-long", "早めに置いた3本目も、候補になってから 0.25 秒以上残すと発火しない", [32, 12],
     [finger(1, .55, .4, .1, 1), finger(2, .7, .4, .1, 1), finger(3, .3, .4, .15, .6)], [], [])
case("tiptap-retap-too-soon", "発火の直後（0.2 秒以内）の次のタップは発火しない（BTT は準備を測り直す）", [35, 19],
     anchors(off=1.2) + [finger(3, .3, .4, .3, .4), finger(4, .3, .4, .45, .55)], [], ["middleClick"], triggers=["tipTapLeft"])
case("tiptap-click-before-candidate", "3本目を置いてから候補になる前に3本指クリックしても、TipTap は発火しない（二重発火しない）", [36, 15, 2],
     [finger(1, .55, .4, .1, 1), finger(2, .7, .4, .1, 1), finger(3, .3, .4, .15, .4)], click(.2, .25), [], [C, C], triggers=["threeFingerClick"])
case("tiptap-too-wide", "3本の x の広がりが 0.6 以上なら発火しない", [33],
     [finger(1, .5, .4, 0, 1), finger(2, .8, .4, 0, 1), finger(3, .15, .4, .3, .4)], [], [])
case("tiptap-margin-too-small", "タップが固定側の左端から 0.03 未満しか離れていなければ発火しない", [34],
     [finger(1, .55, .4, 0, 1), finger(2, .7, .4, 0, 1), finger(3, .53, .45, .3, .4)], [], [])

# タイムスタンプの巻き戻り
ev = build(anchors() + [finger(3, .3, .4, .3, .4)], [])
for e in ev:
    if e["t"] >= .35: e["t"] = round(e["t"] - .3, 4)
case("tiptap-time-rewind", "タップ中にタイムスタンプが巻き戻ったら発火しない（クラッシュもしない）", [20], None, None, [], events=ev)


# クリック元の特定（Force Touch、#2）。押す力は実機（内蔵トラックパッド）の値を参考に、置くだけ 20、クリック 120
REST = 20
def press(t0, t1):
    # t0〜t1 の間だけ強く押す
    return lambda t: 120 if t0 <= t < t1 - 1e-9 else REST
def ff(id, x, on=0, off=.5, device=0, pressure=REST):
    return finger(id, x, .5, on, off, device=device, pressure=pressure)
PRESSED = press(.18, .32)

case("force-1finger-click", "Force Touch: 1本指クリックは素通り", [1, 43],
     [ff(1, .5, pressure=PRESSED)], click(.2, .3), [], [P, P])
case("force-3finger-click", "Force Touch: 3本指クリック（強く押すのは1本だけ）→ 中クリック", [2, 53],
     [ff(1, .4), ff(2, .5, pressure=PRESSED), ff(3, .6)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"])
case("force-4finger-click", "Force Touch: 4本指クリック → ⇧⌘5", [3, 53],
     [ff(i, .2 + .1 * i, pressure=PRESSED if i == 1 else REST) for i in range(1, 5)], click(.2, .3), ["screenshotShortcut"], [S, S], triggers=["fourFingerClick"])
case("force-rest3-mouse-click", "Force Touch: 3本置いただけでマウスをクリック → 素通り（30ms 待ってから）", [28, 43, 47],
     [ff(i, .3 + .1 * i) for i in range(1, 4)], click(.2, .3), [], [P, P], timeline=["wait", "down", "up"])
case("force-rest4-mouse-click", "Force Touch: 4本置いただけでマウスをクリック → 握りつぶさず素通り", [28, 43, 47],
     [ff(i, .2 + .1 * i) for i in range(1, 5)], click(.2, .3), [], [P, P])
case("force-two-devices-3finger", "Force Touch 2台: 片方に1本置いたまま、もう片方で3本指クリック → 中クリック", [44],
     [ff(1, .4), ff(2, .5, pressure=PRESSED), ff(3, .6), ff(9, .5, device=1)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"])
case("force-two-devices-4finger", "Force Touch 2台: 片方に3本置いたまま、もう片方で4本指クリック → ⇧⌘5", [44, 45],
     [ff(i, .3 + .1 * i) for i in range(1, 4)] + [ff(10 + i, .2 + .1 * i, device=1, pressure=PRESSED if i == 2 else REST) for i in range(1, 5)],
     click(.2, .3), ["screenshotShortcut"], [S, S], triggers=["fourFingerClick"])
case("force-wrong-device", "Force Touch 2台: 片方に4本置いたまま、もう片方を1本指でクリック → 素通り（PR #1 レビューの指摘）", [27, 45],
     [ff(i, .1 + .1 * i) for i in range(1, 5)] + [ff(10, .5, device=1, pressure=PRESSED)], click(.2, .3), [], [P, P])
case("force-late-pressure", "Force Touch: 強く押したフレームが左クリックより 15ms 遅れて届いても 3本指クリックになる", [46],
     [ff(1, .4), ff(2, .5, pressure=press(.215, .32)), ff(3, .6)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"],
     timeline=["wait", "down", "up", "trigger:threeFingerClick"])
case("force-too-late-pressure", "Force Touch: 強く押したフレームが 30ms を過ぎても届かなければ素通り", [47],
     [ff(1, .4), ff(2, .5, pressure=press(.25, .32)), ff(3, .6)], click(.2, .3), [], [P, P])
case("force-old-press", "Force Touch: 3本置いたまま 0.1 秒前に強く押していても、マウスのクリックは素通り", [49],
     [ff(1, .4), ff(2, .5, pressure=press(.05, .1)), ff(3, .6)], click(.2, .3), [], [P, P])
case("force-stale-pressed", "Force Touch: 4本で強く押したフレームのあとコールバックが止まり、あとで通常クリック → 素通り（PR #1 レビューの指摘）", [26, 50], None, None, [], [P, P],
     events=[dict(t=0.0, touches=[dict(id=i, x=.1 + .1 * i, y=.5, pressure=120 if i == 1 else REST) for i in range(1, 5)]),
             dict(t=10.0, mouse="down"), dict(t=10.1, mouse="up")])
case("force-both-pressed", "Force Touch 2台: 両方強く押したら、新しく押された方（3本）で判定", [51],
     [ff(1, .5, pressure=press(.1, .32)), ff(10, .4, device=1), ff(11, .5, device=1, pressure=press(.19, .32)), ff(12, .6, device=1)],
     click(.2, .3), [], [C, C], triggers=["threeFingerClick"])
case("force-both-pressed-reverse", "Force Touch 2台: 3本で押したあと、もう片方を1本指で押したら、新しく押された方（1本）で判定 → 素通り", [51],
     [ff(1, .5, pressure=press(.19, .32)), ff(10, .4, device=1), ff(11, .5, device=1, pressure=press(.1, .32)), ff(12, .6, device=1)],
     click(.2, .3), [], [P, P])
case("force-mixed-legacy-click", "Force Touch に3本置いたまま、押す力が分からないトラックパッドを1本指でクリック → 素通り", [52],
     [ff(i, .3 + .1 * i) for i in range(1, 4)] + [finger(9, .5, .5, 0, .5, device=1)], click(.2, .3), [], [P, P])
case("force-mixed-legacy-3finger", "Force Touch に1本置いたまま、押す力が分からないトラックパッドで3本指クリック → どちらのクリックか分からないので素通り（main と同じ）", [52, 61],
     [ff(1, .5)] + [finger(10 + i, .3 + .1 * i, .5, 0, .5, device=1) for i in range(1, 4)], click(.2, .3), [], [P, P])
case("force-3finger-drag", "Force Touch: 3本指で押したままドラッグ（押す力が途中で弱まる）→ 最後まで中ボタン", [5, 4],
     [ff(1, .4), ff(2, .5, pressure=press(.18, .22)), ff(3, .6)], [(.2, "down"), (.3, "dragged"), (.4, "dragged"), (.45, "up")], [], [C, C, C, C], triggers=["threeFingerClick"])
case("force-rest2-no-wait", "Force Touch: 2本置いたままマウスをクリックしても待たない（通常のクリックを遅らせない）", [48],
     [ff(1, .4), ff(2, .5)], click(.2, .3), [], [P, P], timeline=["down", "up"])
case("force-3finger-no-wait", "Force Touch: 強く押したフレームが先に届いていれば待たない", [48, 2],
     [ff(1, .4), ff(2, .5, pressure=PRESSED), ff(3, .6)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"],
     timeline=["down", "up", "trigger:threeFingerClick"])
case("force-held-mouse-click", "Force Touch: 3本のうち1本を押す力 60 で押し続けたまま（クリックせず）、0.7 秒後にマウスをクリック → 素通り（PR #6 の Codex レビューの指摘）", [57],
     [finger(1, .4, .5, 0, 1.0, pressure=REST), finger(2, .5, .5, 0, 1.0, pressure=lambda t: 60 if t >= .1 else REST), finger(3, .6, .5, 0, 1.0, pressure=REST)],
     click(.8, .9), [], [P, P])
case("force-slow-press", "Force Touch: ゆっくり押し込んだ3本指クリック（50 を超えてから 0.15 秒後にクリックが確定）→ 中クリック", [58, 2],
     [ff(1, .4), ff(2, .5, pressure=lambda t: 60 if .05 <= t < .32 else REST), ff(3, .6)], click(.2, .3), [], [C, C], triggers=["threeFingerClick"])
case("force-repress", "Force Touch: 押し続けたあといったん力を抜き、指を置いたまま押し直して3本指クリック → 中クリック", [59, 57],
     [ff(1, .4, off=.6), ff(2, .5, off=.6, pressure=lambda t: 120 if (t < .3 or .34 <= t < .5) else REST), ff(3, .6, off=.6)],
     click(.37, .45), [], [C, C], triggers=["threeFingerClick"])
case("force-mixed-legacy-4finger-mouse", "Force Touch に1本、押す力が分からないトラックパッドに4本置いたままマウスでクリック → 握りつぶさず素通り（PR #6 の Codex レビューの指摘）", [61, 1],
     [ff(1, .5)] + [finger(10 + i, .2 + .1 * i, .5, 0, .5, device=1) for i in range(1, 5)], click(.2, .3), [], [P, P])
FA = lambda on=0.0, off=1.0, device=0: [finger(1, .55, .4, on, off, device=device, pressure=REST), finger(2, .7, .4, on, off, device=device, pressure=REST)]
case("force-tiptap-during-wait", "Force Touch: TipTap の候補中にマウスでクリックし、押す力を待っている間にタップした指を離す → TipTap は発火しない（PR #6 の Codex レビューの指摘）", [60, 15],
     FA() + [finger(3, .3, .4, .3, .41, pressure=REST)], click(.4, .5), [], [P, P], timeline=["wait", "down", "up"])
case("force-tiptap-during-wait-other-device", "Force Touch 2台: 片方に1本置き、もう片方の TipTap の候補中にマウスでクリックして待っている間にタップを離す → TipTap は発火しない", [60, 15],
     [ff(9, .5, off=1.0, device=1)] + FA() + [finger(3, .3, .4, .3, .41, pressure=REST)], click(.4, .5), [], [P, P], timeline=["wait", "down", "up"])
case("force-tiptap-left", "Force Touch: 押す力付きのフレームでも TipTap左は発火する", [10],
     [finger(1, .55, .4, 0, 1, pressure=REST), finger(2, .7, .4, 0, 1, pressure=REST), finger(3, .3, .4, .3, .4, pressure=REST)], [], ["middleClick"], triggers=["tipTapLeft"])

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".json"): os.remove(os.path.join(OUT, f))
for i, (file, body) in enumerate(cases, 1):
    with open(os.path.join(OUT, f"{i:02d}-{file}.json"), "w") as fp:
        json.dump(body, fp, ensure_ascii=False, indent=1)
print(len(cases), "fixtures")
