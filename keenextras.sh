#!/bin/sh
trap cleanup HUP INT TERM EXIT 2>/dev/null || true

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="keen-extras"
SCRIPT="keenextras.sh"
BRANCH="main"
SCRIPT_VERSION="1.9"
DATE=$(date +%Y-%m-%d_%H-%M)
OPT_DIR="/opt"
USERNAME="rndnaame"

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

# ====================== ГРАФИЧЕСКИЙ ЛОГО ======================
print_logo() {
  cat <<'EOF'
   __ __                __ __ _ __
  / //_/__  ___  ____  / //_/(_) /_
 / ,< / _ \/ _ \/ __ \/ ,<  / / __/
 / /| /  __/  __/ / / / /| |/ / /_
/_/ |_\___/\___/_/ /_/_/ |_/_/\__/
               KeenExtras
EOF
}

# ====================== ФУНКЦИИ ИНФОРМАЦИИ ИЗ ОРИГИНАЛЬНОГО KEENKIT ======================
get_version_info() {
  if [ -z "$VERSION_INFO" ]; then
    VERSION_INFO=$(rci_request "show/version" 2>/dev/null)
  fi
  echo "$VERSION_INFO"
}

get_system_info() {
  if [ -z "$SYSTEM_INFO" ]; then
    SYSTEM_INFO=$(rci_request "show/system" 2>/dev/null)
  fi
  echo "$SYSTEM_INFO"
}

get_interface_info() {
  if [ -z "$INTERFACE_INFO" ]; then
    INTERFACE_INFO=$(rci_request "show/interface" 2>/dev/null)
  fi
  echo "$INTERFACE_INFO"
}

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

get_device() {
  get_version_info | grep -o '"device": "[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "Unknown"
}

get_hw_id() {
  get_version_info | grep -o '"hw_id": "[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "Unknown"
}

get_fw_version() {
  get_version_info | grep -o '"title": "[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "Unknown"
}

get_boot_current() {
  cat /proc/dual_image/boot_current 2>/dev/null || echo "1"
}

get_cpu_model() {
  cat /tmp/sysinfo/soc 2>/dev/null || echo "Unknown"
}

get_radio_temp() {
  get_interface_info | awk -v iface="$1" '
    !in_iface {
      pos = index($0, "\"" iface "\"")
      if (pos) { in_iface=1; $0=substr($0,pos) }
    }
    in_iface && match($0, /"temperature": *[0-9]+/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
    in_iface && /}/ { in_iface=0 }
  ' | grep -o '[0-9]*' | head -n1
}

get_temperatures() {
  temp_2=$(get_radio_temp WifiMaster0)
  temp_5=$(get_radio_temp WifiMaster1)
  arch=$(get_architecture)
  cpu_str=""
  wifi_str=""

  if [ "$arch" = "aarch64" ]; then
    temp_cpu_raw=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null | tr -d -c '0-9')
    [ -n "$temp_cpu_raw" ] && cpu_str="CPU: $((temp_cpu_raw / 1000))°C"
  fi

  if ! echo "$temp_2" | grep -qE '^[0-9]+$'; then
    [ -n "$cpu_str" ] && echo " | $cpu_str"
    return
  fi

  if echo "$temp_5" | grep -qE '^[0-9]+$'; then
    diff=$((temp_5 - temp_2))
    [ $diff -lt 0 ] && diff=$((-diff))
    if [ $diff -lt 3 ]; then
      wifi_str="Wi-Fi: ${temp_5}°C"
    else
      wifi_str="2.4GHz: ${temp_2}°C | 5GHz: ${temp_5}°C"
    fi
  else
    wifi_str="2.4GHz: ${temp_2}°C"
  fi

  [ -n "$cpu_str" ] && wifi_str="$wifi_str | $cpu_str"
  echo " | $wifi_str"
}

get_ram_usage() {
  local memory=$(get_system_info | grep -o '"memory": "[^"]*"' | cut -d'"' -f4 2>/dev/null)
  local used=$(echo "$memory" | cut -d'/' -f1)
  local total=$(echo "$memory" | cut -d'/' -f2)
  printf "%d / %d MB" "$((used / 1024))" "$((total / 1024))"
}

get_opkg_storage() {
  local opkg_label
  local ls_json
  opkg_label=$(rci_request "show/sc/opkg/disk" 2>/dev/null | grep -o '"disk": *"[^\"]*"' | cut -d'"' -f4 | sed 's,/$,,;s,:$,,')
  ls_json=$(rci_request "ls" 2>/dev/null)

  free=$(echo "$ls_json" | grep -A10 "\"$opkg_label:\"" | grep '"free":' | head -1 | grep -o '[0-9]\+')
  total=$(echo "$ls_json" | grep -A10 "\"$opkg_label:\"" | grep '"total":' | head -1 | grep -o '[0-9]\+')

  if [ -n "$free" ] && [ -n "$total" ]; then
    used=$((total - free))
    echo "$(format_size $used $total)"
    return
  fi
  echo "0 / 0 MB"
}

get_uptime() {
  local uptime=$(get_system_info | grep -o '"uptime": "[0-9]*"' | cut -d'"' -f4 2>/dev/null)
  format_uptime_seconds "$uptime"
}

format_uptime_seconds() {
  local uptime=$1
  if [ -z "$uptime" ] || ! echo "$uptime" | grep -qE '^[0-9]+$'; then
    echo "Unknown"
    return
  fi
  local days=$((uptime / 86400))
  local hours=$(((uptime % 86400) / 3600))
  local minutes=$(((uptime % 3600) / 60))
  local seconds=$((uptime % 60))

  if [ "$days" -gt 0 ]; then
    printf "%d дн. %02d:%02d:%02d" "$days" "$hours" "$minutes" "$seconds"
  else
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
  fi
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

get_modem() { :; }
get_mws_members() { :; }
check_update() { :; }

# ====================== BACKUP ENTWARE ======================
get_internal_storage_size() {
  local ls_json=$(rci_request "ls" 2>/dev/null || echo '{"storage":{"free":0,"total":0}}')
  local free=$(echo "$ls_json" | grep -o '"free":[0-9]*' | head -1 | grep -o '[0-9]*' || echo 0)
  echo $((free / 1024 / 1024))
}

# (остальные backup-функции оставлены как работали раньше)

# ====================== AWG + NFQWS + UPDATE ======================
install_awg_last() { 
  print_message "Установка AWG Manager (последняя версия)..." "$GREEN"
  curl -sL https://raw.githubusercontent.com/hoaxisr/awg-manager/main/scripts/install.sh | sh
}

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
  opkg install nfqws-keenetic-web && print_message "🎉 Веб-интерфейс NFQWS успешно установлен!" "$GREEN" || print_message "⚠️ Ошибка установки" "$RED"
}

remove_nfqws() { 
  print_message "Удаление всех компонентов NFQWS..." "$RED"
  opkg remove --autoremove nfqws-keenetic nfqws2-keenetic nfqws-keenetic-web 2>/dev/null || true
  rm -f /opt/etc/opkg/nfqws-*.conf
  print_message "NFQWS полностью удалён" "$GREEN"
}

update_menu() {
  print_message "Обновление KeenExtras..." "$CYAN"
  curl -L -s "https://raw.githubusercontent.com/rndnaame/keen-extras/main/keenextras.sh" > /opt/keenextras.sh.tmp || { print_message "❌ Не удалось скачать обновление" "$RED"; return 1; }
  mv /opt/keenextras.sh.tmp /opt/keenextras.sh
  chmod +x /opt/keenextras.sh
  print_message "✅ KeenExtras успешно обновлён до v${SCRIPT_VERSION}" "$GREEN"
  echo "Перезапуск меню..."
  sleep 1
  exec /opt/keenextras.sh
}

cleanup() { echo -e "\n${NC}Выход...${NC}"; }

# ====================== ПОДМЕНЮ ======================
awg_menu() {
  while true; do
    printf "\033c"
    print_logo
    printf "${CYAN}=== AWG Manager ===${NC}\n\n"
    echo "1. Установить последнюю версию AWG Manager"
    echo "2. Установить выбранную версию AWG Manager"
    echo "3. Удалить AWG Manager"
    echo ""
    echo "0. Назад в главное меню"
    echo ""
    read -r -p "Выберите действие: " choice
    case "$choice" in
      1) install_awg_last ;;
      2) install_awg_version ;;
      3) remove_awg ;;
      0|00) return ;;
      *) echo "Неверный выбор" ;;
    esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

nfqws_menu() {
  while true; do
    printf "\033c"
    print_logo
    printf "${CYAN}=== NFQWS ===${NC}\n\n"
    echo "1. Установить NFQWS"
    echo "2. Установить NFQWS2"
    echo "3. Установить веб-интерфейс NFQWS"
    echo "4. Удалить NFQWS (все компоненты)"
    echo ""
    echo "0. Назад в главное меню"
    echo ""
    read -r -p "Выберите действие: " choice
    case "$choice" in
      1) install_nfqws ;;
      2) install_nfqws2 ;;
      3) install_nfqws_web ;;
      4) remove_nfqws ;;
      0|00) return ;;
      *) echo "Неверный выбор" ;;
    esac
    echo ""; read -r -p "Нажмите Enter для продолжения..."
  done
}

# ====================== ГЛАВНОЕ МЕНЮ (ТОЧНО КАК В KEENKIT) ======================
print_main_menu() {
  printf "\033c"
  print_logo

  arch="$(get_architecture)"
  printf "${CYAN}Модель: ${NC}%s\n" "$(get_device) ($(get_hw_id)) | $(get_fw_version) (слот: $(get_boot_current))"
  printf "${CYAN}Процессор: ${NC}%s\n" "$(get_cpu_model) ($arch)$(get_temperatures)"

  if get_modem_info=$(get_modem); [ -n "$get_modem_info" ]; then
    printf "${CYAN}Модем: ${NC}%s\n" "$get_modem_info"
  fi

  printf "${CYAN}ОЗУ: ${NC}%s\n" "$(get_ram_usage)"
  printf "${CYAN}OPKG: ${NC}%s\n" "$(get_opkg_storage)"
  printf "${CYAN}Время работы: ${NC}%s\n" "$(get_uptime)"

  if get_repeaters_info=$(get_mws_members); [ -n "$get_repeaters_info" ]; then
    printf "${CYAN}Ретрансляторы: ${NC}"
    printf "%b\n" "$get_repeaters_info"
  fi

  printf "${CYAN}Версия: ${NC}%s\n\n" "$SCRIPT_VERSION by ${USERNAME}$(check_update)"
  
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
  done
}

main_menu
