#!/bin/sh
trap cleanup HUP INT TERM EXIT 2>/dev/null || true

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="keen-extras"
SCRIPT="keenextras.sh"
BRANCH="main"
SCRIPT_VERSION="1.2"

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

# ====================== AWG MANAGER ======================

install_awg_last() {
  print_message "Установка AWG Manager (последняя версия)..." "$GREEN"
  curl -sL https://raw.githubusercontent.com/hoaxisr/awg-manager/main/scripts/install.sh | sh
}

install_awg_version() {
  print_message "Установка выбранной версии AWG Manager..." "$CYAN"
  
  opkg install curl ca-certificates wget-ssl 2>/dev/null || true
  
  A=$(opkg print-architecture 2>/dev/null | sort -k3 -nr | awk '$2!="all"{print $2;exit}')
  case $A in
    aarch64*) S="aarch64-3.10-kn"; R="aarch64-k3.10" ;;
    mipsel*)  S="mipsel-3.4-kn";  R="mipsel-k3.4" ;;
    mips*)    S="mips-3.4-kn";    R="mips-k3.4" ;;
    *) print_message "❌ Неизвестная архитектура: $A" "$RED"; return 1 ;;
  esac
  
  echo "✅ Архитектура: $A"
  
  V=$(curl -s https://api.github.com/repos/hoaxisr/awg-manager/releases/latest | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p'); V=${V#v}
  [ -z "$V" ] && { print_message "❌ Не удалось получить версию" "$RED"; return 1; }
  echo "✅ Последняя версия: $V"
  
  printf "Введите версию (Enter = $V): "; read -r ver
  [ -z "$ver" ] && ver=$V
  
  cd /tmp || return 1
  print_message "📥 Скачивание awg-manager v$ver..." "$GREEN"
  
  curl -L# -o "awg-manager_${ver}_${S}.ipk" \
    "https://github.com/hoaxisr/awg-manager/releases/download/v${ver}/awg-manager_${ver}_${S}.ipk" || {
    print_message "❌ Ошибка скачивания!" "$RED"
    return 1
  }
  
  opkg install --force-downgrade "awg-manager_${ver}_${S}.ipk" && \
    print_message "🎉 AWG Manager v$ver успешно установлен!" "$GREEN" || \
    print_message "⚠️ Ошибка установки" "$RED"
  
  rm -f "awg-manager_${ver}_${S}.ipk" 2>/dev/null
  echo "Обновление в будущем: opkg update && opkg upgrade awg-manager"
}

remove_awg() {
  print_message "Удаление AWG Manager..." "$RED"
  opkg remove --autoremove awg-manager 2>/dev/null || true
  rm -rf /opt/etc/awg-manager /opt/etc/opkg/awg_manager.conf
  print_message "AWG Manager полностью удалён" "$GREEN"
}

# ====================== NFQWS ======================

install_nfqws() {
  print_message "Установка NFQWS..." "$GREEN"
  mkdir -p /opt/etc/opkg
  echo "src/gz nfqws-keenetic https://nfqws.github.io/nfqws-keenetic/all" > /opt/etc/opkg/nfqws-keenetic.conf
  opkg update >/dev/null 2>&1
  opkg install nfqws-keenetic
}

install_nfqws2() {
  print_message "Установка NFQWS2..." "$GREEN"
  mkdir -p /opt/etc/opkg
  echo "src/gz nfqws2-keenetic https://nfqws.github.io/nfqws2-keenetic/all" > /opt/etc/opkg/nfqws2-keenetic.conf
  opkg update >/dev/null 2>&1
  opkg install nfqws2-keenetic
}

install_nfqws_web() {
  print_message "Установка веб-интерфейса NFQWS..." "$GREEN"
  opkg install ca-certificates wget-ssl 2>/dev/null || true
  opkg remove wget-nossl 2>/dev/null || true
  
  mkdir -p /opt/etc/opkg
  echo "src/gz nfqws-keenetic-web https://nfqws.github.io/nfqws-keenetic-web/all" > /opt/etc/opkg/nfqws-keenetic-web.conf
  opkg update >/dev/null 2>&1
  opkg install nfqws-keenetic-web && \
    print_message "🎉 Веб-интерфейс NFQWS успешно установлен!" "$GREEN" || \
    print_message "⚠️ Ошибка установки" "$RED"
}

remove_nfqws() {
  print_message "Удаление всех компонентов NFQWS..." "$RED"
  opkg remove --autoremove nfqws-keenetic nfqws2-keenetic nfqws-keenetic-web 2>/dev/null || true
  rm -f /opt/etc/opkg/nfqws-*.conf
  print_message "NFQWS полностью удалён" "$GREEN"
}

# ====================== БЭКАП ENTWARE (как в KeenKit) ======================

backup_entware() {
  print_message "Бэкап Entware" "$CYAN"
  packages_checker tar
  
  local DATE=$(date +%Y-%m-%d_%H-%M)
  local BACKUP_FILE="/tmp/entware_backup_${DATE}.tar.gz"
  
  print_message "Создаём резервную копию Entware..." "$GREEN"
  
  if tar -czf "$BACKUP_FILE" -C /opt . --exclude="tmp" --exclude="var/run" 2>/dev/null; then
    print_message "✅ Бэкап успешно создан: $BACKUP_FILE" "$GREEN"
    echo "Размер: $(du -h "$BACKUP_FILE" | awk '{print $1}')"
  else
    print_message "❌ Ошибка при создании бэкапа!" "$RED"
  fi
}

# ====================== СЛУЖЕБНЫЕ ======================

cleanup() { echo -e "\n${NC}Выход...${NC}"; }

packages_checker() {
  local missing=""
  for pkg in "$@"; do
    if ! opkg list-installed | grep -q "^$pkg"; then
      missing
