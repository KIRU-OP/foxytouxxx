#!/bin/bash
# Ubuntu 22.04 (proot) installer + launcher, rootless.
# Run with:  bash ubuntu-root.sh
# Install dir: $ROOTFS_DIR (default: ~/ubuntu-root)

set -u

ROOTFS_DIR="${ROOTFS_DIR:-$HOME/ubuntu-root}"
KEY_DIR="$HOME/.ubuntu-root-keys"
BIN_DIR="$HOME/.local/bin"
PROOT_VERSION="v5.3.0"
PD_VERSION="v4.11.0"
max_retries=5
timeout=15

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }

fetch() { # fetch URL OUTPUT
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry "$max_retries" --connect-timeout "$timeout" "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries="$max_retries" --timeout="$timeout" --no-hsts -O "$2" "$1"
  else
    die "curl ya wget install nahi hai."
  fi
}

# ---------- 1. architecture ----------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  PROOT_ARCH=x86_64 ;;
  aarch64|arm64) PROOT_ARCH=aarch64 ;;
  *) die "Unsupported CPU architecture: $ARCH" ;;
esac

# ---------- 2. proot ----------
mkdir -p "$BIN_DIR"
if command -v proot >/dev/null 2>&1; then
  PROOT_BIN="$(command -v proot)"
else
  PROOT_BIN="$BIN_DIR/proot"
  if [ ! -x "$PROOT_BIN" ]; then
    echo "Downloading proot ($PROOT_VERSION, official proot-me release)..."
    fetch "https://github.com/proot-me/proot/releases/download/${PROOT_VERSION}/proot-${PROOT_VERSION}-${PROOT_ARCH}-static" "$PROOT_BIN" \
      || die "proot download fail (GitHub reachable hai?)."
    [ -s "$PROOT_BIN" ] || die "proot binary khaali hai."
    chmod 755 "$PROOT_BIN"
  fi
fi

# ---------- 3. install rootfs (first run only) ----------
if [ ! -e "$ROOTFS_DIR/.installed" ]; then
  echo "#######################################################"
  echo "#              Ubuntu 22.04 INSTALLER"
  echo "#   install dir: $ROOTFS_DIR"
  echo "#######################################################"
  read -r -p "Do you want to install Ubuntu 22.04? [Y/n]: " ans
  case "${ans:-y}" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Exiting."; exit 0 ;;
  esac

  command -v xz >/dev/null 2>&1 || die "xz install nahi hai (tar -J ke liye zaruri)."

  TARBALL="$HOME/ubuntu-rootfs.tar.xz"
  ROOTFS_URL="https://github.com/termux/proot-distro/releases/download/${PD_VERSION}/ubuntu-jammy-${PROOT_ARCH}-pd-${PD_VERSION}.tar.xz"
  echo "Downloading Ubuntu 22.04 rootfs (${PROOT_ARCH})..."
  rm -f "$TARBALL"
  fetch "$ROOTFS_URL" "$TARBALL" || die "Rootfs download fail: $ROOTFS_URL"
  xz -t "$TARBALL" 2>/dev/null || die "Download kharab hai, dobara chalao."

  # adhuri purani install hatao
  if [ -e "$ROOTFS_DIR" ]; then
    chmod -R u+rwx "$ROOTFS_DIR" 2>/dev/null
    rm -rf "$ROOTFS_DIR"
  fi
  mkdir -p "$ROOTFS_DIR"

  echo "Extracting rootfs..."
  tar -xJf "$TARBALL" -C "$ROOTFS_DIR" --strip-components=1 --no-same-owner --exclude='dev' 2>"$HOME/ubuntu-extract.log" || :
  [ -x "$ROOTFS_DIR/bin/bash" ] || die "Extraction fail. Log: $HOME/ubuntu-extract.log"
  rm -f "$TARBALL"

  mkdir -p "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/root"

  # `groups` stub (proot me fail hota hai)
  printf '#!/bin/sh\nexit\n' > "$ROOTFS_DIR/usr/bin/groups"
  chmod +x "$ROOTFS_DIR/usr/bin/groups"

  # apt keyring fix (proot 5.3.0 faccessat2 bug -> NO_PUBKEY):
  # keyring host aur guest dono me SAME path pe rakho
  mkdir -p "$KEY_DIR" "$ROOTFS_DIR/etc/apt/apt.conf.d"
  if [ -s "$ROOTFS_DIR/usr/share/keyrings/ubuntu-archive-keyring.gpg" ]; then
    cp -f "$ROOTFS_DIR/usr/share/keyrings/ubuntu-archive-keyring.gpg" "$KEY_DIR/ubuntu-archive-keyring.gpg"
    chmod 644 "$KEY_DIR/ubuntu-archive-keyring.gpg"
    echo 'APT::Sandbox::User "root";' > "$ROOTFS_DIR/etc/apt/apt.conf.d/99proot"
    sed -i -E "s#^deb (\[[^]]*\] )?#deb [signed-by=$KEY_DIR/ubuntu-archive-keyring.gpg] #" "$ROOTFS_DIR/etc/apt/sources.list"
  else
    echo "WARNING: apt keyring nahi mili, apt update me NO_PUBKEY aa sakta hai."
  fi

  touch "$ROOTFS_DIR/.installed"
  echo "Install complete."
  echo "Tip (andar jaake): agar 'apt install' me ca-certificates 127 error de to  dpkg --configure -a  chalao."
fi

# ---------- 4. DNS: host ka resolver use karo ----------
if grep -qE '^nameserver' /etc/resolv.conf 2>/dev/null; then
  cp -f /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
else
  printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > "$ROOTFS_DIR/etc/resolv.conf"
fi

# ---------- 5. launch ----------
unset LD_PRELOAD

proot_args=(
  --rootfs="$ROOTFS_DIR"
  -0 -w /root
  -b /dev -b /sys -b /proc
  -b "$ROOTFS_DIR/tmp:/dev/shm"
  -b "$KEY_DIR:$KEY_DIR"
  -b "$HOME:/host-home"
  --kill-on-exit
)

# env -i host ka environment mita deta hai, isliye proxy variables khud pass karo
guest_env=(
  HOME=/root
  PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games
  TERM="${TERM:-xterm-256color}"
  LANG=C.UTF-8
)
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY; do
  if [ -n "${!v:-}" ]; then guest_env+=("$v=${!v}"); fi
done

echo "-----> Ubuntu 22.04 started! (exit se bahar aao) <-----"
if [ "$#" -gt 0 ]; then
  exec "$PROOT_BIN" "${proot_args[@]}" /usr/bin/env -i "${guest_env[@]}" /bin/bash --login -c "$*"
else
  exec "$PROOT_BIN" "${proot_args[@]}" /usr/bin/env -i "${guest_env[@]}" /bin/bash --login
fi
