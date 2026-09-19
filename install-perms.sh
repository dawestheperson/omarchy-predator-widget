#!/usr/bin/env bash
# Run once:  sudo bash ~/.config/omarchy/plugins/dawestheperson.predator/install-perms.sh
# 1. Installs a boot service that makes the Linuwu-Sense fan, battery and CPU-cap control
#    files group-writable by `wheel`, so the bar panel can change them without a
#    password prompt on every slider move.
# 2. Also opens the CPU boost cap (intel_pstate/max_perf_pct). Safe to re-run.
# Undo:  sudo systemctl disable --now predator-sense-perms && sudo rm /etc/systemd/system/predator-sense-perms.service
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }

install -m 0755 -o root -g root /dev/stdin /usr/local/sbin/predator-sense-perms <<'HELPER'
#!/usr/bin/env bash
D=/sys/devices/platform/acer-wmi/predator_sense
for _ in $(seq 30); do [ -e "$D/fan_speed" ] && break; sleep 1; done
for f in "$D/fan_speed" "$D/battery_limiter" /sys/devices/system/cpu/intel_pstate/max_perf_pct; do
  [ -e "$f" ] && chgrp wheel "$f" && chmod g+w "$f"
done
exit 0
HELPER

cat > /etc/systemd/system/predator-sense-perms.service <<'UNIT'
[Unit]
Description=Group-write (wheel) on Linuwu-Sense fan, battery and CPU-cap controls
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/predator-sense-perms

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable predator-sense-perms.service
systemctl restart predator-sense-perms.service

ls -l /sys/devices/platform/acer-wmi/predator_sense/{fan_speed,battery_limiter} /sys/devices/system/cpu/intel_pstate/max_perf_pct
