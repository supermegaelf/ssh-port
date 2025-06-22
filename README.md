![#c5f015](https://placehold.co/10x10/c5f015/c5f015.png) **СКРИПТ** ![#c5f015](https://placehold.co/10x10/c5f015/c5f015.png)

```
bash <(curl -s https://raw.githubusercontent.com/supermegaelf/ssh-port/main/ssh-port.sh)
```

![#1589F0](https://placehold.co/10x10/1589F0/1589F0.png) **РУЧНАЯ НАСТРОЙКА** ![#1589F0](https://placehold.co/10x10/1589F0/1589F0.png)

```
nano /etc/ssh/sshd_config
```

Сменить `Port 22` на другой.

Добавить новый порт в UFW:

```
ufw allow 2222/tcp comment "SSH"
systemctl restart ssh
```

Подключитесь по новому порту, не разрывая соединение, затем:

```
ufw delete allow 22/tcp
```
