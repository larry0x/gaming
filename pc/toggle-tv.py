#!/usr/bin/env python3
"""Toggle the Hisense VIDAA TV's power over its local MQTT broker.

Usage: toggle-tv.py {on,off}

The gaming PC's resume and suspend hooks run this (see pc/configuration.nix),
so the TV's power follows the PC's: on with the machine, standby with it,
instead of needing its own remote. Zero dependencies: Python standard library
only -- it hand-rolls the little bit of MQTT it needs rather than pulling in a
client library.

State-aware: it asks the TV for its power state first and only sends KEY_POWER
when the TV is not already in the intended state. KEY_POWER is a toggle, so a
blind press would flip a TV that is already where it should be to exactly the
wrong state. A standby TV answers a state query with silence, so the two
directions must read silence oppositely: "on" takes it as the standby
signature and sends the key, while "off" takes it as unknown and does nothing,
since a blind toggle there could wake a TV that was off all along.

The reverse-engineered credential algorithm, the imperative host setup this
needs (the /var/lib/vidaa client certificate), and the whole investigation
behind it are documented in pc/WAKING.md.
"""

import hashlib
import json
import socket
import ssl
import struct
import sys
import time

# ------------------------------- Configuration -------------------------------

TV_HOST = "192.168.1.74"  # pinned by the router's DHCP reservation
TV_PORT = 36669  # the VIDAA MQTT broker, reachable even in standby
TV_MAC = "c4:08:26:aa:b4:c3"  # the TV's own MAC (from its UPnP descriptor);
#                               seeds the client-id, must match what was paired

CERT = "/var/lib/vidaa/vidaa_client.pem"  # the VIDAA app's client certificate
KEY = "/var/lib/vidaa/vidaa_client.key"  # ... and its private key (mutual TLS)

# Connection retry budget, per direction. "on" runs right after resume, when
# WiFi is still reassociating, so it gets ~20 s. "off" runs just before
# suspend on a network that is already up -- and since systemd puts no timeout
# on it there (it is sleep-actions' start phase, which the suspend waits on),
# this small budget is the only bound on how long it can delay the suspend.
CONNECT_RETRIES = {"on": 20, "off": 2}
STATE_WAIT = 3.0  # seconds to wait for the TV to report its power state

# ---------------------------- Dynamic credentials ----------------------------
#
# The broker rejects static credentials (CONNACK 5); the username and password
# are generated per connection by an algorithm reverse-engineered from the
# app's libmqttcrypt.so. These constants and the formula are the MODERN variant
# (VIDAA protocol >= 3290). If a firmware update ever breaks authentication,
# this is the first suspect -- see pc/WAKING.md.

_PATTERN = "38D65DC30F45109A369A86FCE866A85B"
_SUFFIX = "h!i@s#$v%i^d&a*a"
_XOR = 0x56981477_2B03A968


def _md5(s):
    return hashlib.md5(s.encode()).hexdigest().upper()


def make_creds(mac, brand="his", operation="vidaacommon", ts=None):
    """Return (client_id, username, password) for the MQTT CONNECT."""
    if ts is None:
        ts = int(time.time())
    race = _md5(f"{_PATTERN}${mac}")[:6]
    client_id = f"{mac}${brand}${race}_{operation}_001"
    username = f"{brand}${ts ^ _XOR}"
    value_md5 = _md5(f"{brand}{sum(int(d) for d in str(ts)) % 10}{_SUFFIX}")[:6]
    password = _md5(f"{ts}${value_md5}")
    return client_id, username, password


# --------------------------- Minimal MQTT 3.1.1 ------------------------------
#
# Only the four packet types a fire-and-forget control client needs: CONNECT,
# SUBSCRIBE, PUBLISH (all outbound, QoS 0) and reading inbound packets.


def _remlen_encode(n):
    """Encode an MQTT variable-length 'remaining length' field."""
    out = bytearray()
    while True:
        digit = n & 0x7F
        n >>= 7
        out.append(digit | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _field(s):
    """A 2-byte length-prefixed UTF-8 string, MQTT's string wire format."""
    b = s.encode()
    return struct.pack("!H", len(b)) + b


def _packet(kind, body):
    return bytes([kind]) + _remlen_encode(len(body)) + body


def _connect_packet(client_id, username, password, keepalive=60):
    # 0x04 = protocol level 4 (MQTT 3.1.1); 0xC2 flags = username+password+clean
    var = _field("MQTT") + bytes([0x04, 0xC2]) + struct.pack("!H", keepalive)
    payload = _field(client_id) + _field(username) + _field(password)
    return _packet(0x10, var + payload)


def _subscribe_packet(topic, packet_id=1):
    # 0x82: SUBSCRIBE type with the mandatory 0b0010 reserved bits.
    body = struct.pack("!H", packet_id) + _field(topic) + bytes([0x00])
    return _packet(0x82, body)


def _publish_packet(topic, payload):
    return _packet(0x30, _field(topic) + payload.encode())  # 0x30 = PUBLISH, QoS 0


def _read_remlen(sock):
    """Read an MQTT remaining-length varint. Returns the int, or None on EOF."""
    n = shift = 0
    while True:
        b = sock.recv(1)
        if not b:
            return None
        n |= (b[0] & 0x7F) << shift
        if not b[0] & 0x80:
            return n
        shift += 7


def _read_packet(sock):
    """Read one whole MQTT packet. Returns (type_byte, body) or (None, None)."""
    head = sock.recv(1)
    if not head:
        return None, None
    length = _read_remlen(sock)
    if length is None:
        return None, None
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            break
        body += chunk
    return head[0], body


# -------------------------------- Toggle logic --------------------------------
#
# {c} is the dynamic client-id, which in our token-less setup is also the
# MQTT-level client-id (see pc/WAKING.md).

_T_GETSTATE = "/remoteapp/tv/ui_service/{c}/actions/gettvstate"
_T_SENDKEY = "/remoteapp/tv/remote_service/{c}/actions/sendkey"
# The exact topic the TV broadcasts power state on. Its old broker (mosquitto
# 1.4.2) does not honour a '#' wildcard subscription here, so match it exactly.
_T_STATE = "/remoteapp/mobile/broadcast/ui_service/state"


def _tls_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False  # must precede CERT_NONE below
    ctx.verify_mode = ssl.CERT_NONE  # the TV serves a self-signed certificate
    ctx.load_cert_chain(CERT, KEY)  # present the app's client cert (mutual TLS)
    return ctx


def _connect(ctx, retries):
    """Open a TLS socket and complete an MQTT CONNECT, retrying network lag."""
    client_id, username, password = make_creds(TV_MAC)
    for _ in range(retries):
        try:
            raw = socket.create_connection((TV_HOST, TV_PORT), timeout=5)
            sock = ctx.wrap_socket(raw, server_hostname=TV_HOST)
            sock.sendall(_connect_packet(client_id, username, password))
            kind, body = _read_packet(sock)
            if kind == 0x20 and len(body) >= 2 and body[1] == 0x00:
                return sock, client_id  # CONNACK, return code 0 = accepted
            rc = body[1] if body and len(body) >= 2 else "?"
            sock.close()
            sys.exit(f"toggle-tv: MQTT CONNECT refused (return code {rc})")
        except (OSError, ssl.SSLError):
            time.sleep(1)  # network likely not up yet after resume; retry
    return None, None


def _tv_state(sock, client_id):
    """Ask the TV for its power state: "on", "standby", or None if it stayed
    silent. The TV answers promptly when on and not at all in standby; what to
    make of the silence is the caller's, direction-dependent, call."""
    sock.sendall(_subscribe_packet(_T_STATE))
    sock.sendall(_publish_packet(_T_GETSTATE.format(c=client_id), ""))
    deadline = time.time() + STATE_WAIT
    while time.time() < deadline:
        sock.settimeout(max(0.1, deadline - time.time()))
        try:
            kind, body = _read_packet(sock)
        except (OSError, ssl.SSLError):
            break
        if kind is None:
            break
        if kind & 0xF0 != 0x30:  # only PUBLISH carries state; skip SUBACK etc.
            continue
        if len(body) < 2:
            continue
        tlen = struct.unpack("!H", body[:2])[0]
        offset = 2 + tlen
        if kind & 0x06:  # QoS > 0 inserts a 2-byte packet id before the payload
            offset += 2
        try:
            state = json.loads(body[offset:].decode())
        except (ValueError, UnicodeDecodeError):
            continue
        statetype = state.get("statetype")
        if statetype:
            # "fake_sleep_0" is standby; any other state means the TV is on.
            return "standby" if statetype == "fake_sleep_0" else "on"
    return None


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else None
    if mode not in ("on", "off"):
        sys.exit("usage: toggle-tv.py {on,off}")

    sock, client_id = _connect(_tls_context(), CONNECT_RETRIES[mode])
    if sock is None:
        if mode == "off":
            # A deliberate no-op, not an error: an unreachable TV has nothing
            # to switch off, and the suspend must not be held up over it.
            print("toggle-tv: TV unreachable, leaving it be")
            return
        sys.exit("toggle-tv: TV unreachable after retries; giving up")
    try:
        state = _tv_state(sock, client_id)
        if mode == "on":
            if state != "on":  # standby, or the silence that stands for it
                sock.sendall(_publish_packet(_T_SENDKEY.format(c=client_id), "KEY_POWER"))
                print("toggle-tv: TV asleep, sent KEY_POWER")
            else:
                print("toggle-tv: TV already on, nothing to do")
        else:
            if state == "on":  # and only then -- silence must not be toggled
                sock.sendall(_publish_packet(_T_SENDKEY.format(c=client_id), "KEY_POWER"))
                print("toggle-tv: TV on, sent KEY_POWER")
            elif state == "standby":
                print("toggle-tv: TV already off, nothing to do")
            else:
                print("toggle-tv: TV state unknown, leaving it alone")
        try:
            sock.sendall(bytes([0xE0, 0x00]))  # MQTT DISCONNECT
        except OSError:
            pass
    finally:
        sock.close()


if __name__ == "__main__":
    main()
