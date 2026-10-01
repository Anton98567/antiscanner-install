#!/usr/bin/env bash
# Установка AntiScanner (sngvy/AntiScanner) НА САМОМ VPS — без SSH, без логина/пароля.
# Скрипт сам определяет IP сервера и запускает AntiScanner.sh локально, отвечая на диалоги автоматически.
#
#   bash <(curl -Ls https://checkvpn.net/files/antiscanner-install.sh)
#   bash <(curl -Ls https://checkvpn.net/files/antiscanner-install.sh) -m ufw
#   bash <(curl -Ls https://checkvpn.net/files/antiscanner-install.sh) -m iptables
#
# Ключи:
#   -m|--method ufw|iptables   метод защиты (по умолчанию iptables)
#   -y|--yes                   создать antiscanner-update.service (по умолчанию да)
#   -u|--update-only           только обновить список AntiScanner, без установки
#   -r|--reinstall             переустановить (по умолчанию повторный запуск безопасен)
#   --url <link>               свой URL AntiScanner.sh
#   --log-dir <dir>            каталог логов (по умолчанию /var/log/antiscanner)
#
# Переменные окружения: METHOD ANSWER SCRIPT_URL LOG_DIR MODE
set -uo pipefail

METHOD_IPTABLES="iptables"
METHOD_UFW="ufw"
METHOD="${METHOD:-$METHOD_IPTABLES}"
ANSWER="${ANSWER:-y}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/sngvy/AntiScanner/refs/heads/main/AntiScanner.sh}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/root/AntiScanner.sh}"
LOG_DIR="${LOG_DIR:-/var/log/antiscanner}"
MODE="${MODE:-install}"
INSECURE=0

die()  { printf '\n[ОШИБКА] %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--method)    METHOD="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    -y|--yes)       ANSWER=y; shift ;;
    -n|--no)        ANSWER=n; shift ;;
    -U|--update-only) MODE=update; shift ;;
    -r|--reinstall) MODE=reinstall; shift ;;
    --url)          SCRIPT_URL="$2"; shift 2 ;;
    --log-dir)      LOG_DIR="$2"; shift 2 ;;
    -h|--help)      awk 'NR>1 { if (/^#/) { s=$0; sub(/^# ?/, "", s); print s } else exit }' "$0"; exit 0 ;;
    *)              die "неизвестный ключ: $1 (см. --help)" ;;
  esac
done

case "$METHOD" in
  iptables|ipt|iptables-nft) CHOICE=2 ;;
  ufw)                        CHOICE=1 ;;
  *) die "метод должен быть ufw или iptables (получено: $METHOD)" ;;
esac

# ------------------------------------------------------------------ окружение
[ "$(id -u)" = 0 ] || die "нужны права root"

if [ -r /etc/os-release ]; then . /etc/os-release; OS="${PRETTY_NAME:-$ID}"; else OS="unknown"; fi
KERNEL="$(uname -r)"

# публичный IP — определяем сами, для логов и подписи
PUBLIC_IP=""
for u in https://ifconfig.me/ip https://api.ipify.org https://icanhazip.com \
         https://ifconfig.co/ip https://ipinfo.io/ip; do
  PUBLIC_IP="$(curl -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
  case "$PUBLIC_IP" in
    *[!0-9.]*|'') PUBLIC_IP="" ;;
    *) break ;;
  esac
done
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="unknown"

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=/tmp
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/antiscanner-${PUBLIC_IP}-${STAMP}.log"
STATE_FILE="$LOG_DIR/last-install.txt"

printf '=== AntiScanner installer ===\n'
printf 'хост      : %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'IP        : %s\n' "$PUBLIC_IP"
printf 'ОС        : %s\n' "$OS"
printf 'ядро      : %s\n' "$KERNEL"
printf 'метод     : %s (ответ в диалоге: %s)\n' "$METHOD" "$CHOICE"
printf 'режим     : %s\n' "$MODE"
printf 'лог       : %s\n' "$LOG_FILE"
printf '\n'

# ------------------------------------------------------------------ зависимости
install_pkgs() {
  need apt-get || return 1
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq </dev/null >/dev/null 2>&1 || true
  apt-get -o Dpkg::Options::=--force-confold install -y "$@" </dev/null
}

if ! need expect; then
  printf '[*] ставим expect ... '
  install_pkgs expect >/dev/null 2>&1 || die "не удалось поставить expect"
  need expect || die "expect не найден после установки"
  echo "готово"
fi

if ! need curl; then
  printf '[*] ставим curl ... '
  install_pkgs curl >/dev/null 2>&1 || die "не удалось поставить curl"
  echo "готово"
fi

if [ "$CHOICE" = 2 ] && ! need iptables && ! need iptables-nft; then
  printf '[*] iptables не найден, пробуем поставить пакетом ... '
  if install_pkgs iptables >/dev/null 2>&1 || install_pkgs iptables-nft >/dev/null 2>&1; then
    echo "готово"
  else
    echo "не удалось (продолжаем — установщик AntiScanner поставит пакет сам)"
  fi
fi

# ------------------------------------------------------------------ загрузка
printf '[*] загрузка %s\n' "$SCRIPT_URL"
curl -fsSL --max-time 120 "$SCRIPT_URL" -o "$REMOTE_SCRIPT" \
  || die "не удалось скачать AntiScanner.sh"
chmod +x "$REMOTE_SCRIPT"
[ -s "$REMOTE_SCRIPT" ] || die "скачался пустой файл"
bash -n "$REMOTE_SCRIPT" 2>/dev/null || die "скачанный файл не проходит проверку синтаксиса"
printf '[+] скачано %s байт\n' "$(wc -c < "$REMOTE_SCRIPT" | tr -d ' ')"

if [ "$MODE" = update ]; then
  printf '[*] только обновление списка AntiScanner\n'
  ( bash "$REMOTE_SCRIPT" --update-only 2>&1 || bash "$REMOTE_SCRIPT" 2>&1 ) | tee -a "$LOG_FILE"
  printf '[*] готово, лог: %s\n' "$LOG_FILE"
  exit 0
fi

# ------------------------------------------------------------------ установка
printf '[*] запуск установки, отвечаем на диалоги автоматически\n\n'

export CHOICE ANSWER REMOTE_SCRIPT
expect <<'EXPECT' 2>&1 | tee "$LOG_FILE"
set timeout 3600
log_user 1
set answered 0
proc answer {val} {
    incr ::answered
    if { $::answered > 40 } { puts "\n[СТОП] слишком много диалогов"; exit 125 }
    send "$val\r"
    exp_continue
}
spawn bash $::env(REMOTE_SCRIPT)
expect {
    -re {[Pp]assword: *$}                                             { send "\r"; exp_continue }
    -re {(\[[12]\]|Ваш выбор|Выбор|метод защиты)[^\r\n]*\r?\s*$}       { answer $::env(CHOICE) }
    -re {(\[y/N\]|\[Y/n\]|\[yN\]|Создать службу)[^\r\n]*\r?\s*$}       { answer $::env(ANSWER) }
    -re {(Continue|continue)[^\r\n]*\[[Yy]/[Nn]\][^\r\n]*\r?\s*$}      { answer "y" }
    -re {(Overwrite|overwrite|\[Y/n\])[^\r\n]*\r?\s*$}                { answer "y" }
    -re {Press \[ENTER\][^\r\n]*\r?\s*$}                             { answer "\r" }
    eof                                                               { }
    timeout                                                           { puts "\n[ТАЙМАУТ] установка не завершилась"; exit 124 }
}
catch wait result
exit [lindex $result 3]
EXPECT

EXP_RC=${PIPESTATUS[0]}

# ------------------------------------------------------------------ проверка
printf '\n=== Проверка результата ===\n'
{
  if [ "$CHOICE" = 2 ]; then
    if iptables -n -L TCP-FLAGS-PROTECT >/dev/null 2>&1; then
      printf 'цепочка TCP-FLAGS-PROTECT : OK\n'
      printf 'правил в INPUT            : %s\n' "$(iptables -L INPUT -n 2>/dev/null | grep -c TCP-FLAGS-PROTECT)"
    else
      printf 'цепочка TCP-FLAGS-PROTECT : ОТСУТСТВУЕТ\n'
    fi
    printf 'netfilter-persistent      : %s\n' "$(systemctl is-active netfilter-persistent 2>/dev/null || echo нет)"
    printf 'строк в rules.v4          : %s\n' "$(grep -c . /etc/iptables/rules.v4 2>/dev/null || echo 0)"
  else
    printf 'ufw status                :\n'
    ufw status 2>/dev/null | head -n 5 || echo '  (ufw не установлен)'
  fi
  printf 'antiscanner-update.service: %s\n' "$(systemctl is-enabled antiscanner-update.service 2>/dev/null || echo нет)"
} 2>&1 | tee -a "$LOG_FILE"

{
  printf 'date=%s\nhost=%s\nip=%s\nos=%s\nmethod=%s\nanswer=%s\nrc=%s\nlog=%s\n' \
    "$(date -Is)" "$(hostname)" "$PUBLIC_IP" "$OS" "$METHOD" "$ANSWER" "$EXP_RC" "$LOG_FILE"
} > "$STATE_FILE" 2>/dev/null || true

echo
[ "$EXP_RC" -eq 0 ] || die "установка завершилась с кодом $EXP_RC (лог: $LOG_FILE)"

echo "[OK] AntiScanner настроен ($METHOD) на $PUBLIC_IP"
echo "     состояние: $STATE_FILE"
echo "     лог      : $LOG_FILE"
