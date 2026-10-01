# antiscanner-install

Автоустановщик [AntiScanner](https://github.com/sngvy/AntiScanner) на VPS **одной командой** — без SSH-обёрток, без логина и пароля. Скрипт запускается прямо на сервере, сам определяет свой публичный IP и отвечает на все диалоги установщика.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Anton98567/antiscanner-install/main/antiscanner-install.sh)
```

Готовая копия также лежит на https://checkvpn.net/files/antiscanner-install.sh

## Зачем

Официальный `AntiScanner.sh` интерактивный: спрашивает метод защиты (UFW или iptables) и создание systemd-службы обновления. На голом VPS с этим возня — скрипт запускает установщик в псевдо-терминале (expect) и отвечает сам:

| диалог | ответ |
|---|---|
| `Ваш выбор [1-2]` | `2` — iptables (или `1` с ключом `-m ufw`) |
| `Создать службу systemd ...? [y/N]` | `y` |
| apt `Do you want to continue? [Y/n]` | `y` |
| `Overwrite ...? [Y/n]` | `y` |
| `Press [ENTER] to continue` | Enter |

## Возможности

- сам определяет публичный IP (5 сервисов с фолбэком), хост, ОС и ядро — пишет в лог;
- доустанавливает `expect`, `curl`, `iptables`, если их нет;
- проверяет скачанный скрипт через `bash -n` перед запуском;
- после установки проверяет результат: цепочку `TCP-FLAGS-PROTECT`, число правил в `INPUT`, `netfilter-persistent`, `/etc/iptables/rules.v4`, юнит `antiscanner-update.service` (для UFW — `ufw status`);
- сохраняет лог и состояние последней установки;
- страховка: максимум 40 диалогов, таймаут 1 час, ненулевой код возврата при сбое.

## Требования

- Linux-сервер (Debian/Ubuntu и производные), права **root**;
- `bash`, `curl`, `expect` (ставится автоматически через `apt-get`, если есть сеть до репозиториев);
- для метода iptables — пакет `iptables` / `iptables-nft`.

## Использование

```bash
# по умолчанию: iptables + systemd-служба обновления
bash <(curl -Ls https://raw.githubusercontent.com/Anton98567/antiscanner-install/main/antiscanner-install.sh)

# метод UFW вместо iptables
bash <(curl -Ls https://raw.githubusercontent.com/Anton98567/antiscanner-install/main/antiscanner-install.sh) -m ufw

# без systemd-службы обновления
bash <(curl -Ls https://raw.githubusercontent.com/Anton98567/antiscanner-install/main/antiscanner-install.sh) -n
```

Скачать и запустить из файла:

```bash
curl -LsO https://raw.githubusercontent.com/Anton98567/antiscanner-install/main/antiscanner-install.sh
chmod +x antiscanner-install.sh
sudo ./antiscanner-install.sh -m iptables
```

## Ключи

| ключ | описание |
|---|---|
| `-m, --method ufw\|iptables` | метод защиты (по умолчанию `iptables`) |
| `-y, --yes` | создать `antiscanner-update.service` (по умолчанию да) |
| `-n, --no` | не создавать systemd-службу |
| `-u, --update-only` | только обновить список AntiScanner, без установки |
| `-r, --reinstall` | переустановить (повторный запуск и так безопасен) |
| `--url <link>` | свой URL AntiScanner.sh (своё зеркало) |
| `--log-dir <dir>` | каталог логов (по умолчанию `/var/log/antiscanner`) |
| `-h, --help` | справка |

Переменные окружения: `METHOD`, `ANSWER`, `SCRIPT_URL`, `REMOTE_SCRIPT`, `LOG_DIR`, `MODE`.

## Что куда ставится

| путь | что это |
|---|---|
| `/root/AntiScanner.sh` | скачанный установщик AntiScanner |
| `/etc/iptables/before.rules` | правила цепочки `TCP-FLAGS-PROTECT` (метод iptables) |
| `/etc/iptables/rules.v4` | сохранённые правила `netfilter-persistent` |
| `/etc/systemd/system/antiscanner-update.service` | автообновление списка при старте |
| `/var/log/antiscanner/` | логи установки и `last-install.txt` |

## Логи и диагностика

```bash
# последняя установка
cat /var/log/antiscanner/last-install.txt

# все логи
ls -lt /var/log/antiscanner/

# что реально применилось
iptables -L INPUT -n --line-numbers | grep TCP-FLAGS-PROTECT
iptables -L TCP-FLAGS-PROTECT -n -v
systemctl status antiscanner-update.service

# ручной повтор с подробным выводом
SCRIPT_URL=https://raw.githubusercontent.com/sngvy/AntiScanner/refs/heads/main/AntiScanner.sh \
  bash -x antiscanner-install.sh -m iptables
```

Типичные проблемы:

- `нет expect` — не было сети до apt-репозиториев; поставьте вручную: `apt-get install -y expect`;
- `SSH недоступен` — в этой версии скрипта не бывает: установка идёт локально, нужен только root;
- таймаут 3600 с — установщик завис на диалоге, который не распознан; посмотрите лог и запустите вручную: `bash /root/AntiScanner.sh`;
- `iptables: command not found` после установки — в системе нет пакета `iptables`, поставьте `apt-get install -y iptables` и перезапустите скрипт.

## Как это работает

1. Проверка прав (`root`), определение IP/ОС/ядра, создание каталога логов.
2. Установка недостающих зависимостей через `apt-get` (мягкий фолбэк: если пакет ставится нечем — предупреждение, дальше разберётся сам AntiScanner).
3. Загрузка `AntiScanner.sh` с проверкой `bash -n`.
4. Запуск под `expect` в псевдо-терминале с таблицей автоответов.
5. Проверка результата (цепочка, правила, юниты) и запись состояния в `/var/log/antiscanner/last-install.txt`.

Повторный запуск безопасен: установщик идемпотентен, правила перезаписываются, а не дублируются.

## Безопасность

- скрипт работает только от root и только на том сервере, где его запустили — он не ходит ни в какие другие машины по SSH;
- внешние адреса: `raw.githubusercontent.com` (установщик и сам скрипт) и сервисы определения IP (`ifconfig.me`, `api.ipify.org`, `icanhazip.com`, `ifconfig.co`, `ipinfo.io`) — можно подменить через `SCRIPT_URL`, список IP-сервисов зашит в fallback-цепочку;
- в скрипте нет паролей, ключей и IP-адресов серверов.

## Источники

- AntiScanner: https://github.com/sngvy/AntiScanner
- Установщик: https://raw.githubusercontent.com/sngvy/AntiScanner/refs/heads/main/AntiScanner.sh

## Лицензия

MIT — см. [LICENSE](LICENSE).
