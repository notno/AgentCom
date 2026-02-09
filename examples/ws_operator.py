#!/usr/bin/env python3
"""
Example WebSocket operator agent.

This operator modifies signals by amplifying storm-related responders.
It connects to SpellRouter, registers itself, and responds to transform requests.

Usage:
    pip install websocket-client
    python ws_operator.py [host:port]

Then include it in a pipeline:
    {"type": "remote", "agent": "storm_amplifier"}
"""

import sys
import json
import websocket

HOST = sys.argv[1] if len(sys.argv) > 1 else "localhost:4000"
AGENT_ID = "storm_amplifier"


def transform_signal(signal: dict) -> dict:
    """Apply storm amplification to the signal."""
    values = signal.get("values", {})
    
    # Amplify storm-related responders
    values["storm_bringer"] = min(1.0, values.get("storm_bringer", 0) + 0.35)
    values["void_singer"] = min(1.0, values.get("void_singer", 0) + 0.15)
    values["spark_lord"] = min(1.0, values.get("spark_lord", 0) + 0.10)
    
    # Dampen quiet aspects
    values["quiet_tide"] = max(-1.0, values.get("quiet_tide", 0) - 0.20)
    values["silk_shadow"] = max(-1.0, values.get("silk_shadow", 0) - 0.10)
    
    signal["values"] = values
    return signal


def on_message(ws, message):
    msg = json.loads(message)
    print(f"← {msg['type']}: {json.dumps(msg)[:100]}...")
    
    if msg["type"] == "transform":
        # Transform the signal
        signal = transform_signal(msg["signal"])
        
        response = {
            "type": "transform_result",
            "request_id": msg["request_id"],
            "signal": signal
        }
        print(f"→ transform_result for {msg['request_id']}")
        ws.send(json.dumps(response))
    
    elif msg["type"] == "registered":
        print(f"✓ Registered as {msg['agent_id']}")
    
    elif msg["type"] == "pong":
        pass  # Heartbeat response


def on_error(ws, error):
    print(f"Error: {error}")


def on_close(ws, close_status_code, close_msg):
    print(f"Connection closed: {close_status_code} {close_msg}")


def on_open(ws):
    print(f"Connected to ws://{HOST}/socket")
    
    # Register as an operator
    register_msg = {
        "type": "register",
        "agent_id": AGENT_ID,
        "capabilities": ["transform"]
    }
    print(f"→ Registering as {AGENT_ID}")
    ws.send(json.dumps(register_msg))


if __name__ == "__main__":
    print(f"🌩️  Storm Amplifier Operator")
    print(f"   Connecting to ws://{HOST}/socket")
    print()
    
    ws = websocket.WebSocketApp(
        f"ws://{HOST}/socket",
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close
    )
    
    ws.run_forever()
