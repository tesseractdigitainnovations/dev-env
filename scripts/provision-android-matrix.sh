#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; echo "ERROR: command failed"; echo "  line: $LINENO"; echo "  command: $BASH_COMMAND"; exit 1' ERR

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
ANDROID_SDK_ROOT="$ANDROID_HOME"
APIS=(34 35 36)
DEVICE_PROFILE="pixel_2"
CPU_CORES=2
RAM_MB=3072
IMAGE_FLAVOR="google_apis"
ARCH="x86_64"
ANDROID_CLI_INSTALL_URL="https://dl.google.com/android/cli/latest/linux_x86_64/install.sh"

export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$HOME/.local/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

log(){ echo; echo "==> $*"; }
die(){ echo; echo "ERROR: $*"; exit 1; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
sdk_package_installed(){ android sdk list 2>/dev/null | grep -Fq "$1"; }
install_sdk_if_missing(){
  local package="$1"
  if sdk_package_installed "$package"; then
    echo "Already installed: $package"
  else
    echo "Installing: $package"
    android sdk install "$package"
  fi
}

log "Checking host"
[[ "$(uname -m)" == "x86_64" ]] || die "x86_64 host required"
[[ -e /dev/kvm ]] || die "/dev/kvm does not exist"
ls -l /dev/kvm
if ! command_exists kvm-ok; then
  sudo apt-get update
  sudo apt-get install -y \
      cpu-checker \
      qemu-system-x86 \
      xvfb \
      unzip \
      wget \
      curl \
      ca-certificates \
      adb \
      openjdk-21-jdk-headless
fi
kvm-ok

log "Installing host dependencies"
sudo apt-get update
sudo apt-get install -y cpu-checker qemu-system-x86 xvfb curl wget unzip ca-certificates openjdk-21-jdk-headless adb
sudo usermod -aG kvm "$USER"

log "Installing/checking Android CLI"
if ! command_exists android; then
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "$ANDROID_CLI_INSTALL_URL" | bash
fi
export PATH="$HOME/.local/bin:$PATH"
command_exists android || die "Android CLI not found after installation"
android update
android --version || true

log "Configuring Android SDK"
mkdir -p "$ANDROID_HOME"
cat > "$HOME/.androidrc" <<EOF2
--sdk=$ANDROID_HOME
EOF2
android info

log "Initializing Android CLI agent integration"
android init
android skills add --all || true

log "Ensuring exact SDK packages"
for API in "${APIS[@]}"; do
  install_sdk_if_missing "system-images/android-${API}/${IMAGE_FLAVOR}/${ARCH}"
done
install_sdk_if_missing "platform-tools"
install_sdk_if_missing "emulator"
for API in "${APIS[@]}"; do
  install_sdk_if_missing "platforms/android-${API}"
done

log "Verifying emulator/KVM"
EMULATOR="$ANDROID_HOME/emulator/emulator"
ADB="$ANDROID_HOME/platform-tools/adb"
[[ -x "$EMULATOR" ]] || die "Emulator binary not found: $EMULATOR"
[[ -x "$ADB" ]] || die "ADB not found: $ADB"
"$EMULATOR" -accel-check
"$ADB" version

log "Checking hardware profile"
if ! avdmanager list device 2>/dev/null | grep -q "id: '${DEVICE_PROFILE}'"; then
  echo "Available device profiles:"
  avdmanager list device | sed -n "s/.*id: '\([^']*\)'.*/\1/p" | head -50
  die "Device profile '${DEVICE_PROFILE}' not found"
fi

log "Ensuring AVDs exist"
for API in "${APIS[@]}"; do
  AVD_NAME="app-api${API}"
  IMAGE="system-images;android-${API};${IMAGE_FLAVOR};${ARCH}"
  if emulator -list-avds | grep -Fxq "$AVD_NAME"; then
    echo "Already exists: $AVD_NAME"
  else
    echo "Creating $AVD_NAME from exact image $IMAGE"
    echo "no" | avdmanager create avd --force --name "$AVD_NAME" --package "$IMAGE" --device "$DEVICE_PROFILE"
  fi
  AVD_CONFIG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
  if [[ -f "$AVD_CONFIG" ]]; then
    sed -i \
      -e '/^hw.cpu.ncore=/d' \
      -e '/^hw.ramSize=/d' \
      -e '/^hw.keyboard=/d' \
      -e '/^hw.audioInput=/d' \
      -e '/^hw.audioOutput=/d' \
      -e '/^showDeviceFrame=/d' \
      -e '/^fastboot.forceColdBoot=/d' \
      -e '/^hw.gpu.enabled=/d' "$AVD_CONFIG"
    cat >> "$AVD_CONFIG" <<EOF2

hw.cpu.ncore=${CPU_CORES}
hw.ramSize=${RAM_MB}
hw.keyboard=yes
hw.audioInput=no
hw.audioOutput=no
showDeviceFrame=no
fastboot.forceColdBoot=yes
hw.gpu.enabled=no
EOF2
  fi
done

log "Writing environment"
cat > "$HOME/.android-env" <<EOF2
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
export PATH="$HOME/.local/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:\$PATH"
EOF2

log "Installing lifecycle commands"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="$HOME/.local/bin"
mkdir -p "$INSTALL_BIN"
for f in android-test-start android-test-stop android-test-reset android-test-status android-test-wait android-test-install android-test-screenshot android-test-logs; do
  install -m 0755 "$SCRIPT_DIR/bin/$f" "$INSTALL_BIN/$f"
done

log "Ensuring emulators are stopped by default"
"$INSTALL_BIN/android-test-stop" || true

log "Final verification"
echo "AVDs:"
emulator -list-avds
echo
echo "Running emulator processes:"
if pgrep -af -- "$ANDROID_HOME/emulator/emulator" >/dev/null 2>&1; then
  pgrep -af -- "$ANDROID_HOME/emulator/emulator"
  echo "WARNING: emulator process still detected"
else
  echo "NONE"
fi

echo
echo "Done. Emulators are provisioned but stopped."
echo "Use: android-test-start app-api35"
