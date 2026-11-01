"""nuketown-prompter REQDIR: the sudo approval card (GTK 4, X11 and Wayland).

The broker (approval-daemon.nix) runs it for every REQUEST with the request
directory written by nuketown-approve (request.json, review.json,
snapshots/, kind/). The contract is the one the zenity prompter had:

  exit 0             approve
  exit 1             deny; the first line of stdout is the reason the
                     requester sees (at most 500 bytes, may be empty)
  timeout            request.json's prompt_timeout seconds (default 120,
                     0 = none): prints "no answer within Ns", exit 1
  SIGTERM/INT/HUP    exit 1 (the broker approved by a YubiKey touch, or
                     the requester went away)

Deny is the default. The keyboard starts on Deny; Enter there or Esc
anywhere on the card opens the optional reason in the card, where Enter
denies with the reason (empty is fine) and Esc denies with the fixed
reason "aborted by the human (dismissed without a reason)" (so Esc Esc
is a quick deny). Closing the window denies with no reason. Only a click on Approve or Ctrl+Enter
approves; Approve never takes the keyboard, so a bare Enter or Space
can't. Ctrl+I toggles the details; Ctrl+C copies selected text. Keys in
the card's first second are dropped, these included. review.json goes from {"status":"pending"} to the review while
the card is up; the card updates in place.

Everything the agent or the reviewer wrote is shown as plain text (never
Pango markup), with control and bidi characters made visible, and cut to
the zenity renderer's lengths.

Test hook: with NUKETOWN_PROMPTER_STATE=<file> the card writes what it
shows (texts, focus, widget bounds, X window id) to that file as JSON
after every change.
"""

import json
import os
import re
import sys
import time
import warnings

warnings.simplefilter("ignore", DeprecationWarning)     # GdkX11 get_xid, Gtk.Spinner

REASON_BYTES = 500
FILE_CAP = 1 << 20          # per file in the details (as "Show files" had)
CUT = {"display": 800, "why": 400, "summary": 1500, "bullet": 300, "reason": 300,
       "headline": 200, "note": 600, "kind": 100, "who": 64, "full": 65536}
DEFAULT_TIMEOUT = 120
POLL_MS = 300
# The card takes the keyboard when it appears, possibly mid-typing in
# another window: keys in its first second are dropped (so the rest of a
# password can't open the reason field and become the deny reason), and
# Approve only takes clicks after half a second.
KEYS_AFTER_MS, APPROVE_AFTER_MS = 1000, 500
# Esc in the reason field: the agent learns the human stopped it on purpose.
DISMISSED = "aborted by the human (dismissed without a reason)"

# C0/C1 controls and the bidi controls that can make text read differently
# than it runs (Trojan Source); shown as \xNN / \u{NNNN}.
_INVISIBLE = re.compile("[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]")
_ESCAPES = {"\t": "\\t", "\r": "\\r", "\n": "\\n", "\u001b": "\\e"}


def _visible(c):
    if c in _ESCAPES:
        return _ESCAPES[c]
    o = ord(c)
    return f"\\x{o:02x}" if o < 0x100 else f"\\u{{{o:04x}}}"


_ALL_CONTROLS = re.compile("[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]")


def clean(s, n=None, mode="line"):
    """Untrusted text -> plain, visible text, at most n characters (+ an ellipsis).
    mode "line": newlines and tabs become spaces; "block": newlines stay;
    "cmd": every control character is shown escaped (\\n, \\t, \\x01)."""
    s = "" if s is None else str(s)
    if n is not None and len(s) > n:
        s = s[:n] + "\u2026"
    vis = lambda m: _visible(m.group())  # noqa: E731
    if mode == "cmd":
        return _ALL_CONTROLS.sub(vis, s)
    if mode == "block":
        return _INVISIBLE.sub(vis, s.replace("\t", "    "))
    return _INVISIBLE.sub(vis, s.replace("\t", " ")).replace("\n", " ")


def clean_block(s):
    """File contents: keep newlines and tabs, make other controls visible."""
    return _INVISIBLE.sub(lambda m: _visible(m.group()), s)


def clip_reason(text):
    """The deny reason as the broker wants it: one line, at most 500 bytes."""
    s = re.sub(r"[\u0000-\u001f\u007f]", " ", str(text or "")).strip()
    b = s.encode("utf-8")[:REASON_BYTES]
    return b.decode("utf-8", errors="ignore")


def prompt_timeout(req):
    t = req.get("prompt_timeout", DEFAULT_TIMEOUT)
    if isinstance(t, bool) or not isinstance(t, int) or t < 0:
        return DEFAULT_TIMEOUT
    return t


def _str(v):
    return v if isinstance(v, str) else ""


def _list(v):
    return [x for x in v if x is not None] if isinstance(v, list) else []


def review_model(rev):
    """review.json (or None) → what the review line shows."""
    if not isinstance(rev, dict):
        rev = {"status": "missing"}
    st = _str(rev.get("status")) or "missing"
    if st == "ok":
        headline = clean(_str(rev.get("headline")).strip(), CUT["headline"])
        summary = clean(rev.get("summary"), CUT["summary"], "block")
        risk = _str(rev.get("risk")).lower()
        return {
            "state": "ok",
            "risk": risk if risk in ("low", "medium", "high") else "unknown",
            "recommendation": clean(_str(rev.get("recommendation")).lower(), 20),
            # A review from before reviewers wrote headlines: lead with the summary.
            "headline": headline or clean(rev.get("summary"), CUT["bullet"]),
            "has_headline": bool(headline),
            "notes": [clean(n, CUT["bullet"]) for n in _list(rev.get("notes"))],
            "summary": summary,
            "not_shown": [clean(n, CUT["bullet"]) for n in _list(rev.get("not_shown"))],
            "line": "",
        }
    m = {"state": "none", "risk": "", "recommendation": "", "headline": "", "has_headline": False,
         "notes": [], "summary": "", "not_shown": []}
    reason = clean(rev.get("reason"), CUT["reason"])
    if st == "pending":
        m.update(state="pending", line="Reviewer is reading this request\u2026")
    elif st == "disabled":
        m["line"] = "No reviewer configured."
    elif st == "skipped" and rev.get("by") == "collector":
        m["line"] = "No review: " + reason
    elif st == "skipped":
        m["line"] = "Not reviewed: " + (reason or "skipped") + "."
    elif st == "missing":
        m["line"] = "No review."
    else:
        m["line"] = "No review: " + (reason or clean(st, 40))
    return m


def card_model(req, rev, note=""):
    """request.json + review.json → every text on the card."""
    who = clean(req.get("requester"), CUT["who"]) or "?"
    run_as = clean(((req.get("run_as") or {}).get("user")) or "root", CUT["who"])
    by_root = req.get("origin") == "root"
    argv = [clean(a, CUT["full"], "cmd") for a in _list(req.get("argv"))]
    display = _str(req.get("display")) or " ".join(_str(a) for a in _list(req.get("argv")))
    kind = req.get("kind") if isinstance(req.get("kind"), dict) else None
    why = _str(req.get("why"))
    return {
        "who": f"{who} (via root) asks to run as {run_as}" if by_root else f"{who} wants to run as {run_as}",
        "cwd": clean(req.get("cwd"), 4096, "cmd"),
        "command": clean(display, CUT["display"], "cmd"),
        "command_full": clean(display, CUT["full"], "cmd"),
        "argv": argv,
        "why": ("Stated reason: " if by_root else "Reason: ") + clean(why, CUT["why"]) if why else "",
        "kind": "Kind: " + clean(kind.get("name"), CUT["kind"]) if kind else "",
        "decrypt": [clean(d, CUT["bullet"]) for d in _list(req.get("decrypt"))],
        "note": clean(note, CUT["note"]),
        "review": review_model(rev),
        "requester": who,
    }


def _safe_snapshot(rel):
    return isinstance(rel, str) and rel.startswith("snapshots/") and ".." not in rel.split("/")


def _head(path):
    with open(path, "rb") as f:
        data = f.read(FILE_CAP + 1)
    text = data[:FILE_CAP].decode("utf-8", errors="replace")
    if len(data) > FILE_CAP:
        text += f"\n[\u2026 cut at {FILE_CAP} bytes]"
    return clean_block(text)


def files_text(reqdir, req):
    """The snapshotted files and kind/ files with their contents (the details view)."""
    out = []
    for s in _list(req.get("snapshots")):
        if not isinstance(s, dict) or not _safe_snapshot(s.get("snapshot")):
            continue
        how = "runs; the snapshot is what runs" if s.get("executed") is True else "for review"
        out.append(f"==== {clean(s.get('path'), 4096)} ({how})\n==== sha256 {clean(s.get('sha256'), 80)}\n")
        p = os.path.join(reqdir, s["snapshot"])
        try:
            if os.path.islink(p) or not os.path.isfile(p):
                raise OSError("not a regular file")
            out.append(_head(p))
        except OSError as e:
            out.append(f"[can't read the snapshot: {e}]")
        out.append("\n\n")
    kdir = os.path.join(reqdir, "kind")
    if os.path.isdir(kdir):
        for n in sorted(os.listdir(kdir)):
            p = os.path.join(kdir, n)
            if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) == 0:
                continue
            out.append(f"==== kind/{clean(n, 255)}\n\n")
            try:
                out.append(_head(p))
            except OSError as e:
                out.append(f"[can't read: {e}]")
            out.append("\n\n")
    return "".join(out).rstrip("\n") + ("\n" if out else "")


def files_heading(req):
    """The details' files heading: kind/ files are root's, not snapshots."""
    kind = req.get("kind") if isinstance(req.get("kind"), dict) else None
    if kind:
        return ("Files (snapshots are what runs; kind/ is what root collected for "
                + clean(kind.get("name"), CUT["kind"]) + ")")
    return "Files (snapshotted; the snapshot is what runs)"


def load_json(path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read(1 << 20))
    except (OSError, ValueError):
        return None


# ── the window ──────────────────────────────────────────────────────

CSS = b"""
.nt-card { padding: 16px 18px 14px 18px; }
.nt-who { font-weight: bold; }
.nt-command { font-family: monospace; }
.nt-badge { border-radius: 4px; padding: 1px 7px; font-weight: bold; font-size: smaller; color: #ffffff; }
.nt-risk-low { background-color: #2e7d32; }
.nt-risk-medium { background-color: #a35f00; }
.nt-risk-high { background-color: #c62828; }
.nt-risk-unknown { background-color: #616161; }
.nt-headline { font-weight: bold; }
.nt-section { font-weight: bold; font-size: smaller; opacity: 0.7; margin-top: 6px; }
.nt-dim { opacity: 0.6; font-size: smaller; }
.nt-info { min-width: 22px; min-height: 22px; padding: 0; border-radius: 9999px;
           border: 1px solid alpha(currentColor, 0.45); font-weight: bold; font-family: serif; }
.nt-files { font-family: monospace; font-size: smaller; }
"""


class Card:
    def __init__(self, gi_modules, reqdir, note, state_file):
        self.Gtk, self.GLib, self.Gdk, self.Pango = gi_modules
        GLib = self.GLib
        self.reqdir = reqdir
        self.note = note
        self.state_file = state_file
        self.result = None          # (rc, stdout text)
        self.loop = GLib.MainLoop()
        self.req = load_json(os.path.join(reqdir, "request.json"))
        if not isinstance(self.req, dict):
            raise ValueError("unreadable request.json")
        self.timeout = prompt_timeout(self.req)
        self.deadline = time.monotonic() + self.timeout
        self.review_raw = None
        self.review_updates = 0
        self.files_loaded = False
        self.labels = {}            # name → Gtk.Label, for the test hook
        self._dump_pending = False
        self.cause = None
        self.keys_armed = False
        self.dropped_keys = 0
        self.model = card_model(self.req, None, note)
        self._build()
        self._refresh_review(force=True)
        self._tick()
        GLib.timeout_add(POLL_MS, self._poll)
        GLib.timeout_add(1000, self._tick)

    # widgets
    def _label(self, name, text="", classes=(), wrap=True, mono=False, selectable=True):
        Gtk = self.Gtk
        l = Gtk.Label()
        l.set_use_markup(False)
        l.set_use_underline(False)
        l.set_text(text)
        l.set_xalign(0)
        l.set_halign(Gtk.Align.FILL)
        l.set_selectable(selectable)
        if wrap:
            l.set_wrap(True)
            l.set_wrap_mode(self.Pango.WrapMode.WORD_CHAR)
            l.set_max_width_chars(76)
        for c in classes:
            l.add_css_class(c)
        if mono:
            l.add_css_class("nt-command")
        if name:
            self.labels[name] = l
        return l

    def _build(self):
        Gtk, Gdk = self.Gtk, self.Gdk
        m = self.model
        prov = Gtk.CssProvider()
        if hasattr(prov, "load_from_string"):       # GTK >= 4.12
            prov.load_from_string(CSS.decode())
        else:
            prov.load_from_data(CSS, -1)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        w = self.win = Gtk.Window()
        w.set_title("Nuketown: Sudo Approval")
        # Not resizable: the size follows the content (it grows with the
        # details).
        w.set_resizable(False)
        # Modal: on X11 that is _NET_WM_STATE_MODAL, which i3 floats when
        # it manages the window (the fixed size hints come too late).
        w.set_modal(True)
        w.connect("close-request", self._on_close)

        box = self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.add_css_class("nt-card")
        box.set_size_request(600, -1)
        w.set_child(box)

        box.append(self._label("who", m["who"], ("nt-who",)))
        cmd = self._label("command", m["command"], mono=True)
        cmd.set_lines(3)
        cmd.set_ellipsize(self.Pango.EllipsizeMode.END)
        cmd.set_margin_start(12)
        box.append(cmd)
        for key in ("why", "kind"):
            if m[key]:
                box.append(self._label(key, m[key]))
        if m["decrypt"]:
            box.append(self._label("decrypt", "Also decrypts: " + ", ".join(m["decrypt"])))
        if m["note"]:
            box.append(self._label("note", m["note"], ("nt-dim",)))

        self.review_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.review_box.set_margin_top(10)
        box.append(self.review_box)

        info_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.info = Gtk.ToggleButton()
        i = self._label(None, "i", selectable=False, wrap=False)
        i.set_xalign(0.5)
        i.set_halign(self.Gtk.Align.CENTER)
        self.info.set_child(i)
        self.info.set_tooltip_text("Details (Ctrl+I)")
        self.info.set_focus_on_click(False)     # the keyboard stays on Deny
        self.info.add_css_class("circular")
        self.info.add_css_class("flat")
        self.info.add_css_class("nt-info")
        self.info.set_halign(Gtk.Align.END)
        self.info.set_hexpand(True)
        self.info.connect("toggled", self._on_info)
        info_row.append(self.info)
        box.append(info_row)

        # The details scroll as a whole when they don't fit on the screen,
        # so the action row never leaves it.
        self.details = Gtk.ScrolledWindow()
        self.details.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.details.set_propagate_natural_height(True)
        self.details.set_child(self._build_details())
        self.details.set_visible(False)
        box.append(self.details)

        drow = self.deny_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        drow.set_visible(False)
        self.reason = Gtk.Entry()
        self.reason.set_max_length(REASON_BYTES)
        self.reason.set_placeholder_text(f"Reason {m['requester']} sees (optional)")
        self.reason.connect("activate", lambda *_: self._deny(self.reason.get_text(), "reason-enter"))
        drow.append(self.reason)
        drow.append(self._label("reason_hint", "Enter denies with this reason \u00b7 Esc dismisses", ("nt-dim",),
                                selectable=False))
        box.append(drow)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        actions.set_margin_top(6)
        self.remaining = self._label("remaining", "", ("nt-dim",), wrap=False, selectable=False)
        self.remaining.set_hexpand(True)
        self.remaining.set_valign(Gtk.Align.CENTER)
        actions.append(self.remaining)
        self.deny_btn = Gtk.Button(label="Deny")
        self.deny_btn.connect("clicked", self._on_deny)
        self.deny_btn.set_tooltip_text("Deny (Esc)")
        self.approve_btn = Gtk.Button(label="Approve")
        self.approve_btn.set_sensitive(False)
        self.approve_btn.connect("clicked", lambda *_: self._finish(0, None, "approve"))
        self.approve_btn.set_tooltip_text("Approve (Ctrl+Enter)")
        # Never the keyboard's: Tab skips it, so bare Enter/Space can't approve.
        self.approve_btn.set_focusable(False)
        actions.append(self.deny_btn)
        actions.append(self.approve_btn)
        box.append(actions)

        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._on_key)
        w.add_controller(keys)
        w.connect("notify::focus-widget", lambda *_: self._dump())
        # No default widget: Enter only activates what has the keyboard.
        w.set_focus(self.deny_btn)
        w.connect("map", self._on_map)

    def _build_details(self):
        Gtk = self.Gtk
        d = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        d.set_margin_top(4)
        d.append(self._label(None, "Summary", ("nt-section",), selectable=False))
        d.append(self._label("summary", ""))
        d.append(self._label(None, "Could not verify", ("nt-section",), selectable=False))
        d.append(self._label("not_shown", ""))
        d.append(self._label(None, files_heading(self.req), ("nt-section",), selectable=False))
        self.files_view = Gtk.TextView()
        self.files_view.set_editable(False)
        self.files_view.set_cursor_visible(False)
        self.files_view.set_monospace(True)
        self.files_view.add_css_class("nt-files")
        self.files_view.set_wrap_mode(Gtk.WrapMode.NONE)
        sw = self.files_sw = Gtk.ScrolledWindow()
        sw.set_child(self.files_view)
        sw.set_min_content_height(24)
        sw.set_max_content_height(300)
        sw.set_propagate_natural_height(True)
        sw.set_min_content_width(560)
        d.append(sw)
        d.append(self._label(None, "Command", ("nt-section",), selectable=False))
        argv = self.model["argv"]
        full = self.model["command_full"]
        if argv:
            full += "\n\n" + "\n".join(f"argv[{i}] {a}" for i, a in enumerate(argv))
        if self.model["cwd"]:
            full += "\n\nin " + self.model["cwd"]
        d.append(self._label("command_full", full, mono=True))
        return d

    def _load_files(self):
        if self.files_loaded:
            return
        self.files_loaded = True
        text = files_text(self.reqdir, self.req)
        # Room for a few lines of a file even when the details have to
        # scroll; one line when there is nothing to show.
        self.files_sw.set_min_content_height(120 if text else 24)
        self.files_view.get_buffer().set_text(text or "No files in this request.\n", -1)

    # the review, in place
    def _poll(self):
        if self.result is None:
            self._refresh_review()
        return self.result is None

    def _refresh_review(self, force=False):
        try:
            with open(os.path.join(self.reqdir, "review.json"), "rb") as f:
                raw = f.read(1 << 20)
        except OSError:
            raw = b""
        if raw == self.review_raw and not force:
            return
        self.review_raw = raw
        try:
            rev = json.loads(raw) if raw else None
        except ValueError:
            rev = {"status": "unavailable", "reason": "review.json is not valid JSON"}
        if not force:
            self.review_updates += 1
        r = self.model["review"] = review_model(rev)
        self._render_review(r)
        self._dump()

    def _render_review(self, r):
        Gtk = self.Gtk
        for k in [k for k in self.labels if k.startswith("review_")]:
            del self.labels[k]
        child = self.review_box.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self.review_box.remove(child)
            child = nxt
        if r["state"] == "ok":
            line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            badge = self._label("review_badge", r["risk"].upper(), ("nt-badge", "nt-risk-" + r["risk"]),
                                wrap=False, selectable=False)
            badge.set_valign(Gtk.Align.START)
            badge.set_hexpand(False)
            line.append(badge)
            text = self._label("review_headline", f"{r['recommendation']} \u00b7 {r['headline']}", ("nt-headline",))
            text.set_hexpand(True)
            line.append(text)
            self.review_box.append(line)
            for i, n in enumerate(r["notes"]):
                b = self._label(f"review_note_{i}", "\u2022 " + n)
                b.set_margin_start(12)
                self.review_box.append(b)
        else:
            line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            if r["state"] == "pending":
                sp = Gtk.Spinner()
                sp.start()
                line.append(sp)
            line.append(self._label("review_line", r["line"]))
            self.review_box.append(line)
        self.labels["summary"].set_text(r["summary"] or (r["line"] or ""))
        self.labels["not_shown"].set_text("\n".join("\u2022 " + n for n in r["not_shown"]) or "Nothing listed.")

    # time
    def _tick(self):
        if self.result is not None:
            return False
        if self.timeout == 0:
            self.remaining.set_text("")
            return True
        left = int(self.deadline - time.monotonic() + 0.999)
        if left <= 0:
            self._finish(1, f"no answer within {self.timeout}s", "timeout")
            return False
        self.remaining.set_text(f"Denies in {left // 60}:{left % 60:02d}")
        self._dump()
        return True

    # input
    def _on_map(self, *_):
        self.deny_btn.grab_focus()
        self.GLib.timeout_add(APPROVE_AFTER_MS, self._arm_approve)
        self.GLib.timeout_add(KEYS_AFTER_MS, self._arm_keys)
        self._dump()

    def _arm_approve(self):
        self.approve_btn.set_sensitive(True)
        self._dump()
        return False

    def _arm_keys(self):
        self.keys_armed = True
        self._dump()
        return False

    def _on_key(self, _ctl, keyval, _code, state):
        Gdk = self.Gdk
        if not self.keys_armed:
            self.dropped_keys += 1
            self._dump()
            return True
        ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
        if keyval == Gdk.KEY_Escape and not ctrl:
            if self.deny_row.get_visible():
                self._deny(DISMISSED, "reason-escape")      # Esc Esc: a quick deny
            else:
                self._open_deny()
            return True
        if ctrl and keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_ISO_Enter):
            if self.approve_btn.get_sensitive():
                self._finish(0, None, "ctrl-enter")
            return True
        if ctrl and keyval in (Gdk.KEY_i, Gdk.KEY_I):
            self.info.set_active(not self.info.get_active())
            return True
        return False     # Ctrl+C and the rest: the focused widget's

    def _on_info(self, btn):
        if btn.get_active():
            self._load_files()
            self.details.set_max_content_height(self._details_room())
        self.details.set_visible(btn.get_active())
        self._dump()

    def _details_room(self):
        """Height the details may take. Window managers centre the card and
        keep its top where it is as it grows (GTK 4 can't move it), so the
        details get the room below a centred card, less a margin; beyond
        that they scroll."""
        screen_h = 0
        try:
            surface = self.win.get_surface()
            mon = surface and self.Gdk.Display.get_default().get_monitor_at_surface(surface)
            screen_h = mon.get_geometry().height if mon else 0
        except (AttributeError, TypeError):
            pass
        if screen_h <= 0:
            return 480
        return max(160, min(640, (screen_h - self.win.get_height()) // 2 - 48))

    def _on_deny(self, _btn):
        if self.deny_row.get_visible():
            self._deny(self.reason.get_text(), "deny-button")
            return
        self._open_deny()

    def _open_deny(self):
        self.deny_row.set_visible(True)
        self.reason.grab_focus()
        self._dump()

    def _deny(self, reason, cause):
        self._finish(1, clip_reason(reason), cause)

    def _on_close(self, *_):
        self._finish(1, None, "close")
        return True

    def _finish(self, rc, out, cause):
        if self.result is not None:
            return
        self.result = (rc, out)
        self.cause = cause
        self._dump(final=True)
        self.loop.quit()

    # the test hook
    def _dump(self, final=False):
        """Write the state after the next layout (or now, for the last one)."""
        if not self.state_file:
            return
        if final:
            self._dump_now(final=True)
        elif not self._dump_pending:
            self._dump_pending = True
            self.GLib.timeout_add(80, self._dump_now)

    def _dump_now(self, final=False):
        self._dump_pending = False
        bounds = {}
        named = dict(self.labels)
        named.update(deny=self.deny_btn, approve=self.approve_btn, info=self.info, reason=self.reason)
        for k, wdg in named.items():
            ok, rect = wdg.compute_bounds(self.win)
            if ok and wdg.get_mapped():
                bounds[k] = [round(rect.get_x()), round(rect.get_y()), round(rect.get_width()),
                             round(rect.get_height())]
        focus = self.win.get_focus()
        fname = next((k for k, wdg in named.items() if focus is not None and
                      (focus == wdg or focus.is_ancestor(wdg))), type(focus).__name__ if focus else "")
        sel = {}
        for k, l in self.labels.items():
            got = l.get_selection_bounds()
            if got and got[0]:
                sel[k] = [got[1], got[2]]
        state = {
            "pid": os.getpid(), "title": self.win.get_title(), "xid": _xid(self.win),
            "backend": self.Gdk.Display.get_default().__gtype__.name,
            "texts": {k: l.get_text() for k, l in self.labels.items()},
            "markup": [k for k, l in self.labels.items() if l.get_use_markup()],
            "review": self.model["review"], "review_updates": self.review_updates,
            "details_open": self.details.get_visible(), "deny_open": self.deny_row.get_visible(),
            "reason_text": self.reason.get_text(), "focus": fname, "bounds": bounds, "selections": sel,
            "files": self.files_view.get_buffer().get_property("text") if self.files_loaded else None,
            "size": [self.win.get_width(), self.win.get_height()],
            "result": list(self.result) if self.result else None, "final": final,
            "cause": self.cause,
            "armed": self.keys_armed and self.approve_btn.get_sensitive(),
            "dropped_keys": self.dropped_keys,
            "tooltips": {k: w.get_tooltip_text() for k, w in
                         (("deny", self.deny_btn), ("approve", self.approve_btn), ("info", self.info))},
        }
        tmp = self.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, self.state_file)

    def run(self):
        self.win.present()
        self.loop.run()
        return self.result


def _xid(win):
    try:
        import gi
        gi.require_version("GdkX11", "4.0")
        from gi.repository import GdkX11
        s = win.get_surface()
        if isinstance(s, GdkX11.X11Surface):
            return s.get_xid()
    except (ImportError, ValueError, AttributeError):
        pass
    return None


def main(argv):
    if len(argv) != 2:
        print("usage: nuketown-prompter REQDIR", file=sys.stderr)
        return 2
    reqdir = argv[1].rstrip("/") or "/"
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, GLib, Gtk, Pango

    def die(sig):
        os._exit(1)
    import signal
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, die, sig)

    GLib.set_prgname("nuketown-prompter")      # WM_CLASS / app id
    GLib.set_application_name("Nuketown: Sudo Approval")
    if not Gtk.init_check():
        print("no display for the approval card")
        return 1
    try:
        card = Card((Gtk, GLib, Gdk, Pango), reqdir, os.environ.get("NUKETOWN_PROMPT_NOTE", ""),
                    os.environ.get("NUKETOWN_PROMPTER_STATE") or None)
    except (OSError, ValueError) as e:
        print(f"the approval card could not read the request ({e})", file=sys.stderr)
        return 1
    rc, out = card.run()
    if out:
        sys.stdout.write(out + "\n")
    sys.stdout.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
