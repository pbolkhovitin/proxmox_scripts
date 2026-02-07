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
# Обработка флага --force
FORCE_DOWNLOAD=0

if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
  FORCE_DOWNLOAD=1
  shift
  echo "⚡ Режим принудительного обновления включен"
fi

# Проверка количества аргументов после обработки флагов
[[ $# -lt 5 ]] && {
  echo "Usage: $0 [--force|-f] <TEMPLATE_VMID> <UBUNTU_VERSION> <RAM_MB> <DISK_GB> <CORES> [CUSTOM_PACKAGES]"
  echo "Пример: $0 9100 22.04 2048 30 4"
  echo "Пример с force: $0 --force 9100 22.04 2048 30 4 'vim git'"
  echo "Доступные версии Ubuntu: 20.04, 22.04, 24.04"
  exit 1
}

VMID="$1"
UBUNTU_VERSION="$2"
RAM="$3"
DISK="${4}G"
CORES="$5"

# Обработка дополнительных пакетов
CUSTOM_PACKAGES=""
if [[ $# -ge 6 ]]; then
    shift 5
    CUSTOM_PACKAGES="$@"
    echo "📦 Дополнительные пакеты: $CUSTOM_PACKAGES"
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
ISO_PATH="/var/lib/vz/template/iso"
# Проверяем существование
if [[ ! -d "$ISO_PATH" ]]; then
    ISO_PATH="/tmp"
    echo "⚠️  Директория ISO не найдена, использую /tmp"
fi
IMAGE="${ISO_PATH}/ubuntu-${UBUNTU_CODENAME}-cloudimg-amd64.img"

# Пакеты для установки (зависит от версии Ubuntu)
declare -A DEFAULT_PACKAGES=(
  ["base"]="qemu-guest-agent cloud-guest-utils curl wget htop net-tools"
  ["20.04"]="ipcalc iproute2 netplan.io iperf3 iptables iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2"
  ["22.04"]="ipcalc iproute2 netplan.io iperf3 iptables-nft iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2"
  ["24.04"]="ipcalc iproute2 netplan.io iperf3 nftables iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2"
)

# Формируем полный список пакетов
REQUIRED_PACKAGES="${DEFAULT_PACKAGES[base]} ${DEFAULT_PACKAGES[$UBUNTU_VERSION]}"
if [[ -n "$CUSTOM_PACKAGES" ]]; then
  REQUIRED_PACKAGES="$REQUIRED_PACKAGES $CUSTOM_PACKAGES"
fi

# Глобальная переменная для сетевого драйвера
NET_MODEL="virtio"  # Значение по умолчанию

# ===== ФУНКЦИИ =====
check_pve_environment() {
  echo "=== Проверка окружения Proxmox VE 9 ==="
  echo "Force mode: $FORCE_DOWNLOAD"

  [[ $EUID -ne 0 ]] && { echo "Ошибка: Запустите от root"; exit 1; }

  local pve_major
  if pveversion &>/dev/null; then
    pve_major=$(pveversion | grep -oP "pve-manager/\K\d+" || echo "0")
  else
    pve_major=0
  fi

  # Определяем сетевой драйвер на основе версии Proxmox
  if [[ "$pve_major" -ge 9 ]]; then
    NET_MODEL="virtio"
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
  echo "=== Проверка и загрузка образа Ubuntu $UBUNTU_VERSION ==="

  mkdir -p "$(dirname "$IMAGE")"

  local need_download=1
  local image_age_days=0

  # 1. Проверяем флаг --force ДО любой работы с файлом
  if [[ $FORCE_DOWNLOAD -eq 1 ]]; then
    echo "⚡ Принудительное обновление образа (флаг --force)"
    if [[ -f "$IMAGE" ]]; then
      rm -f "$IMAGE"
      echo "🗑️  Старый образ удалён"
    fi
  fi

  # 2. Теперь проверяем существование образа
  if [[ -f "$IMAGE" ]]; then
    echo "✓ Образ найден: $(ls -lh "$IMAGE" | awk '{print $5}')"

    # Проверяем возраст образа (в днях)
    # Теперь stat выполняется только если файл существует
    local image_timestamp=$(stat -c %Y "$IMAGE" 2>/dev/null || echo "0")
    local current_timestamp=$(date +%s)
    image_age_days=$(( (current_timestamp - image_timestamp) / 86400 ))

    # Образ считается актуальным если ему меньше 7 дней
    if [[ $image_age_days -lt 7 ]]; then
      echo "✓ Образ актуален ($image_age_days дней)"
      need_download=0
    else
      echo "⚠️  Образ устарел ($image_age_days дней)"
      read -p "   Обновить? (Y/n): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "🗑️  Удаляем старый образ..."
        rm -f "$IMAGE"
        need_download=1
      else
        echo "✓ Используем существующий образ (устаревший)"
        need_download=0
      fi
    fi
  else
    echo "✗ Образ не найден"
    need_download=1
  fi

  # Скачиваем если нужно
  if [[ $need_download -eq 1 ]]; then
    echo "⬇️  Загрузка образа из: $IMAGE_URL"
    echo "   Это может занять несколько минут..."

    # Используем wget с продолжением и проверкой
    if wget -q --show-progress --continue --progress=bar:force:noscroll -O "$IMAGE.tmp" "$IMAGE_URL"; then
      mv "$IMAGE.tmp" "$IMAGE"
      echo "✅ Образ успешно загружен: $(ls -lh "$IMAGE" | awk '{print $5}')"

      # Устанавливаем правильные права
      chmod 644 "$IMAGE"

      # Обновляем время модификации файла
      touch "$IMAGE"
    else
      echo "❌ Ошибка загрузки образа"
      rm -f "$IMAGE.tmp" 2>/dev/null
      exit 1
    fi
  fi

  # Финальная проверка файла
  if [[ ! -f "$IMAGE" ]]; then
    echo "❌ Критическая ошибка: образ не доступен после проверки"
    exit 1
  fi

  # Дополнительная проверка размера файла
  local min_size=$((100 * 1024 * 1024))  # 100MB минимальный размер
  local actual_size=$(stat -c %s "$IMAGE" 2>/dev/null || echo 0)

  if [[ $actual_size -lt $min_size ]]; then
    echo "❌ Ошибка: образ слишком мал ($((actual_size/1024/1024))MB), вероятно загрузка не удалась"
    exit 1
  fi
}

verify_image_integrity() {
  echo "🔍 Проверка целостности образа..."

  # Проверяем доступность curl
  if ! command -v curl &>/dev/null; then
    echo "⚠️  curl не установлен, пропускаем проверку"
    return 0
  fi

  # Получаем размер из заголовков URL
  local expected_size=0
  expected_size=$(curl -sI "$IMAGE_URL" | grep -i "content-length" | awk '{print $2}' | tr -d '\r')

  if [[ -z "$expected_size" ]] || [[ "$expected_size" -eq 0 ]]; then
    echo "⚠️  Не удалось проверить ожидаемый размер"
    return 0
  fi

  local actual_size=$(stat -c %s "$IMAGE" 2>/dev/null || echo 0)

  if [[ $actual_size -eq $expected_size ]]; then
    echo "✓ Целостность образа подтверждена ($((actual_size/1024/1024))MB)"
  else
    echo "⚠️  Размер образа отличается от ожидаемого"
    echo "   Ожидалось: $((expected_size/1024/1024))MB ($expected_size байт)"
    echo "   Фактически: $((actual_size/1024/1024))MB ($actual_size байт)"
    echo "   Разница: $(( (actual_size - expected_size) / 1024 / 1024 ))MB"

    # Если разница небольшая (< 1%), считаем приемлемым
    local diff_percent=$(( (actual_size * 100) / expected_size - 100 ))
    if [[ ${diff_percent#-} -lt 1 ]]; then
      echo "✓ Небольшая разница (${diff_percent}%) допустима"
    fi
  fi
}

wait_for_vm_ip() {
  echo -n "Ожидание загрузки гостевого агента..."
  sleep 30  # Даем время на загрузку
  echo " OK"

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

  # 1. Обновление системы с обработкой ошибок
  echo "1. Обновление системы..."
  if ! qm guest exec "$VMID" -- timeout 300 bash -c \
    "sudo DEBIAN_FRONTEND=noninteractive apt update && sudo apt upgrade -y" 2>/dev/null; then
    echo "⚠️  Предупреждение: не удалось обновить систему, продолжаем..."
  fi

  # 2. Проверяем и устанавливаем только отсутствующие пакеты
  echo "2. Проверка пакетов..."
  local check_script="
    missing=''
    for pkg in $REQUIRED_PACKAGES; do
      if ! dpkg -l | grep -q \"^ii  \\\$pkg \"; then
        missing=\"\\\$missing \\\$pkg\"
        echo \"▸ \\\$pkg: будет установлен\"
      else
        echo \"✓ \\\$pkg: уже установлен\"
      fi
    done
    echo \"Missing:\\\$missing\"
  "

  local result=$(qm guest exec "$VMID" -- bash -c "$check_script")
  local missing=$(echo "$result" | grep "^Missing:" | cut -d: -f2)

  if [[ -n "$missing" ]]; then
    echo "3. Установка отсутствующих пакетов..."
    qm guest exec "$VMID" -- timeout 600 bash -c \
      "sudo DEBIAN_FRONTEND=noninteractive apt install -y $missing" || \
      echo "⚠️  Не удалось установить некоторые пакеты"
    echo "✓ Пакеты установлены"
  else
    echo "3. Все пакеты уже установлены"
  fi

  # 4. Очистка и оптимизация
  echo "4. Очистка кэша..."
  qm guest exec "$VMID" -- bash -c \
    "sudo apt autoremove -y && sudo apt clean && sudo apt autoclean" 2>/dev/null || true

  # 5. Включаем сервисы
  echo "5. Настройка сервисов..."
  qm guest exec "$VMID" -- bash -c \
    "sudo systemctl enable --now qemu-guest-agent 2>/dev/null || true"

  # 6. Создаем файл с информацией об установке
  qm guest exec "$VMID" -- bash -c \
    "echo 'Ubuntu $UBUNTU_VERSION Template (Proxmox VE 9 optimized)' > /opt/pve-template-info.txt
     echo 'Created: $(date)' >> /opt/pve-template-info.txt
     echo 'Packages: $REQUIRED_PACKAGES' >> /opt/pve-template-info.txt
     dpkg -l | grep -E '(${REQUIRED_PACKAGES// /|})' > /opt/installed-packages.txt 2>/dev/null || true"
}

# ===== ОСНОВНОЙ ПРОЦЕСС =====
main() {  # Создаем лог-файл
  LOG_FILE="/var/log/pve-template-${VMID}-$(date +%Y%m%d-%H%M%S).log"
  exec 3>&1 4>&2  # Сохраняем оригинальные дескрипторы
  exec > >(tee -a "$LOG_FILE") 2>&1

  echo "🔧 Proxmox VE 9 Auto-Template Creator (Ubuntu $UBUNTU_VERSION)"
  echo "Логирование: $LOG_FILE"

  trap 'exec 1>&3 2>&4' EXIT

  # Этап 1: Подготовка
  check_pve_environment
  download_image
  verify_image_integrity

  echo "=== Проверка готовности образа ==="
  if [[ ! -f "$IMAGE" ]] || [[ ! -s "$IMAGE" ]]; then
    echo "❌ Ошибка: образ не найден или пустой: $IMAGE"
    exit 1
  fi
  echo "✓ Образ готов к импорту: $(ls -lh "$IMAGE")"

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
  qm guest exec "$VMID" -- timeout 10 bash -c "sudo poweroff" || true

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
