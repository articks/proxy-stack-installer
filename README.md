# Proxy Stack Installer

Автоматическая установка собственного прокси-стека на чистый VPS с Ubuntu или Debian.

Один Bash-скрипт разворачивает два варианта MTProto, экспериментальный Telegram WEB Proxy, SOCKS5 и VLESS WebSocket+TLS. IPv6 включается только при передаче отдельного IPv6-домена.

> Используйте проект только на серверах, которыми вы имеете право управлять, и соблюдайте применимое законодательство и правила хостинг-провайдера.

## Что устанавливается

| Сервис | Порт | IPv4 | IPv6 | Назначение |
|---|---:|:---:|:---:|---|
| MTProto FakeTLS (Teleproxy) | TCP/443 | Да | Опционально | Основной прокси Telegram |
| Telegram WEB Proxy | HTTPS/443 | Да | Нет | WebView-транспорт через `tproxy-server` |
| MTProto legacy random padding | TCP/8443 | Да | Опционально | Резервный прокси Telegram |
| SOCKS5 с логином и паролем | TCP/1080 | Да | Опционально | Универсальный TCP-прокси |
| VLESS WebSocket+TLS | TCP/443, TCP/9443 | Да | Опционально | Happ и другие VLESS-клиенты; `443` основной, `9443` резервный |
| HTTP ACME challenge | TCP/80 | Да | Опционально | Выпуск и продление сертификата Let's Encrypt |

Дополнительно устанавливаются:

- nginx как TLS-терминатор и WebSocket reverse proxy;
- официальный proof-of-concept `telegramdesktop/tproxy-server`, собранный из закреплённого коммита;
- Xray с закреплённой версией и проверкой SHA-256;
- UFW с открытием только необходимых публичных портов;
- автоматическое продление сертификата;
- ежедневное обновление relay-конфигурации Telegram;
- готовая Happ-подписка с VLESS-узлами.

## Требования

- чистый VPS на Ubuntu или Debian с `systemd`;
- архитектура `x86_64`;
- доступ `root` или `sudo`;
- свободные публичные TCP-порты `80`, `443`, `1080`, `8443` и `9443`;
- свободные локальные TCP-порты `8080` и `8081` для WEB relay;
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
- Telegram WEB Proxy через основной IPv4-домен;
- SOCKS5 через домен и IP;
- VLESS URI через домен и IP;
- отдельные IPv6-конфигурации, если передан второй домен;
- URL готовой Happ-подписки;
- команды диагностики.

Показывайте файл только доверенным пользователям: в нём находятся все секреты доступа.

## Telegram WEB Proxy

WEB Proxy использует только имя хоста и MTProto-секрет. Внешний HTTPS-порт
зафиксирован протоколом на `443`, поэтому произвольный публичный порт указать
нельзя. Установщик сохраняет существующий MTProto FakeTLS на том же порту и
добавляет отдельный relay на локальных адресах `127.0.0.1:8080` и
`127.0.0.1:8081` по цепочке:

```text
Telegram -> HTTPS/443 -> Teleproxy -> nginx -> tproxy-server -> MTProxy
```

Готовые `Hostname`, `Secret` и `tg://webproxy`-ссылка записываются в
`/root/proxy-credentials.txt`. WEB Proxy настраивается только для первого,
IPv4-домена; подключение по IP не поддерживается из-за TLS и привязки
производного bridge-ключа к имени хоста.

На момент фиксации этой версии upstream называет реализацию
[proof-of-concept](https://github.com/telegramdesktop/tproxy-server): Desktop-клиент
реализован, Android экспериментален, а iOS описан как план. Обычные клиенты без
пункта `WEB Proxy` этот вариант использовать не смогут.

## Happ

Скопируйте URL подписки из `/root/proxy-credentials.txt` и добавьте его в Happ. Подписка включает:

```text
#proxy-enable: 1
#fragmentation-enable: 0
```

При наличии второго домена подписка содержит два VLESS-узла: IPv4 и IPv6.
Узлы используют TLS fingerprint `safari`: он совместим с Xray в Happ на
macOS/iOS и не вызывает зависание TLS ClientHello, наблюдаемое с `fp=chrome`.
Основной VLESS-маршрут делит внешний `443` с MTProto и WEB Proxy: Teleproxy
передаёт обычный TLS во внутренний nginx, а nginx выбирает Xray только по
точному секретному WebSocket-пути. Порт `9443` остаётся доступным как резервный.

Установщик создаёт один файл подписки с одним идентификатором. Он не добавляет
старые Reality/TUN-профили и не объединяет найденные на сервере подписки.

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

## Восстановление файла доступов

Если `/root/proxy-credentials.txt` был случайно удалён, восстановите его без
переустановки сервисов:

```bash
cd proxy-stack-installer
sudo bash rebuild-proxy-credentials.sh
```

На сервере, установленном через `install-proxy-stack.sh`, утилита читает
`/etc/proxy-stack/credentials.env` и сохраняет действующие MTProto-секреты,
SOCKS5-пароль, VLESS UUID, WebSocket-путь и идентификатор Happ-подписки. По
умолчанию она ничего не ротирует и не перезапускает.

Показать восстановленный файл сразу после создания:

```bash
sudo bash rebuild-proxy-credentials.sh --print
```

Для старой или вручную собранной конфигурации, у которой нет постоянного файла
состояния, укажите домены:

```bash
sudo bash rebuild-proxy-credentials.sh \
  --domain d1.example.com \
  --ipv6-domain d2.example.com
```

Если в `/var/www/faketls/happ` осталось несколько файлов подписок, утилита не
объединяет их автоматически. Укажите идентификатор единственной рабочей
подписки — имя файла без `.txt`:

```bash
sudo bash rebuild-proxy-credentials.sh \
  --domain d1.example.com \
  --subscription-id 0123456789abcdef0123456789abcdef
```

На старом сервере SOCKS5-пароль можно сохранить только при наличии прежнего
`/root/proxy-credentials.txt`. Если открытый пароль утрачен, его невозможно
получить из `/etc/shadow`; выполните явную ротацию:

```bash
sudo bash rebuild-proxy-credentials.sh \
  --domain d1.example.com \
  --rotate-socks-password
```

После ротации обновите SOCKS5-пароль во всех клиентах. Новый пароль будет
записан в `/root/proxy-credentials.txt`, а на установке, управляемой этим
проектом, также в `/etc/proxy-stack/credentials.env`.

## Основные файлы на сервере

| Файл | Назначение |
|---|---|
| `/root/proxy-credentials.txt` | Клиентские конфигурации и секреты |
| `/etc/proxy-stack/credentials.env` | Постоянное состояние установщика |
| `rebuild-proxy-credentials.sh` | Безопасное пересоздание файла клиентских доступов |
| `/etc/mtproxy/teleproxy.toml` | Настройки MTProto FakeTLS |
| `/etc/tproxy-server/config.json` | Настройки Telegram WEB Proxy relay |
| `/etc/tproxy-server/profiles.json` | Закрытый WEB-профиль и секрет |
| `/etc/danted.conf` | Настройки SOCKS5 |
| `/usr/local/etc/xray/config.json` | Настройки VLESS/Xray |
| `/etc/nginx/sites-available/proxy-stack.conf` | HTTP, TLS и WebSocket reverse proxy |

## Диагностика

Состояние служб:

```bash
systemctl status teleproxy tproxy-server mtproxy danted xray nginx
```

Если включён IPv6:

```bash
systemctl status mtproxy-ipv6
```

Последние сообщения журналов:

```bash
journalctl -u teleproxy -u tproxy-server -u mtproxy -u danted -u xray -u nginx --no-pager -n 150
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
curl --fail http://127.0.0.1:8081/readyz
```

Таймер обновления Telegram relay-конфигурации:

```bash
systemctl list-timers mtproxy-config-refresh.timer
```

## Безопасность

- SOCKS5 требует логин и пароль, но сам протокол не шифрует соединение до VPS.
- VLESS доступен через TLS с сертификатом Let's Encrypt.
- Xray слушает только `127.0.0.1`; наружу VLESS публикуется через Teleproxy/nginx
  на `443` и напрямую через nginx на резервном `9443`.
- Telegram WEB Proxy relay и его административный endpoint слушают только loopback; TLS обслуживает существующий nginx.
- Случайные секреты, UUID и WebSocket-путь создаются индивидуально при установке.
- Не публикуйте `/root/proxy-credentials.txt` и `/etc/proxy-stack/credentials.env`.
- Регулярно обновляйте систему и следите за журналами необычных подключений.

## Поддерживаемый сценарий

Проект предназначен для нового VPS. Если нужные порты заняты сторонними службами, установщик завершится без попытки их удалить или перенастроить.

## Проверка установщика перед публикацией

```bash
bash -n install-proxy-stack.sh rebuild-proxy-credentials.sh
```

Версии сторонних компонентов и их контрольные суммы закреплены непосредственно в начале скрипта.
