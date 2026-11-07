#!/usr/bin/env python3
"""Test sender for tvOS Browser's network pointer receiver.

Run on any computer on the same Wi-Fi as the Apple TV (Python 3, no extra packages):

    python3 pointer_test_sender.py 192.168.1.50            # draw circles with the cursor, then click
    python3 pointer_test_sender.py 192.168.1.50 --mode gyro # same, but as simulated gyro packets
    python3 pointer_test_sender.py 192.168.1.50 --mode scroll

The Apple TV's address is shown in the app's Motion Debug Overlay
(Play/Pause double tap -> Motion Pointer -> Show Motion Debug Overlay).
"""

import argparse
import json
import math
import socket
import time

PORT = 47800


def send(sock, addr, packet):
    sock.sendto(json.dumps(packet).encode("utf-8"), addr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host", help="Apple TV IP address")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--mode", choices=["move", "gyro", "scroll"], default="move")
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--no-click", action="store_true", help="don't send a click at the end")
    args = parser.parse_args()

    addr = (args.host, args.port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)

    send(sock, addr, {"type": "hello", "name": socket.gethostname()})
    try:
        reply, _ = sock.recvfrom(2048)
        print("Receiver replied:", reply.decode("utf-8", "replace"))
    except socket.timeout:
        print("No welcome reply within 1 s (check IP / Wi-Fi / that the app is open). Sending anyway...")

    rate = 60.0
    steps = int(args.seconds * rate)
    radius_px = 250.0
    sensitivity = 2600.0  # must match the app's default to make gyro circles the same size
    for i in range(steps):
        angle = 2 * math.pi * i / (rate * 2)  # one circle every 2 seconds
        dx = -radius_px * math.sin(angle) * (2 * math.pi / (rate * 2))
        dy = radius_px * math.cos(angle) * (2 * math.pi / (rate * 2))
        if args.mode == "move":
            send(sock, addr, {"type": "move", "dx": dx, "dy": dy})
        elif args.mode == "gyro":
            send(sock, addr, {"type": "motion", "dyaw": dx / sensitivity, "dpitch": -dy / sensitivity})
        else:
            send(sock, addr, {"type": "scroll", "dx": 0, "dy": 8 if (i // 60) % 2 == 0 else -8})
        time.sleep(1.0 / rate)

    if not args.no_click and args.mode != "scroll":
        send(sock, addr, {"type": "click"})
        print("Sent click.")
    print(f"Sent {steps} {args.mode} packets to {args.host}:{args.port}.")


if __name__ == "__main__":
    main()
