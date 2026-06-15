# multi-fec — Options Reference

`multi-fec` is a UDP proxy combining FEC (Forward Error Correction),
multipath routing, and GFW/DPI obfuscation. It sits between WireGuard and
the network, transparently improving tunnel reliability and survivability.

---

## Architecture overview

```
[WireGuard client]
       |  UDP (plaintext — WireGuard encrypts this)
[multi-fec client]  ──path1──────────────▶  [multi-fec server]
                    ──path2──▶ [POP relay] ──▶       |  UDP
                    ──pathN──────────────▶  [WireGuard server]

Each path: obfs(QUIC/TLS mimic + HMAC auth + size normalization) + FEC
```

- **Client** (`-c`): receives WireGuard traffic on a local port, applies FEC encoding and
  obfuscation, sends over one or more `--path` entries simultaneously (multipath).
  A random 8-byte `session_id` is embedded in every packet so the server can aggregate
  packets arriving via different POPs to the same FEC session.
- **Server** (`-s`): receives obfuscated traffic, verifies HMAC auth, decodes FEC, forwards to
  WireGuard server via `--wg`.
- **Relay/POP** (`-r`): transparent stateful UDP forwarder. Does not decode FEC or obfuscation —
  passes raw bytes unchanged. Useful as a geographic POP between client and server.

### GFW obfuscation layers

| Priority | Layer | Description |
|----------|-------|-------------|
| 1 | HMAC auth | SipHash-2-4 token in every packet. HMAC failure → TLS `close_notify` alert (7 bytes) sent back to prober. |
| 2 | Protocol mimic | `--obfs-mode quic` (default): first byte 0x40–0x7F (QUIC Short Header). `--obfs-mode tls`: `0x17 0x03 0x03` header (TLS 1.3 Application Data). |
| 3 | Packet size normalization | Padded to fixed bucket sizes: 300 / 500 / 700 / 900 / 1100 / 1300 bytes. |

### TCP/UDP port separation

When using UDP/443 with `--obfs-mode tls`, **TCP/443 must be handled by a separate process**
(nginx, caddy, etc.) running independently. The OS separates TCP and UDP at the kernel level —
multi-fec on UDP/443 and nginx on TCP/443 coexist without any integration.

Active UDP probes (GFW scanners) that fail HMAC receive a `TLS close_notify` alert automatically.
TCP probes are handled by nginx/caddy directly.

---

## Synopsis

```
# Client
multi-fec -c -l <local_addr> --path <spec> [--path <spec> ...] -k <key> [OPTIONS]

# Server
multi-fec -s -l <listen_addr> --wg <wg_addr> -k <key> [OPTIONS]

# Relay / POP (transparent forwarder — no key required)
multi-fec -r -l <listen_addr> --upstream <server_addr> [OPTIONS]
```

---

## Required options

### `-c`
Run in **client** mode. Cannot be combined with `-s` or `-r`.

### `-s`
Run in **server** mode. Cannot be combined with `-c` or `-r`.

### `-r`
Run in **relay (POP) mode**. Transparent stateful UDP forwarder.
Does not decode FEC or obfuscation — forwards raw bytes unchanged.
Requires `--upstream`. The `-k` key is **not** required in relay mode.

### `-l ip:port`
**Local listen address.**

| Mode   | Meaning |
|--------|---------|
| Client | Local UDP port WireGuard sends traffic to (e.g. `127.0.0.1:51820`) |
| Server | UDP port to listen on for client connections (e.g. `0.0.0.0:443`) |

### `--path local_ip:remote_ip:port`  *(client only, repeatable)*
Add one **multipath entry**. Specify once per physical interface or ISP link.
The first `--path` is always the highest-priority path in failover mode.

| Field       | Meaning |
|-------------|---------|
| `local_ip`  | Source IP on this machine. `0.0.0.0` = OS auto-select. |
| `remote_ip` | Server's IP address. |
| `port`      | Server's listening port. |

**Examples:**
```
# Single path
--path 0.0.0.0:1.2.3.4:443

# Dual path: wired (eth0) + wireless (wlan0)
--path 192.168.1.10:1.2.3.4:443
--path 10.0.0.2:1.2.3.4:443

# Two ISP uplinks to same server
--path 203.0.113.10:1.2.3.4:443
--path 198.51.100.5:1.2.3.4:443
```

mud_lite selects the best available path based on RTT and packet loss.

### `--wg ip:port`  *(server only)*
**WireGuard upstream address** — the actual WireGuard server that multi-fec
forwards decrypted payloads to.

```
--wg 127.0.0.1:51820    # WireGuard on the same host
--wg 10.0.0.1:51820     # WireGuard on a different host
```

### `-k keystring`
**Pre-shared key** for HMAC authentication and PSK derivation.
Must be identical on client and server. Any printable string, up to 999 chars.

```
-k "my-secret-key-2024"
```

The key is processed as:
```
PSK[0:8]  = SipHash24("multi-fec-psk-v1", key)
PSK[8:16] = SipHash24("multi-fec-psk-v1", key || 0x01)
```

---

## FEC options

### `-f x:y`  *(default: `20:10`)*
**FEC ratio** — for every `x` data packets, send `y` redundant parity packets.
Recovers up to `y` lost packets per group without retransmission.

```
-f 20:10    # 10 parity / 20 data  (~33% overhead, recovers up to ~33% loss)
-f 10:4     # 4 parity / 10 data   (~29% overhead)
-f 4:2      # 2 parity / 4 data    (smaller groups, lower latency penalty)
-f 1:0      # FEC disabled (same as --disable-fec)
```

Higher `y/x` → better loss recovery, higher bandwidth overhead.

### `--fec-timeout N`  *(default: `8` ms)*
Flush an incomplete FEC group after `N` ms of inactivity. Prevents
head-of-line blocking when traffic is bursty.

```
--fec-timeout 8     # good for interactive traffic (gaming, VoIP)
--fec-timeout 50    # better for bulk transfer or video streaming
--fec-timeout 0     # flush only when the group is full
```

### `--mode 0|1`  *(default: `0`)*
**FEC operating mode.**

| Mode | Name | Description |
|------|------|-------------|
| `0` | Bandwidth-saving | Groups packets before encoding. Waits up to `--fec-timeout` for group to fill. |
| `1` | Low-latency | Encodes each packet immediately without grouping. Higher overhead, less delay. |

```
--mode 0    # default: bulk / streaming workloads
--mode 1    # interactive: gaming, VoIP, SSH
```

### `--mtu N`  *(default: `1250`)*
**FEC packet MTU** (bytes). Sets the maximum size for FEC-encoded wire packets.
Should be ≤ path MTU minus IP/UDP headers (~28 bytes) and obfuscation overhead (~10 bytes).

```
--mtu 1250    # safe for most links
--mtu 1400    # if path MTU is 1500 and overhead is known
--mtu 500     # for links with small MTU (e.g. some PPPoE paths)
```

### `-q N` / `--queue-len N`  *(default: `200`)*
**FEC encode queue length** (mode 0 only). Maximum number of packets buffered before
forced encoding. Larger values allow better grouping at the cost of higher memory use.

```
-q 200      # default
-q 50       # low-memory devices
```

### `--decode-buf N`  *(default: `2000`)*
**FEC decoder ring buffer size** (300–20000 packets). Larger buffers allow the decoder
to recover from more reordering and burst loss at the cost of more memory.

```
--decode-buf 2000    # default
--decode-buf 5000    # high-loss / high-reorder links
--decode-buf 300     # minimum (embedded / low-memory)
```

### `--disable-fec`
Completely **disable FEC encoding and decoding**. Packets are passed through without
redundancy. Useful for testing raw tunnel performance without FEC overhead.

---

## Network options

### `--sock-buf N`  *(10–10240 kB, default: OS default)*
Set the UDP socket **send and receive buffer size** to `N` kilobytes via `SO_SNDBUF` /
`SO_RCVBUF`. Increase on high-bandwidth links where the OS default causes drops.

```
--sock-buf 4096    # 4 MB — for 1 Gbps+ links
--sock-buf 512     # 512 kB — moderate throughput
```

> **Note**: Linux caps these at `net.core.rmem_max` / `net.core.wmem_max`. To set 4 MB:
> `sysctl -w net.core.rmem_max=4194304 net.core.wmem_max=4194304`

---

## Obfuscation options

### `--multipath-mode M`  *(client only, default: `failover`)*
Controls how packets are distributed across multiple `--path` entries.

| Mode | Behavior | 사용 시나리오 |
|------|----------|---------------|
| `failover` | Active-Standby. `--path` 순서대로 우선순위(pref 0,1,2...). 상위 경로가 살아있는 한 하위는 대기. 장애 시 자동 전환. | 메인/백업 인터페이스 |
| `duplicate` | 모든 경로에 동일 패킷을 **동시** 전송. 수신측이 중복 자동 제거. 어느 한 경로만 살아있어도 패킷 전달 보장. | 2개 회선 동시 가용성 극대화 |

```
# 예: eth0 장애 시 wlan0으로 자동 전환
--path 192.168.1.10:SERVER:443 --path 10.0.0.2:SERVER:443 --multipath-mode failover

# 예: eth0+wlan0 동시 전송, 어느 쪽이든 도착하면 성공
--path 192.168.1.10:SERVER:443 --path 10.0.0.2:SERVER:443 --multipath-mode duplicate
```

> **Duplicate 모드 동작 원리**
> - 클라이언트: 각 FEC 패킷을 모든 경로로 동시 발송 (인터페이스별 `IP_PKTINFO` 사용)
> - 서버: `mud_recv()`가 패킷 타임스탬프 기반 dedup 링버퍼(128엔트리, 500ms TTL)로
>   중복을 자동 제거 → 첫 번째로 도착한 패킷만 처리
> - 대역폭 소비: 경로 수 × 원래 트래픽. 두 경로면 2배.

### `--obfs-mode M`  *(default: `quic`)*
Choose the protocol mimicry mode for obfuscation.

| Value | Wire format | Best for |
|-------|-------------|----------|
| `quic` | First byte 0x40–0x7F (QUIC Short Header) | UDP on any port |
| `tls`  | `0x17 0x03 0x03 <len>` (TLS 1.3 Application Data record) | UDP/443, co-located with nginx/caddy on TCP/443 |

The decoder **auto-detects** the format from the first byte, so both endpoints can
run different modes simultaneously — no simultaneous restart required during upgrades.

```
# QUIC mimic (default)
multi-fec -s -l 0.0.0.0:4096 --wg 127.0.0.1:51820 -k secret

# TLS mimic on UDP/443
multi-fec -s -l 0.0.0.0:443 --wg 127.0.0.1:51820 -k secret --obfs-mode tls
```

> **TCP/443 co-existence**: nginx or caddy running on TCP/443 operates completely
> independently — the OS separates TCP and UDP sockets. No integration is needed.
> UDP probes that fail HMAC receive an automatic TLS `close_notify` alert (7 bytes).

### `--upstream ip:port`  *(relay mode only)*
The server address that the relay forwards all packets to.

```
multi-fec -r -l 0.0.0.0:443 --upstream 1.2.3.4:443
```

### `--disable-obfs`
Disable all obfuscation layers (QUIC mimic, HMAC auth, size normalization).
Packets are sent in raw mud_lite format. **For testing and debugging only.**

> **Warning**: Without obfuscation any packet is accepted by the server.
> Do not use in production.

---

## Simulation / debug options

### `-j N` / `--jitter N`  *(default: `0`)*
Add **artificial jitter** to outgoing packets. `N` is the maximum additional delay in ms.
Supports `min:max` form for a fixed range.

```
-j 20          # random delay 0–20 ms
-j 10:50       # random delay 10–50 ms
-j 0           # disabled (default)
```

> Used to simulate unstable network conditions in a lab. **Not for production.**

### `--random-drop N`  *(0–10000, default: `0`)*
Simulate **packet loss**. `N` is expressed in units of 0.01% (i.e. 10000 = 100% loss).

```
--random-drop 0       # no loss (default)
--random-drop 100     # 1% loss
--random-drop 1000    # 10% loss
```

> **For testing only.** Simulates a lossy link without needing a real impaired network.

### `--disable-checksum`
Disable **packet checksum** verification. May improve performance on links that already
provide hardware checksum offloading. Not recommended unless you know what you're doing.

---

## Runtime control

### `--fifo PATH`
Create a **FIFO file** at `PATH` and listen for runtime commands. Allows changing FEC
parameters without restarting the process.

```
--fifo /tmp/mf-cmd
```

Supported commands (written to the FIFO as text):

| Command | Example | Effect |
|---------|---------|--------|
| `fec x:y` | `fec 10:4` | Change FEC ratio |
| `mtu N` | `mtu 1200` | Change FEC MTU |
| `mode N` | `mode 1` | Change FEC mode |
| `timeout N` | `timeout 20` | Change FEC timeout (ms) |

```bash
echo "fec 10:4" > /tmp/mf-cmd    # reduce FEC overhead
echo "timeout 20" > /tmp/mf-cmd  # increase timeout
```

### `--report N`  *(default: `0` = disabled)*
Print **statistics** (throughput, FEC recovery rate, loss, latency) every `N` seconds.

```
--report 10    # print stats every 10 seconds
--report 60    # once per minute
```

---

## Logging

### `--log-level N`  *(default: `4`)*

| N | Level   | Description |
|---|---------|-------------|
| 0 | fatal   | Fatal errors only |
| 1 | error   | Errors |
| 2 | warn    | Warnings |
| 3 | info    | Startup, path changes |
| 4 | debug   | Debug messages (default) |
| 5 | trace   | Per-packet trace |
| 6 | verbose | Maximum verbosity |

```
--log-level 3    # production: quiet
--log-level 5    # troubleshooting: trace each packet
```

### `--log-position`
Include **source file, function name, and line number** in each log line.
Useful when debugging with source code in hand.

```
[log.cpp,func:mylog,line:26] [client] mud_recv 128 bytes
```

### `--disable-color` / `--enable-color`
Control **ANSI color output** in log messages. Color is enabled by default.

```
--disable-color    # plain text log (for log files, syslog piping)
--enable-color     # colored output (default, useful in terminal)
```

---

## Full examples

### Minimal single-path setup

**Server:**
```bash
./multi-fec -s \
    -l 0.0.0.0:443 \
    --wg 127.0.0.1:51820 \
    -k "shared-secret" \
    --log-level 3
```

**Client:**
```bash
./multi-fec -c \
    -l 127.0.0.1:51820 \
    --path 0.0.0.0:SERVER_IP:443 \
    -k "shared-secret" \
    --log-level 3
```

### Dual-path with aggressive FEC (high-loss link)

**Server:**
```bash
./multi-fec -s \
    -l 0.0.0.0:443 \
    --wg 127.0.0.1:51820 \
    -k "shared-secret" \
    -f 10:6
```

**Client (eth0 + wlan0 bonded):**
```bash
./multi-fec -c \
    -l 127.0.0.1:51820 \
    --path 192.168.1.10:SERVER_IP:443 \
    --path 10.0.0.2:SERVER_IP:443 \
    -k "shared-secret" \
    -f 10:6
```

### Low-latency interactive traffic (gaming / VoIP)

```bash
# Small FEC groups + short timeout = minimal added latency
./multi-fec -c \
    -l 127.0.0.1:51820 \
    --path 0.0.0.0:SERVER_IP:443 \
    -k "shared-secret" \
    -f 4:2 \
    --fec-timeout 4
```

---

## Option summary table

| Option | Mode | Default | Description |
|--------|------|---------|-------------|
| `-c` | — | — | Client mode |
| `-s` | — | — | Server mode |
| `-r` | — | — | Relay (POP) mode — transparent UDP forwarder |
| `-l ip:port` | all | — | Local listen address |
| `--path local:remote:port` | client | — | Add multipath entry (repeatable) |
| `--multipath-mode M` | client | `failover` | `failover` or `duplicate` |
| `--wg ip:port` | server | — | WireGuard upstream address |
| `--upstream ip:port` | relay | — | Server address to forward to |
| `-k keystring` | client/server | `default-key` | Pre-shared key (not needed for relay) |
| **FEC** | | | |
| `-f x:y` | client/server | `20:10` | FEC data:parity ratio |
| `--fec-timeout N` | client/server | `8` ms | FEC group flush timeout (ms) |
| `--mode 0\|1` | client/server | `0` | FEC mode: 0=bandwidth-saving, 1=low-latency |
| `--mtu N` | client/server | `1250` | FEC packet MTU (bytes) |
| `-q N` / `--queue-len N` | client/server | `200` | FEC encode queue length |
| `--decode-buf N` | client/server | `2000` | FEC decoder ring buffer (300–20000) |
| `--disable-fec` | client/server | off | Disable FEC entirely |
| **Network** | | | |
| `--sock-buf N` | all | OS | UDP socket buffer size (kB) |
| **Obfuscation** | | | |
| `--obfs-mode M` | client/server | `quic` | `quic` (QUIC Short Header) or `tls` (TLS AppData) |
| `--disable-obfs` | client/server | off | Disable obfuscation (testing only) |
| **Simulation** | | | |
| `-j N` / `--jitter N` | all | `0` | Artificial jitter 0–N ms (or min:max) |
| `--random-drop N` | all | `0` | Simulate packet loss N/10000 |
| `--disable-checksum` | all | off | Disable packet checksum |
| **Runtime** | | | |
| `--fifo PATH` | all | — | FIFO for runtime commands |
| `--report N` | all | `0` (off) | Stats reporting interval (seconds) |
| **Logging** | | | |
| `--log-level N` | all | `4` | Log verbosity 0–6 |
| `--log-position` | all | off | Include file/function/line in logs |
| `--disable-color` | all | — | Disable ANSI color in logs |
| `--enable-color` | all | on | Enable ANSI color in logs |
| `-h` / `--help` | — | — | Show help and exit |
