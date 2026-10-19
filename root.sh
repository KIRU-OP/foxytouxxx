#!/bin/sh
# Ubuntu 22.04 rootfs + proot installer (fixed: HTTPS, error checks, no false ".installed")

ROOTFS_DIR=$(pwd)
max_retries=5
timeout=15
ARCH=$(uname -m)

case "$ARCH" in
  x86_64)  ARCH_ALT=amd64 ;;
  aarch64) ARCH_ALT=arm64 ;;
  *) echo "Unsupported CPU architecture: $ARCH"; exit 1 ;;
esac

ROOTFS_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-${ARCH_ALT}.tar.gz"

# Self-heal: if a previous run marked it installed but bash is missing, start over
if [ -e "$ROOTFS_DIR/.installed" ] && [ ! -x "$ROOTFS_DIR/bin/bash" ]; then
  echo "Previous install is broken (no /bin/bash). Reinstalling..."
  rm -f "$ROOTFS_DIR/.installed"
fi

if [ ! -e "$ROOTFS_DIR/.installed" ]; then
  echo "Downloading Ubuntu 22.04.5 rootfs ($ARCH_ALT)..."
  rm -f /tmp/rootfs.tar.gz
  FILE="ubuntu-base-22.04.5-base-${ARCH_ALT}.tar.gz"
  got=0
  for BASE in \
    "https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release" \
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/22.04/release" \
    "https://mirrors.ustc.edu.cn/ubuntu-cdimage/ubuntu-base/releases/22.04/release" \
    "https://mirror.nju.edu.cn/ubuntu-cdimage/ubuntu-base/releases/22.04/release" \
    "https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/22.04/release"
  do
    echo "Trying $BASE ..."
    rm -f /tmp/rootfs.tar.gz
    if wget --tries=2 --timeout=$timeout --no-hsts -O /tmp/rootfs.tar.gz "$BASE/$FILE" \
       && [ -s /tmp/rootfs.tar.gz ]; then
      got=1
      break
    fi
  done
  if [ "$got" != 1 ]; then
    echo "ERROR: all download sources failed."
    echo "Download $FILE on another device, copy it to /tmp/rootfs.tar.gz, and re-run."
    exit 1
  fi

  echo "Extracting..."
  tar -xf /tmp/rootfs.tar.gz -C "$ROOTFS_DIR" || { echo "ERROR: extraction failed"; exit 1; }
  [ -x "$ROOTFS_DIR/bin/bash" ] || { echo "ERROR: rootfs incomplete (no /bin/bash)"; exit 1; }

  mkdir -p "$ROOTFS_DIR/root" "$ROOTFS_DIR/usr/local/bin"

  # Prefer the system proot; only download one if none is installed
  if command -v proot >/dev/null 2>&1; then
    echo "Using system proot: $(command -v proot)"
  else
    echo "No system proot found, downloading one..."
    wget --tries=$max_retries --timeout=$timeout --no-hsts \
      -O "$ROOTFS_DIR/usr/local/bin/proot" \
      "https://raw.githubusercontent.com/foxytouxxx/freeroot/main/proot-${ARCH}" \
      || { echo "ERROR: proot download failed"; exit 1; }
    [ -s "$ROOTFS_DIR/usr/local/bin/proot" ] || { echo "ERROR: proot file is empty"; exit 1; }
    chmod 755 "$ROOTFS_DIR/usr/local/bin/proot"
  fi

  printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > "$ROOTFS_DIR/etc/resolv.conf"
  rm -f /tmp/rootfs.tar.gz
  touch "$ROOTFS_DIR/.installed"
fi

if command -v proot >/dev/null 2>&1; then
  PROOT=$(command -v proot)
else
  PROOT="$ROOTFS_DIR/usr/local/bin/proot"
fi

clear
echo "___________________________________________________"
echo
echo "           -----> Ubuntu 22.04 Started! <-----"
echo "___________________________________________________"

exec "$PROOT" \
  --rootfs="$ROOTFS_DIR" \
  -0 -w /root \
  -b /dev -b /sys -b /proc -b /etc/resolv.conf \
  --kill-on-exit \
  /bin/bash
