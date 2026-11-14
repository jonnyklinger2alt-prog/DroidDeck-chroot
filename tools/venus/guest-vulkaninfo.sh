#!/bin/bash
# vulkaninfo as the session's Linux processes see the GPU: through Venus, and through the Mali
# compatibility layer when DROIDDECK_MALI_COMPAT is 1. Needs a running session (the vtest server).
# Run from Git Bash: MSYS_NO_PATHCONV=1 bash tools/venus/guest-vulkaninfo.sh [0|1] > vulkaninfo.txt
set -euo pipefail
COMPAT=${1:-1}
A=/c/Users/derab/tools/platform-tools/adb.exe
PKG=com.droiddeck.launcher
F=/data/user/0/$PKG/files
LAUNCH=/data/user/0/$PKG/no_backup/guest-runtime/chroot/launch.sh
U=$($A shell stat -c %u $F | tr -d '\r')
$A exec-out "su -c 'sh $LAUNCH --root $F/linuxfs --uid $U --gid $U -b /dev -b /proc -b /sys -b $F /usr/bin/env -i HOME=/root \
  PATH=/usr/bin:/bin DROIDDECK_MALI_COMPAT=$COMPAT VK_ICD_FILENAMES=$F/venus/virtio_icd.json VN_DEBUG=vtest \
  VTEST_SOCKET_NAME=$F/venus/vtest.sock vulkaninfo 2>&1'"
