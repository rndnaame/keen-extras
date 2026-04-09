#!/bin/sh
trap cleanup HUP INT TERM EXIT 2>/dev/null || true

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="keen-extras"
SCRIPT="keenextras.sh"
BRANCH="main"
SCRIPT_VERSION="1.5"
DATE=$(date +%Y-%m-%d_%H-%M)
OPT_DIR="/opt"

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

# ====================== BACKUP HELPERS (ТОЧНО КАК В KEENKIT) ======================
get_architecture() {
  if [ -z "$ARCHITECTURE" ]; then
    local arch
    arch=$(opkg print-architecture | grep -oE 'mips-3|mipsel-3|aarch64-3' | head -n 1)
    case "$arch" in
      "mips-3") ARCHITECTURE="mips" ;;
      "mipsel-3") ARCHITECTURE="mipsel" ;;
      "aarch64-3") ARCHITECTURE="aarch64" ;;
      *) ARCHITECTURE="unknown_arch" ;;
    esac
  fi
  echo "$ARCHITECTURE"
}

get_internal_storage_size() {
  local ls_json=$(rci_request "ls" 2>/dev/null || echo '{"storage":{"free":0,"total":0}}')
  local free total
  free=$(echo "$ls_json" | grep -o '"free":[0-9]*' | head -1 | grep -o '[0-9]*' || echo 0)
  total=$(echo "$ls_json" | grep -o '"total":[0-9]*' | head -1 | grep -o '[0-9]*' || echo 0)
  echo $((free / 1024 / 1024))
}

format_size() {
  local used=$1 total=$2
  local used_mb=$((used / 1024 / 1024))
  local total_mb=$((total / 1024 / 1024))
  if [ "$total_mb" -ge 1024 ]; then
    local total_gb=$((total_mb / 1024))
    [ "$used_mb" -lt 1024 ] && printf "%d MB / %d GB" $used_mb $total_gb || printf "%d / %d GB" $((used_mb / 1024)) $total_gb
  else
    printf "%d / %d MB" $used_mb $total_mb
  fi
}

select_drive_extract_value() { echo "$1" | cut -d ':' -f2- | sed 's/^[[:space:]]*//; s/[",]//g'; }
select_drive_reset_partition() { in_partition=0; uuid=""; label=""; fstype=""; total_bytes=""; free_bytes=""; }
select_drive_reset_media() { media_found=1; media_is_usb=0; current_manufacturer=""; select_drive_reset_partition; }

select_drive_add_partition() {
  [ -z "$uuid" ] || [ -z "$fstype" ] || [ "$(echo "$fstype" | tr '[:upper:]' '[:lower:]')" = "swap" ] && { select_drive_reset_partition; return; }
  echo "$total_bytes" | grep -qE '^[0-9]+$' || total_bytes=0
  echo "$free_bytes" | grep -qE '^[0-9]+$' || free_bytes=0
  used_bytes=$((total_bytes - free_bytes)); [ "$used_bytes" -lt 0 ] && used_bytes=0
  display_name=${label:-${current_manufacturer:-Unknown}}
  fstype_upper=$(echo "$fstype" | tr '[:lower:]' '[:upper:]')
  echo "$index. $display_name ($fstype_upper, $(format_size $used_bytes $total_bytes))"
  uuids="${uuids:+$uuids
}$uuid"
  index=$((index + 1))
  select_drive_reset_partition
}

exit_main_menu() { printf "\n${CYAN}00. Выход в главное меню${NC}\n\n"; }

select_drive() {
  local message="$1"
  uuids=""; index=2; media_found=0; media_is_usb=0
  media_output=$(rci_parse "show media" 2>/dev/null || echo "")
  current_manufacturer=""
  select_drive_reset_partition

  echo "0. Временное хранилище (tmp)"
  echo "1. Встроенное хранилище ($(get_internal_storage_size))"

  while IFS= read -r line; do
    value=$(select_drive_extract_value "$line")
    case "$line" in
      *"\"Media"*"\":"* | *"name: Media"*) select_drive_reset_media ;;
      *"\"usb\":"* | *"usb:"*) [ "$media_found" = "1" ] && media_is_usb=1 ;;
      *"\"bus\":"* | *"bus:"*) [ "$media_found" = "1" ] && [ "$value" = "usb" ] && media_is_usb=1 ;;
      *"\"manufacturer\":"* | *"manufacturer:"*) [ "$media_found" = "1" ] && current_manufacturer="$value" ;;
      *"\"uuid\":"* | *"uuid:"*) [ "$media_found" = "1" ] && [ "$media_is_usb" = "1" ] && { select_drive_reset_partition; in_partition=1; uuid="$value"; } ;;
      *"\"label\":"* | *"label:"*) [ "$in_partition" = "1" ] && label="$value" ;;
      *"\"fstype\":"* | *"fstype:"*) [ "$in_partition" = "1" ] && fstype="$value" ;;
      *"\"total\":"* | *"total:"*) [ "$in_partition" = "1" ] && total_bytes="$value" ;;
      *"\"free\":"* | *"free:"*) [ "$in_partition" = "1" ] && { free_bytes="$value"; select_drive_add_partition; } ;;
    esac
  done <<EOF
$media_output
EOF

  exit_main_menu
  read -r -p "$message " choice
  choice=$(echo "$choice" | tr -d ' \n\r')
  [ "$choice" = "00" ] && main_menu
  echo ""
  case "$choice" in
    0) selected_drive="/tmp" ;;
    1) selected_drive="/storage" ;;
    *)
      selected_drive=$(printf '%s\n' "$uuids" | sed -n "$((choice - 1))p")
      [ -z "$selected_drive" ] && { print_message "Неверный выбор" "$RED"; exit_function; }
      selected_drive="/tmp/mnt/$selected_drive"
      ;;
  esac
}

spinner_start() {
  SPINNER_MSG="$1"
  local spin='|/-\\' i=0
  echo -n "[ ] $SPINNER_MSG"
  (while :; do i=$(((i+1)%4)); printf "\r[%s] %s" "${spin:$i:1}" "$SPINNER_MSG"; usleep 100000; done) &
  SPINNER_PID=$!
}

spinner_stop() {
  local rc=${1:-0}
  [ -n "$SPINNER_PID" ] && { kill "$SPINNER_PID" 2>/dev/null; wait "$SPINNER_PID" 2>/dev/null; unset SPINNER_PID; }
  [ $rc -eq 0 ] && printf "\r[✔] %s\n" "$SPINNER_MSG" || printf "\r[✖] %s\n" "$SPINNER_MSG"
}

exit_function() {
  echo ""
  read -n 1 -s -r -p "Для возврата нажмите любую клавишу..." || echo ""
  pkill -P $$ 2>/dev/null
  exec /opt/keenextras.sh
}

packages_checker() {
  local packages="$1"
  local missing=""
  for pkg in $packages; do
    if ! opkg list-installed | grep -q "^$pkg "; then missing="$missing $pkg"; fi
  done
  [ -n "$missing" ] && { print_message "Устанавливаем:$missing" "$GREEN"; opkg update >/dev/null 2>&1; opkg install $missing; echo ""; }
}

# ====================== БЭКАП ENTWARE (ТОЧНО КАК В ОРИГИНАЛЕ KEENKIT) ======================
backup_entware() {
  packages_checker "tar libacl"
  select_drive "Выберите накопитель:"
  backup_file="$selected_drive/$(get_architecture)_entware_backup_$DATE.tar.gz"

  spinner_start "Выполняю копирование"
  tar_output=$(tar cvzf "$backup_file" -C /opt --exclude="$(basename "$backup_file")" . 2>&1)
  rc=$?

  if echo "$tar_output" | tail -n 2 | grep -iq "error\|no space left"; then
    spinner_stop 1
    print_message "Ошибка при создании бэкапа:" "$RED"
    echo "$tar_output" | tail -n 5
  else
    spinner_stop 0
    print_message "Бэкап успешно сохранен в $backup_file" "$GREEN"
  fi
  exit_function
}

# ====================== AWG MANAGER ======================
install_awg_last() { print_message "Установка AWG Manager (последняя версия)..." "$GREEN"; curl -sL https://raw.githubusercontent.com/hoaxisr/awg-manager/main/scripts/install.sh | sh; }

install_awg_version() {
  print_message "Установка выбранной версии AWG Manager..." "$CYAN"
  opkg install curl ca-certificates wget-ssl 2>/dev/null || true
  A=$(opkg print-architecture 2>/dev/null | sort -k3 -nr | awk '$2!="all"{print $2;exit}')
  case $A in aarch64*) S="aarch64-3.10-kn";; mipsel*) S="mipsel-3.4-kn";; mips*) S="mips-3.4-kn";; *) print_message "❌ Неизвестная архитектура" "$RED"; return 1;; esac
  echo "✅ Архитектура: $A"
  V=$(curl -s https://api.github.com/repos/hoaxisr/awg-manager/releases/latest | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p'); V=${V#v}
  [ -z "$V" ] && { print_message "❌ Не удалось получить версию" "$RED"; return 1; }
  echo "✅ Последняя версия: $V"
  printf "Введите версию (Enter = $V): "; read -r ver; [ -z "$ver" ] && ver=$V
  cd /tmp || return 1
  print_message "📥 Скачивание awg-manager v$ver..." "$GREEN"
  curl -L# -o "awg-manager_${ver}_${S}.ipk" "https://github.com/hoaxisr/awg-manager/releases/download/v${ver}/awg-manager_${ver}_${S}.ipk" || { print_message "❌ Ошибка скачивания!" "$RED"; return 1; }
  opkg install --force-downgrade "awg-manager_${ver}_${S}.ipk" && print_message "🎉 AWG Manager v$ver успешно установлен!" "$GREEN" || print_message "⚠️ Ошибка установки" "$RED"
  rm -f "awg-manager_${ver}_${S}.ipk" 2>/dev/null
}

remove_awg() { print_message "Удаление AWG Manager..." "$RED"; opkg remove --autoremove awg-manager 2>/dev/null || true; rm -rf /opt/etc/awg-manager /opt/etc/opkg/awg_manager.conf; print_message "AWG Manager полностью удалён" "$GREEN"; }

# ====================== NFQWS ======================
install_nfqws() { print_message "Установка NFQWS..." "$GREEN"; mkdir -p /opt/etc/opkg; echo "src/gz nfqws-keenetic https://nfqws.github.io/nfqws-keenetic/all" > /opt/etc/opkg/nfqws-keenetic.conf; opkg update >/dev/null 2>&1; opkg install nfqws-keenetic; }
install_nfqws2() { print_message "Установка NFQWS2..." "$GREEN"; mkdir -p /opt/etc/opkg; echo "src/gz nfqws2-keenetic https://nfqws.github.io/nfqws2-keenetic/all" > /opt/etc/opkg/nfqws2-keenetic.conf; opkg update >/dev/null 2>&1; opkg install nfqws2-keenetic; }
install_nfqws_web() { print_message "Установка веб-интерфейса NFQWS..." "$GREEN"; opkg install ca-certificates wget-ssl 2>/dev/null || true; opkg remove wget-nossl 2>/dev/null || true; mkdir -p /opt/etc/opkg; echo "src/gz nfqws-keenetic-web https://nfqws.github.io/nfqws-keenetic-web/all" > /opt/etc/opkg/nfqws-keenetic-web.conf; opkg update >/dev/null 2>&1; opkg install nfqws-keenetic-web && print_message "🎉 Веб-интерфейс NFQWS успешно установлен!" "$GREEN" || print_message "⚠️ Ошибка установки" "$RED"; }
remove_nfqws() { print_message "Удаление всех компонентов NFQWS..." "$RED"; opkg remove --autoremove nfqws-keenetic nfqws2-keenetic nfqws-keenetic-web 2>/dev/null || true; rm -f /opt/etc/opkg/nfqws-*.conf; print_message "NFQWS полностью удалён" "$GREEN"; }

# ====================== ОБНОВЛЕНИЕ ======================
update_menu() {
  print_message "Обновление KeenExtras..." "$CYAN"
  curl -L -s "https://raw.githubusercontent.com/rndnaame/keen-extras/main/keenextras.sh" > /opt/keenextras.sh.tmp || { print_message "❌ Не удалось скачать обновление" "$RED"; return 1; }
  mv /opt/keenextras.sh.tmp /opt/keenextras.sh; chmod +x /opt/keenextras.sh
  print_message "✅ KeenExtras успешно обновлён до v${SCRIPT_VERSION}" "$GREEN"
  echo "Перезапуск меню..."; sleep 1; exec /opt/keenextras.sh
}

cleanup() { echo -e "\n${NC}Выход...${NC}"; }

# ====================== МЕНЮ ======================
awg_menu() {
  while true; do
    printf "\033c"; printf "${CYAN}=== AWG Manager ===${NC}\n\n"
    echo "1. Установить последнюю версию AWG Manager"
    echo "2. Установить выбранную версию AWG Manager"
    echo "3. Удалить AWG Manager"
    echo ""; echo "0. Назад в главное меню"; echo ""
    read -r -p "Выберите действие: " choice
    case "$choice" in 1) install_awg_last;; 2) install_awg_version;; 3) remove_awg;; 0|00) return;; *) echo "Неверный выбор";; esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

nfqws_menu() {
  while true; do
    printf "\033c"; printf "${CYAN}=== NFQWS ===${NC}\n\n"
    echo "1. Установить NFQWS"
    echo "2. Установить NFQWS2"
    echo "3. Установить веб-интерфейс NFQWS"
    echo "4. Удалить NFQWS (все компоненты)"
    echo ""; echo "0. Назад в главное меню"; echo ""
    read -r -p "Выберите действие: " choice
    case "$choice" in 1) install_nfqws;; 2) install_nfqws2;; 3) install_nfqws_web;; 4) remove_nfqws;; 0|00) return;; *) echo "Неверный выбор";; esac
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
  printf "${CYAN}KeenExtras v${SCRIPT_VERSION}${NC}\n\n"
  echo "1. AWG Manager"
  echo "2. NFQWS"
  echo "3. Бэкап Entware"
  echo "4. Обновить меню"
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
      4) update_menu ;;
      00|0) exit 0 ;;
      *) echo "Неверный выбор. Попробуйте снова." ;;
    esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

main_menu
