#!/usr/bin/env bats
#
# node-skipped-mounts: the node's own file systems below a node root, which
# `borg create --one-file-system` stores as empty directories. Listed are
# disk file systems on another device than their root (btrfs: another
# subvolume) that Borg reaches, i.e. with nothing but the root's device
# between, and that are not roots themselves; not kubelet volumes, NFS,
# tmpfs, overlay or squashfs, and not a bind mount of the root's own file
# system. The mount tables are fixtures in /proc/self/mountinfo's format,
# shaped after a node pod's.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  export NODE_MOUNTINFO="$TMP/mountinfo"
  unset NODE_FS_TYPES KUBELET_DIR NODE_HOST_ROOT
  cat >"$NODE_MOUNTINFO" <<'MI'
1200 1100 8:1 / /node rw,relatime master:1 - ext4 /dev/sda1 rw
1201 1200 8:15 / /node/boot/efi rw,relatime master:2 - vfat /dev/sda15 rw
1202 1200 8:17 / /node/var/lib rw,relatime master:3 - ext4 /dev/sdb1 rw
1203 1202 8:49 / /node/var/lib/longhorn rw,relatime master:4 - ext4 /dev/sdd1 rw
1204 1202 0:60 / /node/var/lib/kubelet/pods/p1/volumes/kubernetes.io~csi/pvc-1/mount rw - ext4 /dev/longhorn/pvc-1 rw
1205 1200 0:61 / /node/mnt/share rw - nfs4 nas:/export rw
1206 1200 0:25 / /node/run rw,nosuid - tmpfs tmpfs rw
1207 1200 8:2 /@home /node/home rw,relatime master:5 - btrfs /dev/sda2 rw,subvol=/@home
1208 1200 8:33 / /node/srv/my\040data rw - xfs /dev/sdc1 rw
1209 1200 0:70 / /node/var/lib/containerd/x/rootfs rw - overlay overlay rw
1210 1100 0:80 / /var/lib/k8s-borg/sqlite rw - ext4 /dev/sda1 rw
MI
}

teardown() { common_teardown; }

skipped() {
  printf '%s\n' "$@" >"$TMP/include"
  "$BIN/node-skipped-mounts" "$TMP/include"
}

@test "a partition below a root is listed, not what lies below it, nor kubelet volumes" {
  run skipped "R /node/var"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "/node/var/lib (ext4 /dev/sdb1)" ] || fail "$output"
}

@test "a root on another file system is not listed, nor a mount not below any root" {
  run skipped "R /node/etc" "R /node/var/lib" "R /node/home" "R /var/lib/k8s-borg/sqlite"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  # /node/var/lib is a root; the partition below it is not.
  [ "$output" = "/node/var/lib/longhorn (ext4 /dev/sdd1)" ] || fail "$output"
  run skipped "R /node/etc" "R /node/var/lib" "R /node/var/lib/longhorn" "R /node/home"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "$output"
}

@test "below the whole host root: every disk file system, not NFS, tmpfs or overlay" {
  run skipped "P fm" "R /node/"
  [ "$output" = "/node/boot/efi (vfat /dev/sda15)
/node/home (btrfs /dev/sda2)
/node/srv/my data (xfs /dev/sdc1)
/node/var/lib (ext4 /dev/sdb1)" ] || fail "$output"
}

@test "a partition under a root that is partly a root itself is still listed" {
  run skipped "R /node/var" "R /node/var/lib/longhorn"
  [ "$output" = "/node/var/lib (ext4 /dev/sdb1)" ] || fail "$output"
}

@test "NODE_FS_TYPES sets which file system types are the node's own" {
  NODE_FS_TYPES="nfs4 tmpfs" run skipped "R /node"
  [ "$output" = "/node/mnt/share (nfs4 nas:/export)
/node/run (tmpfs tmpfs)" ] || fail "$output"
}

@test "an unreadable mount table or pattern file lists nothing and is no failure" {
  NODE_MOUNTINFO="$TMP/none" run skipped "R /node"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "$output"
  run "$BIN/node-skipped-mounts" "$TMP/none"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "$output"
}

@test "a bind mount of the root's file system is not skipped; nothing below a tmpfs or overlay is reached" {
  cat >"$NODE_MOUNTINFO" <<'MI'
5667 3628 0:169 / / rw - overlay overlay rw
5684 5667 259:2 /var/lib/kubelet/pods/p1/volumes/kubernetes.io~empty-dir/mounts /mnt rw - ext4 /dev/nvme0n1p2 rw
5686 5667 259:2 / /node rw,relatime - ext4 /dev/nvme0n1p2 rw
5695 5686 0:26 / /node/run rw - tmpfs tmpfs rw
6143 5695 0:169 / /node/run/k3s/containerd/task/c1/rootfs rw - overlay overlay rw
6151 6143 259:2 /var/lib/kubelet/pods/p1/volumes/kubernetes.io~empty-dir/mounts /node/run/k3s/containerd/task/c1/rootfs/mnt rw - ext4 /dev/nvme0n1p2 rw
6152 5686 259:2 /srv/data /node/opt/data rw - ext4 /dev/nvme0n1p2 rw
6153 6152 259:3 / /node/opt/data/disk rw - ext4 /dev/nvme0n1p3 rw
6211 5686 0:36 / /node/mnt/shared rw - autofs systemd-1 rw
6221 6211 0:54 / /node/mnt/shared rw - nfs4 nas:/export rw
6229 5686 259:1 / /node/boot/firmware rw - vfat /dev/nvme0n1p1 rw
6232 5686 7:2 / /node/snap/snapd/1 ro - squashfs /dev/loop2 ro
6265 5686 259:2 /var/lib/kubelet/pods/p2/volumes/kubernetes.io~configmap/cfg/x.conf /node/var/lib/kubelet/pods/p2/volume-subpaths/cfg/x/0 rw - ext4 /dev/nvme0n1p2 rw
6278 5686 8:0 / /node/var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/v1/globalmount rw - ext4 /dev/longhorn/pvc-1 rw
6707 5667 259:2 /var/lib/kubelet/pods/p1/volumes/kubernetes.io~configmap/config /root/.borg ro - ext4 /dev/nvme0n1p2 rw
MI
  run skipped "R /node"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  # The bind mount /node/opt/data is the root's device: Borg goes in and
  # skips the partition below it.
  [ "$output" = "/node/boot/firmware (vfat /dev/nvme0n1p1)
/node/opt/data/disk (ext4 /dev/nvme0n1p3)" ] || fail "$output"
}

@test "btrfs: another subvolume below a root is listed, the root's own subvolume is not" {
  cat >"$NODE_MOUNTINFO" <<'MI'
1200 1100 0:30 /@ /node rw - btrfs /dev/sda2 rw,subvolid=256,subvol=/@
1201 1200 0:30 /@home /node/home rw - btrfs /dev/sda2 rw,subvolid=257,subvol=/@home
1202 1200 0:30 /@/srv /node/data rw - btrfs /dev/sda2 rw,subvolid=256,subvol=/@
1203 1200 0:30 /@snapshots /node/.snapshots rw - btrfs /dev/sda2 rw,subvolid=258,subvol=/@snapshots
MI
  run skipped "R /node" "R /node/home"
  [ "$output" = "/node/.snapshots (btrfs /dev/sda2)" ] || fail "$output"
}

@test "only the kubelet's root directory is left out, the configured one" {
  cat >"$NODE_MOUNTINFO" <<'MI'
1200 1100 8:1 / /node rw - ext4 /dev/sda1 rw
1201 1200 8:17 / /node/data/kubelet/archive rw - ext4 /dev/sdb1 rw
1202 1200 8:0 / /node/var/lib/kubelet/plugins/kubernetes.io/csi/x/globalmount rw - ext4 /dev/longhorn/pvc-1 rw
1203 1200 8:16 / /node/var/lib/k0s/kubelet/pods/p1/volumes/kubernetes.io~csi/pvc-2/mount rw - ext4 /dev/longhorn/pvc-2 rw
MI
  run skipped "R /node"
  [ "$output" = "/node/data/kubelet/archive (ext4 /dev/sdb1)
/node/var/lib/k0s/kubelet/pods/p1/volumes/kubernetes.io~csi/pvc-2/mount (ext4 /dev/longhorn/pvc-2)" ] || fail "$output"
  KUBELET_DIR=/var/lib/k0s/kubelet run skipped "R /node"
  [ "$output" = "/node/data/kubelet/archive (ext4 /dev/sdb1)
/node/var/lib/kubelet/plugins/kubernetes.io/csi/x/globalmount (ext4 /dev/longhorn/pvc-1)" ] || fail "$output"
}
