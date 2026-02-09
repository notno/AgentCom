# Meshtastic Integration for SpellRouter

Off-grid spell casting over LoRa mesh networks.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        MESH NETWORK                             │
│                                                                 │
│   ┌─────────────┐        ┌─────────────┐        ┌─────────────┐│
│   │ Pi + LoRa   │~~~~~~~~│ Pi + LoRa   │~~~~~~~~│ Pi + LoRa   ││
│   │  "ignite"   │  LoRa  │   "hush"    │  LoRa  │  "veil"     ││
│   │  operator   │  mesh  │  operator   │  mesh  │  operator   ││
│   └─────────────┘        └─────────────┘        └─────────────┘│
│         │                                              │        │
│         │ (optional)                      (optional)   │        │
│         ▼                                              ▼        │
│   ┌─────────────────────────────────────────────────────┐      │
│   │          WiFi/Internet Gateway (optional)           │      │
│   │              SpellRouter Hub                        │      │
│   └─────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

Two modes:
1. **Hub mode**: Mesh nodes relay to a central SpellRouter (hybrid connectivity)
2. **Pure P2P mode**: Spells propagate entirely over mesh, no internet

## Hardware Options

### Meshtastic Devices (ready to go)
- **Heltec LoRa 32** (~$20) - ESP32 + LoRa + OLED
- **LILYGO T-Beam** (~$35) - ESP32 + LoRa + GPS
- **RAK WisBlock** (~$30) - Modular, low power

### Nerves + LoRa (custom/powerful)
- **Raspberry Pi Zero W** (~$15) + **RFM95W LoRa module** (~$10)
- **Raspberry Pi + RAK2245** (LoRa concentrator, more range)
- Run full Elixir/OTP on the device

### Hybrid Approach (recommended for MVP)
- Use off-the-shelf Meshtastic devices
- Connect to them via **serial/USB** from a Pi running Nerves
- Pi handles spell logic, Meshtastic handles radio

```
┌──────────────────────┐     USB/Serial     ┌──────────────────┐
│   Nerves (Elixir)    │◄──────────────────►│    Meshtastic    │
│   Spell Operator     │     Protobuf       │    LoRa Radio    │
│   Business Logic     │                    │    Mesh Network  │
└──────────────────────┘                    └──────────────────┘
```

## Protocol Layers

### Layer 1: Meshtastic Transport
Meshtastic uses protobufs over a framed serial protocol:

```
┌────────┬────────┬─────────┬──────────────────┐
│ 0x94   │ 0xc3   │ LEN_MSB │ LEN_LSB │ PROTOBUF...
└────────┴────────┴─────────┴──────────────────┘
   START1   START2     Length        Payload
```

Key protobufs:
- `ToRadio` - Commands to the radio
- `FromRadio` - Events from the radio  
- `MeshPacket` - Actual mesh messages
- `Data` - Payload within packets (we use this)

### Layer 2: Spell Signal Encoding

Compress the 16-dimensional signal for LoRa's limited bandwidth.

**Option A: Quantized Binary (64 bytes)**
```
┌────────┬────────────────────────────────────────────┐
│ Header │ 16 × 4-byte floats (IEEE 754)              │
│ 4 bytes│ = 64 bytes                                 │
└────────┴────────────────────────────────────────────┘

Header: [version:4][op_id:8][seq:12][flags:8] = 32 bits
Total: 68 bytes (fits in one LoRa packet)
```

**Option B: Quantized Compact (34 bytes)**
```
Each responder = 1 byte (signed, -127 to +127, /127.0 = float)
16 responders = 16 bytes
+ 4 byte header + 2 byte checksum = 22 bytes
```

**Option C: Delta Encoding (variable)**
Only send changes from previous signal:
```
[header][count][idx1,delta1][idx2,delta2]...
```

### Layer 3: Spell Protocol

Messages between operators:

```protobuf
// spell_signal.proto
syntax = "proto3";

message SpellSignal {
  uint32 spell_id = 1;        // Unique spell instance
  uint32 sequence = 2;        // Step in pipeline
  string source_node = 3;     // Originating operator
  string target_node = 4;     // Next operator (or broadcast)
  bytes values = 5;           // Quantized 16-dim vector
  uint32 timestamp = 6;       // For ordering
}

message SpellAck {
  uint32 spell_id = 1;
  uint32 sequence = 2;
  bool success = 3;
  string error = 4;
}
```

## Elixir Implementation

### Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:protox, "~> 1.7"},           # Protobuf encoding
    {:circuits_uart, "~> 1.5"},    # Serial communication
    {:nerves, "~> 1.10", runtime: false},  # For embedded
  ]
end
```

### Meshtastic Client

```elixir
defmodule SpellRouter.Meshtastic.Client do
  @moduledoc """
  Serial connection to a Meshtastic device.
  """
  use GenServer
  alias Circuits.UART

  @start1 0x94
  @start2 0xc3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = opts[:port] || "/dev/ttyUSB0"
    {:ok, uart} = UART.start_link()
    :ok = UART.open(uart, port, speed: 115200, active: true)
    
    {:ok, %{uart: uart, buffer: <<>>, handlers: []}}
  end

  def send_packet(data) when is_binary(data) do
    GenServer.call(__MODULE__, {:send, data})
  end

  def handle_call({:send, data}, _from, state) do
    frame = <<@start1, @start2, byte_size(data)::16>> <> data
    UART.write(state.uart, frame)
    {:reply, :ok, state}
  end

  def handle_info({:circuits_uart, _port, data}, state) do
    buffer = state.buffer <> data
    {packets, remaining} = parse_frames(buffer)
    
    for packet <- packets do
      handle_packet(packet, state.handlers)
    end
    
    {:noreply, %{state | buffer: remaining}}
  end

  defp parse_frames(<<@start1, @start2, len::16, rest::binary>> = buffer) 
       when byte_size(rest) >= len do
    <<packet::binary-size(len), remaining::binary>> = rest
    {more_packets, final_remaining} = parse_frames(remaining)
    {[packet | more_packets], final_remaining}
  end
  defp parse_frames(buffer), do: {[], buffer}

  defp handle_packet(packet, handlers) do
    # Decode protobuf and dispatch
    case Meshtastic.FromRadio.decode(packet) do
      {:ok, msg} -> Enum.each(handlers, &send(&1, {:mesh_message, msg}))
      {:error, _} -> :ignore
    end
  end
end
```

### Mesh Operator

```elixir
defmodule SpellRouter.Operator.Mesh do
  @moduledoc """
  An operator that sends/receives signals over Meshtastic.
  """
  use GenServer
  
  alias SpellRouter.Signal
  alias SpellRouter.Meshtastic.Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def init(opts) do
    node_id = opts[:node_id] || generate_node_id()
    
    {:ok, %{
      node_id: node_id,
      pending_spells: %{},
      known_operators: %{}
    }}
  end

  @doc "Send a signal to a remote operator over mesh"
  def send_signal(operator_name, %Signal{} = signal, opts \\ []) do
    GenServer.call(__MODULE__, {:send_signal, operator_name, signal, opts})
  end

  def handle_call({:send_signal, target, signal, _opts}, from, state) do
    spell_id = :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned()
    
    # Encode signal to compact binary
    encoded = encode_signal(signal)
    
    # Build mesh packet
    packet = %SpellSignal{
      spell_id: spell_id,
      sequence: 0,
      source_node: state.node_id,
      target_node: target,
      values: encoded,
      timestamp: System.system_time(:second)
    }
    
    # Send over mesh
    Client.send_packet(SpellSignal.encode(packet))
    
    # Track pending
    state = put_in(state.pending_spells[spell_id], %{from: from, sent_at: DateTime.utc_now()})
    
    {:noreply, state}
  end

  defp encode_signal(%Signal{values: values}) do
    # Quantize to bytes: float [-1,1] -> byte [-127,127]
    Signal.responders()
    |> Enum.map(fn r -> 
      val = Map.get(values, r, 0.0)
      round(val * 127) |> max(-127) |> min(127)
    end)
    |> :binary.list_to_bin()
  end

  defp decode_signal(<<bytes::binary-size(16)>>) do
    values = 
      :binary.bin_to_list(bytes)
      |> Enum.zip(Signal.responders())
      |> Enum.map(fn {byte, responder} ->
        # Convert signed byte back to float
        val = if byte > 127, do: byte - 256, else: byte
        {responder, val / 127.0}
      end)
      |> Map.new()
    
    %Signal{values: values}
  end
end
```

## Network Topology Options

### Option 1: Star (Hub-and-Spoke)
```
       [Hub]
      /  |  \
     /   |   \
   [A]  [B]  [C]
```
- Simple routing
- Hub is single point of failure
- Good for: fixed installations, workshops

### Option 2: Linear Pipeline
```
[Source] → [Op1] → [Op2] → [Op3] → [Emit]
```
- Signal flows through operators in order
- Each node knows only "next"
- Good for: ritual processions, spatial spells

### Option 3: Full Mesh (P2P)
```
   [A]───[B]
    │╲   ╱│
    │ ╲ ╱ │
    │  ╳  │
    │ ╱ ╲ │
   [C]───[D]
```
- Any node can route to any other
- Most resilient
- Needs discovery/routing protocol
- Good for: festivals, distributed rituals

## Bandwidth Considerations

LoRa bandwidth varies by settings:
- **Long range mode**: ~0.3 kbps (max ~20 bytes/sec)
- **Fast mode**: ~21 kbps (max ~2.6 KB/sec)
- **Meshtastic default**: ~1-5 kbps

Our compact signal (22 bytes) + overhead (~30 bytes) ≈ 52 bytes

At 1 kbps:
- ~2 signals/second sustained
- Latency: 400-800ms per hop

**Implications:**
- Keep signals small
- Batch updates if possible
- Consider delta encoding for repeated transforms
- Async/eventual consistency model

## Security

Meshtastic supports:
- **AES-256 encryption** on channel
- **Channel keys** shared among trusted nodes

For spell routing:
- Use a dedicated encrypted channel for spell traffic
- Consider signing signals (Ed25519) for authenticity
- Node allowlists for operator registration

## MVP Roadmap

### Phase 1: Serial Bridge
1. Get Meshtastic device
2. Connect via USB to dev machine
3. Elixir client sends/receives raw messages
4. Prove round-trip works

### Phase 2: Signal Encoding
1. Implement compact signal format
2. Test encode/decode cycle
3. Measure actual bandwidth usage

### Phase 3: Nerves Deployment
1. Port to Nerves on Pi Zero
2. Run as standalone operator node
3. Test mesh with 2-3 devices

### Phase 4: Integration
1. Bridge mesh operators to SpellRouter hub
2. Mixed pipelines (local + mesh operators)
3. Full distributed spells

## Hardware Shopping List (MVP)

| Item | Price | Notes |
|------|-------|-------|
| Heltec LoRa 32 v3 (×2) | $40 | Meshtastic-ready |
| Raspberry Pi Zero 2 W | $15 | Runs Nerves |
| USB-C cables | $10 | Connect Pi to Heltec |
| **Total** | ~$65 | Basic 2-node test setup |

Alternative: **LILYGO T-Echo** ($50) - has e-ink display, good for showing spell state.

## Resources

- [Meshtastic Protobufs](https://github.com/meshtastic/protobufs)
- [Meshtastic Python API](https://python.meshtastic.org/)
- [Nerves Project](https://nerves-project.org/)
- [Circuits.UART](https://hexdocs.pm/circuits_uart/)
- [Protox (Elixir protobuf)](https://github.com/ahamez/protox)
