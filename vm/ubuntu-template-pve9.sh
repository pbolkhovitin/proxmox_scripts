#!/bin/bash
# ============================================================================
# Proxmox VE 9 Ubuntu Cloud Template Creator (SDN-ready)
# Оптимизирован для Proxmox VE 9, поддерживает Ubuntu 20.04/22.04/24.04
# ============================================================================

set -euo pipefail

# ===== АРГУМЕНТЫ ЗАПУСКА =====
# $1 — VMID шаблона
# $2 — Ubuntu версия (20.04|22.04|24.04)
# $3 — RAM в мегабайтах
# $4 — размер диска в гигабайтах
# $5 — количество CPU ядер
[[ $# -ne 5 ]] && {
  echo "Usage: $0 <TEMPLATE_VMID> <UBUNTU_VERSION> <RAM_MB> <DISK_GB> <CORES>"
  echo "Пример: $0 9000 22.04 1024 20 2"
  echo "Доступные версии Ubuntu: 20.04 (focal), 22.04 (jammy), 24.04 (noble)"
  exit 1
}

VMID="$1"
UBUNTU_VERSION="$2"
RAM="$3"
DISK="${4}G"
CORES="$5"

# ===== КОНСТАНТЫ НА ОСНОВЕ ВЕРСИИ =====
declare -A VERSION_MAP=(
  ["20.04"]="focal"
  ["22.04"]="jammy"
  ["24.04"]="noble"
)

declare -A STORAGE_DEFAULT=(
  ["20.04"]="local-lvm"
  ["22.04"]="local-lvm"
  ["24.04"]="local-lvm"
)

UBUNTU_CODENAME="${VERSION_MAP[$UBUNTU_VERSION]}"
if [[ -z "$UBUNTU_CODENAME ]]; then
  echo "Ошибка: Неподдерживаемая версия Ubuntu: $UBUNTU_VERSION"
  echo "Поддерживаемые версии: 20.04, 22.04, 24.04"
  exit 1
fi

STORAGE="${STORAGE_DEFAULT[$UBUNTU_VERSION]}"
NAME="ubuntu${UBUNTU_VERSION//./}-template-pve9"

# Образы Ubuntu cloud (официальные)
declare -A IMAGE_URLS=(
  ["20.04"]="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
  ["22.04"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  ["24.04"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

IMAGE_URL="${IMAGE_URLS[$UBUNTU_VERSION]}"
IMAGE="/var/lib/vz/template/iso/ubuntu-${UBUNTU_CODENAME}-cloudimg-amd64.img"

# ===== ПРОВЕРКИ ДЛЯ PROXMOX 9 =====
check_pve_environment() {
  echo "=== Проверка окружения Proxmox VE ==="

  # Только root
  [[ $EUID -ne 0 ]] && { echo "Ошибка: Запустите от root"; exit 1; }

  # Проверка версии Proxmox
  local pve_major
  if pveversion &>/dev/null; then
    pve_major=$(pveversion | grep -oP "pve-manager/\K\d+" || echo "0")
  else
    echo "Предупреждение: Не удалось определить версию Proxmox"
    pve_major=0
  fi

  if [[ "$pve_major" -lt 7 ]]; then
    echo "⚠️  Внимание: Скрипт оптимизирован для Proxmox VE 7+"
    echo "   Текущая версия: ${pve_major:-не определена}"
    read -p "   Продолжить? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
  fi

  # Проверка VMID
  if qm status "$VMID" &>/dev/null; then
    echo "Ошибка: VMID $VMID уже существует"
    exit 1
  fi

  # Проверка хранилища
  if ! pvesm status 2>/dev/null | grep -q "${STORAGE}.*active"; then
    echo "Ошибка: Хранилище '$STORAGE' недоступно"
    echo "Доступные хранилища:"
    pvesm status 2>/dev/null | grep active || echo "Не удалось получить список"
    exit 1
  fi

  echo "✓ Проверки пройдены: Proxmox $(pveversion 2>/dev/null || echo 'unknown'), хранилище '$STORAGE'"
}

# ===== СКАЧИВАНИЕ ОБРАЗА =====
download_image() {
  echo "=== Загрузка образа Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) ==="

  # Создаем директорию если нужно
  mkdir -p "$(dirname "$IMAGE")"

  if [[ -f "$IMAGE" ]]; then
    echo "✓ Образ уже существует: $(ls -lh "$IMAGE" | awk '{print $5}')"

    # Проверяем актуальность (30 дней)
    local image_age=$(( ($(date +%s) - $(stat -c %Y "$IMAGE")) / 86400 ))
    if [[ $image_age -gt 30 ]]; then
      echo "⚠️  Образ устарел ($image_age дней). Рекомендуется обновить:"
      echo "   rm '$IMAGE' && $0 $*"
    fi
  else
    echo "Загрузка: $IMAGE_URL"
    wget -q --show-progress --progress=bar:force -O "$IMAGE.tmp" "$IMAGE_URL"
    mv "$IMAGE.tmp" "$IMAGE"
    echo "✓ Образ загружен: $(ls -lh "$IMAGE" | awk '{print $5}')"
  fi
}

# ===== СОЗДАНИЕ VM =====
create_vm() {
  echo "=== Создание VM $VMID (Ubuntu $UBUNTU_VERSION) ==="

  # Оптимизированные параметры для Proxmox 9
  qm create "$VMID" \
    --name "$NAME" \
    --memory "$RAM" \
    --balloon "$((RAM/2 > 256 ? RAM/2 : 256))" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio-net-pci,bridge=vmbr0,firewall=1 \
    --scsihw virtio-scsi-pci \
    --scsi0 "$STORAGE:0,discard=on,iothread=1" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "$STORAGE:0,format=qcow2,size=4M" \
    --tags "template,ubuntu-${UBUNTU_VERSION},pve9-optimized" \
    --description "Ubuntu ${UBUNTU_VERSION} template optimized for Proxmox VE 9\nCreated: $(date '+%Y-%m-%d %H:%M:%S')"

  echo "✓ Базовая VM создана"
}

# ===== ИМПОРТ И НАСТРОЙКА =====
setup_vm() {
  echo "=== Импорт и настройка диска ==="

  # Импорт диска
  qm importdisk "$VMID" "$IMAGE" "$STORAGE" \
    --format qcow2

  # Подключение дисков и cloud-init
  qm set "$VMID" \
    --scsi0 "$STORAGE:vm-$VMID-disk-0,discard=on,iothread=1" \
    --ide2 "$STORAGE:cloudinit" \
    --ciuser ubuntu \
    --cipassword "" \
    --ipconfig0 ip=dhcp \
    --citype configdrive2 \
    --searchdomain "local" \
    --nameserver "8.8.8.8" \
    --ciupgrade 1

  # Изменение размера диска
  qm resize "$VMID" scsi0 "$DISK"
  echo "✓ Диск настроен: $DISK"
}

# ===== ФИНАЛИЗАЦИЯ =====
finalize_template() {
  echo "=== Финальная подготовка шаблона ==="

  # Очистка cloud-init состояния
  qm set "$VMID" \
    --sshkey /dev/null \
    --ciupgrade 0 \
    --net0 virtio-net-pci,firewall=1  # Убираем bridge для SDN

  # Отметка времени обновления
  qm set "$VMID" \
    --description "Ubuntu ${UBUNTU_VERSION} template optimized for Proxmox VE 9\nCreated: $(date '+%Y-%m-%d %H:%M:%S')\nVersion: 1.0-pve9"

  # Превращение в шаблон
  qm template "$VMID"

  echo "✅ ШАБЛОН СОЗДАН!"
  echo "=========================================="
  echo "Template VMID: $VMID"
  echo "Имя: $NAME"
  echo "Ubuntu: $UBUNTU_VERSION ($UBUNTU_CODENAME)"
  echo "Конфигурация: ${RAM}MB RAM, ${DISK} disk, ${CORES} cores"
  echo "Хранилище: $STORAGE"
  echo ""
  echo "Использование:"
  echo "  qm clone $VMID 101 --name my-vm"
  echo "  qm set 101 --net0 virtio-net-pci,bridge=YOUR_BRIDGE"
  echo "  qm set 101 --sshkey ~/.ssh/id_rsa.pub"
  echo "  qm start 101"
  echo "=========================================="
}

# ===== ГЛАВНАЯ ФУНКЦИЯ =====
main() {
  echo "🔧 Proxmox VE 9 Ubuntu Cloud Template Creator"
  echo "=========================================="

  check_pve_environment
  download_image
  create_vm
  setup_vm
  finalize_template
}

# Запуск
main "$@"
