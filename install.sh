#!/usr/bin/env bash

# ============================================================================
# --- 01-core
# ============================================================================
# ============================================================================
#  gore — установщик: nginx SNI-роутер, фейковый сайт, Smart DNS, VPN-панель
#  https://github.com/tamrazcode/gore
#
#  Ставится одной командой:
#    bash <(curl -fsSL https://raw.githubusercontent.com/tamrazcode/gore/main/install.sh)
#
#  Один файл, без зависимостей кроме apt. Ubuntu 22.04/24.04, Debian 12+.
# ============================================================================

set -Eeuo pipefail
umask 022

VERSION="1.0.0"
SCRIPT_NAME="gore"
# каталог, откуда запущен скрипт (может быть /dev/fd при запуске из curl)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /root)"
RAW_BASE="${GORE_RAW_BASE:-https://raw.githubusercontent.com/tamrazcode/gore/main}"
STATE_DIR="/etc/sni-stack"
STATE_FILE="$STATE_DIR/state.env"
LOG_FILE="/var/log/gore.log"
ACME_WEBROOT="/var/www/acme"

# --------------------------------------------------------------- вывод -----
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'
  C_YEL=$'\e[33m'; C_BLU=$'\e[36m'; C_BOLD=$'\e[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''
fi

step() { printf '\n%s=>%s %s%s%s\n' "$C_BLU" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '   %s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
info() { printf '   %s·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() { printf '   %s!%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
fail() { printf '   %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; }
die()  { fail "$*"; printf '\n%sПрервано.%s\n' "$C_RED" "$C_RESET"; exit 1; }

log_to_file() {
  $DRY_RUN && return 0
  [[ -d /var/log ]] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------ опции ---------
P=""                 # префикс путей (непустой в --dry-run)
DRY_RUN=false
NONINTERACTIVE=false
ACTION="install"
MODE=""
WITH_DNS=true
WITH_VPN=true

path() { printf '%s%s' "$P" "$1"; }

run() {
  if $DRY_RUN; then info "dry-run: $*"; return 0; fi
  log_to_file "run: $*"
  "$@"
}

runsh() {
  if $DRY_RUN; then info "dry-run: $*"; return 0; fi
  log_to_file "runsh: $*"
  bash -c "$*"
}

need_root() { [[ $EUID -eq 0 ]] || die "нужен root: sudo bash install.sh"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1; }

# -------------------------------------------------------------- ввод -------
ask() { # ask <переменная> <вопрос> <дефолт> [валидатор]
  local var="$1" question="$2" def="${3:-}" validator="${4:-}"
  local current="${!var:-}" answer
  if [[ -n "$current" ]]; then
    answer="$current"
  elif $NONINTERACTIVE; then
    answer="$def"
  else
    if [[ -n "$def" ]]; then
      printf '   %s%s%s [%s]: ' "$C_BOLD" "$question" "$C_RESET" "$def"
    else
      printf '   %s%s%s: ' "$C_BOLD" "$question" "$C_RESET"
    fi
    read -r answer || answer=""
    [[ -z "$answer" ]] && answer="$def"
  fi
  if [[ -n "$validator" ]] && ! "$validator" "$answer"; then
    die "не подходит значение: '$answer'"
  fi
  printf -v "$var" '%s' "$answer"
}

confirm() { # confirm <вопрос> <y|n>
  local q="$1" def="${2:-n}" answer
  if $NONINTERACTIVE; then [[ "$def" == "y" ]]; return; fi
  printf '   %s%s%s [%s]: ' "$C_BOLD" "$q" "$C_RESET" "$def"
  read -r answer || answer=""
  [[ -z "$answer" ]] && answer="$def"
  [[ "$answer" =~ ^[YyДд] ]]
}

# --------------------------------------------------------- валидаторы ------
is_domain()  { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
is_ip4()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_domain_or_empty() { [[ -z "$1" ]] || is_domain "$1"; }

# ------------------------------------------------------------ утилиты ------
rand_str() { head -c 512 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "${1:-10}"; }

rand_port() {
  local port tries=0
  while (( tries++ < 300 )); do
    port=$(( (RANDOM << 15 | RANDOM) % 49152 + 10000 ))
    port_busy "$port" || { printf '%s' "$port"; return 0; }
  done
  die "не нашёл свободный порт"
}

port_busy() { ss -tuln 2>/dev/null | grep -qE "[:.]$1\b"; }

get_ip4() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -Po -- 'src \K[0-9.]+' | head -1)
  is_ip4 "$ip" || ip=$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
  is_ip4 "$ip" || return 1
  printf '%s' "$ip"
}

get_ip6() {
  local ip
  ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -Po -- 'src \K[0-9a-fA-F:]+' | head -1)
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

domain_points_here() {
  local host="$1" ip="$2" got
  got=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  [[ -z "$got" ]] && return 1
  grep -qx "$ip" <<<"$got"
}

# -------------------------------------------------------------- файлы ------
ensure_dir() {
  # в dry-run путь уже с префиксом /tmp/sni-stack-dry, поэтому создаём по-настоящему
  mkdir -p "$(path "$1")"
}

write_file() { # write_file <путь> [права]  (читает stdin)
  local target mode="${2:-644}"
  target="$(path "$1")"
  mkdir -p "$(dirname "$target")"
  cat > "$target.tmp.$$"
  chmod "$mode" "$target.tmp.$$"
  mv -f "$target.tmp.$$" "$target"
  info "записан ${1} (${mode})"
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  $DRY_RUN && { info "dry-run: бэкап $f"; return 0; }
  local dest="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)/${f#/}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest" 2>/dev/null || true
}

subst() { # subst <файл> <из> <в>
  $DRY_RUN && { info "dry-run: subst $2 -> $3 в $1"; return 0; }
  sed -i "s|$2|$3|g" "$(path "$1")"
}

# ---------------------------------------------------------- состояние ------
state_set() {
  local key="$1" val="$2"
  if $DRY_RUN; then info "dry-run: state ${key}=${val}"; return 0; fi
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  if grep -qE "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}='${val}'|" "$STATE_FILE"
  else
    printf "%s='%s'\n" "$key" "$val" >> "$STATE_FILE"
  fi
}

state_load() { [[ -f "$STATE_FILE" ]] && { source "$STATE_FILE"; return 0; } || return 1; }

state_get() {
  [[ -f "$STATE_FILE" ]] || return 1
  grep -E "^$1=" "$STATE_FILE" | tail -1 | cut -d= -f2- | tr -d "'\""
}

banner() {
  cat <<'EOF'
   ██████  ██████  ██████  ███████
  ██      ██    ██ ██   ██ ██
  ██   ███ ██    ██ ██████  █████
  ██    ██ ██    ██ ██   ██ ██
   ██████   ██████  ██   ██ ███████
EOF
  printf '  nginx SNI · фейковый сайт · Smart DNS · VPN   v%s\n' "$VERSION"
}


# ============================================================================
# --- 02-args
# ============================================================================
# ---------------------------------------------------------------- аргументы --
DOMAIN=""
REALITY_DOMAIN=""
DNS_DOMAIN=""
ACME_EMAIL=""
AUTO_DOMAIN=false
NO_CERT=false
FAKE_SITE="auto"
PANEL_USER=""
PANEL_PASS=""
RESTORE_FILE=""
ADGUARD_SRC="auto"
KEEP_DATA=false
PANEL="yes"        # yes = ставим 3x-ui с автонастройкой, no = чистый xray без панели
USERS="3"          # сколько клиентов завести
REGION="ru"        # ru = geodata + split-tunnel для РФ, none = не трогать

usage() {
  cat <<EOF
${C_BOLD}gore${C_RESET} — nginx SNI-роутер, фейковый сайт, Smart DNS и VPN-панель одной командой.

  ${C_BOLD}Установка${C_RESET}
    sudo bash install.sh [флаги]

  ${C_BOLD}Что ставим${C_RESET}
    --mode full|dns|vpn     что разворачивать (по умолчанию full)
    --no-dns / --with-dns   Smart DNS-слой (AdGuard + релей + дашборд)
    --no-vpn / --with-vpn   VPN-слой (3x-ui + xray)

  ${C_BOLD}Домены${C_RESET}
    --domain <имя>          домен панели и фейк-сайта (panel.example.com)
    --reality-domain <имя>  домен-прикрытие Reality (cdn.example.com)
    --dns-domain <имя>      домен DNS/DoH/дашборда (dns.example.com)
    --auto-domain           без вопросов: <ip>.cdn-one.org и <ip-тире>.cdn-one.org
    --email <адрес>         почта ACME (необязательно)
    --no-cert               самоподписанные сертификаты (тест, без доменов)

  ${C_BOLD}Панель${C_RESET}
    --panel yes|no          ставить 3x-ui с автонастройкой (по умолчанию yes)
    --users <N>             сколько клиентов завести (по умолчанию 3)
    --panel-user <логин>    логин 3x-ui (по умолчанию случайный)
    --panel-pass <пароль>   пароль 3x-ui (по умолчанию случайный)

  ${C_BOLD}Регион${C_RESET}
    --region ru|none        ru: geodata + split-tunnel, RU-трафик напрямую (по умолчанию ru)

  ${C_BOLD}Прочее${C_RESET}
    --fake-site <тема|auto> тема фейкового сайта
    --adguard-src <путь|url|auto>  откуда взять AdGuardHome
    --dry-run               ничего не менять, собрать конфиги в /tmp/sni-stack-dry
    -y, --yes               без вопросов (нужны --domain и --reality-domain)
    -h, --help              эта справка

  ${C_BOLD}Обслуживание${C_RESET}
    --status                состояние стека
    --doctor                диагностика
    --backup [файл]         архив конфигов
    --restore <файл>        восстановление из архива
    --uninstall             снять стек
    --keep-data             при удалении оставить данные Smart DNS

  ${C_BOLD}Примеры${C_RESET}
    sudo bash install.sh --domain panel.example.com \\
         --reality-domain cdn.example.com --dns-domain dns.example.com
    sudo bash install.sh --auto-domain --mode dns
    sudo bash install.sh --dry-run --auto-domain
    sudo bash install.sh --status
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)           MODE="$2"; shift 2;;
      --domain)         DOMAIN="$2"; shift 2;;
      --reality-domain) REALITY_DOMAIN="$2"; shift 2;;
      --dns-domain)     DNS_DOMAIN="$2"; shift 2;;
      --email)          ACME_EMAIL="$2"; shift 2;;
      --auto-domain)    AUTO_DOMAIN=true; shift;;
      --no-cert)        NO_CERT=true; shift;;
      --fake-site)      FAKE_SITE="$2"; shift 2;;
      --panel-user)     PANEL_USER="$2"; shift 2;;
      --panel-pass)     PANEL_PASS="$2"; shift 2;;
      --adguard-src)    ADGUARD_SRC="$2"; shift 2;;
      --panel)          PANEL="$2"; shift 2;;
      --users)          USERS="$2"; shift 2;;
      --region)         REGION="$2"; shift 2;;
      --with-dns)       WITH_DNS=true; shift;;
      --no-dns)         WITH_DNS=false; shift;;
      --with-vpn)       WITH_VPN=true; shift;;
      --no-vpn)         WITH_VPN=false; shift;;
      --dry-run)        DRY_RUN=true; shift;;
      -y|--yes)         NONINTERACTIVE=true; shift;;
      --status)         ACTION="status"; shift;;
      --doctor)         ACTION="doctor"; shift;;
      --backup)         ACTION="backup"
                        if [[ "${2:-}" && "${2:0:1}" != "-" ]]; then RESTORE_FILE="$2"; shift; fi
                        shift;;
      --restore)        ACTION="restore"; RESTORE_FILE="${2:-}"; shift 2;;
      --uninstall)      ACTION="uninstall"; shift;;
      --keep-data)      KEEP_DATA=true; shift;;
      -h|--help)        usage; exit 0;;
      -v|--version)     echo "$SCRIPT_NAME $VERSION"; exit 0;;
      *)                warn "неизвестный аргумент: $1"; shift;;
    esac
  done

  case "$MODE" in
    "")   ;;
    full) WITH_DNS=true;  WITH_VPN=true;;
    dns)  WITH_DNS=true;  WITH_VPN=false; PANEL="no";;
    vpn)  WITH_DNS=false; WITH_VPN=true;;
    *)    die "неизвестный --mode: $MODE (full|dns|vpn)";;
  esac

  case "$PANEL" in
    yes|true|1)  PANEL="yes";;
    no|false|0)  PANEL="no";;
    *)           die "--panel: ожидал yes или no, получил '$PANEL'";;
  esac
  case "$REGION" in
    ru|none) ;;
    *)       die "--region: ожидал ru или none, получил '$REGION'";;
  esac
  [[ "$USERS" =~ ^[0-9]+$ ]] || die "--users: нужно число"

  $WITH_DNS || $WITH_VPN || die "нечего ставить: DNS и VPN оба выключены"

  [[ -n "$DOMAIN" ]]         && ! is_domain "$DOMAIN"         && die "--domain не похож на домен: $DOMAIN"
  [[ -n "$REALITY_DOMAIN" ]] && ! is_domain "$REALITY_DOMAIN" && die "--reality-domain не похож на домен: $REALITY_DOMAIN"
  [[ -n "$DNS_DOMAIN" ]]     && ! is_domain "$DNS_DOMAIN"     && die "--dns-domain не похож на домен: $DNS_DOMAIN"
  if [[ -n "$REALITY_DOMAIN" && "$REALITY_DOMAIN" == "$DOMAIN" ]]; then
    die "--reality-domain должен отличаться от --domain"
  fi

  if $DRY_RUN; then
    P="/tmp/sni-stack-dry"
    rm -rf "$P"
    mkdir -p "$P"
    STATE_DIR="$P/etc/sni-stack"
    STATE_FILE="$STATE_DIR/state.env"
    ACME_WEBROOT="$P/var/www/acme"
  fi

  # хосты, куда мы пишем, должны быть отдельными, чтобы не поломать чужие сайты
  if ! $DRY_RUN && [[ -f /etc/sni-stack/state.env ]]; then
    info "найден прошлый запуск, читаю /etc/sni-stack/state.env"
  fi
}

resolve_domains() {
  local ip4="${IP4:-}" base
  if $AUTO_DOMAIN; then
    [[ -n "$ip4" ]] || die "не смог определить внешний IPv4"
    DOMAIN="${ip4}.cdn-one.org"
    REALITY_DOMAIN="${ip4//./-}.cdn-one.org"
    [[ -n "$DNS_DOMAIN" ]] || DNS_DOMAIN="dns-${ip4//./-}.cdn-one.org"
    info "auto-domain: панель $DOMAIN, reality $REALITY_DOMAIN"
  fi

  if ! $NO_CERT; then
    ask DOMAIN "Домен панели и фейк-сайта (panel.example.com)" "" is_domain
    if $WITH_VPN; then
      ask REALITY_DOMAIN "Домен-прикрытие Reality (cdn.example.com)" "" is_domain
    fi
    if $WITH_DNS; then
      ask DNS_DOMAIN "Домен DNS/DoH/дашборда (dns.example.com)" "dns.${DOMAIN#*.}" is_domain
    fi
  else
    # без сертификатов домены всё равно нужны для SNI и Host
    ask DOMAIN "Домен панели и фейк-сайта (panel.example.com)" "" is_domain
    if $WITH_VPN; then
      ask REALITY_DOMAIN "Домен-прикрытие Reality (cdn.example.com)" "" is_domain
    fi
    if $WITH_DNS; then
      ask DNS_DOMAIN "Домен DNS/DoH/дашборда (dns.example.com)" "dns.${DOMAIN#*.}" is_domain
    fi
  fi

  MAIN_DOMAIN="${DOMAIN#*.}"
  [[ "$MAIN_DOMAIN" == "$DOMAIN" ]] && MAIN_DOMAIN="$DOMAIN"
  state_set DOMAIN "$DOMAIN"
  $WITH_VPN && state_set REALITY_DOMAIN "$REALITY_DOMAIN"
  $WITH_DNS && state_set DNS_DOMAIN "$DNS_DOMAIN"
}


# ============================================================================
# --- 03-system
# ============================================================================
# ------------------------------------------------------------------ система --
install_packages() {
  step "Пакеты"
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(
    curl wget ca-certificates jq openssl sqlite3 dnsutils
    nginx-full python3 ufw unzip tar netcat-openbsd
  )
  # certbot нужен только когда выпускаем настоящие сертификаты
  if ! $NO_CERT; then
    pkgs+=(certbot python3-certbot-nginx)
  fi
  $WITH_DNS || pkgs+=(xxd)
  run apt-get update -qq
  run apt-get install -y -qq "${pkgs[@]}"
  ok "пакеты на месте"

  # nginx-full на Debian может не принести stream-модуль
  if ! nginx -V 2>&1 | grep -q with-stream; then
    info "догружаю stream-модуль"
    run apt-get install -y -qq libnginx-mod-stream
  fi
}

tune_system() {
  step "Тюнинг системы"
  local tpl
  tpl="$(path /etc/sysctl.d/99-gore.conf)"
  write_file /etc/sysctl.d/99-gore.conf 644 <<'EOF'
# gore: сеть под много соединений через nginx/xray
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_forward = 0
fs.file-max = 1048576
EOF
  run sysctl --system -q

  # журнал не должен съедать диск — на старом хосте он разросся до 3 ГБ
  write_file /etc/systemd/journald.conf.d/99-gore.conf 644 <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
  run systemctl restart systemd-journald

  # лимиты файлов для nginx
  write_file /etc/security/limits.d/99-gore.conf 644 <<'EOF'
* soft nofile 65535
* hard nofile 65535
EOF
  ok "bbr, лимиты журнала и файлов выставлены"
}

ensure_ports_free() {
  step "Проверка портов"
  local p
  for p in 80 443; do
    if port_busy "$p"; then
      warn "порт $p занят процессом:"
      ss -tulpn 2>/dev/null | grep -E "[:.]$p\b" | sed 's/^/      /' || true
      if confirm "Остановить nginx и освободить $p?" y; then
        run systemctl stop nginx 2>/dev/null || true
      else
        die "порт $p занят, не могу продолжить"
      fi
    fi
  done
  ok "80 и 443 свободны"
}

setup_firewall() {
  step "Файрвол"
  local ports=(22 80 443 53 853 9339 7443 9443 17443)
  run ufw --force reset >/dev/null 2>&1 || true
  run ufw default deny incoming
  run ufw default allow outgoing
  for p in "${ports[@]}"; do
    case "$p" in
      53)   run ufw allow 53/tcp  comment 'DNS TCP'
            run ufw allow 53/udp  comment 'DNS UDP' ;;
      853)  run ufw allow 853/tcp comment 'DNS over TLS' ;;
      9339) run ufw allow 9339/tcp
            run ufw allow 9339/udp ;;
      *)    run ufw allow "$p/tcp" ;;
    esac
  done
  if [[ -n "${IP4:-}" ]] && $WITH_DNS; then
    # пробросы игр и прочего добавляются отдельно, здесь только 443/udp закрываем
    run ufw deny 443/udp
  fi
  run ufw --force enable
  ok "ufw включён: 22, 80, 443, 53, 853, 9339, 7443, 9443, 17443"
}

create_layout() {
  step "Каталоги"
  local d
  for d in /etc/smartdns /opt/smartdns /var/lib/smartdns \
           /var/www/smartdns /var/www/html /var/www/subpage \
           /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/snippets \
           /etc/nginx/conf.d /etc/nginx/stream-enabled /root/cert; do
    ensure_dir "$d"
  done
  # STATE_DIR уже с префиксом в dry-run
  mkdir -p "$STATE_DIR/backups"
  # ACME_WEBROOT тоже уже с префиксом
  mkdir -p "$ACME_WEBROOT"

  # пути и порты панели/подписок: при повторном запуске берём из state
  PANEL_PATH="${PANEL_PATH:-$(state_get PANEL_PATH 2>/dev/null || echo "p$(rand_str 12)")}"
  PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT 2>/dev/null || rand_port)}"
  SUB_PATH="${SUB_PATH:-$(state_get SUB_PATH 2>/dev/null || echo "s$(rand_str 12)")}"
  SUB_PORT="${SUB_PORT:-$(state_get SUB_PORT 2>/dev/null || rand_port)}"
  JSON_PATH="${JSON_PATH:-$(state_get JSON_PATH 2>/dev/null || echo "j$(rand_str 12)")}"
  XHTTP_PATH="${XHTTP_PATH:-$(state_get XHTTP_PATH 2>/dev/null || echo "x$(rand_str 12)")}"
  WS_PATH="${WS_PATH:-$(state_get WS_PATH 2>/dev/null || echo "/w$(rand_str 11)")}"
  REALITY_PORT="${REALITY_PORT:-$(state_get REALITY_PORT 2>/dev/null || echo 8443)}"
  XHTTP_PORT="${XHTTP_PORT:-$(state_get XHTTP_PORT 2>/dev/null || echo 2096)}"
  REALITY_DEST="${REALITY_DEST:-$(state_get REALITY_DEST 2>/dev/null || echo 'www.microsoft.com:443')}"

  state_set PANEL_PATH "$PANEL_PATH"
  state_set PANEL_PORT "$PANEL_PORT"
  state_set SUB_PATH "$SUB_PATH"
  state_set SUB_PORT "$SUB_PORT"
  state_set JSON_PATH "$JSON_PATH"
  state_set XHTTP_PATH "$XHTTP_PATH"
  state_set WS_PATH "$WS_PATH"
  state_set REALITY_PORT "$REALITY_PORT"
  state_set XHTTP_PORT "$XHTTP_PORT"
  state_set REALITY_DEST "$REALITY_DEST"

  ok "каталоги готовы (панель: /$PANEL_PATH → 127.0.0.1:$PANEL_PORT)"
}


# ============================================================================
# --- 04-certs
# ============================================================================
# ---------------------------------------------------------------- сертификаты --
CERT_DIR_OF() { printf '/etc/letsencrypt/live/%s' "$1"; }

selfsigned_cert() { # selfsigned_cert <домен>
  local d="$1" dir
  dir="$(path "$(CERT_DIR_OF "$d")")"
  mkdir -p "$dir"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
    -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1 \
    || die "openssl не смог сделать сертификат для $d"
  cp "$dir/fullchain.pem" "$dir/cert.pem"
  chmod 600 "$dir/privkey.pem"
  ok "самоподписанный сертификат: $d"
}

issue_cert() { # issue_cert <домен>
  local d="$1" dir
  dir="$(CERT_DIR_OF "$d")"

  if $NO_CERT; then
    selfsigned_cert "$d"
    return 0
  fi

  if [[ -f "$(path "$dir/fullchain.pem")" ]] && ! $DRY_RUN; then
    if openssl x509 -in "$dir/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1; then
      ok "сертификат уже есть и живой: $d"
      return 0
    fi
  fi

  if ! domain_points_here "$d" "${IP4:-}"; then
    warn "$d не резолвится в этот сервер (${IP4:-?})"
    if confirm "Выпустить самоподписанный вместо Let's Encrypt?" y; then
      NO_CERT=true
      selfsigned_cert "$d"
      return 0
    fi
    die "поправь A-запись $d и запусти снова"
  fi

  step "Сертификат Let's Encrypt: $d"
  local email_arg=(--register-unsafely-without-email)
  [[ -n "$ACME_EMAIL" ]] && email_arg=(--email "$ACME_EMAIL")

  # port 80 ещё никем не занят — standalone самый надёжный путь
  if ! run certbot certonly --standalone --non-interactive --agree-tos \
        "${email_arg[@]}" \
        --pre-hook "systemctl stop nginx" \
        --post-hook "systemctl start nginx" \
        --deploy-hook "systemctl reload nginx" \
        -d "$d"; then
    # nginx мог уже работать — пробуем через webroot
    warn "standalone не вышло, пробую webroot"
    ensure_dir "$ACME_WEBROOT"
    run systemctl start nginx 2>/dev/null || true
    run certbot certonly --webroot -w "$ACME_WEBROOT" --non-interactive --agree-tos \
        "${email_arg[@]}" --deploy-hook "systemctl reload nginx" -d "$d" \
      || die "не смог выпустить сертификат для $d (см. /var/log/letsencrypt)"
  fi
  ok "сертификат готов: $d"
}

issue_all_certs() {
  step "Сертификаты"
  issue_cert "$DOMAIN"
  $WITH_VPN && [[ -n "$REALITY_DOMAIN" ]] && issue_cert "$REALITY_DOMAIN"
  $WITH_DNS && [[ -n "$DNS_DOMAIN" ]] && issue_cert "$DNS_DOMAIN"

  if ! $NO_CERT && ! $DRY_RUN; then
    # автопродление: у пакета certbot есть свой таймер, добавим релог nginx после обновления
    local f
    for f in /etc/letsencrypt/renewal/*.conf; do
      [[ -f "$f" ]] || continue
      grep -q '^renew_hook' "$f" || echo 'renew_hook = systemctl reload nginx' >> "$f"
    done
    ok "продление: systemd-таймер certbot + reload nginx после обновления"
  fi
}


# ============================================================================
# --- 05-nginx
# ============================================================================
# ------------------------------------------------------------------- nginx ---

nginx_prepare() {
  step "Подготовка nginx"
  backup_file /etc/nginx/nginx.conf

  if $DRY_RUN; then
    # в dry-run собираем изолированную копию, чтобы прогнать nginx -t -c
    mkdir -p "$(path /etc/nginx)"
    cp /etc/nginx/nginx.conf "$(path /etc/nginx/nginx.conf)" 2>/dev/null || true
    local conf; conf="$(path /etc/nginx/nginx.conf)"
    sed -i "s|include /etc/nginx/conf.d|include ${P}/etc/nginx/conf.d|g;
            s|include /etc/nginx/sites-enabled|include ${P}/etc/nginx/sites-enabled|g" "$conf"
    grep -q 'stream-enabled' "$conf" || \
      printf '\nstream {\n    include %s/etc/nginx/stream-enabled/*.conf;\n}\n' "$P" >> "$conf"
    sed -i 's/^\( *\)server_tokens .*;/\1server_tokens off;/' "$conf"
    info "dry-run: nginx.conf собран в $conf"
  else
    if ! grep -q 'stream-enabled' /etc/nginx/nginx.conf; then
      printf '\nstream {\n    include /etc/nginx/stream-enabled/*.conf;\n}\n' >> /etc/nginx/nginx.conf
    fi
    sed -i 's/worker_connections [0-9]*;/worker_connections 8192;/' /etc/nginx/nginx.conf
    # версия nginx в заголовке не нужна (в 26.04 там server_tokens build)
    sed -i 's/^\( *\)server_tokens .*;/\1server_tokens off;/' /etc/nginx/nginx.conf
  fi

  # общие настройки http-уровня
  # server_tokens не задаём: в Ubuntu 26.04 он уже есть в nginx.conf, дубль ломает конфиг
  write_file /etc/nginx/conf.d/00-gore-base.conf 644 <<'EOF'
# gore: базовые настройки (server_tokens живёт в nginx.conf)
client_max_body_size 64m;
client_body_timeout 1d;
proxy_read_timeout 1d;
send_timeout 1d;
EOF

  # зоны rate limit (используются в vhost'ах DNS)
  write_file /etc/nginx/conf.d/00-gore-rate.conf 644 <<'EOF'
limit_req_zone $proxy_protocol_addr zone=smartdns_monitor:10m rate=10r/s;
limit_req_zone $proxy_protocol_addr zone=smartdns_doh:10m rate=20r/s;
EOF

  # дефолтный сайт мешает: он ловит неизвестные Host
  if ! $DRY_RUN; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  ok "nginx подготовлен"
}

# stream.conf собирается из policy.json: панель и DNS-домены исключаются из списка,
# иначе их SNI улетел бы в релей вместо своего vhost'а.
gen_stream_conf_file() {
  local out
  out="$(path /etc/nginx/stream-enabled/stream.conf)"
  mkdir -p "$(dirname "$out")"
  {
    printf '%s\n' "# gore: SNI-роутер (сгенерирован $(date '+%F %T'))"
    printf '%s\n' "map \$ssl_preread_server_name \$sni_target {"
    printf '%s\n' "    hostnames;"
    $WITH_DNS && [[ -n "$DNS_DOMAIN" ]] && printf '    %-52s smartdns_monitor;\n' "$DNS_DOMAIN"
    printf '    %-52s www;\n' "$DOMAIN"
    if $WITH_VPN && [[ -n "$REALITY_DOMAIN" ]]; then
      printf '    %-52s xray;\n' "$REALITY_DOMAIN"
    fi
    if $WITH_DNS; then
      local policy; policy="$(path /etc/smartdns/policy.json)"
      if [[ -f "$policy" ]]; then
        python3 - "$policy" "$DOMAIN" "${REALITY_DOMAIN:-}" "${DNS_DOMAIN:-}" <<'PY'
import json, sys
src, *skip = sys.argv[1:]
skip = {s.lower() for s in skip if s}
pol = json.load(open(src))
for h in pol.get('exact', []):
    if h.lower() not in skip:
        print(f"    {h:<52} smartdns_relay;")
for r in pol.get('roots', []):
    if r.lower() not in skip:
        print("    ~^(?:[^.]+\\.)*" + r.replace('.', '\\.') + "$  smartdns_relay;")
PY
      fi
    fi
    printf '%s\n' "    default                                              xray;"
    printf '%s\n' "}"
    printf '%s\n' ""
    printf '%s\n' "upstream www              { server 127.0.0.1:7443; }"
    printf '%s\n' "upstream xray             { server 127.0.0.1:8443; }"
    printf '%s\n' "upstream smartdns_relay   { server 127.0.0.1:15443; }"
    printf '%s\n' "upstream smartdns_monitor { server 127.0.0.1:17443; }"
    printf '%s\n' ""
    printf '%s\n' "server {"
    printf '%s\n' "    listen 443;"
    printf '%s\n' "    listen [::]:443;"
    printf '%s\n' "    proxy_pass \$sni_target;"
    printf '%s\n' "    ssl_preread on;"
    printf '%s\n' "    proxy_protocol on;"
    printf '%s\n' "    proxy_connect_timeout 10s;"
    printf '%s\n' "}"
  } > "$out"
  ok "stream.conf: $(grep -cE 'smartdns_relay;' "$out" 2>/dev/null || echo 0) доменов на Smart DNS"
}

gen_vhost_80() {
  write_file /etc/nginx/sites-available/gore-80.conf 644 <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${REALITY_DOMAIN:-} ${DNS_DOMAIN:-};

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type text/plain;
    }

    location / { return 301 https://\$host\$request_uri; }
}
EOF
}

gen_vhost_panel() {
  local cert; cert="$(path /etc/letsencrypt/live/${DOMAIN})"
  write_file "/etc/nginx/sites-available/${DOMAIN}" 644 <<EOF
# gore: панель + фейковый сайт
server {
    server_tokens off;
    server_name ${DOMAIN};
    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl proxy_protocol;
    root $(path /var/www/html);
    index index.html;

    ssl_certificate     ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!EXP:!PSK:!DSS;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_stapling off;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    if (\$host !~* ^(.+\.)?${DOMAIN//./\\.}\$) { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\\$|&&|\?\?|0x00|0X00|\||\\\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404.html;

    # панель 3x-ui
    location /${PANEL_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        break;
    }

    include $(path /etc/nginx/snippets/gore-includes.conf);
}
EOF
}

gen_vhost_reality() {
  local cert; cert="$(path /etc/letsencrypt/live/${REALITY_DOMAIN})"
  write_file "/etc/nginx/sites-available/${REALITY_DOMAIN}" 644 <<EOF
# gore: домен-прикрытие Reality — отдаёт фейковый сайт
server {
    server_tokens off;
    server_name ${REALITY_DOMAIN};
    listen 9443 ssl http2;
    listen [::]:9443 ssl proxy_protocol;
    root $(path /var/www/html);
    index index.html;

    ssl_certificate     ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!EXP:!PSK:!DSS;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    if (\$host !~* ^(.+\.)?${REALITY_DOMAIN//./\\.}\$) { return 444; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404.html;
    include $(path /etc/nginx/snippets/gore-includes.conf);
}
EOF
}

gen_vhost_dns() {
  local cert; cert="$(path /etc/letsencrypt/live/${DNS_DOMAIN})"
  write_file "/etc/nginx/conf.d/gore-dns-tls.conf" 644 <<EOF
# gore: DoH и дашборд Smart DNS
server {
    listen 17443 ssl http2 proxy_protocol;
    listen [::]:17443 ssl proxy_protocol;
    server_name ${DNS_DOMAIN};

    ssl_certificate     ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    port_in_redirect off;

    include $(path /etc/nginx/snippets/gore-dns.conf);

    location = /dns-query {
        limit_req zone=smartdns_doh burst=40 nodelay;
        limit_req_status 429;
        client_max_body_size 65536;
        proxy_pass https://127.0.0.1:10443/dns-query;
        proxy_ssl_server_name on;
        proxy_ssl_name ${DNS_DOMAIN};
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 4;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_set_header Host ${DNS_DOMAIN};
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_intercept_errors off;
    }

    location @smartdns_error { return 503; }

    # всё остальное — фейковый сайт с соседнего vhost'а (маскировка)
    location / {
        proxy_pass https://127.0.0.1:9443;
        proxy_ssl_server_name on;
        proxy_ssl_name ${REALITY_DOMAIN:-$DOMAIN};
        proxy_set_header Host ${REALITY_DOMAIN:-$DOMAIN};
        proxy_intercept_errors off;
    }
}
EOF
}

gen_snippets() {
  # общие пути панели/xray (динамический прокси по номеру порта)
  write_file /etc/nginx/snippets/gore-includes.conf 644 <<'EOF'
    # подписки 3x-ui
    location /__SUB__ { if ($hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:__SUBPORT__;
        break;
    }
    # json-подписки
    location /__JSON__ { if ($hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:__SUBPORT__;
        break;
    }
    location /assets { proxy_pass http://127.0.0.1:__SUBPORT__; }
    # xhttp (gRPC по unix-сокету)
    location /__XHTTP__ {
        grpc_pass grpc://unix:/dev/shm/xray-uds.sock;
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host $host;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    # динамический прокси: /<порт>/<путь> -> 127.0.0.1:<порт>
    location ~ ^/(?<fwdport>\d+)(?<fwdpath>/.*)?$ {
        if ($hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        if ($content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:$fwdport;
            break;
        }
        if ($http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:$fwdport$fwdpath$is_args$args;
            break;
        }
        proxy_pass http://127.0.0.1:$fwdport$fwdpath$is_args$args;
    }
    location / { try_files $uri $uri/ =404; }
EOF

  sed -i "s|__SUB__|${SUB_PATH:-sub$(rand_str 6)}|g; s|__JSON__|${JSON_PATH:-json$(rand_str 6)}|g; s|__SUBPORT__|${SUB_PORT:-20000}|g; s|__XHTTP__|${XHTTP_PATH:-xhttp$(rand_str 6)}|g" \
      "$(path /etc/nginx/snippets/gore-includes.conf)"

  # WS-инбаунд Xray наружу через nginx (совместимо с Cloudflare)
  if [[ -n "${WS_PATH:-}" ]]; then
    cat >> "$(path /etc/nginx/snippets/gore-includes.conf)" <<EOF

    # WS за nginx: путь для CDN/Cloudflare
    location ${WS_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
        proxy_pass http://127.0.0.1:${WS_PORT_LOCAL:-10000};
    }
EOF
  fi

  # дашборд Smart DNS
  write_file /etc/nginx/snippets/gore-dns.conf 644 <<'EOF'
location = /dns { return 302 /dns/overview; }
location = /dns/ { return 302 /dns/overview; }
location = /dns/overview {
    alias /var/www/smartdns/index.html;
    default_type text/html;
    add_header Cache-Control "no-cache";
    add_header X-Content-Type-Options nosniff;
}
location = /dns/style.css  { alias /var/www/smartdns/style.css; }
location = /dns/app.js     { alias /var/www/smartdns/app.js; }
location = /dns/guides.js  { alias /var/www/smartdns/guides.js; }
location = /dns/fonts.css  { alias /var/www/smartdns/fonts.css; }
location = /dns/catalog.json   { alias /var/www/smartdns/catalog.json;   default_type application/json; add_header Cache-Control "no-cache"; }
location = /dns/logo-map.json  { alias /var/www/smartdns/logo-map.json;  default_type application/json; add_header Cache-Control "no-cache"; }
location ^~ /dns/logos/ { alias /var/www/smartdns/logos/; add_header Cache-Control "public, max-age=86400"; }
location ^~ /dns/fonts/ { alias /var/www/smartdns/fonts/; add_header Cache-Control "public, max-age=86400"; }
location = /dns/favicon.svg  { alias /var/www/smartdns/favicon.svg; default_type image/svg+xml; add_header Cache-Control "public, max-age=604800"; }
location = /dns/favicon.ico  { alias /var/www/smartdns/favicon.ico; default_type image/x-icon; add_header Cache-Control "public, max-age=604800"; }
location = /dns/apple-touch-icon.png { alias /var/www/smartdns/apple-touch-icon.png; default_type image/png; add_header Cache-Control "public, max-age=604800"; }

location = /dns/api/telemetry {
    limit_req zone=smartdns_monitor burst=20 nodelay;
    limit_req_status 429;
    proxy_pass http://127.0.0.1:18081/api/telemetry$is_args$args;
    proxy_set_header X-SmartDNS-Client $proxy_protocol_addr;
    proxy_set_header X-Forwarded-For "";
    proxy_read_timeout 5s;
    proxy_intercept_errors off;
    error_page 500 502 503 504 = @smartdns_error;
}
location = /dns/api/history {
    limit_req zone=smartdns_monitor burst=20 nodelay;
    proxy_pass http://127.0.0.1:18081/api/history$is_args$args;
    proxy_set_header X-SmartDNS-Client $proxy_protocol_addr;
    proxy_read_timeout 15s;
    error_page 500 502 503 504 = @smartdns_error;
}
location = /dns/api/system {
    limit_req zone=smartdns_monitor burst=20 nodelay;
    proxy_pass http://127.0.0.1:18081/api/system$is_args$args;
    proxy_set_header X-SmartDNS-Client $proxy_protocol_addr;
    proxy_read_timeout 15s;
    error_page 500 502 503 504 = @smartdns_error;
}
location = /dns/api/diagnostics {
    limit_req zone=smartdns_monitor burst=20 nodelay;
    proxy_pass http://127.0.0.1:18081/api/diagnostics$is_args$args;
    proxy_set_header X-SmartDNS-Client $proxy_protocol_addr;
    proxy_read_timeout 15s;
    error_page 500 502 503 504 = @smartdns_error;
}
EOF

  # в dry-run путь дашборда тоже под префиксом
  if $DRY_RUN; then
    sed -i "s|/var/www/smartdns|$(path /var/www/smartdns)|g" \
      "$(path /etc/nginx/snippets/gore-dns.conf)"
  fi
}

nginx_activate() {
  step "Проверка и запуск nginx"
  if ! $DRY_RUN; then
    ln -sf "/etc/nginx/sites-available/${DOMAIN}"        /etc/nginx/sites-enabled/
    ln -sf "/etc/nginx/sites-available/gore-80.conf"     /etc/nginx/sites-enabled/
    $WITH_VPN && [[ -n "$REALITY_DOMAIN" ]] && \
      ln -sf "/etc/nginx/sites-available/${REALITY_DOMAIN}" /etc/nginx/sites-enabled/
  fi

  if $DRY_RUN; then
    # линкуем собранные vhost'ы в префикс и проверяем настоящим nginx
    mkdir -p "$(path /etc/nginx/sites-enabled)"
    ln -sf "$(path "/etc/nginx/sites-available/${DOMAIN}")" "$(path /etc/nginx/sites-enabled/)$(basename "$DOMAIN")"
    ln -sf "$(path /etc/nginx/sites-available/gore-80.conf)" "$(path /etc/nginx/sites-enabled/gore-80.conf)"
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
      ln -sf "$(path "/etc/nginx/sites-available/${REALITY_DOMAIN}")" "$(path /etc/nginx/sites-enabled/)$(basename "$REALITY_DOMAIN")"
    fi
    info "dry-run: nginx -t -c $(path /etc/nginx/nginx.conf)"
    # -p: префикс дистрибутива, иначе относительные пути модулей из modules-enabled/ не найдутся
    local npx="/usr/share/nginx"
    [[ -d "$npx" ]] || npx="/etc/nginx"
    if nginx -t -c "$(path /etc/nginx/nginx.conf)" -p "$npx/" 2>&1 | tail -3; then
      ok "dry-run: собранный конфиг nginx валиден"
    else
      die "dry-run: nginx -t упал на сгенерированном конфиге"
    fi
    return 0
  fi

  if ! nginx -t 2>&1 | tail -3; then
    die "nginx -t упал — конфиг не применён"
  fi
  ok "nginx -t чисто"
  run systemctl enable nginx
  run systemctl restart nginx
  ok "nginx запущен"
}

configure_nginx() {
  nginx_prepare
  gen_vhost_80
  gen_vhost_panel
  $WITH_VPN && [[ -n "$REALITY_DOMAIN" ]] && gen_vhost_reality
  $WITH_DNS && [[ -n "$DNS_DOMAIN" ]] && gen_vhost_dns
  gen_snippets
  gen_stream_conf_file
  nginx_activate
}


# ============================================================================
# --- 06-fakesite
# ============================================================================
# --------------------------------------------------------------- фейк-сайт --
# Свои шаблоны, без внешних реп: сеть может быть недоступна, а сайт нужен всегда.
# Темы: corp, blog, docs, shop.

FAKE_THEMES=(corp blog docs shop)

install_fake_site() {
  step "Фейковый сайт"
  local theme="${FAKE_SITE:-auto}"
  if [[ "$theme" == "auto" ]]; then
    theme="${FAKE_THEMES[RANDOM % ${#FAKE_THEMES[@]}]}"
  fi

  local root
  root="$(path /var/www/html)"
  mkdir -p "$root"

  case "$theme" in
    corp) write_theme_corp "$root";;
    blog) write_theme_blog "$root";;
    docs) write_theme_docs "$root";;
    shop) write_theme_shop "$root";;
    *)    die "неизвестная тема фейк-сайта: $theme (есть: ${FAKE_THEMES[*]})";;
  esac

  write_common_404 "$root" "$theme"
  state_set FAKE_THEME "$theme"
  ok "тема фейк-сайта: $theme → /var/www/html"
}

write_common_404() {
  local root="$1" theme="$2"
  cat > "$root/404.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>404 — Not Found</title><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/style.css"></head>
<body><main class="wrap"><h1>404</h1>
<p>This page does not exist.</p><p><a href="/">Back to the main page</a></p></main></body></html>
EOF
}

write_theme_corp() {
  local root="$1"
  cat > "$root/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Nordwind Systems — infrastructure &amp; integration</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="Nordwind Systems designs and operates reliable infrastructure for data-heavy teams.">
<link rel="stylesheet" href="/style.css"><link rel="icon" href="/favicon.svg"></head>
<body>
<header class="hdr"><div class="wrap row">
  <a class="brand" href="/"><span class="mark"></span>Nordwind Systems</a>
  <nav><a href="#about">About</a><a href="#services">Services</a><a href="#contact">Contact</a></nav>
</div></header>
<main>
  <section class="hero wrap">
    <p class="kicker">Since 2016 · Tallinn</p>
    <h1>Infrastructure that keeps working when everything else stops.</h1>
    <p class="lead">We build, migrate and operate backend platforms: bare metal, private cloud, network edge.
       Small team, direct communication, no resellers in the chain.</p>
    <div class="cta"><a class="btn" href="#contact">Start a project</a><a class="btn ghost" href="#services">What we do</a></div>
  </section>
  <section id="services" class="wrap grid">
    <article><h3>Platform engineering</h3><p>Kubernetes, Terraform, CI/CD pipelines. From one node to a multi-region cluster.</p></article>
    <article><h3>Network &amp; edge</h3><p>BGP, anycast, TLS termination, load balancing and traffic analysis at the edge.</p></article>
    <article><h3>Storage &amp; data</h3><p>Postgres clusters, object storage, backup and disaster recovery plans.</p></article>
    <article><h3>24/7 operations</h3><p>Monitoring, on-call rotation, incident reviews. We take the pager.</p></article>
  </section>
  <section id="about" class="wrap split">
    <div><h2>About</h2>
      <p>Nordwind Systems is a nine-person engineering company. We have been running production workloads
         since 2016 and currently operate around 140 services for 30 clients across the EU and the UK.</p>
      <p>We do not subcontract infrastructure work. The people who design your platform are the people
         who answer the phone at 3 a.m.</p></div>
    <div><h2>Numbers</h2>
      <dl><div><dt>30</dt><dd>active clients</dd></div>
          <div><dt>140</dt><dd>services in production</dd></div>
          <div><dt>99.98%</dt><dd>average uptime 2025</dd></div></dl></div>
  </section>
  <section id="contact" class="wrap band">
    <h2>Talk to an engineer</h2>
    <p>Write to <a href="mailto:office@nordwind-systems.example">office@nordwind-systems.example</a> —
       we answer within one business day.</p>
  </section>
</main>
<footer class="ftr"><div class="wrap row"><span>© 2016–2026 Nordwind Systems OÜ</span>
<span>Reg. 12940518 · Tallinn, Estonia</span></div></footer>
</body></html>
EOF
  cat > "$root/style.css" <<'EOF'
:root{--bg:#0b0d10;--fg:#e8eaed;--mut:#98a0ab;--acc:#5aa9ff;--line:#1e2329}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:1040px;margin:0 auto;padding:0 24px}
.row{display:flex;align-items:center;justify-content:space-between;gap:24px;flex-wrap:wrap}
.hdr{border-bottom:1px solid var(--line);padding:18px 0}
.brand{display:flex;align-items:center;gap:10px;font-weight:600;font-size:17px;color:var(--fg)}
.mark{width:18px;height:18px;border-radius:5px;background:linear-gradient(135deg,var(--acc),#9b6bff)}
nav a{margin-left:22px;color:var(--mut);font-size:15px}nav a:hover{color:var(--fg)}
.hero{padding:96px 0 72px}
.kicker{color:var(--mut);font-size:13px;letter-spacing:.08em;text-transform:uppercase;margin:0 0 18px}
h1{font-size:clamp(30px,5vw,52px);line-height:1.12;margin:0 0 22px;font-weight:680;letter-spacing:-.02em}
.lead{color:var(--mut);font-size:18px;max-width:62ch;margin:0 0 32px}
.cta{display:flex;gap:14px;flex-wrap:wrap}
.btn{display:inline-block;padding:12px 22px;border-radius:10px;background:var(--acc);color:#06101f;font-weight:600}
.btn.ghost{background:transparent;color:var(--fg);border:1px solid var(--line)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:22px;padding:24px 0 72px}
.grid article{border:1px solid var(--line);border-radius:14px;padding:22px}
.grid h3{margin:0 0 10px;font-size:17px}
.grid p{margin:0;color:var(--mut);font-size:15px}
.split{display:grid;grid-template-columns:1.4fr 1fr;gap:48px;padding:48px 0 72px;border-top:1px solid var(--line)}
h2{font-size:22px;margin:0 0 14px}
.split p{color:var(--mut);margin:0 0 14px}
dl{margin:0}dl div{display:flex;justify-content:space-between;border-bottom:1px solid var(--line);padding:12px 0}
dt{font-size:26px;font-weight:680}dd{margin:0;color:var(--mut);font-size:14px;align-self:center}
.band{margin:0 auto 72px;padding:36px;border:1px solid var(--line);border-radius:16px;background:#0e1116}
.band p{color:var(--mut);margin:0}
.ftr{border-top:1px solid var(--line);padding:26px 0;color:var(--mut);font-size:14px}
@media(max-width:720px){.split{grid-template-columns:1fr;gap:28px}.hero{padding:64px 0 48px}}
EOF
  write_favicon_svg "$root"
}

write_theme_blog() {
  local root="$1"
  cat > "$root/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>margin notes — essays on software and craft</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="A small blog about long-lived software, boring technology and writing things down.">
<link rel="stylesheet" href="/style.css"><link rel="icon" href="/favicon.svg"></head>
<body>
<header class="site"><div class="wrap"><a href="/">margin notes</a>
<span class="sub">essays on software and craft</span></div></header>
<main class="wrap">
  <article class="post">
    <h1>Boring technology is a feature, not an apology</h1>
    <p class="meta">March 2026 · 9 min read</p>
    <p>Every migration I have regretted started with the sentence “this is much more modern”. Not because the
       new tool was bad — usually it was fine — but because we underestimated how much of our operational
       knowledge was stored in the shape of the old one.</p>
    <p>A boring stack is a stack whose failure modes you have already met. That is not a small thing.
       When the pager goes off at 2 a.m., the difference between “I have seen this before” and
       “I think this is the queue” is roughly an hour of downtime.</p>
    <h2>The real cost of novelty</h2>
    <p>Novelty is not paid at adoption. It is paid six months later, when your YAML is three versions behind
       and the one person who understood the upgrade path has changed jobs.</p>
    <blockquote>Choose new things deliberately, in one layer at a time, and write down why.</blockquote>
    <p>That is the whole trick. One new layer per year, with an ADR next to it, and a rollback that you have
       actually executed at least once on a staging machine.</p>
  </article>
  <article class="post">
    <h1>On writing runbooks nobody reads</h1>
    <p class="meta">February 2026 · 5 min read</p>
    <p>A runbook that starts with three pages of architecture diagrams is a runbook that will be opened at
       2 a.m. and abandoned at 2:01. Put the command first, the why second, the diagram last.</p>
  </article>
  <article class="post">
    <h1>Postgres is not a queue (but sometimes it is)</h1>
    <p class="meta">January 2026 · 12 min read</p>
    <p>Every argument on this topic is really an argument about throughput assumptions nobody wrote down.</p>
  </article>
</main>
<footer class="foot"><div class="wrap">© 2026 margin notes · RSS · <a href="mailto:hi@marginnotes.example">hi@marginnotes.example</a></div></footer>
</body></html>
EOF
  cat > "$root/style.css" <<'EOF'
:root{--bg:#fbfaf7;--fg:#1c1a17;--mut:#6b645c;--acc:#8a4b1f;--line:#e3ddd3}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.75 Georgia,"Iowan Old Style",serif}
.wrap{max-width:680px;margin:0 auto;padding:0 22px}
a{color:var(--acc)}
.site{padding:44px 0 8px}
.site a{font-size:20px;font-weight:600;color:var(--fg);text-decoration:none}
.site .sub{display:block;color:var(--mut);font-size:14px;font-style:italic;margin-top:2px}
main{padding:28px 0 60px}
.post{border-top:1px solid var(--line);padding:34px 0}
.post:first-child{border-top:0}
h1{font-size:clamp(25px,4vw,33px);line-height:1.25;margin:0 0 8px;letter-spacing:-.01em}
h2{font-size:21px;margin:30px 0 10px}
.meta{color:var(--mut);font-size:14px;margin:0 0 22px}
p{margin:0 0 18px}
blockquote{margin:22px 0;padding:2px 0 2px 20px;border-left:3px solid var(--line);color:var(--mut);font-style:italic}
.foot{border-top:1px solid var(--line);padding:26px 0 60px;color:var(--mut);font-size:14px}
EOF
  write_favicon_svg "$root"
}

write_theme_docs() {
  local root="$1"
  cat > "$root/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Relay API — documentation</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="Documentation for the Relay API: authentication, endpoints, limits.">
<link rel="stylesheet" href="/style.css"><link rel="icon" href="/favicon.svg"></head>
<body>
<aside class="side"><a class="logo" href="/">Relay API</a>
  <nav><a class="on" href="#intro">Introduction</a><a href="#auth">Authentication</a>
  <a href="#events">Events</a><a href="#limits">Rate limits</a><a href="#errors">Errors</a></nav>
  <p class="ver">v2.4 · updated 2026-03</p></aside>
<main>
  <h1 id="intro">Introduction</h1>
  <p>The Relay API accepts JSON over HTTPS and returns JSON. All endpoints live under
     <code>https://api.relay.example/v2</code>.</p>
  <pre><code>curl -H "Authorization: Bearer $RELAY_KEY" \
     https://api.relay.example/v2/events?limit=2</code></pre>
  <h2 id="auth">Authentication</h2>
  <p>Every request carries a bearer token. Tokens are scoped to one workspace and can be rotated
     without downtime — old tokens stay valid for 24 hours after rotation.</p>
  <h2 id="events">Events</h2>
  <p>Returns a cursor-paginated list of events. The response contains <code>data</code> and
     <code>next_cursor</code>.</p>
  <pre><code>{
  "data": [
    {"id": "evt_8f2", "type": "order.created", "ts": "2026-03-11T09:14:02Z"}
  ],
  "next_cursor": "cur_9a1"
}</code></pre>
  <h2 id="limits">Rate limits</h2>
  <p>600 requests per minute per token. Headers <code>X-RateLimit-Remaining</code> and
     <code>X-RateLimit-Reset</code> are set on every response.</p>
  <h2 id="errors">Errors</h2>
  <p>Errors use standard status codes and a body of the form <code>{"error": {"code": "...", "message": "..."}}</code>.</p>
</main>
</body></html>
EOF
  cat > "$root/style.css" <<'EOF'
:root{--bg:#ffffff;--fg:#14181d;--mut:#5b6673;--acc:#2563eb;--line:#e6e9ee;--code:#f5f7fa}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.7 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;display:flex}
a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
.side{width:250px;flex:0 0 250px;border-right:1px solid var(--line);padding:26px 20px;position:sticky;top:0;height:100vh}
.logo{font-weight:700;color:var(--fg);display:block;margin-bottom:22px}
.side nav a{display:block;padding:7px 10px;border-radius:7px;color:var(--mut);font-size:15px}
.side nav a.on{background:var(--code);color:var(--fg);font-weight:600}
.ver{color:var(--mut);font-size:12px;margin-top:26px}
main{flex:1;max-width:860px;padding:40px 36px 90px;min-width:0}
h1{font-size:32px;margin:0 0 18px;letter-spacing:-.02em}
h2{font-size:21px;margin:36px 0 10px}
p{margin:0 0 16px}
code{background:var(--code);padding:2px 5px;border-radius:5px;font-size:14px}
pre{background:var(--code);border:1px solid var(--line);border-radius:10px;padding:16px;overflow:auto}
pre code{background:0;padding:0}
@media(max-width:800px){body{display:block}.side{position:static;height:auto;width:auto;border-right:0;border-bottom:1px solid var(--line)}main{padding:26px 20px 60px}}
EOF
  write_favicon_svg "$root"
}

write_theme_shop() {
  local root="$1"
  cat > "$root/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Kavárna — specialty coffee, roasted weekly</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="Small-batch coffee roasted in Brno. Beans, filters, and a subscription that skips the middleman.">
<link rel="stylesheet" href="/style.css"><link rel="icon" href="/favicon.svg"></head>
<body>
<header class="top"><div class="wrap row"><a class="logo" href="/">Kavárna</a>
<nav><a href="#beans">Beans</a><a href="#gear">Gear</a><a href="#sub">Subscription</a></nav>
<a class="cart" href="#cart">Cart (0)</a></div></header>
<main>
  <section class="hero wrap">
    <div><p class="kicker">Roasted in Brno · every Tuesday</p>
      <h1>Coffee that tastes like the farm it came from.</h1>
      <p class="lead">We buy small lots directly from three farms and roast them light enough that you can
         still tell them apart. No blends, no dark-roast hiding.</p>
      <a class="btn" href="#beans">Shop the beans</a></div>
    <img alt="" class="shot" src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='520' height='420'><rect width='520' height='420' rx='18' fill='%23f1e6da'/><circle cx='260' cy='210' r='96' fill='%236b4227'/><circle cx='236' cy='188' r='26' fill='%238a5a37'/><path d='M260 120 q30 90 0 180' stroke='%23301c0f' stroke-width='9' fill='none'/><rect x='150' y='330' width='220' height='16' rx='8' fill='%23d8c3ae'/></svg>">
  </section>
  <section id="beans" class="wrap cards">
    <article><h3>Ethiopia · Guji</h3><p class="note">peach, jasmine, black tea</p><p class="price">€14 · 250 g</p></article>
    <article><h3>Colombia · Huila</h3><p class="note">red apple, caramel, cocoa nib</p><p class="price">€13 · 250 g</p></article>
    <article><h3>Kenya · Nyeri</h3><p class="note">blackcurrant, tomato leaf, lime</p><p class="price">€16 · 250 g</p></article>
  </section>
  <section id="gear" class="wrap split">
    <div><h2>Gear we actually use</h2>
      <p>Hand grinder, a scale with a timer, and a dripper. That is the whole list. Everything else is
         decoration for your kitchen counter.</p></div>
    <div><h2>Subscription</h2>
      <p>Two bags a month, roasted the day before we ship, paused or cancelled in one click.
         €24 including shipping in the EU.</p>
      <a class="btn" href="#sub">Start a subscription</a></div>
  </section>
</main>
<footer class="foot"><div class="wrap row"><span>© 2026 Kavárna s.r.o.</span><span>Brno, Czechia · hello@kavarna.example</span></div></footer>
</body></html>
EOF
  cat > "$root/style.css" <<'EOF'
:root{--bg:#fffdfa;--fg:#231b14;--mut:#7a6a5b;--acc:#6b4227;--line:#eee2d5}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.7 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:inherit;text-decoration:none}
.wrap{max-width:1080px;margin:0 auto;padding:0 22px}
.row{display:flex;align-items:center;justify-content:space-between;gap:20px;flex-wrap:wrap}
.top{border-bottom:1px solid var(--line);padding:18px 0}
.logo{font-weight:700;font-size:19px;letter-spacing:.02em}
nav a{margin-right:20px;color:var(--mut);font-size:15px}
.cart{font-size:14px;border:1px solid var(--line);padding:8px 14px;border-radius:999px}
.hero{display:grid;grid-template-columns:1.1fr .9fr;gap:40px;align-items:center;padding:64px 0}
.kicker{color:var(--mut);font-size:13px;text-transform:uppercase;letter-spacing:.08em;margin:0 0 12px}
h1{font-size:clamp(28px,4.4vw,46px);line-height:1.12;margin:0 0 18px;letter-spacing:-.02em}
.lead{color:var(--mut);margin:0 0 26px;max-width:52ch}
.btn{display:inline-block;background:var(--acc);color:#fff;padding:12px 22px;border-radius:10px;font-weight:600}
.shot{width:100%;height:auto;border-radius:18px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:20px;padding:10px 0 60px}
.cards article{border:1px solid var(--line);border-radius:14px;padding:22px;background:#fff}
.cards h3{margin:0 0 6px;font-size:17px}
.note{color:var(--mut);font-size:14px;margin:0 0 14px}
.price{margin:0;font-weight:600}
.split{display:grid;grid-template-columns:1fr 1fr;gap:40px;padding:40px 22px 80px;border-top:1px solid var(--line)}
h2{font-size:22px;margin:0 0 12px}
.split p{color:var(--mut);margin:0 0 16px}
.foot{border-top:1px solid var(--line);padding:24px 0;color:var(--mut);font-size:14px}
@media(max-width:780px){.hero,.split{grid-template-columns:1fr;gap:26px}}
EOF
  write_favicon_svg "$root"
}

write_favicon_svg() {
  local root="$1"
  cat > "$root/favicon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#2b6cb0"/><path d="M18 44V20h8l12 15V20h8v24h-8L26 29v15z" fill="#fff"/></svg>
EOF
}


# ============================================================================
# --- 07-smartdns
# ============================================================================
# --------------------------------------------------------------- Smart DNS ---
ASSET_DIR="/opt/gore-assets"

assets_fetch() {
  step "Наши настройки Smart DNS"
  # в dry-run активы тоже складываем под префикс
  ASSET_DIR="$(path /opt/gore-assets)"
  local local_assets="${GORE_ASSETS:-}"

  if [[ -n "$local_assets" && -e "$local_assets" ]]; then
    if [[ -d "$local_assets" ]]; then
      rm -rf "$ASSET_DIR"; cp -a "$local_assets" "$ASSET_DIR"
    else
      rm -rf "$ASSET_DIR"; mkdir -p "$ASSET_DIR"
      tar -xzf "$local_assets" -C "$ASSET_DIR"
    fi
    ok "активы из локального пути: $local_assets"
  elif [[ -d "${ROOT_DIR:-/nonexistent}/assets" ]]; then
    rm -rf "$ASSET_DIR"; cp -a "$ROOT_DIR/assets" "$ASSET_DIR"
    ok "активы из каталога установщика"
  else
    info "качаю активы с $RAW_BASE/assets.tar.gz"
    local tmp="/tmp/gore-assets.tar.gz"
    if ! curl -fsSL --max-time 120 -o "$tmp" "$RAW_BASE/assets.tar.gz"; then
      die "не смог скачать активы. Передай каталог/assets.tar.gz через GORE_ASSETS=/путь"
    fi
    rm -rf "$ASSET_DIR"; mkdir -p "$ASSET_DIR"
    tar -xzf "$tmp" -C "$ASSET_DIR"
    ok "активы скачаны"
  fi

  # в архиве может быть обёртка assets/ — учитываем оба варианта
  if [[ -f "$ASSET_DIR/smartdns/etc/policy.json" ]]; then
    :
  elif [[ -f "$ASSET_DIR/assets/smartdns/etc/policy.json" ]]; then
    ASSET_DIR="$ASSET_DIR/assets"
  else
    die "в активах нет smartdns/etc/policy.json (смотрел $ASSET_DIR)"
  fi
}

install_adguard() {
  step "AdGuardHome"
  local bin="/opt/smartdns/AdGuardHome/AdGuardHome"

  if $DRY_RUN; then
    info "dry-run: AdGuardHome не качаю"
    return 0
  fi

  if [[ -x "$bin" ]]; then
    ok "уже установлен: $($bin --version 2>&1 | head -1)"
    return 0
  fi

  local arch url tmp=/tmp/agh.tar.gz
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64;;
    aarch64|arm64) arch=arm64;;
    armv7l) arch=armv7;;
    *) die "неизвестная архитектура: $(uname -m)";;
  esac

  local src="${ADGUARD_SRC:-auto}"
  if [[ "$src" == "auto" ]]; then
    url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${arch}.tar.gz"
  elif [[ "$src" =~ ^https?:// ]]; then
    url="$src"
  else
    url=""
    tmp="$src"
  fi

  if [[ -n "$url" ]]; then
    info "качаю AdGuardHome ($arch)"
    curl -fsSL --max-time 300 -o "$tmp" "$url" || die "не смог скачать AdGuardHome: $url"
  fi

  mkdir -p /opt/smartdns
  tar -xzf "$tmp" -C /opt/smartdns
  # в архиве каталог AdGuardHome/
  [[ -x "$bin" ]] || die "в архиве нет AdGuardHome/AdGuardHome"
  ok "AdGuardHome распакован"
}

gen_policy() {
  # policy.json — это наш список доменов, которые идут через релей.
  local src="$ASSET_DIR/smartdns/etc/policy.json" dst
  dst="$(path /etc/smartdns/policy.json)"
  ensure_dir /etc/smartdns
  cp -f "$src" "$dst"
  local n_exact n_roots
  n_exact=$(python3 -c "import json;print(len(json.load(open('$dst')).get('exact',[])))")
  n_roots=$(python3 -c "import json;print(len(json.load(open('$dst')).get('roots',[])))")
  ok "policy.json: $n_exact точных + $n_roots семейств"
}

gen_agh_config() {
  step "Конфиг AdGuardHome"
  local tpl="$ASSET_DIR/smartdns/etc/AdGuardHome.yaml"
  local out; out="$(path /etc/smartdns/AdGuardHome.yaml)"
  local ip6="${IP6:-}"

  python3 - "$tpl" "$out" "$IP4" "$DNS_DOMAIN" "$ip6" "$(path /etc/letsencrypt/live/${DNS_DOMAIN})" <<'PY'
import re, sys
tpl, out, ip4, domain, ip6, certdir = sys.argv[1:7]
lines = open(tpl, encoding='utf-8').read().split('\n')

# --- rewrites из policy.json ---
import json, os
pol_path = os.path.join(os.path.dirname(out), 'policy.json')
pol = json.load(open(pol_path))
rw = []
for h in pol.get('exact', []):
    rw.append((h, ip4))
for r in pol.get('roots', []):
    rw.append((r, ip4))
    rw.append(('*.' + r, ip4))

def indent_of(line):
    return len(line) - len(line.lstrip(' '))

res = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    # bind_hosts: заменить список на наш IP
    if stripped == 'bind_hosts:':
        res.append(line)
        base = indent_of(line)
        i += 1
        new = [' ' * (base + 2) + '-' + ' ' + ip4]
        if ip6:
            new.append(' ' * (base + 2) + '-' + ' ' + ip6)
        new.append(' ' * (base + 2) + '- 127.0.0.1')
        res.extend(new)
        while i < len(lines) and (lines[i].strip() == '' or
                                  indent_of(lines[i]) > base and lines[i].strip().startswith('-')):
            i += 1
        continue

    # rewrites: сгенерировать заново
    if stripped == 'rewrites:':
        res.append(line)
        base = indent_of(line)
        i += 1
        while i < len(lines) and (lines[i].strip() == '' or indent_of(lines[i]) > base):
            i += 1
        pad = ' ' * (base + 2)
        for host, answer in rw:
            q = '"' + host + '"' if host.startswith('*.') else host
            res.append(f'{pad}- domain: {q}')
            res.append(f'{pad}  answer: {answer}')
            res.append(f'{pad}  enabled: true')
        continue

    # tls: server_name и пути к сертификатам
    if stripped.startswith('server_name:') and 'manima.ru' in line:
        res.append(re.sub(r'server_name:.*', 'server_name: ' + domain, line))
        i += 1
        continue
    if stripped.startswith('certificate_path:') or stripped.startswith('private_key_path:'):
        key = stripped.split(':')[0]
        val = certdir + ('/fullchain.pem' if key == 'certificate_path' else '/privkey.pem')
        res.append(' ' * indent_of(line) + key + ': "' + val + '"')
        i += 1
        continue

    res.append(line)
    i += 1

text = '\n'.join(res)
# страховка: если путей к сертификатам в шаблоне не было — дописать в блок tls
if 'certificate_path:' not in text:
    text = text.replace('  strict_sni_check:',
                        '  certificate_path: "' + certdir + '/fullchain.pem"\n'
                        '  private_key_path: "' + certdir + '/privkey.pem"\n'
                        '  strict_sni_check:', 1)
open(out, 'w', encoding='utf-8').write(text)
print(f"   rewrites: {len(rw)}")
PY

  chmod 600 "$out"
  ok "AdGuardHome.yaml собран (rewrites на $IP4)"
}

install_dns_code() {
  step "Релей и телеметрия"
  ensure_dir /opt/smartdns
  cp -f "$ASSET_DIR/smartdns/relay.py"    "$(path /opt/smartdns/relay.py)"
  cp -f "$ASSET_DIR/smartdns/telemetry.py" "$(path /opt/smartdns/telemetry.py)"
  rm -rf "$(path /opt/smartdns/__pycache__)"

  # «свои» адреса в коде — чтобы релей не ходил сам в себя
  local ip6="${IP6:-$IP4}"
  sed -i "s/185\.249\.155\.218/${IP4}/g; s/77\.239\.102\.114/${IP4}/g; s/2a01:ecc0:200:f5e::2/${ip6}/g" \
    "$(path /opt/smartdns/relay.py)" "$(path /opt/smartdns/telemetry.py)"
  sed -i -E "s/'([0-9a-fA-F:.]+)',\s*'\1'/'\\1'/g" "$(path /opt/smartdns/relay.py)"

  # брендинг дашборда и точка входа телеметрии
  sed -i "s|https://dns\.manima\.ru/dns-query|https://${DNS_DOMAIN}/dns-query|g; s|'manima\.ru'|'${DNS_DOMAIN}'|g; s|manima\.ru|${DNS_DOMAIN}|g" \
    "$(path /opt/smartdns/telemetry.py)"

  chmod 755 "$(path /opt/smartdns/relay.py)" "$(path /opt/smartdns/telemetry.py)"
  ok "relay.py и telemetry.py на месте"
}

install_dashboard() {
  step "Дашборд DNS"
  local www; www="$(path /var/www/smartdns)"
  ensure_dir /var/www/smartdns
  cp -a "$ASSET_DIR/smartdns/www/." "$www/"

  # подставить наш домен и IP вместо manima.ru
  local f
  for f in index.html app.js guides.js style.css logo-map.json manima-doh.mobileconfig; do
    [[ -f "$www/$f" ]] || continue
    sed -i "s/185\.249\.155\.218/${IP4}/g; s/dns\.manima\.ru/${DNS_DOMAIN}/g; s/manima\.ru/${DNS_DOMAIN}/g" "$www/$f"
  done
  [[ -f "$www/manima-doh.mobileconfig" ]] && mv "$www/manima-doh.mobileconfig" "$www/${DNS_DOMAIN}-doh.mobileconfig"
  sed -i "s|/dns/manima-doh\.mobileconfig|/dns/${DNS_DOMAIN}-doh.mobileconfig|g" \
    "$(path /etc/nginx/snippets/gore-dns.conf)" 2>/dev/null || true

  cp -f "$ASSET_DIR/smartdns/etc/catalog.json" "$(path /var/www/smartdns/catalog.json)"
  ok "статика дашборда: /var/www/smartdns"
}

install_dns_units() {
  step "Службы DNS"
  write_file /etc/systemd/system/smartdns-resolver.service 644 <<'EOF'
[Unit]
Description=Smart DNS resolver (AdGuardHome) with DoH and DoT
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/opt/smartdns/AdGuardHome/AdGuardHome -c /etc/smartdns/AdGuardHome.yaml -w /var/lib/smartdns --no-check-update
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/etc/smartdns /var/lib/smartdns
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

  write_file /etc/systemd/system/smartdns-relay.service 644 <<'EOF'
[Unit]
Description=Allowlisted transparent TLS relay for Smart DNS
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/smartdns/relay.py
Restart=on-failure
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

  write_file /etc/systemd/system/smartdns-telemetry.service 644 <<'EOF'
[Unit]
Description=Smart DNS live telemetry
After=smartdns-resolver.service

[Service]
ExecStart=/usr/bin/python3 /opt/smartdns/telemetry.py
DynamicUser=yes
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  run systemctl daemon-reload
  run systemctl enable smartdns-resolver smartdns-relay smartdns-telemetry
  ok "юниты включены"
}

start_dns_services() {
  step "Запуск DNS"
  run systemctl restart smartdns-resolver
  sleep 2
  run systemctl restart smartdns-relay smartdns-telemetry
  sleep 1
  if ! $DRY_RUN; then
    if dig +short "@127.0.0.1" chatgpt.com 2>/dev/null | grep -qx "$IP4"; then
      ok "rewrite работает: chatgpt.com → $IP4"
    else
      warn "rewrite не подтвердился, проверь: journalctl -u smartdns-resolver -n 50"
    fi
  fi
}

setup_smartdns() {
  assets_fetch
  install_adguard
  gen_policy
  gen_agh_config
  install_dns_code
  install_dashboard
  install_dns_units
}


# ============================================================================
# --- 08-vpn
# ============================================================================
# ------------------------------------------------------------------- VPN -----
# Транспорт по состоянию на 2026: Reality закрывает TLS-отпечаток и активное
# зондирование, XHTTP — поведение соединения после рукопожатия. Оба ставим,
# панель не ставим: это самая заметная снаружи часть.

REALITY_PORT_DEFAULT=8443
XHTTP_PORT_DEFAULT=2096
WS_PORT_LOCAL=10000
REALITY_DEST_DEFAULT="www.microsoft.com:443"

install_xray() {
  step "Xray-core"
  if [[ -x /usr/local/bin/xray ]]; then
    ok "уже установлен: $(/usr/local/bin/xray version 2>/dev/null | head -1)"
    return 0
  fi
  info "ставлю официальным скриптом XTLS/Xray-install"
  if ! $DRY_RUN; then
    curl -fsSL --max-time 60 -o /tmp/xray-install.sh \
      "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
      || die "не смог скачать установщик Xray"
    bash /tmp/xray-install.sh install >/dev/null 2>&1 || die "установщик Xray упал"
    rm -f /tmp/xray-install.sh
  fi
  ok "xray установлен"
}

gen_xray_config() {
  step "Конфиг Xray (Reality + XHTTP)"

  local uuid_count="${USERS:-3}"
  local reality_port="${REALITY_PORT:-$REALITY_PORT_DEFAULT}"
  local xhttp_port="${XHTTP_PORT:-$XHTTP_PORT_DEFAULT}"
  local dest="${REALITY_DEST:-$REALITY_DEST_DEFAULT}"

  # ключи Reality
  local priv pub shortid
  if $DRY_RUN; then
    priv="private-key-placeholder"
    pub="public-key-placeholder"
  else
    local keys
    keys=$(/usr/local/bin/xray x25519 2>/dev/null | tr -d '\r')
    priv=$(awk -F': *' '/[Pp]rivate/{print $2; exit}' <<<"$keys")
    pub=$(awk -F': *' '/[Pp]ublic/{print $2; exit}' <<<"$keys")
    [[ -n "$priv" && -n "$pub" ]] || die "не смог сгенерировать ключи Reality"
  fi
  shortid=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

  # UUID клиентов
  local uuids=()
  local i
  for (( i=0; i<uuid_count; i++ )); do
    if $DRY_RUN; then uuids+=("00000000-0000-4000-8000-00000000000$i")
    else uuids+=("$(cat /proc/sys/kernel/random/uuid)"); fi
  done

  local ws_path
  ws_path="/$(rand_str 12)"

  local out; out="$(path /usr/local/etc/xray/config.json)"
  ensure_dir /usr/local/etc/xray
  local rules_json; rules_json="$(xray_routing_rules)"

  python3 - "$out" "$uuids" "$priv" "$dest" "$reality_port" "$xhttp_port" "$WS_PORT_LOCAL" "$ws_path" "$shortid" "$rules_json" <<'PY'
import json, sys
out, uuids, privkey, dest, rport, xport, wsport, wspath, shortid, rules = sys.argv[1:11]
uuids = uuids.split()
host = dest.split(':')[0]

clients_vision = [{"id": u, "flow": "xtls-rprx-vision", "email": f"user{i+1}"} for i, u in enumerate(uuids)]
clients_plain  = [{"id": u, "email": f"user{i+1}-xhttp"} for i, u in enumerate(uuids)]

def reality(flow=False):
    return {
        "show": False,
        "dest": dest,
        "xver": 0,
        "serverNames": [host],
        "privateKey": privkey,
        "shortIds": [shortid],
    }

cfg = {
    "log": {"loglevel": "warning"},
    "dns": {
        "servers": ["1.1.1.1", "8.8.8.8"],
        "queryStrategy": "UseIPv4",
    },
    "inbounds": [
        {
            "tag": "vless-reality",
            "listen": "0.0.0.0",
            "port": int(rport),
            "protocol": "vless",
            "settings": {"clients": clients_vision, "decryption": "none"},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": reality(True),
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        },
        {
            "tag": "vless-xhttp-reality",
            "listen": "0.0.0.0",
            "port": int(xport),
            "protocol": "vless",
            "settings": {"clients": clients_plain, "decryption": "none"},
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": reality(False),
                "xhttpSettings": {
                    "path": "/api/v2/sync",
                    "mode": "auto",
                    "extra": {"xPaddingBytes": "100-1000"},
                },
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        },
        {
            "tag": "vless-ws-cdn",
            "listen": "127.0.0.1",
            "port": int(wsport),
            "protocol": "vless",
            "settings": {"clients": clients_plain, "decryption": "none"},
            "streamSettings": {
                "network": "ws",
                "security": "none",
                "wsSettings": {"path": wspath, "host": ""},
            },
        },
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
        {"tag": "block", "protocol": "blackhole", "settings": {}},
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": json.loads(rules),
    },
}
open(out, 'w').write(json.dumps(cfg, indent=2, ensure_ascii=False))
PY

  chmod 600 "$out"

  REALITY_PORT="$reality_port"
  XHTTP_PORT="$xhttp_port"
  WS_PATH="$ws_path"
  REALITY_DEST="$dest"
  state_set REALITY_PORT "$reality_port"
  state_set XHTTP_PORT "$xhttp_port"
  state_set WS_PATH "$ws_path"
  state_set REALITY_PUB "$pub"
  state_set REALITY_SHORTID "$shortid"
  state_set REALITY_DEST "$dest"

  # ссылки для клиентов
  write_links "$uuids" "$pub" "$shortid" "$dest" "$reality_port" "$xhttp_port" "$ws_path"
  ok "Reality :$reality_port (Vision) · XHTTP :$xhttp_port · WS за nginx"
}

write_links() {
  local uuids=("$1") # приходит строкой
  local pub="$2" shortid="$3" dest="$4" rport="$5" xport="$6" wspath="$7"
  local host="${dest%%:*}"
  local f_links f_json
  f_links="$(path /root/gore-links.txt)"
  f_json="$(path /root/gore-clients.json)"

  if $DRY_RUN; then info "dry-run: ссылки клиентов в $f_links"; return 0; fi

  : > "$f_links"
  local json="[]" n=0 u
  for u in "${uuids[@]}"; do
    n=$((n+1))
    {
      echo "# клиент $n — Reality (XTLS-Vision)"
      echo "vless://${u}@${IP4}:${rport}?encryption=none&security=reality&sni=${host}&fp=chrome&pbk=${pub}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#gore-reality-$n"
      echo
      echo "# клиент $n — XHTTP + Reality (для сетей, где душат TCP-TLS)"
      echo "vless://${u}@${IP4}:${xport}?encryption=none&security=reality&sni=${host}&fp=chrome&pbk=${pub}&sid=${shortid}&type=xhttp&path=%2Fapi%2Fv2%2Fsync&mode=auto&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#gore-xhttp-$n"
      echo
      echo "# клиент $n — WS за nginx/Cloudflare (:443)"
      echo "vless://${u}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&path=$(printf '%s' "$wspath" | sed 's|/|%2F|g')&host=${DOMAIN}#gore-ws-$n"
      echo
    } >> "$f_links"
    json=$(python3 -c "
import json,sys
a=json.loads('''$json''')
a.append({'n':$n,'uuid':'$u','reality_port':$rport,'xhttp_port':$xport,'ws_path':'$wspath','sni':'$host','pbk':'$pub','sid':'$shortid'})
print(json.dumps(a))
")
  done
  printf '%s' "$json" > "$f_json"
  chmod 600 "$f_links" "$f_json"
  ok "ссылки: /root/gore-links.txt"
}

start_vpn() {
  step "Запуск Xray"
  if ! $DRY_RUN; then
    /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 \
      || die "конфиг Xray не проходит проверку: xray run -test"
    ok "конфиг Xray проверен"
  fi
  run systemctl enable xray
  run systemctl restart xray
  ok "xray запущен"
}

setup_vpn() {
  install_xray
  gen_xray_config
  start_vpn
}


# ============================================================================
# --- 08b-panel
# ============================================================================
# ------------------------------------------------------------- панель 3x-ui --
# Панель ставим официальным установщиком, а inbound'ы создаём прямо в её БД:
# это не зависит от версии HTTP-API и переживает обновления 3x-ui.
XUI_DB="/etc/x-ui/x-ui.db"
XUI_BIN="/usr/local/bin/xray"

install_xui() {
  step "Панель 3x-ui"
  if [[ -f /usr/local/x-ui/x-ui && -f "$XUI_DB" ]]; then
    ok "3x-ui уже установлен"
    return 0
  fi

  if $DRY_RUN; then info "dry-run: ставлю 3x-ui"; else
    local log=/tmp/xui-install.log
    curl -fsSL --max-time 90 -o /tmp/xui-install.sh \
      "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" \
      || die "не смог скачать установщик 3x-ui"
    # на все вопросы отвечаем «нет»: порт/путь/логин зададим сами через БД
    printf 'n\nn\n' | bash /tmp/xui-install.sh >"$log" 2>&1 || die "установщик 3x-ui упал, смотри $log"

    XUI_USER=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | awk -F': *' '/[Uu]sername/{print $2; exit}')
    XUI_PASS=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | awk -F': *' '/[Pp]assword/{print $2; exit}')
    rm -f /tmp/xui-install.sh
    ok "3x-ui установлен"
  fi
}

certs_for_xui() {
  # панель отдаёт только localhost, наружу — через nginx, поэтому сертификаты не нужны
  :
}

xui_configure() {
  step "Настройка панели"
  if $DRY_RUN; then info "dry-run: настройка БД 3x-ui"; return 0; fi

  [[ -f "$XUI_DB" ]] || die "нет $XUI_DB — установка 3x-ui не удалась"

  local reality_priv="" reality_pub="" shortid
  shortid=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

  # ключи Reality берём тем xray, который пришёл вместе с 3x-ui
  local xraybin=""
  for xraybin in /usr/local/x-ui/bin/xray-linux-* /usr/local/bin/xray; do
    [[ -x "$xraybin" ]] && break
  done
  if [[ -x "$xraybin" ]]; then
    local keys
    keys=$("$xraybin" x25519 2>/dev/null | tr -d '\r')
    reality_priv=$(awk -F': *' '/[Pp]rivate/{print $2; exit}' <<<"$keys")
    reality_pub=$(awk -F': *' '/[Pp]ublic/{print $2; exit}' <<<"$keys")
  fi
  [[ -n "$reality_priv" ]] || die "не смог сгенерировать ключи Reality"

  python3 - "$XUI_DB" "$PANEL_PORT" "/$PANEL_PATH" "$SUB_PORT" "/$SUB_PATH" "/$JSON_PATH" \
      "$reality_priv" "$shortid" "${USERS:-3}" "${REALITY_PORT:-8443}" \
      "${XHTTP_PORT:-2096}" "${WS_PORT_LOCAL:-10000}" "${WS_PATH:-}" \
      "${DOMAIN:-}" "${REALITY_DEST:-www.microsoft.com:443}" <<'PY'
import json, sqlite3, sys, uuid, time

(db, panel_port, panel_path, sub_port, sub_path, json_path,
 priv, shortid, users, rport, xport, wsport, wspath, domain, dest) = sys.argv[1:16]
users = int(users); rport = int(rport); xport = int(xport); wsport = int(wsport)
host = dest.split(':')[0]
con = sqlite3.connect(db)
cur = con.cursor()

def set_setting(key, value):
    cur.execute('SELECT COUNT(*) FROM settings WHERE key=?', (key,))
    if cur.fetchone()[0]:
        cur.execute('UPDATE settings SET value=? WHERE key=?', (str(value), key))
    else:
        cur.execute('INSERT INTO settings (key, value) VALUES (?, ?)', (key, str(value)))

for k, v in [
    ('webPort', panel_port), ('webBasePath', panel_path), ('webListen', '127.0.0.1'),
    ('subPort', sub_port), ('subPath', sub_path), ('subEnable', 'true'),
    ('subJsonPath', json_path),
    ('subURI', f'https://{domain}/{sub_path.lstrip("/")}/'),
    ('subJsonURI', f'https://{domain}/{json_path.lstrip("/")}'),
    ('subClashEnable', 'false'), ('subEnableRouting', 'false'),
    ('webDomain', ''), ('webCertFile', ''), ('webKeyFile', ''),
]:
    set_setting(k, v)

uuids = [str(uuid.uuid4()) for _ in range(users)]
now = int(time.time() * 1000)

def client(u, suffix=''):
    return {
        "id": u, "flow": suffix, "email": f"user{u[:8]}",
        "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True,
        "tgId": "", "subId": u[:16], "reset": 0,
    }

def reality_stream():
    return {
        "network": "tcp", "security": "reality",
        "realitySettings": {
            "show": False, "xver": 0, "dest": dest, "serverNames": [host],
            "privateKey": priv, "shortIds": [shortid], "maxTimeDiff": 0,
        },
        "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}},
    }

sniff = {"enabled": True, "destOverride": ["http", "tls", "quic"],
         "metadataOnly": False, "routeOnly": False}

def add_inbound(remark, port, protocol, settings, stream, tag):
    cols = [r[1] for r in cur.execute('PRAGMA table_info(inbounds)').fetchall()]
    row = {
        "user_id": 1, "up": 0, "down": 0, "total": 0,
        "remark": remark, "enable": 1, "expiry_time": 0,
        "listen": "", "port": port, "protocol": protocol,
        "settings": json.dumps(settings, ensure_ascii=False),
        "stream_settings": json.dumps(stream, ensure_ascii=False),
        "tag": tag, "sniffing": json.dumps(sniff, ensure_ascii=False),
    }
    row = {k: v for k, v in row.items() if k in cols}
    keys = ",".join(f'"{k}"' for k in row)
    qs = ",".join("?" * len(row))
    cur.execute(f'INSERT INTO inbounds ({keys}) VALUES ({qs})', list(row.values()))
    return cur.lastrowid

# 1. VLESS + Reality (XTLS-Vision)
iid = add_inbound("gore-reality", rport, "vless",
                  {"clients": [client(u, "xtls-rprx-vision") for u in uuids],
                   "decryption": "none", "fallbacks": []},
                  reality_stream(), f"inbound-{rport}")

# 2. VLESS + XHTTP + Reality
xhttp_stream = reality_stream()
xhttp_stream["network"] = "xhttp"
xhttp_stream.pop("tcpSettings", None)
xhttp_stream["xhttpSettings"] = {
    "path": "/api/v2/sync", "host": "", "headers": {},
    "mode": "auto", "extra": {"xPaddingBytes": "100-1000"},
}
add_inbound("gore-xhttp", xport, "vless",
            {"clients": [client(u) for u in uuids], "decryption": "none", "fallbacks": []},
            xhttp_stream, f"inbound-{xport}")

# 3. VLESS + WS за nginx
ws_stream = {
    "network": "ws", "security": "none",
    "wsSettings": {"acceptProxyProtocol": False, "path": wspath, "host": domain, "headers": {}},
}
add_inbound("gore-ws", wsport, "vless",
            {"clients": [client(u) for u in uuids], "decryption": "none", "fallbacks": []},
            ws_stream, f"inbound-{wsport}")

# трафик-записи для клиентов (3x-ui ждёт их для статистики)
for u in uuids:
    cur.execute('INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) '
                'VALUES (?, 1, ?, 0, 0, 0, 0, 0)', (iid, f"user{u[:8]}"))

con.commit()
print(f"   inbounds: reality:{rport}, xhttp:{xport}, ws:{wsport}")
print(f"   клиентов: {len(uuids)}")
print("UUID:" + ",".join(uuids))
PY

  real_uuids=$(python3 - "$XUI_DB" <<'PY2'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
row = con.execute("SELECT settings FROM inbounds WHERE tag LIKE 'inbound-%' ORDER BY id LIMIT 1").fetchone()
print(",".join(c["id"] for c in json.loads(row[0])["clients"]))
PY2
)

  state_set PANEL_USER "${XUI_USER:-admin}"
  state_set PANEL_PASS "${XUI_PASS:-}"
  state_set REALITY_PUB "$reality_pub"
  state_set REALITY_SHORTID "$shortid"
  state_set REALITY_DEST "${REALITY_DEST:-www.microsoft.com:443}"
  ok "панель настроена: /$PANEL_PATH → 127.0.0.1:$PANEL_PORT"

  write_links "$real_uuids" "$reality_pub" "$shortid" \
              "${REALITY_DEST:-www.microsoft.com:443}" \
              "${REALITY_PORT:-8443}" "${XHTTP_PORT:-2096}" "${WS_PATH:-}"
}

setup_panel() {
  install_xui
  certs_for_xui
  xui_configure
  run systemctl restart x-ui
  $DRY_RUN || sleep 2
  if ! $DRY_RUN; then
    if systemctl is-active --quiet x-ui; then ok "x-ui запущен"
    else warn "x-ui не поднялся: journalctl -u x-ui -n 50"; fi
  fi
}


# ============================================================================
# --- 08c-region
# ============================================================================
# ------------------------------------------------------- российский регион ---
# Что здесь «для РФ»:
#   * geoip/geosite, чтобы .ru-трафик не гнать через заграницу (иначе банк/госуслуги ломаются);
#   * готовые клиентские профили с split-tunnel: RU → напрямую, остальное → туннель;
#   * серверный routing для нашего xray-режима;
#   * DNS: локальный резолвер для своих доменов, публичный для остального.

GEODATA_DIR_LOCAL="/usr/share/xray"
GEODATA_URL_IP="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEODATA_URL_SITE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

install_geodata() {
  [[ "${REGION:-ru}" == "ru" ]] || return 0
  step "Geodata для РФ"
  local dirs=("$GEODATA_DIR_LOCAL" "/usr/local/share/xray" "/usr/local/x-ui/bin" "/usr/local/etc/xray")
  local d ok_any=false
  if $DRY_RUN; then info "dry-run: скачивание geoip.dat/geosite.dat"; return 0; fi

  local tmp_ip=/tmp/geoip.dat tmp_site=/tmp/geosite.dat
  if curl -fsSL --max-time 180 -o "$tmp_ip" "$GEODATA_URL_IP" 2>/dev/null; then
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      cp -f "$tmp_ip" "$d/geoip.dat" 2>/dev/null || true
    done
    ok "geoip.dat ($(du -h "$tmp_ip" | cut -f1))"
  else
    warn "geoip.dat не скачался — routing по geoip:ru работать не будет"
  fi
  if curl -fsSL --max-time 180 -o "$tmp_site" "$GEODATA_URL_SITE" 2>/dev/null; then
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      cp -f "$tmp_site" "$d/geosite.dat" 2>/dev/null || true
    done
    ok "geosite.dat ($(du -h "$tmp_site" | cut -f1))"
  else
    warn "geosite.dat не скачался"
  fi
  rm -f "$tmp_ip" "$tmp_site"
}

# серверный routing: RU-адреса отдаём напрямую, приватные — в блок
xray_routing_rules() {
  if [[ "${REGION:-ru}" != "ru" ]]; then
    printf '%s' '[]'
    return 0
  fi
  cat <<'JSON'
[
  {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
  {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
  {"type": "field", "ip": ["geoip:ru"], "outboundTag": "direct"},
  {"type": "field", "domain": ["geosite:category-ru", "geosite:yandex", "geosite:mailru",
                               "geosite:vk", "geosite:gosuslugi", "geosite:tinkoff"],
                     "outboundTag": "direct"}
]
JSON
}

# Клиентские профили: sing-box и Clash с разделением RU/не-RU.
write_client_profiles() {
  [[ "${REGION:-ru}" == "ru" ]] || return 0
  $WITH_VPN || return 0
  step "Клиентские профили (split-tunnel для РФ)"

  local dir; dir="$(path /root/gore-clients)"
  ensure_dir /root/gore-clients
  local links; links="$(path /root/gore-links.txt)"
  if $DRY_RUN; then info "dry-run: клиентские профили в $dir"; return 0; fi
  [[ -f "$links" ]] || { warn "нет ссылок клиентов, пропускаю профили"; return 0; }

  # берём параметры первого клиента из ссылки reality
  local line uuid host_port
  line=$(grep -m1 '^vless://' "$links")
  uuid=$(sed -E 's|^vless://([^@]+)@.*|\1|' <<<"$line")
  local server_port; server_port=$(sed -E 's|^vless://[^@]+@([^?]+)\?.*|\1|' <<<"$line")
  local server="${server_port%%:*}" port="${server_port##*:}"

  local pbk sid sni
  pbk=$(sed -E 's|.*[?&]pbk=([^&]+).*|\1|' <<<"$line")
  sid=$(sed -E 's|.*[?&]sid=([^&]+).*|\1|' <<<"$line")
  sni=$(sed -E 's|.*[?&]sni=([^&]+).*|\1|' <<<"$line")

  # --- sing-box ---
  python3 - "$dir/sing-box.json" "$server" "$port" "$uuid" "$pbk" "$sid" "$sni" <<'PY'
import json, sys
out, server, port, uuid, pbk, sid, sni = sys.argv[1:8]
cfg = {
  "log": {"level": "warn"},
  "dns": {
    "servers": [
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "proxy"},
      {"tag": "dns-direct", "address": "77.88.8.8", "detour": "direct"},
      {"tag": "dns-block", "address": "rcode://success"},
    ],
    "rules": [
      {"outbound": "any", "server": "dns-direct"},
      {"rule_set": "ads", "server": "dns-block"},
    ],
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
     "auto_route": True, "strict_route": True, "stack": "mixed"},
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080},
  ],
  "outbounds": [
    {"type": "vless", "tag": "proxy", "server": server, "server_port": int(port), "uuid": uuid,
     "flow": "xtls-rprx-vision",
     "tls": {"enabled": True, "server_name": sni,
             "utls": {"enabled": True, "fingerprint": "chrome"},
             "reality": {"enabled": True, "public_key": pbk, "short_id": sid}}},
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"},
  ],
  "route": {
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": True, "outbound": "direct"},
      {"rule_set": ["ru-domains", "ru-ip"], "outbound": "direct"},
      {"rule_set": "ads", "outbound": "block"},
    ],
    "rule_set": [
      {"tag": "ru-domains", "type": "remote", "format": "binary",
       "url": "https://raw.githubusercontent.com/Loyalsoldier/sing-box-rules/release/geosite-category-ru.srs",
       "download_detour": "direct"},
      {"tag": "ru-ip", "type": "remote", "format": "binary",
       "url": "https://raw.githubusercontent.com/Loyalsoldier/sing-box-rules/release/geoip-ru.srs",
       "download_detour": "direct"},
      {"tag": "ads", "type": "remote", "format": "binary",
       "url": "https://raw.githubusercontent.com/Loyalsoldier/sing-box-rules/release/geosite-category-ads-all.srs",
       "download_detour": "direct"},
    ],
    "final": "proxy",
    "auto_detect_interface": True,
  },
}
open(out, "w").write(json.dumps(cfg, indent=2, ensure_ascii=False))
PY

  # --- Clash / mihomo ---
  cat > "$dir/clash.yaml" <<EOF
# gore: mihomo/Clash Meta. Российские ресурсы — напрямую, остальное — в туннель.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
dns:
  enable: true
  ipv6: false
  nameserver: [77.88.8.8, 1.1.1.1]
rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - GEOSITE,category-ads-all,REJECT
  - GEOSITE,category-ru,DIRECT
  - GEOSITE,yandex,DIRECT
  - GEOSITE,vk,DIRECT
  - GEOIP,RU,DIRECT
  - MATCH,Proxy
proxies:
  - name: "gore"
    type: vless
    server: ${server}
    port: ${port}
    uuid: ${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${pbk}
      short-id: ${sid}
proxy-groups:
  - name: Proxy
    type: select
    proxies: [gore]
EOF

  # --- xray-клиент (JSON) ---
  python3 - "$dir/xray-client.json" "$server" "$port" "$uuid" "$pbk" "$sid" "$sni" <<'PY'
import json, sys
out, server, port, uuid, pbk, sid, sni = sys.argv[1:8]
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": 1080, "protocol": "socks",
                "settings": {"udp": True}}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless",
     "settings": {"vnext": [{"address": server, "port": int(port),
                             "users": [{"id": uuid, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
     "streamSettings": {"network": "tcp", "security": "reality",
                        "realitySettings": {"serverName": sni, "fingerprint": "chrome",
                                            "publicKey": pbk, "shortId": sid}}},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"},
  ],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:ru"], "outboundTag": "direct"},
    {"type": "field", "domain": ["geosite:category-ru"], "outboundTag": "direct"},
  ]},
}
open(out, "w").write(json.dumps(cfg, indent=2, ensure_ascii=False))
PY

  chmod 600 "$dir"/*.json "$dir"/*.yaml 2>/dev/null || true
  cat > "$dir/README.txt" <<EOF
Профили для клиентов (регион РФ, split-tunnel):
  sing-box.json      sing-box / NekoBox / Hiddify — RU идёт напрямую, остальное в туннель
  clash.yaml         mihomo / Clash Meta / Stash
  xray-client.json   Xray-core напрямую (SOCKS5 127.0.0.1:1080)

Ссылки vless:// — /root/gore-links.txt
Сервер: ${server}:${port}, прикрытие SNI: ${sni}
EOF
  ok "клиентские профили: /root/gore-clients/"
}


# ============================================================================
# --- 09-commands
# ============================================================================
# ------------------------------------------------- обслуживание и команды ----

print_summary() {
  local theme; theme="$(state_get FAKE_THEME 2>/dev/null || echo '—')"
  step "Готово"
  cat <<EOF

  ${C_BOLD}Фейковый сайт${C_RESET}      https://${DOMAIN}/                 (тема: ${theme})
  ${C_BOLD}SNI-роутер${C_RESET}        :443 — ${DOMAIN} / ${DNS_DOMAIN:-—} / Smart DNS-список
EOF
  if $WITH_VPN; then
    cat <<EOF
  ${C_BOLD}VLESS + Reality${C_RESET}    :${REALITY_PORT} (XTLS-Vision), прикрытие ${REALITY_DEST}
  ${C_BOLD}VLESS + XHTTP${C_RESET}      :${XHTTP_PORT} (Reality + паддинг, для сетей, где душат TCP-TLS)
  ${C_BOLD}VLESS + WS${C_RESET}         ws://${DOMAIN}${WS_PATH} через nginx (для CDN)
  ${C_BOLD}Ссылки для клиентов${C_RESET}  /root/gore-links.txt (chmod 600)
EOF
    if [[ "$PANEL" == "yes" ]]; then
      cat <<EOF
  ${C_BOLD}Панель 3x-ui${C_RESET}        https://${DOMAIN}/${PANEL_PATH}/
                          логин: ${XUI_USER:-admin}   пароль: ${XUI_PASS:-см. /etc/sni-stack/state.env}
EOF
    fi
    if [[ "${REGION:-ru}" == "ru" ]]; then
      cat <<EOF
  ${C_BOLD}РФ-профиль${C_RESET}          geoip/geosite + split-tunnel (RU напрямую)
  ${C_BOLD}Профили клиентов${C_RESET}   /root/gore-clients/{sing-box.json,clash.yaml,xray-client.json}
EOF
    fi
  fi
  if $WITH_DNS; then
    cat <<EOF
  ${C_BOLD}DNS${C_RESET}                ${IP4}:53 · DoT ${DNS_DOMAIN}:853 · DoH https://${DNS_DOMAIN}/dns-query (POST)
  ${C_BOLD}Дашборд${C_RESET}            https://${DNS_DOMAIN}/dns/overview
  ${C_BOLD}Админка AdGuard${C_RESET}    http://127.0.0.1:13000 (только с сервера, без пароля)
EOF
  fi
  cat <<EOF

  ${C_DIM}Дальше:${C_RESET}
    1. A-записи ${DOMAIN}${REALITY_DOMAIN:+ / ${REALITY_DOMAIN}}${DNS_DOMAIN:+ / ${DNS_DOMAIN}} → ${IP4}
    2. Клиенты: импортировать ссылки из /root/gore-links.txt
    3. Диагностика: bash install.sh --doctor
    4. Бэкап конфигов: bash install.sh --backup
    5. Состояние: bash install.sh --status

  ${C_DIM}Логи:${C_RESET} /var/log/gore.log · journalctl -u xray -u smartdns-relay
EOF
}

cmd_status() {
  banner
  state_load || warn "нет /etc/sni-stack/state.env — стек не ставился этим скриптом"
  local dom reality dns_dom
  dom="$(state_get DOMAIN 2>/dev/null || echo '—')"
  reality="$(state_get REALITY_DOMAIN 2>/dev/null || echo '—')"
  dns_dom="$(state_get DNS_DOMAIN 2>/dev/null || echo '—')"

  step "Стек"
  printf '  домен панели : %s\n' "$dom"
  printf '  reality      : %s\n' "$reality"
  printf '  dns          : %s\n' "$dns_dom"
  printf '  тема сайта   : %s\n' "$(state_get FAKE_THEME 2>/dev/null || echo '—')"
  printf '  порты        : reality %s, xhttp %s\n' \
    "$(state_get REALITY_PORT 2>/dev/null || echo '—')" \
    "$(state_get XHTTP_PORT 2>/dev/null || echo '—')"

  step "Службы"
  local u
  for u in nginx xray smartdns-resolver smartdns-relay smartdns-telemetry; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1 && \
       systemctl list-unit-files "$u.service" 2>/dev/null | grep -q "$u"; then
      printf '  %-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo 'не активен')"
    fi
  done

  step "Порты"
  ss -tuln 2>/dev/null | grep -E ':(53|80|443|853|13000|15443|18081|17443)\b' | awk '{print "  "$1" "$5}' | sort -u

  step "Сертификаты"
  local c
  for c in "$dom" "$reality" "$dns_dom"; do
    [[ -z "$c" || "$c" == "—" ]] && continue
    local crt="/etc/letsencrypt/live/$c/fullchain.pem"
    if [[ -f "$crt" ]]; then
      printf '  %-28s до %s\n' "$c" "$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
    else
      printf '  %-28s нет файла\n' "$c"
    fi
  done
}

cmd_doctor() {
  banner
  local fails=0
  chk() { # chk <описание> <команда...>
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '  %s✓%s %s\n' "$C_GRN" "$C_RESET" "$d"
    else printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$d"; fails=$((fails+1)); fi
  }

  step "Проверки"
  chk "nginx -t"                       nginx -t
  chk "xray config -test"              /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
  chk "порт 443 слушается"             bash -c 'ss -tuln | grep -q ":443\b"'
  chk "порт 53 слушается"              bash -c 'ss -tuln | grep -q ":53\b"'
  chk "DoH отвечает (POST)"            bash -c 'printf "\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07github\x03com\x00\x00\x01\x00\x01" > /tmp/gore-q.bin; curl -sk -o /dev/null -w "%{http_code}" -X POST https://127.0.0.1:10443/dns-query -H "content-type: application/dns-message" --data-binary @/tmp/gore-q.bin | grep -q 200'
  chk "flood nginx: журнал < 500M"     bash -c 'a=$(journalctl --disk-usage 2>/dev/null | grep -oE "[0-9.]+[GM]" | head -1); echo $a'

  step "DNS-ответы"
  local ip4; ip4="$(state_get IP4 2>/dev/null || get_ip4 || true)"
  if [[ -n "$ip4" ]]; then
    local a
    a=$(dig +short "@127.0.0.1" chatgpt.com 2>/dev/null | head -1)
    if [[ "$a" == "$ip4" ]]; then printf '  %s✓%s rewrite: chatgpt.com → %s\n' "$C_GRN" "$C_RESET" "$ip4"
    else printf '  %s✗%s rewrite: chatgpt.com → %s (ждали %s)\n' "$C_RED" "$C_RESET" "${a:-пусто}" "$ip4"; fails=$((fails+1)); fi
    local g; g=$(dig +short "@127.0.0.1" github.com 2>/dev/null | head -1)
    if [[ -n "$g" && "$g" != "$ip4" ]]; then printf '  %s✓%s обычный домен идёт напрямую: github.com → %s\n' "$C_GRN" "$C_RESET" "$g"
    else printf '  %s✗%s обычный домен: %s\n' "$C_RED" "$C_RESET" "${g:-пусто}"; fails=$((fails+1)); fi
  fi

  step "Логи (последние строки)"
  journalctl -u xray -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true
  journalctl -u smartdns-relay -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true

  echo
  if (( fails == 0 )); then ok "всё зелёное"; return 0; fi
  warn "провалов: $fails"
  return 1
}

cmd_backup() {
  local out="${RESTORE_FILE:-/root/gore-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  step "Бэкап → $out"
  local targets=()
  local t
  for t in /etc/smartdns /etc/nginx /etc/letsencrypt /etc/sni-stack \
           /opt/smartdns /var/www/html /var/www/smartdns \
           /usr/local/etc/xray /etc/systemd/system/smartdns-resolver.service \
           /etc/systemd/system/smartdns-relay.service /etc/systemd/system/smartdns-telemetry.service; do
    [[ -e "$t" ]] && targets+=("$t")
  done
  [[ -f /root/gore-links.txt ]] && targets+=("/root/gore-links.txt")
  tar czf "$out" "${targets[@]}" 2>/dev/null || die "tar упал"
  chmod 600 "$out"
  ok "готово: $out ($(du -h "$out" | cut -f1))"
}

cmd_restore() {
  local f="${RESTORE_FILE:-}"
  [[ -n "$f" && -f "$f" ]] || die "использование: --restore /путь/к/бэкапу.tar.gz"
  step "Восстановление из $f"
  confirm "Точно перезаписать /etc/smartdns, /etc/nginx, /opt/smartdns?" n || die "отменено"
  tar xzf "$f" -C /
  run systemctl daemon-reload
  run systemctl restart nginx smartdns-resolver smartdns-relay smartdns-telemetry
  $WITH_VPN && run systemctl restart xray
  ok "восстановлено"
}

cmd_uninstall() {
  banner
  confirm "Снять стек: остановить службы и удалить конфиги?" n || die "отменено"

  step "Остановка"
  local u
  for u in smartdns-telemetry smartdns-relay smartdns-resolver xray; do
    run systemctl stop "$u" 2>/dev/null || true
    run systemctl disable "$u" 2>/dev/null || true
  done
  run systemctl stop nginx 2>/dev/null || true

  step "Удаление конфигов"
  local dom reality dns_dom
  dom="$(state_get DOMAIN 2>/dev/null || true)"
  reality="$(state_get REALITY_DOMAIN 2>/dev/null || true)"
  dns_dom="$(state_get DNS_DOMAIN 2>/dev/null || true)"
  if ! $DRY_RUN; then
    rm -f "/etc/nginx/sites-enabled/${dom}" "/etc/nginx/sites-enabled/${reality}" \
          "/etc/nginx/sites-enabled/gore-80.conf" "/etc/nginx/sites-available/gore-80.conf"
    [[ -n "$dom" ]] && rm -f "/etc/nginx/sites-available/${dom}"
    [[ -n "$reality" ]] && rm -f "/etc/nginx/sites-available/${reality}"
    rm -f /etc/nginx/conf.d/00-gore-base.conf /etc/nginx/conf.d/00-gore-rate.conf \
          /etc/nginx/conf.d/gore-dns-tls.conf /etc/nginx/snippets/gore-includes.conf \
          /etc/nginx/snippets/gore-dns.conf /etc/nginx/stream-enabled/stream.conf
    rm -f /etc/systemd/system/smartdns-{resolver,relay,telemetry}.service
    rm -rf /etc/sysctl.d/99-gore.conf /etc/systemd/journald.conf.d/99-gore.conf
  fi

  if ! $KEEP_DATA; then
    if confirm "Удалить данные Smart DNS (/etc/smartdns, /var/lib/smartdns, /opt/smartdns, дашборд)?" n; then
      if ! $DRY_RUN; then
        rm -rf /etc/smartdns /var/lib/smartdns /opt/smartdns /var/www/smartdns "$ASSET_DIR"
      fi
      ok "данные удалены"
    else
      ok "данные оставлены"
    fi
  fi

  run systemctl daemon-reload
  run nginx -t 2>/dev/null || true
  run systemctl start nginx 2>/dev/null || true
  ok "снято. Xray-бинарь оставлен (удалить: bash <(curl -L .../install-release.sh) remove)"
}

# ------------------------------------------------------------------- main ---
preflight() {
  need_root
  [[ -f /etc/os-release ]] || die "не вижу /etc/os-release — это точно Linux?"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) warn "проверено на Ubuntu/Debian, у тебя ${ID:-?} — продолжаю на свой риск";;
  esac

  IP4="$(get_ip4 || true)"
  [[ -n "$IP4" ]] || die "не смог определить внешний IPv4"
  IP6="$(get_ip6 || true)"
  state_set IP4 "$IP4"
  [[ -n "$IP6" ]] && state_set IP6 "$IP6"
  info "сервер: $IP4${IP6:+ / $IP6}"
}

main() {
  parse_args "$@"

  case "$ACTION" in
    status)    cmd_status; exit 0;;
    doctor)    cmd_doctor; exit $?;;
    backup)    need_root; cmd_backup; exit 0;;
    restore)   need_root; cmd_restore; exit 0;;
    uninstall) need_root; cmd_uninstall; exit 0;;
  esac

  banner
  preflight
  resolve_domains

  if $DRY_RUN; then
    warn "режим --dry-run: система не меняется, файлы собираются в $P"
  fi

  install_packages
  tune_system
  ensure_ports_free
  create_layout
  install_fake_site
  issue_all_certs
  $WITH_DNS && setup_smartdns
  if $WITH_VPN; then
    install_geodata
    if [[ "$PANEL" == "yes" ]]; then setup_panel; else setup_vpn; fi
    write_client_profiles
  fi
  configure_nginx
  $WITH_DNS && start_dns_services
  setup_firewall

  print_summary
}

trap 'fail "ошибка на строке $LINENO"; log_to_file "ERROR line $LINENO: $BASH_COMMAND"' ERR

main "$@"

