#!/bin/sh
trap cleanup HUP INT TERM EXIT 2>/dev/null || true

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="keen-extras"          # ← имя твоего репозитория
SCRIPT="keenextras.sh"
BRANCH="main"
SCRIPT_VERSION="1.0"

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

# ====================== ФУНКЦИИ ======================

install_awg_last() {
  print_message "Установка AWG Manager (последняя версия)..." "$GREEN"
  curl -sL https://raw.githubusercontent.com/hoaxisr/awg-manager/main/scripts/install.sh | sh
}

install_awg_version() {
  print_message "Выбор версии AWG Manager (через opkg)" "$CYAN"
  echo "Сначала обновляем список пакетов..."
  opkg update >/dev/null 2>&1
  
  echo -e "\nДоступные версии awg-manager:"
  opkg list awg-manager | cat
  
  echo -e "\nВведи версию (например 2.7.6) или Enter для последней:"
  read -r ver
  if [ -n "$ver" ]; then
    opkg install "awg-manager=$ver"
  else
    opkg install awg-manager
  fi
}

remove_awg() {
  print_message "Удаление AWG Manager..." "$RED"
  opkg remove --autoremove awg-manager 2>/dev/null || true
  rm -rf /opt/etc/awg-manager
  print_message "AWG Manager полностью удалён" "$GREEN"
}

# ---------------- NFQWS ----------------

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
  mkdir -p /opt/etc/opkg
  echo "src/gz nfqws-keenetic-web https://nfqws.github.io/nfqws-keenetic-web/all" > /opt/etc/opkg/nfqws-keenetic-web.conf
  opkg update >/dev/null 2>&1
  opkg install nfqws-keenetic-web
}

remove_nfqws() {
  print_message "Удаление всех компонентов NFQWS..." "$RED"
  opkg remove --autoremove nfqws-keenetic nfqws2-keenetic nfqws-keenetic-web 2>/dev/null || true
  rm -f /opt/etc/opkg/nfqws-*.conf
  print_message "NFQWS полностью удалён" "$GREEN"
}

# ---------------- Backup Entware ----------------

backup_entware() {
  local DATE=$(date +%Y-%m-%d_%H-%M)
  local BACKUP_FILE="/tmp/entware_backup_${DATE}.tar.gz"
  
  print_message "Создаём бэкап Entware..." "$GREEN"
  
  if tar -czf "$BACKUP_FILE" /opt/ --exclude="/opt/tmp" --exclude="/opt/var/run" 2>/dev/null; then
    print_message "Бэкап успешно создан:\n$BACKUP_FILE" "$GREEN"
    echo "Размер: $(du -h "$BACKUP_FILE" | cut -f1)"
  else
    print_message "Ошибка создания бэкапа!" "$RED"
  fi
}

cleanup() {
  echo -e "\n${NC}Выход...${NC}"
}

# ====================== МЕНЮ ======================

awg_menu() {
  while true; do
    printf "\033c"
    printf "${CYAN}=== AWG Manager ===${NC}\n\n"
    echo "1.1  Установка AWG Manager (Last Release)"
    echo "1.2  Выбор версии для установки"
    echo "1.3  Удаление AWG Manager"
    echo "0.   Назад в главное меню"
    echo ""
    read -r -p "Выберите действие: " choice
    case "$choice" in
      1.1|1) install_awg_last ;;
      1.2|2) install_awg_version ;;
      1.3|3) remove_awg ;;
      0|00) return ;;
      *) echo "Неверный выбор" ;;
    esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

nfqws_menu() {
  while true; do
    printf "\033c"
    printf "${CYAN}=== NFQWS ===${NC}\n\n"
    echo "2.1  Установка NFQWS"
    echo "2.2  Установка NFQWS2"
    echo "2.3  Установка Веб-интерфейса NFQWS"
    echo "2.4  Удаление NFQWS (все компоненты)"
    echo "0.   Назад в главное меню"
    echo ""
    read -r -p "Выберите действие: " choice
    case "$choice" in
      2.1|1) install_nfqws ;;
      2.2|2) install_nfqws2 ;;
      2.3|3) install_nfqws_web ;;
      2.4|4) remove_nfqws ;;
      0|00) return ;;
      *) echo "Неверный выбор" ;;
    esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

print_main_menu() {
  printf "\033c"
  cat <<'EOF'
   __ __                __ __ _ __
  / //_/__  ___  ____  / //_/(_) /_
 / ,< / _ \/ _ \/ __ \/ ,<  / / __/
/ /| /  __/  __/ / / / /| |/ / /_
/_/ |_\___/\___/_/ /_/_/ |_/_/\__/
EOF
  printf "${CYAN}KeenExtras v${SCRIPT_VERSION} by @yourname${NC}\n\n"
  echo "1. AWG Manager"
  echo "2. NFQWS"
  echo "3. Backup Entware"
  echo ""
  echo "00. Выход"
}

main_menu() {
  while true; do
    print_main_menu
    read -r -p "Выберите действие: " choice
    case "$choice" in
      1) awg_menu ;;
      2) nfqws_menu ;;
      3) backup_entware ;;
      00|0) exit 0 ;;
      *) echo "Неверный выбор. Попробуйте снова." ;;
    esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

# ====================== ЗАПУСК ======================

packages_checker() {
  # если нужно добавить зависимости — раскомментируй
  # opkg install curl jq 2>/dev/null || true
  :
}

main_menu
