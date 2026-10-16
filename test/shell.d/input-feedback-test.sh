#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

OMARCHY_PATH="$ROOT" /usr/bin/python - <<'PY'
import copy
import importlib.util
import json
import os
import socket
import subprocess
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("indicator", os.environ["OMARCHY_PATH"] + "/default/input-methods/indicator.py")
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

keyboards = [{"name": "physical", "layout": "us,ara", "variant": ",", "active_layout_index": 0}]
reader = indicator.Indicator(None)
reader.keyboards = copy.deepcopy(keyboards)
feedback = indicator.InputFeedback(reader)
english = {"methods": ["keyboard-us", "mozc"], "current": "keyboard-us", "language": "en", "name": "English"}
japanese = {**english, "current": "mozc", "language": "ja", "name": "Mozc"}
initial = dict(feedback.observe(english))
assert initial["serial"] == 0 and initial["language"] == "eng"
assert feedback.observe(english) == initial
reader.remember_layout(1)
arabic = dict(feedback.observe(english))
assert arabic["serial"] == 1 and arabic["language"] == "ara"
reader.pending = "mozc"
assert feedback.observe(japanese) == arabic
reader.pending = ""
reader.remember_layout(0)
activated = dict(feedback.observe(japanese))
assert activated["serial"] == 2 and activated["language"] == "ja"
assert feedback.observe(japanese) == activated
assert feedback.observe(english)["serial"] == 3
assert indicator.InputFeedback(reader).observe(english)["serial"] == 0
print("ok - feedback follows confirmed changes once, including external switches, and starts silently")

reader.remember_layout(1)
fallback = dict(feedback.observe({"methods": [], "current": ""}))
assert fallback["language"] == "ara" and fallback["serial"] == 4
assert feedback.observe(english) == fallback
reader.pending = "mozc"
with patch.object(indicator, "keyboard_language", side_effect=ValueError("bad metadata")), patch("builtins.print"):
  reader.pending = ""
  assert feedback.observe(english) == fallback
  reader.pending = "mozc"
  assert feedback.observe(english) == fallback
assert reader.pending == "mozc"
reader.pending = ""
with patch.object(indicator, "layout_languages", side_effect=OSError("unreadable catalog")), patch("builtins.print"):
  assert feedback.observe(english) == fallback
assert reader.pending == ""
print("ok - Fcitx loss uses the compositor layout; cosmetic failures cannot change input or pending choices")

single = indicator.Indicator(None)
single.keyboards = [{"name": "physical", "layout": "us", "main": True, "active_layout_index": 0}]
single_feedback = indicator.InputFeedback(single)
single_feedback.observe(japanese)
assert single_feedback.observe({"methods": [], "current": ""})["language"] == "eng"
with patch.object(indicator.socket, "socket", side_effect=OSError("no socket")), \
     patch.object(indicator.subprocess, "run", side_effect=OSError("no compositor")), patch("builtins.print"):
  assert indicator.follow_layouts(single, Mock()) is None
print("ok - a single layout also recovers from Fcitx loss, and an unavailable event socket is harmless")

live = dict(english)
refuse = [True]
def controller(bus, method, args=None):
  assert method == "SetCurrentIM"
  if not refuse[0]:
    live.update(japanese)
  return ()
def process(args, **kwargs):
  if args == ["hyprctl", "-j", "devices"]:
    return subprocess.CompletedProcess(args, 0, stdout=json.dumps({"keyboards": keyboards}))
  return subprocess.CompletedProcess(args, 0)
reader = indicator.Indicator(None)
reader.keyboards = copy.deepcopy(keyboards)
reader.remember_layout(1)
feedback = indicator.InputFeedback(reader)
feedback.observe(english)
with patch.object(indicator, "snapshot", side_effect=lambda bus: dict(live)), \
     patch.object(indicator, "call", side_effect=controller), \
     patch.object(indicator.subprocess, "run", side_effect=process) as run:
  # Start from Arabic, immediately before Mozc in the native cycle.
  keyboards[0]["active_layout_index"] = 1
  reader.select_next()
  assert reader.pending == "mozc"
  assert feedback.observe(reader.refresh())["serial"] == 0
  refuse[0] = False
  state = reader.refresh()
  assert reader.pending == ""
  assert feedback.observe(state)["serial"] == 1
  assert sum(call.args[0] == ["hyprctl", "-j", "devices"] for call in run.call_args_list) == 1
print("ok - a refused engine is not announced; acknowledgement needs no extra compositor query")

# Drive real socket reads through the GLib callback without a compositor.
keyboards[0]["active_layout_index"] = 0
reader = indicator.Indicator(None)
listener, sender = socket.socketpair()
transport = Mock()
transport.fileno.return_value = listener.fileno()
transport.recv.side_effect = listener.recv
transport.close.side_effect = listener.close
callback = []
changed = Mock()
with patch.dict(os.environ, {"XDG_RUNTIME_DIR": "/unused", "HYPRLAND_INSTANCE_SIGNATURE": "test"}), \
     patch.object(indicator.socket, "socket", return_value=transport), \
     patch.object(indicator.GLib, "io_add_watch", side_effect=lambda fd, flags, fn: callback.append(fn) or 1), \
     patch.object(indicator.subprocess, "run", side_effect=process) as run:
  watcher = indicator.follow_layouts(reader, changed)
  assert run.call_count == 1 and changed.call_count == 0
  sender.sendall(b"activelayout>>physical,English (US)\n")
  callback[0](None, None)
  assert run.call_count == 1
  sender.sendall(b"activelayout>>physical,Ara")
  callback[0](None, None)
  assert run.call_count == 1
  keyboards[0]["active_layout_index"] = 1
  sender.sendall(b"bic\n")
  callback[0](None, None)
  assert run.call_count == 2 and changed.call_count == 1
  assert reader.keyboards[0]["active_layout_index"] == 1
  reader.pending = "mozc"
  run.side_effect = subprocess.TimeoutExpired("hyprctl", 1)
  with patch("builtins.print"):
    sender.sendall(b"configreloaded>>\n")
    callback[0](None, None)
  assert reader.pending == "mozc"
  assert reader.keyboards[0]["active_layout_index"] == 1
  sender.close()
  assert callback[0](None, None) == indicator.GLib.SOURCE_REMOVE
print("ok - compositor events handle split frames, skip known changes, and isolate query failures")
PY
