#!/bin/bash
# ============================================================================
# Proxmox VE 9 Ubuntu Cloud Template Creator with Auto-Update
# Автоматически обновляет и устанавливает пакеты, оптимизирован для PVE 9
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
  echo "Пример: $0 9100 22.04 2048 30 4"
  echo "Доступные версии Ubuntu: 20.04, 22.04, 24.04"
  exit 1
}

VMID="$1"
UBUNTU_VERSION="$2"
RAM="$3"
DISK="${4}G"
CORES="$5"

CUSTOM_PACKAGES=""
if [[ $# -eq 6 ]]; then
    CUSTOM_PACKAGES="$6"
fi

# ===== КОНСТАНТЫ =====
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
if [[ -z "$UBUNTU_CODENAME" ]]; then
  echo "Ошибка: Неподдерживаемая версия Ubuntu: $UBUNTU_VERSION"
  exit 1
fi

STORAGE="${STORAGE_DEFAULT[$UBUNTU_VERSION]}"
TEMP_BRIDGE="vmbr0"
VM_USER="ubuntu"
VM_PASSWORD="temp_$(date +%s)_${RANDOM}"  # Уникальный временный пароль

# Название шаблона
NAME="ubuntu${UBUNTU_VERSION//./}-template-auto-pve9"

# Образы Ubuntu cloud
declare -A IMAGE_URLS=(
  ["20.04"]="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
  ["22.04"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  ["24.04"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

IMAGE_URL="${IMAGE_URLS[$UBUNTU_VERSION]}"
IMAGE="/var/lib/vz/template/iso/ubuntu-${UBUNTU_CODENAME}-cloudimg-amd64.img"

# Пакеты для установки (зависит от версии Ubuntu)
declare -A DEFAULT_PACKAGES=(
  ["base"]="qemu-guest-agent cloud-guest-utils curl wget htop net-tools"
  ["20.04"]="ipcalc iproute2 netplan.io iperf3 iptables iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2"
  ["22.04"]="ipcalc iproute2 netplan.io iperf3 iptables-nft iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2"
  ["24.04"]="ipcalc iproute2 netplan.io iperf3 nftables iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2"
)

# Формируем полный список пакетов
REQUIRED_PACKAGES="${DEFAULT_PACKAGES[base]} ${DEFAULT_PACKAGES[$UBUNTU_VERSION]} $CUSTOM_PACKAGES"

# Глобальная переменная для сетевого драйвера
NET_MODEL="virtio"  # Значение по умолчанию

# ===== ФУНКЦИИ =====
check_pve_environment() {
  echo "=== Проверка окружения Proxmox VE 9 ==="

  [[ $EUID -ne 0 ]] && { echo "Ошибка: Запустите от root"; exit 1; }

  local pve_major
  if pveversion &>/dev/null; then
    pve_major=$(pveversion | grep -oP "pve-manager/\K\d+" || echo "0")
  else
    pve_major=0
  fi

  # Определяем сетевой драйвер на основе версии Proxmox
  if [[ "$pve_major" -ge 9 ]]; then
    NET_MODEL="virtio-net-pci"
  else
    NET_MODEL="virtio"
  fi
  echo "✓ Сетевой драйвер: $NET_MODEL (Proxmox $pve_major)"

  if [[ "$pve_major" -lt 7 ]]; then
    echo "⚠️  Внимание: Скрипт оптимизирован для Proxmox VE 7+"
    read -p "   Продолжить? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
  fi

  if qm status "$VMID" &>/dev/null; then
    echo "Ошибка: VMID $VMID уже существует"
    exit 1
  fi

  if ! pvesm status 2>/dev/null | grep -q "${STORAGE}.*active"; then
    echo "Ошибка: Хранилище '$STORAGE' недоступно"
    exit 1
  fi

  # Проверка временного bridge
  if ! ip link show "$TEMP_BRIDGE" &>/dev/null; then
    echo "Ошибка: Сетевой мост '$TEMP_BRIDGE' не найден"
    echo "Укажите существующий мост через переменную TEMP_BRIDGE"
    exit 1
  fi

  echo "✓ Проверки пройдены: Proxmox $pve_major, хранилище '$STORAGE', мост '$TEMP_BRIDGE'"
}

download_image() {
  echo "=== Загрузка образа Ubuntu $UBUNTU_VERSION ==="

  mkdir -p "$(dirname "$IMAGE")"

  if [[ -f "$IMAGE" ]]; then
    echo "✓ Образ уже существует"
  else
    echo "Загрузка образа..."
    wget -q --show-progress --progress=bar:force -O "$IMAGE.tmp" "$IMAGE_URL"
    mv "$IMAGE.tmp" "$IMAGE"
    echo "✓ Образ загружен"
  fi
}

wait_for_vm_ip() {
  echo -n "Ожидание IP-адреса VM..."
  local timeout=180
  local start_time=$(date +%s)
  VM_IP=""

  while [[ -z "$VM_IP" ]]; do
    VM_IP=$(qm guest exec "$VMID" -- bash -c \
      "ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.' | head -1" 2>/dev/null)

    if [[ $(($(date +%s) - start_time)) -gt $timeout ]]; then
      echo " Таймаут!"
      echo "Проверьте сетевые настройки и DHCP"
      exit 1
    fi
    sleep 3
    echo -n "."
  done
  echo " OK: $VM_IP"
}

wait_for_ssh() {
  echo -n "Ожидание SSH..."
  local timeout=120
  local start_time=$(date +%s)

  until qm guest exec "$VMID" -- timeout 2 bash -c "nc -z 127.0.0.1 22" &>/dev/null; do
    if [[ $(($(date +%s) - start_time)) -gt $timeout ]]; then
      echo " Таймаут!"
      exit 1
    fi
    sleep 5
    echo -n "."
  done
  echo " OK"
}

install_packages_smart() {
  echo "=== Умная установка пакетов ==="

  # Сначала обновляем
  echo "1. Обновление системы..."
  qm guest exec "$VMID" -- timeout 300 bash -c \
    "sudo DEBIAN_FRONTEND=noninteractive apt update && sudo apt upgrade -y"

  # Проверяем и устанавливаем только отсутствующие пакеты
  echo "2. Проверка пакетов..."
  local check_script="
    missing=''
    for pkg in $REQUIRED_PACKAGES; do
      if ! dpkg -l | grep -q \"^ii  \$pkg \"; then
        missing=\"\$missing \$pkg\"
        echo \"▸ \$pkg: будет установлен\"
      else
        echo \"✓ \$pkg: уже установлен\"
      fi
    done
    echo \"Missing:\$missing\"
  "

  local result=$(qm guest exec "$VMID" -- bash -c "$check_script")
  local missing=$(echo "$result" | grep "^Missing:" | cut -d: -f2)

  if [[ -n "$missing" ]]; then
    echo "3. Установка отсутствующих пакетов..."
    qm guest exec "$VMID" -- timeout 600 bash -c \
      "sudo DEBIAN_FRONTEND=noninteractive apt install -y $missing"
    echo "✓ Пакеты установлены"
  else
    echo "3. Все пакеты уже установлены"
  fi

  # Очистка и оптимизация
  echo "4. Очистка кэша..."
  qm guest exec "$VMID" -- bash -c \
    "sudo apt autoremove -y && sudo apt clean && sudo apt autoclean"

  # Включаем сервисы
  echo "5. Настройка сервисов..."
  qm guest exec "$VMID" -- bash -c \
    "sudo systemctl enable --now qemu-guest-agent 2>/dev/null || true"

  # Создаем файл с информацией об установке
  qm guest exec "$VMID" -- bash -c \
    "echo 'Ubuntu $UBUNTU_VERSION Template (Proxmox VE 9 optimized)' > /opt/pve-template-info.txt
     echo 'Created: $(date)' >> /opt/pve-template-info.txt
     echo 'Packages: $REQUIRED_PACKAGES' >> /opt/pve-template-info.txt
     dpkg -l | grep -E '(${REQUIRED_PACKAGES// /|})' > /opt/installed-packages.txt 2>/dev/null || true"
}

# ===== ОСНОВНОЙ ПРОЦЕСС =====
main() {
  echo "🔧 Proxmox VE 9 Auto-Template Creator (Ubuntu $UBUNTU_VERSION)"
  echo "=========================================="

  # Этап 1: Подготовка
  check_pve_environment
  download_image

  # Этап 2: Создание VM с временной сетью
  echo "=== Создание VM с временной конфигурацией ==="
  qm create "$VMID" \
    --name "$NAME" \
    --memory "$RAM" \
    --balloon "$((RAM/2 > 512 ? RAM/2 : 512))" \
    --cores "$CORES" \
    --cpu host \
    --net0 "$NET_MODEL,bridge=$TEMP_BRIDGE,firewall=1" \
    --scsihw virtio-scsi-pci \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "$STORAGE:0,format=qcow2,size=4M" \
    --cipassword "$VM_PASSWORD" \
    --ciuser "$VM_USER" \
    --ipconfig0 ip=dhcp \
    --citype configdrive2 \
    --tags "template,ubuntu-${UBUNTU_VERSION},auto-installed,pve9"

  qm importdisk "$VMID" "$IMAGE" "$STORAGE" --format qcow2
  qm set "$VMID" \
    --scsi0 "$STORAGE:vm-$VMID-disk-0,discard=on,iothread=1" \
    --ide2 "$STORAGE:cloudinit"
  qm resize "$VMID" scsi0 "$DISK"

  # Этап 3: Запуск и обновление
  echo "=== Запуск и автоматическая настройка ==="
  qm start "$VMID"
  wait_for_vm_ip
  wait_for_ssh

  # Этап 4: Установка пакетов
  install_packages_smart

  # Этап 5: Завершение
  echo "=== Завершение работы и очистка ==="
  echo "Выключение VM..."
  qm guest exec "$VMID" -- timeout 60 bash -c "sudo poweroff" || true

  # Ждем остановки
  until qm status "$VMID" | grep -q "stopped"; do
    sleep 5
  done

  # Очистка чувствительных данных и подготовка шаблона
  echo "Очистка конфиденциальных данных..."
  qm set "$VMID" \
    --sshkey /dev/null \
    --cipassword "" \
    --ciupgrade 0 \
    --net0 "$NET_MODEL,firewall=1"  # Убираем временный bridge

  # Оптимизация размера диска
  echo "Оптимизация размера диска..."
  qm guest exec "$VMID" -- fstrim -a 2>/dev/null || true

  # Превращение в шаблон
  echo "Создание шаблона..."
  qm template "$VMID"

  # Удаление временного пароля из памяти
  unset VM_PASSWORD

  echo "✅ ШАБЛОН С АВТОМАТИЧЕСКОЙ УСТАНОВКОЙ СОЗДАН!"
  echo "=========================================="
  echo "Template VMID: $VMID"
  echo "Имя: $NAME"
  echo "Ubuntu: $UBUNTU_VERSION ($UBUNTU_CODENAME)"
  echo "Размер: ${RAM}MB RAM, ${DISK} disk, ${CORES} cores"
  echo "Установленные пакеты: $(echo $REQUIRED_PACKAGES | wc -w) шт."
  echo ""
  echo "Для клонирования:"
  echo "  qm clone $VMID <NEW_ID> --name <имя>"
  echo "  qm set <NEW_ID> --sshkey ~/.ssh/id_rsa.pub"
  echo "  qm set <NEW_ID> --net0 virtio-net-pci,bridge=<ваш_мост>"
  echo "  qm start <NEW_ID>"
  echo "=========================================="
}

# Запуск
main "$@"
