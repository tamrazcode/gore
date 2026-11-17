# gore

Установщик полного серверного стека: nginx с SNI-роутером, фейковый сайт,
Smart DNS (AdGuard + релей + дашборд), VPN на Xray (Reality + XHTTP) и панель 3x-ui.
Один файл, одна команда, Ubuntu 22.04/24.04 и Debian 12+.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tamrazcode/gore/main/install.sh) \
  --domain panel.example.com \
  --reality-domain cdn.example.com \
  --dns-domain dns.example.com
```

Без аргументов спросит домены и всё остальное.

## Что ставится

| Слой | Что внутри |
|---|---|
| nginx | SNI-роутер на `:443` (`map $ssl_preread_server_name`), vhost'ы на 7443/9443/17443, ACME-челлендж на `:80` |
| фейковый сайт | 4 встроенные темы (corp / blog / docs / shop), случайная по умолчанию, `/var/www/html` |
| сертификаты | Let's Encrypt через certbot (standalone → webroot), автопродление с reload nginx; `--no-cert` для самоподписанных |
| Smart DNS | AdGuardHome `:53`, DoT `:853`, DoH `:10443` + nginx, релей по SNI-политике на `:15443`, дашборд `/dns/overview` |
| VPN | Xray: VLESS + REALITY (XTLS-Vision) на 8443, VLESS + XHTTP + REALITY на 2096, WS за nginx для CDN |
| панель | 3x-ui на localhost, доступ по случайному пути через nginx, inbound'ы и клиенты создаются в БД автоматически |
| РФ | geoip/geosite, split-tunnel: российские адреса и домены идут напрямую, остальное в туннель |
| система | BBR, лимиты журнала (200 МБ), ufw, лимиты файлов |

## Почему так, а не как в старых установщиках

Схема «nginx + WebSocket + панель на 443», которая гуляла по гайдам в 2023–2024,
в 2026 детектируется по нескольким признакам сразу:

- **WebSocket** после `Upgrade` превращается в постоянный двунаправленный поток —
  это давно известный поведенческий паттерн.
- **TLS-отпечаток**: без `fingerprint: chrome` (uTLS) клиент выдаёт Go-стек, а его
  JA3/JA4 уже в базах DPI.
- **443 сам по себе** — первый кандидат на разбор: блокировки часто привязаны
  именно к стандартному порту, тогда как на высоких портах трафик проходит.
- **Свой фейк-сайт за сертификатом** не спасает, если трафик после рукопожатия
  ведёт себя не как сайт, под который косишь.

Поэтому здесь: REALITY (настоящий TLS с чужого сайта, активное зондирование
проходит), XHTTP (трафик разбит на обычные HTTP-транзакции + паддинг), высокие
порты для инбаундов, реальный фейковый сайт на 443 и панель за случайным путём,
а не на своём порту.

Инбаунды Xray и панель настраиваются сами: скрипт ставит 3x-ui, поднимает
VLESS+Reality / XHTTP+Reality / WS и создаёт клиентов — руками в панели ничего
забивать не нужно.

## Флаги

```
--mode full|dns|vpn        что ставить (по умолчанию full)
--domain <имя>             домен панели и фейк-сайта
--reality-domain <имя>     домен-прикрытие REALITY
--dns-domain <имя>         домен DNS/DoH/дашборда
--auto-domain              взять <ip>.cdn-one.org (без своих доменов)
--email <адрес>            почта ACME
--no-cert                  самоподписанные сертификаты
--panel yes|no             ставить 3x-ui с автонастройкой (по умолчанию yes)
--users <N>                сколько клиентов завести (по умолчанию 1)
--region ru|none           geoip/geosite и split-tunnel (по умолчанию ru)
--fake-site corp|blog|docs|shop|auto
--adguard-src <путь|url>   откуда взять AdGuardHome
--dry-run                  собрать всё в /tmp/sni-stack-dry и проверить nginx -t, не трогая систему
-y, --yes                  без вопросов
```

Обслуживание:

```
--status      состояние стека
--doctor      диагностика: службы, порты, DoH, DNS-ответы, сертификаты
--backup      архив конфигов в /root/ge-*.tar.gz
--restore <файл>
--uninstall   снять стек
```

## Что где окажется

```
/etc/smartdns/            AdGuardHome.yaml, policy.json, catalog.json
/opt/smartdns/            AdGuardHome/, relay.py, telemetry.py
/var/www/html/            фейковый сайт
/var/www/smartdns/        статика дашборда
/usr/local/etc/xray/      конфиг Xray (режим --panel no)
/etc/x-ui/x-ui.db         панель и inbound'ы (режим --panel yes)
/etc/nginx/               stream-enabled/, sites-available/, snippets/
/etc/sni-stack/state.env  сгенерированные пути, порты, пароль панели (chmod 600)
/root/gore-links.txt      ссылки vless:// для клиентов
/root/gore-clients/       профили sing-box / Clash / xray с RU-split
/var/log/gore.log         лог установки
```

## После установки

1. A-записи доменов на IP сервера.
2. Импортировать ссылки из `/root/gore-links.txt` или профили из `/root/gore-clients/`.
3. `bash install.sh --doctor` — проверить, что всё живо.

## Ограничения

- Проверено на Ubuntu 24.04 (Debian 12 — по коду совместимо, но не гонялось).
- XHTTP в Xray активно меняется: версии на клиенте и сервере должны совпадать.
- Российский split-tunnel живёт в клиентских профилях; в самих `vless://`-ссылках
  маршрутизации нет, её задаёт клиент.
- Скрипт ничего не знает про ваши прошлые сертификаты и не переносит их сам —
  для этого `--backup` / `--restore`.
