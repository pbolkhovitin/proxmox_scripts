#!/bin/bash
set -e

# ===== ПРОВЕРКА АРГУМЕНТОВ =====
if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <VMID> <RAM_MB> <DISK_GB> <CORES>"
  exit 1
fi

VMID="$1"
RAM="$2"
DISK_SIZE="$3"G
CORES="$4"

# ===== НАСТРОЙКИ =====
VMNAME="ubuntu2004-$VMID"
STORAGE="local-lvm"
BRIDGE="vmbr0"
IMAGE_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
IMAGE_NAME="focal-server-cloudimg-amd64.img"
IMAGE_DIR="/var/lib/vz/template/iso"

# ===== ROOT CHECK =====
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

# ===== ПРОВЕРКИ =====
qm status "$VMID" &>/dev/null && {
  echo "VMID $VMID already exists"
  exit 1
}

# ===== СКАЧИВАНИЕ ОБРАЗА =====
mkdir -p "$IMAGE_DIR"
cd "$IMAGE_DIR"

if [[ ! -f "$IMAGE_NAME" ]]; then
  wget -q --show-progress "$IMAGE_URL"
fi

# ===== СОЗДАНИЕ VM =====
qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --cpu host \
  --net0 virtio,bridge="$BRIDGE" \
  --scsihw virtio-scsi-pci \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1

# ===== ИМПОРТ ДИСКА =====
qm importdisk "$VMID" "$IMAGE_NAME" "$STORAGE"

qm set "$VMID" \
  --scsi0 "$STORAGE:vm-$VMID-disk-0" \
  --ide2 "$STORAGE:cloudinit"

# ===== CLOUD-INIT =====
qm set "$VMID" \
  --ciuser ubuntu \
  --ipconfig0 ip=dhcp

# ===== РЕСАЙЗ ДИСКА =====
qm resize "$VMID" scsi0 "$DISK_SIZE"

echo "✅ VM $VMID created"
echo "👉 Start: qm start $VMID"
