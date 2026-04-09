#!/bin/sh
trap cleanup HUP INT TERM EXIT 2>/dev/null || true

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="keen-extras"
SCRIPT="keenextras.sh"
BRANCH="main"
SCRIPT_VERSION="1.4"

# ====================== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ (как в KeenKit) ======================
DATE=$(date +%Y-%m-%d_%H-%M)
OPT_DIR="/opt"
TMP_DIR="/tmp"
STORAGE_DIR="/storage"

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

# ====================== BACKUP HELPERS ИЗ ОРИГИНАЛЬНОГО KEENKIT ======================

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
  local flag="$1"
  local ls_json
  ls_json=$(rci_request "ls" 2>/dev/null)
  local free total
  free=$(echo "$ls_json" | grep -A10 '"storage:"' | grep '"free":' | head -1 | grep -o '[0-9]\+')
  total=$(echo "$ls_json" | grep -A10 '"storage:"' | grep '"total":' | head -1 | grep -o '[0-9]\+')
  if [ -n "$free" ] && [ -n "$total" ]; then
    used=$((total - free))
    if [ "$flag" = "free" ]; then
      echo $((free / 1024 / 1024))
    else
      format_size $used $total
    fi
  fi
}

format_size() {
  local used=$1 total=$2
  local used_mb=$((used / 1024 / 1024))
  local total_mb=$((total / 1024 / 1024))
  if [ "$total_mb" -ge 1024 ]; then
    total_gb=$((total / 1024 / 1024 / 1024))
    if [ "$used_mb" -lt 1024 ]; then
      printf "%d MB / %d GB" $used_mb $total_gb
    else
      used_gb=$((used / 1024 / 1024 / 1024))
      printf "%d / %d GB" $used_gb $total_gb
    fi
  else
    printf "%d / %d MB" $used_mb $total_mb
  fi
}

select_drive_extract_value() {
  echo "$1" | cut -d ':' -f2- | sed 's/^[[:space:]]*//; s/[",]//g'
}

select_drive_reset_partition() {
  in_partition=0
  uuid=""
  label=""
  fstype=""
  total_bytes=""
  free_bytes=""
}

select_drive_reset_media() {
  media_found=1
  media_is_usb=0
  current_manufacturer=""
  select_drive_reset_partition
}

select_drive_add_partition() {
  local used_bytes display_name fstype_upper
  if [ -z "$uuid" ] || [ -z "$fstype" ] || [ "$(echo "$fstype" | tr '[:upper:]' '[:lower:]')" = "swap" ]; then
    select_drive_reset_partition
    return
  fi
  echo "$total_bytes" | grep -qE '^[0-9]+$' || total_bytes=0
  echo "$free_bytes" | grep -qE '^[0-9]+$' || free_bytes=0
  used_bytes=$((total_bytes - free_bytes))
  [ "$used_bytes" -lt 0 ] && used_bytes=0
  if [ -n "$label" ]; then
    display_name="$label"
  elif [ -n "$current_manufacturer" ]; then
    display_name="$current_manufacturer"
  else
    display_name="Unknown"
  fi
  fstype_upper=$(echo "$fstype" | tr '[:lower:]' '[:upper:]')
  echo "$index. $display_name ($fstype_upper, $(format_size $used_bytes $total_bytes))"
  if [ -n "$uuids" ]; then
    uuids="$uuids
$uuid"
  else
    uuids="$uuid"
  fi
  index=$((index + 1))
  select_drive_reset_partition
}

exit_main_menu() {
  printf "\n${CYAN}00. Выход в главное меню${NC}\n\n"
}

select_drive() {
  local message="$1"
  local value
  uuids=""
  index=2
  media_found=0
  media_is_usb=0
  media_output=$(rci_parse "show media" 2>/dev/null)
  current_manufacturer=""
  select_drive_reset_partition

  if [ -z "$media_output" ]; then
    print_message "Не удалось получить список накопителей" "$RED"
    return 1
  fi

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
  if ! read -r -p "$message " choice; then
    echo ""
    exit 0
  fi
  choice=$(echo "$choice" | tr -d ' \n\r')
  if [ "$choice" = "00" ]; then
    main_menu
  fi
  echo ""
  case "$choice" in
    0) selected_drive="$TMP_DIR" ;;
    1) selected_drive="$STORAGE_DIR" ;;
    *)
      if [ -n "$uuids" ]; then
        selected_drive=$(printf '%s\n' "$uuids" | sed -n "$((choice - 1))p")
        if [ -z "$selected_drive" ]; then
          print_message "Неверный выбор" "$RED"
          exit_function
        fi
        selected_drive="/tmp/mnt/$selected_drive"
      else
        print_message "Неверный выбор" "$RED"
        exit_function
      fi
      ;;
  esac
}

spinner_start() {
  SPINNER_MSG="$1"
  local spin='|/-\\' i=0
  echo -n "[ ] $SPINNER_MSG"
  ( while :; do i=$(((i + 1) % 4)); printf "\r[%s] %s" "${spin:$i:1}" "$SPINNER_MSG"; usleep 100000; done ) &
  SPINNER_PID=$!
}

spinner_stop() {
  local rc=${1:-0}
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    unset SPINNER_PID
  fi
  if [ $rc -eq 0 ]; then
    printf "\r[✔] %s\n" "$SPINNER_MSG"
  else
    printf "\r[✖] %s\n" "$SPINNER_MSG"
  fi
}

exit_function() {
  echo ""
  if [ ! -t 0 ]; then exit 0; fi
  if ! read -n 1 -s -r -p "Для возврата нажмите любую клавишу..."; then echo ""; exit 0; fi
  pkill -P $$ 2>/dev/null
  exec "$OPT_DIR/$SCRIPT"
}

packages_checker() {
  local packages="$1"
  local flag="$2"
  local missing=""
  local installed
  installed=$(opkg list-installed 2>/dev/null)
  for pkg in $packages; do
    if ! echo "$installed" | grep -q "^$pkg "; then
      missing="$missing $pkg"
    fi
  done
  if [ -n "$missing" ]; then
    print_message "Устанавливаем:$missing" "$GREEN"
    opkg update >/dev/null 2>&1
    opkg install $missing $flag
    echo ""
  fi
}

# ====================== BACKUP ENTWARE (ТОЧНО КАК В KEENKIT) ======================

backup_entware() {
  packages_checker "tar libacl"
  output=$(mount)
  select_drive "Выберите накопитель:"
  backup_file="$selected_drive/$(get_architecture)_entware_backup_$DATE.tar.gz"
  
  spinner_start "Выполняю копирование"
  tar_output=$(tar cvzf "$backup_file" -C "$OPT_DIR" --exclude="$(basename "$backup_file")" . 2>&1)
  rc=$?

  log_operation=$(echo "$tar_output" | tail -n 2)
  if echo "$log_operation" | grep -iq "error\|no space left on device"; then
    spinner_stop 1
    print_message "Ошибка при создании бэкапа:" "$RED"
    echo "$log_operation"
  else
    spinner_stop 0
    print_message "Бэкап успешно сохранен в $backup_file" "$GREEN"
  fi
  exit_function
}

# ====================== ОСТАЛЬНЫЕ ФУНКЦИИ (AWG, NFQWS, UPDATE) ======================
# (все функции install_awg_last, install_awg_version, remove_awg, install_nfqws и т.д. — без изменений)

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
  curl -L# -o "awg-manager_${ver}_${S}.ipk" "https://github.com/hoaxisr/awg-manager/releases/download/v${ver}/awg-manager_${ver}_${S}.ipk" || {
    print_message "❌ Ошибка скачивания!" "$RED"; return 1
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

update_menu() {
  print_message "Обновление KeenExtras..." "$CYAN"
  curl -L -s "https://raw.githubusercontent.com/rndnaame/keen-extras/main/keenextras.sh" > /opt/keenextras.sh.tmp || {
    print_message "❌ Не удалось скачать обновление" "$RED"
    return 1
  }
  mv /opt/keenextras.sh.tmp /opt/keenextras.sh
  chmod +x /opt/keenextras.sh
  print_message "✅ KeenExtras успешно обновлён до v${SCRIPT_VERSION}" "$GREEN"
  echo "Перезапуск меню..."
  sleep 1
  exec /opt/keenextras.sh
}

cleanup() { echo -e "\n${NC}Выход...${NC}"; }

# ====================== МЕНЮ (без изменений) ======================

awg_menu() { ... }   # (тот же код что был раньше)

nfqws_menu() { ... } # (тот же код что был раньше)

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
