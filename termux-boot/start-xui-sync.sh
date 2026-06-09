#!/data/data/com.termux/files/usr/bin/bash
#
# Termux:Boot startup script.
#
# Install:
#   1) Install the "Termux:Boot" app (F-Droid).
#   2) mkdir -p ~/.termux/boot
#   3) cp termux-boot/start-xui-sync.sh ~/.termux/boot/
#   4) chmod +x ~/.termux/boot/start-xui-sync.sh
#
# This keeps the CPU awake and (re)starts the crond service after a reboot.

# Keep the device from sleeping so scheduled syncs keep firing.
termux-wake-lock

# Bring the supervised services back up after a reboot:
#   crond     -> hourly sync
#   xui-panel -> local web admin panel
sv up crond 2>/dev/null || crond 2>/dev/null || true
sv up xui-panel 2>/dev/null || true
