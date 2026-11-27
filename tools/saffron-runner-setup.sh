#!/usr/bin/env bash
# Turns this Ubuntu server into a build machine for the Saffron app (GitHub repository us-crypto/saffron-app).
# Run once, as root:   curl -fsSL <this file> | bash -s -- <runner-token>
# Safe to run again: every step checks what is already done.
set -euo pipefail

TOKEN="${1:-}"
if [ -z "$TOKEN" ]; then echo "Missing the runner token (the long text after --token)."; exit 1; fi
if [ "$(id -u)" != "0" ]; then echo "Run this as root."; exit 1; fi

REPO_URL="https://github.com/us-crypto/saffron-app"
# Use the same build user and the same Android tools as the other apps on this server when they exist
# (saves about 7 GB). Otherwise create a build user and its own Android tools.
RUN_USER="saffronrunner"
if id builder >/dev/null 2>&1; then RUN_USER="builder"; fi
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
[ -n "$RUN_HOME" ] || RUN_HOME="/home/${RUN_USER}"
RUNNER_DIR="${RUN_HOME}/actions-runner-saffron"
SDK="${RUN_HOME}/android-sdk"
for c in /opt/android-sdk /usr/lib/android-sdk "${RUN_HOME}/android-sdk" "${RUN_HOME}/Android/Sdk"; do
  if [ -x "$c/cmdline-tools/latest/bin/sdkmanager" ]; then SDK="$c"; break; fi
done
RUN_AS() { su -l -s /bin/bash "$RUN_USER" -c "$1"; }
RUNNER_VER="2.338.2"
RUNNER_SHA="baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
CMDTOOLS="commandlinetools-linux-11076708_latest.zip"

echo "== 0/7 Self-cleaning for the build server (removes leftovers of finished builds, also for the other apps)"
curl -fsSL https://raw.githubusercontent.com/us-crypto/saffron-updates/main/tools/server-cleanup.sh | bash || true

echo "== 1/7 Disk and network check"
mkdir -p /home
FREE_GB=$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')
echo "Free disk space: ${FREE_GB} GB"
if [ "${FREE_GB}" -lt 10 ]; then echo "Still less than 10 GB free after cleaning. Send me the list of biggest folders printed above."; exit 1; fi
for u in https://github.com https://dl.google.com/android/repository/ https://maven.google.com https://services.gradle.org; do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$u" || true)
  echo "  $u -> $code"
  if [ "$code" = "000" ]; then echo "This server cannot reach $u. Android builds need it."; exit 1; fi
done

echo "== 2/7 Programs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openjdk-17-jdk-headless unzip zip curl git python3 python3-venv gh util-linux >/dev/null

echo "== 3/7 Extra memory (swap) so the 4 GB server does not run out during a build"
if [ -z "$(swapon --show --noheadings)" ] && [ "${FREE_GB}" -ge 14 ]; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  4 GB swap added"
else
  echo "  swap already present or not enough disk: skipped"
fi

echo "== 4/7 Build user"
id "$RUN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RUN_USER"
echo "  build user: $RUN_USER, Android tools: $SDK"

echo "== 5/7 Android tools"
if [ ! -x "${SDK}/cmdline-tools/latest/bin/sdkmanager" ]; then
  TMP=$(mktemp -d)
  curl -fsSL -o "${TMP}/${CMDTOOLS}" "https://dl.google.com/android/repository/${CMDTOOLS}"
  unzip -q "${TMP}/${CMDTOOLS}" -d "${TMP}"
  mkdir -p "${SDK}/cmdline-tools"
  rm -rf "${SDK}/cmdline-tools/latest"
  mv "${TMP}/cmdline-tools" "${SDK}/cmdline-tools/latest"
  rm -rf "$TMP"
  chown -R "${RUN_USER}:${RUN_USER}" "$SDK"
fi
# the build user must be able to write there (Gradle adds missing parts by itself)
if ! RUN_AS "test -w ${SDK}"; then chown -R "${RUN_USER}:${RUN_USER}" "$SDK"; fi
RUN_AS "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64; yes | ${SDK}/cmdline-tools/latest/bin/sdkmanager --sdk_root=${SDK} --licenses >/dev/null; ${SDK}/cmdline-tools/latest/bin/sdkmanager --sdk_root=${SDK} 'platform-tools' >/dev/null" || true
echo "  Android tools ready"

echo "== 6/7 GitHub build runner"
if [ ! -x "${RUNNER_DIR}/config.sh" ]; then
  TMP=$(mktemp -d)
  curl -fsSL -o "${TMP}/runner.tar.gz" "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-linux-x64-${RUNNER_VER}.tar.gz"
  echo "${RUNNER_SHA}  ${TMP}/runner.tar.gz" | sha256sum -c -
  mkdir -p "$RUNNER_DIR"
  tar xzf "${TMP}/runner.tar.gz" -C "$RUNNER_DIR"
  rm -rf "$TMP"
  chown -R "${RUN_USER}:${RUN_USER}" "$RUNNER_DIR"
fi
if [ ! -f "${RUNNER_DIR}/.runner" ]; then
  RUN_AS "cd ${RUNNER_DIR} && ./config.sh --unattended --replace --url ${REPO_URL} --token ${TOKEN} --name canada-saffron --labels saffron --work _work"
fi
cat > "${RUNNER_DIR}/.env" <<EOF
ANDROID_HOME=${SDK}
ANDROID_SDK_ROOT=${SDK}
LANG=C.UTF-8
EOF
chown "${RUN_USER}:${RUN_USER}" "${RUNNER_DIR}/.env"

echo "== 7/7 Start as a service (starts again after a reboot)"
cd "$RUNNER_DIR"
./svc.sh install "$RUN_USER" >/dev/null 2>&1 || true
./svc.sh start >/dev/null 2>&1 || true
sleep 3
./svc.sh status | head -5 || true

echo
echo "DONE. In GitHub the runner 'canada-saffron' should now show as Idle."
