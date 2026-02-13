# CoronaSDR - Server Setup Guide

## What You Need

1. **RTL-SDR USB dongle** (RTL2832U-based, e.g. RTL-SDR Blog V3/V4)
2. **Raspberry Pi** (3B+ or newer) or **Linux/macOS PC**
3. **Local network** (Wi-Fi for iOS device; wired Ethernet strongly recommended for the server)

## Setting Up rtl_tcp on Raspberry Pi

### Install rtl-sdr tools

```bash
sudo apt update
sudo apt install rtl-sdr librtlsdr-dev
```

### Test the dongle

```bash
rtl_test -t
```

You should see your tuner type (e.g., R820T).

### Start rtl_tcp server

```bash
rtl_tcp -a 0.0.0.0 -p 1234
```

Options:
- `-a 0.0.0.0` — listen on all interfaces
- `-p 1234` — port (default 1234)
- `-s 1024000` — sample rate (default)
- `-g 0` — gain (0 = auto)

### Auto-start on boot (systemd)

Create `/etc/systemd/system/rtl_tcp.service`:

```ini
[Unit]
Description=RTL-TCP SDR Server
After=network.target

[Service]
ExecStart=/usr/bin/rtl_tcp -a 0.0.0.0 -p 1234
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable rtl_tcp
sudo systemctl start rtl_tcp
```

## Bonjour/mDNS Discovery (Optional)

To enable automatic discovery from the iOS app, advertise the service via Avahi.

Create `/etc/avahi/services/rtltcp.service`:

```xml
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>RTL-SDR Server</name>
  <service>
    <type>_rtltcp._tcp</type>
    <port>1234</port>
  </service>
</service-group>
```

```bash
sudo systemctl restart avahi-daemon
```

## Network Recommendations

- **Wired Ethernet** for the server provides the most stable throughput
- At 2.4 MSPS, the data rate is ~4.8 MB/s (~38 Mbps) — manageable for good Wi-Fi, but drops can cause audio glitches
- Use the "Low" sample rate profile (1.024 MSPS) on slower networks
- Keep the iOS device and server on the **same subnet** (no NAT)
