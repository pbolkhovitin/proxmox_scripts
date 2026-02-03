#!/bin/bash
# ------------------------------------------------------------
# Ubuntu 20.04 Cloud Image → Proxmox Template
#
# Назначение:
#   Создаёт cloud-init template для массового клонирования VM.
#   Сеть намеренно НЕ привязывается к bridge (SDN-friendly).
#
# Требования:
#   - Proxmox VE 7 / 8
#   - Storage: local-lvm
#   - Интернет-доступ для скачивания cloud image
#
# Использование:
#   ./ubuntu2004-template.sh <TEMPLATE_VMID> <RAM_MB> <DISK_GB> <CORES>
#
# Пример:
#   ./ubuntu2004-template.sh 9000 512 4 1
#
# После выполнения:
#   - VM будет переведена в TEMPLATE
#   - Её НЕЛЬЗЯ запускать
#   - Используйте qm clone для создания VM
# ------------------------------------------------------------

set -euo pipefail

# ===== АРГУМЕНТЫ ЗАПУСКА =====
# $1 — VMID шаблона
# $2 — RAM в мегабайтах
# $3 — размер диска в гигабайтах
# $4 — количество CPU ядер
[[ $# -ne 4 ]] && {
  echo "Usage: $0 <TEMPLATE_VMID> <RAM_MB> <DISK_GB> <CORES>"
  exit 1
}

VMID="$1"
RAM="$2"
DISK="${3}G"
CORES="$4"

# ===== КОНСТАНТЫ =====
NAME="ubuntu2004-template"
STORAGE="local-lvm"

# Cloud image Ubuntu 20.04 (официальный)
IMAGE_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64-disk-kvm.img"
IMAGE="/var/lib/vz/template/iso/focal-server-cloudimg-amd64-disk-kvm.img"

# ===== ПРОВЕРКИ =====
# Скрипт должен выполняться от root
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

# VMID не должен существовать
qm status "$VMID" &>/dev/null && {
  echo "VMID $VMID already exists"
  exit 1
}

# ===== СКАЧИВАНИЕ ОБРАЗА =====
# Образ скачивается один раз и переиспользуется
[[ -f "$IMAGE" ]] || wget -q --show-progress -O "$IMAGE" "$IMAGE_URL"

# ===== СОЗДАНИЕ VM =====
# ВАЖНО:
# --net0 virtio      → сеть БЕЗ bridge (назначается при клонировании)
# --cpu host         → максимальная производительность
# --serial0 / vga    → минимальный overhead
qm create "$VMID" \
  --name "$NAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --cpu host \
  --net0 virtio \
  --scsihw virtio-scsi-pci \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1

# ===== ИМПОРТ CLOUD IMAGE =====
# Образ импортируется в local-lvm как thin-диск
qm importdisk "$VMID" "$IMAGE" "$STORAGE"

# ===== ПОДКЛЮЧЕНИЕ ДИСКОВ + CLOUD-INIT =====
# scsi0  → основной диск
# ide2   → cloud-init диск (ОБЯЗАТЕЛЕН)
qm set "$VMID" \
  --scsi0 "$STORAGE:vm-$VMID-disk-0,discard=on" \
  --ide2 "$STORAGE:cloudinit" \
  --ciuser ubuntu \
  --ipconfig0 ip=dhcp

# ===== ИЗМЕНЕНИЕ РАЗМЕРА ДИСКА =====
# Увеличивает root-диск до нужного размера
qm resize "$VMID" scsi0 "$DISK"

# ===== ОЧИСТКА ДЛЯ TEMPLATE =====
# Убираем любые ключи и апдейты,
# чтобы cloud-init выполнялся при каждом клоне
qm set "$VMID" \
  --sshkey /dev/null \
  --ciupgrade 0

# ===== ПРЕВРАЩЕНИЕ В TEMPLATE =====
qm template "$VMID"

echo "✅ Ubuntu 20.04 cloud TEMPLATE создан"
echo "👉 Template VMID: $VMID"
