#!/bin/bash
# ------------------------------------------------------------
# Ubuntu 20.04 Cloud Image → Proxmox Template (AUTO-UPDATE)
#
# Назначение:
#   Создаёт cloud-init template для массового клонирования VM.
#   Автоматически обновляет систему и устанавливает пакеты.
#   Сеть намеренно НЕ привязывается к bridge (SDN-friendly).
#
# Требования:
#   - Proxmox VE 7 / 8
#   - Storage: local-lvm
#   - Интернет-доступ для скачивания cloud image
#   - QEMU Guest Agent внутри гостя (установится автоматически)
#
# Использование:
#   ./ubuntu2004-template-auto.sh <TEMPLATE_VMID> <RAM_MB> <DISK_GB> <CORES>
#
# Пример:
#   ./ubuntu2004-template-auto.sh 9000 512 4 1
#
# После выполнения:
#   - VM будет переведена в TEMPLATE
#   - Её НЕЛЬЗЯ запускать
#   - Используйте qm clone для создания VM
# ------------------------------------------------------------

set -euo pipefail

# ===== АРГУМЕНТЫ ЗАПУСКА =====
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
TEMP_BRIDGE="vmbr0" # Временный мост для авто-обновления
VM_USER="ubuntu"
VM_PASSWORD="temppass123" # Временный пароль, будет удалён

# Cloud image Ubuntu 20.04
IMAGE_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64-disk-kvm.img"
IMAGE="/var/lib/vz/template/iso/focal-server-cloudimg-amd64-disk-kvm.img"

# Список обязательных пакетов для установки
REQUIRED_PACKAGES="ipcalc iproute2 netplan.io net-tools iperf3 iptables iputils-ping nmap procps tcpdump traceroute systemd telnet dnsutils isc-dhcp-server apache2 qemu-guest-agent"

# ===== ФУНКЦИИ =====
wait_for_vm_ip() {
    echo -n "Ожидание IP-адреса VM..."
    local timeout=120
    local start_time=$(date +%s)

    while [[ -z "$VM_IP" ]]; do
        VM_IP=$(qm guest exec "$VMID" -- bash -c \
          "ip -4 addr show ens3 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" 2>/dev/null | head -1)

        if [[ $(($(date +%s) - start_time)) -gt $timeout ]]; then
            echo " Таймаут! Не удалось получить IP."
            exit 1
        fi
        sleep 5
        echo -n "."
    done
    echo " OK: $VM_IP"
}

wait_for_ssh() {
    echo -n "Ожидание доступности SSH..."
    local timeout=180
    local start_time=$(date +%s)

    until qm guest exec "$VMID" -- nc -z 127.0.0.1 22 2>/dev/null; do
        if [[ $(($(date +%s) - start_time)) -gt $timeout ]]; then
            echo " Таймаут! SSH не доступен."
            exit 1
        fi
        sleep 5
        echo -n "."
    done
    echo " OK"
}

install_packages_if_needed() {
    echo "Проверка и установка пакетов..."

    # Формируем команду для проверки состояния каждого пакета
    local check_cmd="for pkg in $REQUIRED_PACKAGES; do \
        if dpkg -l | grep -q \"^ii  \$pkg \"; then \
            echo \"\$pkg: уже установлен\"; \
        else \
            echo \"\$pkg: будет установлен\"; \
            missing_pkgs=\"\$missing_pkgs \$pkg\"; \
        fi; \
    done"

    # Выполняем проверку внутри VM
    local result=$(qm guest exec "$VMID" -- bash -c "$check_cmd")
    echo "$result"

    # Проверяем, есть ли отсутствующие пакеты
    local missing=$(qm guest exec "$VMID" -- bash -c \
        "missing_pkgs=''; \
        for pkg in $REQUIRED_PACKAGES; do \
            dpkg -l | grep -q \"^ii  \$pkg \" || missing_pkgs=\"\$missing_pkgs \$pkg\"; \
        done; \
        echo \$missing_pkgs")

    if [[ -n "$missing" ]]; then
        echo "Установка отсутствующих пакетов: $missing"
        qm guest exec "$VMID" -- timeout 900 bash -c \
            "sudo DEBIAN_FRONTEND=noninteractive apt install -y $missing"

        # Проверяем успешность установки
        local verify=$(qm guest exec "$VMID" -- bash -c \
            "failed=''; \
            for pkg in $missing; do \
                dpkg -l | grep -q \"^ii  \$pkg \" || failed=\"\$failed \$pkg\"; \
            done; \
            if [[ -n \"\$failed\" ]]; then \
                echo \"Ошибка установки: \$failed\"; \
                exit 1; \
            else \
                echo 'Все пакеты успешно установлены'; \
            fi")
        echo "$verify"
    else
        echo "Все требуемые пакеты уже установлены."
    fi

    # Автоматическая очистка кэша apt для уменьшения размера образа
    echo "Очистка кэша apt..."
    qm guest exec "$VMID" -- bash -c "sudo apt autoremove -y && sudo apt clean"

    # Создание файла-метки с версиями установленных пакетов
    echo "Создание отчёта об установленных пакетах..."
    qm guest exec "$VMID" -- bash -c "dpkg -l | grep -E '(${REQUIRED_PACKAGES// /|})' > /opt/installed-packages.txt 2>/dev/null || true"
}

# ===== ПРОВЕРКИ =====
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
qm status "$VMID" &>/dev/null && { echo "VMID $VMID уже существует"; exit 1; }

# ===== СКАЧИВАНИЕ ОБРАЗА =====
[[ -f "$IMAGE" ]] || wget -q --show-progress -O "$IMAGE" "$IMAGE_URL"

echo "=== Этап 1: Создание базовой VM ==="
qm create "$VMID" \
  --name "$NAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --cpu host \
  --net0 virtio,bridge=$TEMP_BRIDGE \
  --scsihw virtio-scsi-pci \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --cipassword "$VM_PASSWORD" \
  --ciuser "$VM_USER" \
  --ipconfig0 ip=dhcp

qm importdisk "$VMID" "$IMAGE" "$STORAGE"
qm set "$VMID" \
  --scsi0 "$STORAGE:vm-$VMID-disk-0,discard=on" \
  --ide2 "$STORAGE:cloudinit"

qm resize "$VMID" scsi0 "$DISK"

echo "=== Этап 2: Первый запуск и обновление ==="
qm start "$VMID"

# Ждём, пока VM получит IP и запустит SSH
wait_for_vm_ip
wait_for_ssh

echo "=== Этап 3: Выполнение команд внутри VM ==="
echo "1. Обновление списка пакетов..."
qm guest exec "$VMID" -- timeout 300 bash -c "sudo DEBIAN_FRONTEND=noninteractive apt update"

echo "2. Обновление системы..."
qm guest exec "$VMID" -- timeout 900 bash -c \
  "sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y"

# Вызов функции проверки и установки пакетов
install_packages_if_needed

# Запуск Guest Agent (если установлен)
qm guest exec "$VMID" -- timeout 30 bash -c \
  "sudo systemctl enable --now qemu-guest-agent 2>/dev/null || true"

echo "=== Этап 4: Завершение работы и очистка ==="
echo "Выключение VM..."
qm guest exec "$VMID" -- timeout 60 bash -c "sudo poweroff" || true

# Ждём полной остановки
until qm status "$VMID" | grep -q "stopped"; do
    sleep 5
done

echo "Очистка конфиденциальных данных..."
qm set "$VMID" \
  --sshkey /dev/null \
  --cipassword "" \
  --ciupgrade 0 \
  --net0 virtio # Убираем временный bridge

echo "Превращение в шаблон..."
qm template "$VMID"

echo "✅ Автоматизированный шаблон создан!"
echo "👉 Template VMID: $VMID"
echo "👉 Имя: $NAME"
echo "👉 Установленные пакеты:"
echo "   $REQUIRED_PACKAGES"
