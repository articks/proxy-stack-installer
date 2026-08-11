# Proxy Stack Installer

Автоматическая установка собственного прокси-стека на чистый VPS с Ubuntu или Debian.

Один Bash-скрипт разворачивает два варианта MTProto, SOCKS5 и VLESS WebSocket+TLS. IPv6 включается только при передаче отдельного IPv6-домена.

> Используйте проект только на серверах, которыми вы имеете право управлять, и соблюдайте применимое законодательство и правила хостинг-провайдера.

## Что устанавливается

| Сервис | Порт | IPv4 | IPv6 | Назначение |
|---|---:|:---:|:---:|---|
| MTProto FakeTLS (Teleproxy) | TCP/443 | Да | Опционально | Основной прокси Telegram |
| MTProto legacy random padding | TCP/8443 | Да | Опционально | Резервный прокси Telegram |
| SOCKS5 с логином и паролем | TCP/1080 | Да | Опционально | Универсальный TCP-прокси |
| VLESS WebSocket+TLS | TCP/9443 | Да | Опционально | Happ и другие VLESS-клиенты |
| HTTP ACME challenge | TCP/80 | Да | Опционально | Выпуск и продление сертификата Let's Encrypt |

Дополнительно устанавливаются:

- nginx как TLS-терминатор и WebSocket reverse proxy;
- Xray с закреплённой версией и проверкой SHA-256;
- UFW с открытием только необходимых публичных портов;
- автоматическое продление сертификата;
- ежедневное обновление relay-конфигурации Telegram;
- готовая Happ-подписка с VLESS-узлами.

## Требования

- чистый VPS на Ubuntu или Debian с `systemd`;
- архитектура `x86_64`;
- доступ `root` или `sudo`;
- свободные TCP-порты `80`, `443`, `1080`, `8443` и `9443`;
- DNS-записи без Cloudflare/CDN-проксирования;
- первый домен только для IPv4;
- второй домен только для IPv6, если IPv6 нужен.

Скрипт не назначает IPv6-адрес сетевому интерфейсу: IPv6 должен быть заранее выдан хостером и добавлен в систему. Установщик проверит, что AAAA-запись второго домена указывает на реально назначенный VPS адрес.

## Подготовка DNS

### Только IPv4

Создайте одну A-запись:

```text
d1.example.com  A  203.0.113.10
```

У `d1.example.com` не должно быть AAAA-записи.

### IPv4 и IPv6

Используйте два разных домена:

```text
d1.example.com  A     203.0.113.10
d2.example.com  AAAA  2001:db8::10
```

- у первого домена не должно быть AAAA-записи;
- у второго домена не должно быть A-записи;
- IPv6-адрес должен быть назначен одному из интерфейсов VPS.

Проверить DNS можно командами:

```bash
dig +short A d1.example.com
dig +short AAAA d1.example.com
dig +short A d2.example.com
dig +short AAAA d2.example.com
```

## Установка

Склонируйте репозиторий на VPS и перейдите в его каталог:

```bash
git clone https://github.com/articks/proxy-stack-installer.git
cd proxy-stack-installer
```

### Только IPv4

```bash
sudo bash install-proxy-stack.sh d1.example.com
```

### IPv4 и IPv6

```bash
sudo bash install-proxy-stack.sh d1.example.com d2.example.com
```

Установщик проверит ОС, DNS, занятые порты, сертификат и доступность всех созданных сервисов. При ошибке выполнение остановится с диагностическим сообщением.

## Результат

После успешной установки все клиентские параметры сохраняются в:

```text
/root/proxy-credentials.txt
```

Файл содержит:

- MTProto FakeTLS через домен и IP;
- MTProto legacy через домен и IP;
- SOCKS5 через домен и IP;
- VLESS URI через домен и IP;
- отдельные IPv6-конфигурации, если передан второй домен;
- URL готовой Happ-подписки;
- команды диагностики.

Показывайте файл только доверенным пользователям: в нём находятся все секреты доступа.

## Happ

Скопируйте URL подписки из `/root/proxy-credentials.txt` и добавьте его в Happ. Подписка включает:

```text
#proxy-enable: 1
#fragmentation-enable: 0
```

При наличии второго домена подписка содержит два VLESS-узла: IPv4 и IPv6.

Не включайте одновременно встроенный MTProto/SOCKS5-прокси Telegram и системный прокси Happ: двойное проксирование может вызвать лавину повторных соединений.

## Повторный запуск

Сгенерированные секреты хранятся в:

```text
/etc/proxy-stack/credentials.env
```

При повторном запуске с теми же доменами установщик использует прежние секреты. Попытка заменить домены на уже настроенном сервере будет остановлена.

Перед изменением конфигурации создаётся каталог резервной копии:

```text
/root/proxy-stack-backup-YYYYMMDD-HHMMSS
```

## Основные файлы на сервере

| Файл | Назначение |
|---|---|
| `/root/proxy-credentials.txt` | Клиентские конфигурации и секреты |
| `/etc/proxy-stack/credentials.env` | Постоянное состояние установщика |
| `/etc/mtproxy/teleproxy.toml` | Настройки MTProto FakeTLS |
| `/etc/danted.conf` | Настройки SOCKS5 |
| `/usr/local/etc/xray/config.json` | Настройки VLESS/Xray |
| `/etc/nginx/sites-available/proxy-stack.conf` | HTTP, TLS и WebSocket reverse proxy |

## Диагностика

Состояние служб:

```bash
systemctl status teleproxy mtproxy danted xray nginx
```

Если включён IPv6:

```bash
systemctl status mtproxy-ipv6
```

Последние сообщения журналов:

```bash
journalctl -u teleproxy -u mtproxy -u danted -u xray -u nginx --no-pager -n 150
```

Открытые порты:

```bash
ss -lntp
```

Проверка конфигураций:

```bash
nginx -t
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
/usr/sbin/danted -V -f /etc/danted.conf
```

Таймер обновления Telegram relay-конфигурации:

```bash
systemctl list-timers mtproxy-config-refresh.timer
```

## Безопасность

- SOCKS5 требует логин и пароль, но сам протокол не шифрует соединение до VPS.
- VLESS доступен через TLS с сертификатом Let's Encrypt.
- Xray слушает только `127.0.0.1`; наружу публикуется nginx на `9443`.
- Случайные секреты, UUID и WebSocket-путь создаются индивидуально при установке.
- Не публикуйте `/root/proxy-credentials.txt` и `/etc/proxy-stack/credentials.env`.
- Регулярно обновляйте систему и следите за журналами необычных подключений.

## Поддерживаемый сценарий

Проект предназначен для нового VPS. Если нужные порты заняты сторонними службами, установщик завершится без попытки их удалить или перенастроить.

## Проверка установщика перед публикацией

```bash
bash -n install-proxy-stack.sh
```

Версии сторонних компонентов и их контрольные суммы закреплены непосредственно в начале скрипта.
