#!/usr/bin/env bash
# Keeps the build server tidy by itself, for every app that builds on it.
# Run once as root:   curl -fsSL <this file> | bash
#
# What it installs: a small program (/usr/local/bin/ci-cleanup.sh) that runs every 20 minutes, and ONLY while no
# build is running. It removes things a build leaves behind and that are made again on the next build:
#   - the checked-out project folders inside every GitHub runner's _work folder (source, node_modules, android build)
#   - build caches (Gradle build cache and transforms, Gradle daemons, npm cache, Metro/Expo temp files in /tmp)
#   - old system logs and downloaded package files
# It never touches: the runners themselves, the Android tools, the Gradle download cache (kept for fast builds, only
# removed when the disk is nearly full), your VPN, the Rizz test server, or anything else.
set -euo pipefail
if [ "$(id -u)" != "0" ]; then echo "Run this as root."; exit 1; fi

cat > /usr/local/bin/ci-cleanup.sh <<'CLEANUP'
#!/usr/bin/env bash
# Build-server tidy-up (installed by server-cleanup.sh). Safe to run by hand: ci-cleanup.sh [--report]
set -uo pipefail
free_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }

if pgrep -f "Runner.Worker" >/dev/null 2>&1; then echo "$(date -Is) a build is running: nothing cleaned"; exit 0; fi
BEFORE=$(free_gb)

# 1. project folders left behind in every runner's _work (the next build checks them out again)
while IFS= read -r w; do
  [ -d "$w" ] || continue
  for d in "$w"/*/; do
    n=$(basename "$d")
    case "$n" in _tool|_temp|_actions|_PipelineMapping|_update_*) continue;; esac
    rm -rf "$d" 2>/dev/null
  done
  rm -rf "$w"/_temp/* 2>/dev/null
done < <(find /home /root /opt /srv -maxdepth 3 -type d -name _work 2>/dev/null)

# 2. caches that are made again by the next build
for h in /home/* /root; do
  [ -d "$h" ] || continue
  rm -rf "$h"/.gradle/daemon "$h"/.gradle/.tmp "$h"/.gradle/caches/build-cache-* "$h"/.gradle/caches/transforms-* \
         "$h"/.gradle/caches/jars-* "$h"/.gradle/caches/journal-* "$h"/.gradle/native "$h"/.npm/_cacache "$h"/.npm/_logs \
         "$h"/.cache/yarn "$h"/.cache/pip "$h"/.expo/cache "$h"/.android/cache 2>/dev/null
done
rm -rf /tmp/metro-* /tmp/haste-map-* /tmp/react-* /tmp/expo-* /tmp/gradle* /tmp/kotlin* /tmp/jna-* /tmp/hsperfdata_* /tmp/*.aab /tmp/*.apk 2>/dev/null

# 3. system leftovers
apt-get clean 2>/dev/null
journalctl --vacuum-size=100M >/dev/null 2>&1
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null
find /var/crash -type f -delete 2>/dev/null

# 4. only if the disk is still nearly full: also drop the Gradle download cache (the next build downloads it again)
if [ "$(free_gb)" -lt 12 ]; then
  for h in /home/* /root; do rm -rf "$h"/.gradle/caches "$h"/.cache 2>/dev/null; done
fi

AFTER=$(free_gb)
echo "$(date -Is) cleaned: free disk ${BEFORE} GB -> ${AFTER} GB"
if [ "${1:-}" = "--report" ] || [ "$AFTER" -lt 10 ]; then
  echo "Biggest folders that are left (these are NOT touched by the cleanup):"
  du -xh --max-depth=2 /home /root /opt /var /tmp /srv 2>/dev/null | sort -rh | head -15
  command -v docker >/dev/null 2>&1 && { echo "Docker:"; docker system df 2>/dev/null; }
fi
CLEANUP
chmod 755 /usr/local/bin/ci-cleanup.sh

cat > /etc/cron.d/ci-cleanup <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/20 * * * * root /usr/local/bin/ci-cleanup.sh >> /var/log/ci-cleanup.log 2>&1
CRON
chmod 644 /etc/cron.d/ci-cleanup

echo "Cleaning now ..."
/usr/local/bin/ci-cleanup.sh --report
echo
echo "DONE. The server now tidies itself every 20 minutes (only while no build runs). Log: /var/log/ci-cleanup.log"
