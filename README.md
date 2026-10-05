# Cluster ELK UCLV

Configuración y automatizaciones del cluster `uclv-elk-cluster` (Elastic 9.5).

## Servidores

| Alias | Host | Función |
|---|---|---|
| es1 | uclv@10.12.1.34 | Elasticsearch (master + data) |
| es2 | uclv@10.12.1.35 | Elasticsearch (master + data) |
| es3 | uclv@10.12.1.36 | Elasticsearch (master + data) |
| es0 | uclv@10.12.1.37 | Kibana + Logstash |

Cada nodo de Elasticsearch tiene 302 GB de disco (los datos están en `/mnt/datos`, en la misma partición que el sistema) y 7,6 GB de RAM.

## Contenido del repositorio

| Ruta | Qué es |
|---|---|
| `Logstash/conf.d/` | Pipeline de Logstash (syslog UDP 5514 → índices diarios `uclv-<categoría>-YYYY.MM.dd`), ver más abajo |
| `elasticsearch.yml` | Configuración de referencia de un nodo de Elasticsearch |
| `ILM/` | Política de retención y plantilla de índices |
| `Revision/` | Revisión semanal automática del cluster |
| `*.txt` | Notas de instalación y comandos útiles |

## Retención de datos (ILM)

Antes no había ninguna política: los índices diarios se acumulaban sin límite. A ~12 GB/día (con réplica), el nodo más lleno habría llegado al watermark del 85 % en unos 11 días.

- **Política `uclv-logs-45d`** (`ILM/uclv-logs-45d.policy.json`):
  - `hot` desde la creación del índice (prioridad 100).
  - `warm` a los 7 días (prioridad 50). No se pone en solo lectura, porque Logstash puede escribir eventos con retraso en índices de días anteriores.
  - `delete` a los 45 días.
- **Plantilla `uclv-logs`** (`ILM/uclv-logs.index-template.json`): asigna la política a todo índice nuevo `uclv-*`.
- Se aplicó también a todos los índices existentes.

Aplicar o actualizar (desde un nodo con acceso a ES):

```bash
curl -k -u elastic -H 'Content-Type: application/json' -X PUT https://10.12.1.34:9200/_ilm/policy/uclv-logs-45d -d @ILM/uclv-logs-45d.policy.json
curl -k -u elastic -H 'Content-Type: application/json' -X PUT https://10.12.1.34:9200/_index_template/uclv-logs -d @ILM/uclv-logs.index-template.json
curl -k -u elastic -H 'Content-Type: application/json' -X PUT 'https://10.12.1.34:9200/uclv-*/_settings' -d '{"index.lifecycle.name":"uclv-logs-45d"}'
```

> **Ojo al cambiar la retención:** cada índice guarda la definición de la fase en la que está. Al alargar la retención, los índices que ya están en `delete` se siguen borrando con el valor antiguo, salvo que se devuelvan a `warm` con `POST _ilm/move/<índice>`. Eso es lo que se hizo al pasar de 30 a 45 días.

### Capacidad (octubre 2026)

| Retención | Ocupación media estimada | ¿Aguanta la caída de un nodo? |
|---|---|---|
| 35 días | ~54 % | Sí (máximo recomendado) |
| 45 días | ~68 % | No: el cluster queda yellow hasta que vuelve el nodo |
| 50 días | ~74 % | No (máximo absoluto) |

`uclv-ha-inverso` es el ~74 % del volumen. La optimización del pipeline de Logstash (ver abajo) debería reducirlo a la mitad aproximadamente, lo que permitiría ampliar la retención sin añadir disco.

La plantilla `uclv-logs` también define, solo para los índices que se creen a partir de su aplicación:
- `index.codec: best_compression`;
- `message`/`syslog_message` como `match_only_text`, sin la copia `.keyword`;
- tipos explícitos para los campos nuevos: `ip` para las IPs y `keyword` para MACs, dominios y usuarios.

## Pipeline de Logstash (`Logstash/conf.d/`)

Entrada syslog UDP 5514 en es0. Los ficheros se aplican en orden; el primer filtro que reconoce un evento le pone el tag `log_procesado` y el índice de destino.

| Fichero | Origen | Índice |
|---|---|---|
| `10-filter-syslog-base.conf` | todos | — (parseo de la cabecera syslog y fecha) |
| `20-filter-sw-core-puerta-254.conf` | switch core 10.12.0.254 | `uclv-core-switch-254` |
| `30-filter-captivo.conf` | portal cautivo (pfSense wifi.uclv.cu, `logportalauth`) | `uclv-captivo` |
| `50-filter-haproxy.conf` | HAProxy (10.12.1.5, .9, .72, .73, .74, .80) | `uclv-ha-inverso` |
| `60-filter-switches.conf` | switches Cisco (`%FAC-n-MNEM`) | `uclv-switches` |
| `70-filter-vpn.conf` | VPN SoftEther (vpn-uclv) | `uclv-vpn` |
| `75-filter-wifi-servicios.conf` | DHCP (kea) y DNS (unbound) del pfSense wifi | `uclv-dhcp`, `uclv-dns` |
| `90-filter.conf` | firewall (filterlog), nginx del portal, sistema, resto | `uclv-firewall`, `uclv-nginx`, `uclv-sistema`, `uclv-otros` |
| `95-filter-final.conf` | todos | calcula el índice en `@metadata` y elimina campos repetidos |

### Optimización de octubre 2026 (probada, **pendiente de desplegar**)

Análisis previo sobre los datos reales:
- En HAProxy cada log se guardaba 3 veces: `message`, `event.original` y `_source`.
- Unos 50.000 eventos/día de HAProxy no se parseaban.
- Captivo perdía los fallos de login con el usuario vacío.
- `uclv-otros` era en un 70 % ruido de comprobaciones de salud del VPN.

**HAProxy**
- El formato se detecta por contenido (HTTP, TCP, error de conexión o mensaje del propio HAProxy), no por el nombre del frontend. Así se parsean los frontends nuevos (`vm-*`, `ftp_front`, `http-8080`…), los `SSL handshake failure` y las peticiones truncadas.
- `@timestamp` pasa a ser la hora real de la petición.
- Las cabeceras capturadas se separan en `http_host` y `user_agent`.
- Si el log se parsea bien, no se guarda el texto original. Ahorro estimado: ~50 % del índice.

**Captivo**
- Se parsean los `FAILURE` sin usuario y se captura el motivo (`uclv_reason`).
- Nuevo campo `uclv_accion` para seguir las sesiones: `login`, `login_reutilizado`, `logout`, `fallo` o `error`.
- Las líneas de validación del formulario (`X invalid: TYPO…`) se guardan como `INPUT INVALIDO` **sin el texto tecleado**, porque puede ser una contraseña escrita en el campo de usuario.
- Ya no se guarda la copia `unparsed_message`.

**VPN** (nuevo índice `uclv-vpn`)
- Se descartan las conexiones de los HAProxy al puerto 5555 que no llevan a una sesión.
- Las líneas `[HUB "VPN"]` (autenticación, sesión, IP asignada, fin de sesión) se conservan siempre, porque los usuarios reales también entran a través de los HAProxy.
- Campos extraídos: `vpn_usuario`, `vpn_sesion`, `vpn_ip_asignada`, `vpn_cliente_ip` y `vpn_motivo`.

**DHCP** (nuevo índice `uclv-dhcp`)
- Se descartan los `EVAL_RESULT` (~280.000/día).
- De cada evento se guardan `dhcp_evento`, `dhcp_mac`, `dhcp_ip` y `dhcp_lease_segundos`, para cruzarlos con captivo (MAC → IP → usuario).

**DNS** (nuevo índice `uclv-dns`)
- Consultas de los clientes del wifi (~440.000/día), con los campos `dns_cliente_ip`, `dns_consulta` y `dns_tipo`.

**Otras correcciones**
- **Switch .254**: todos sus eventos se marcan como procesados. Antes, los que no reconocía ningún grok recibían un segundo `index_name` y ES los rechazaba (~100.000 eventos/semana perdidos).
- `95-filter-final.conf` toma el primer índice si hubiera varios.
- nginx se evalúa antes que «sistema». Su patrón acepta URLs con `?` y peticiones binarias; antes fallaba el ~25 %.
- `60-filter-switches.conf` ya no confunde las URLs codificadas de nginx con mensajes Cisco.
- Se descartan cron y los avisos `snmpd truncating integer`.
- En todos los índices se eliminan las copias `message`/`event.original` cuando ya existe `syslog_message`, y los campos `host`, `type`, `@version`, `index_name` e `indice_local`.

**Pruebas**: se ejecutó en es0 una instancia aislada de Logstash (stdin → fichero, sin red ni ES) con 118 mensajes reales de todos los casos. Los 103 eventos resultantes fueron al índice correcto, con todos los campos esperados y sin fallos de parseo. Solo se descartó el ruido previsto.

**Despliegue** (en es0):

```bash
# 1. plantilla (afecta a los índices que se creen a partir de ahora)
curl -k -u elastic -H 'Content-Type: application/json' -X PUT https://10.12.1.34:9200/_index_template/uclv-logs -d @ILM/uclv-logs.index-template.json
# 2. configuración (99-output.conf: solo cambia la línea index =>)
sudo cp Logstash/conf.d/*.conf /etc/logstash/conf.d/
sudo -u logstash /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t
sudo systemctl restart logstash   # ~1 min sin recibir syslog UDP
```

## Revisión semanal automática

Hay dos partes. Ninguna depende de un día fijo, así que **no se pierde ninguna revisión** aunque pasen 9 días o más sin conectarse.

### 1. es0: genera el informe (`Revision/es0/`)

- `/usr/local/sbin/elk-revision` (Python, sin dependencias externas). Cron lo lanza **todos los días** a las 07:30 y al arrancar, pero solo genera informe si han pasado 7 días desde el anterior.
- Revisa:
  - salud del cluster y shards sin asignar;
  - disco, heap y shards por nodo;
  - ingesta diaria por categoría;
  - estado de ILM e índices sin política;
  - errores de Logstash y eventos rechazados por ES;
  - Kibana y el disco de es0.
- Marca cada hallazgo como `OK`, `AVISO` o `CRITICO`.
- Guarda los informes en `/var/log/elk-revision/revision-YYYY-MM-DD.txt` (legibles por `uclv`; se conservan 1 año).
- Usa el usuario de Elasticsearch **`elk_revision`**, de solo lectura (rol en `elk-revision-role.json`: `monitor`, `read_ilm` y `view_index_metadata`). Sus credenciales están en `/etc/elk-revision/config.ini` (root, 600).

Instalación:

```bash
sudo install -m 755 elk-revision /usr/local/sbin/elk-revision
sudo install -m 644 elk-revision.cron /etc/cron.d/elk-revision
sudo install -d -m 2750 -o root -g uclv /var/log/elk-revision
# /etc/elk-revision/config.ini:
# [es]
# urls = https://10.12.1.34:9200, https://10.12.1.35:9200, https://10.12.1.36:9200
# user = elk_revision
# password = ...
# ca = /etc/elk-revision/ca.pem
sudo elk-revision --force   # generar uno ahora
```

### 2. Portátil: descarga y análisis con Claude (`Revision/local/`)

- Un timer de systemd de usuario (`elk-revision.timer`) se lanza cada hora y al volver de un apagado (`Persistent=true`).
- Si el último informe analizado tiene menos de 7 días, termina sin usar la red.
- Si toca análisis, descarga de es0 **todos** los informes pendientes y se los pasa a `claude -p` junto con el análisis anterior, para comparar tendencias.
- El análisis se guarda en `Revision/analisis/analisis-YYYY-MM-DD.md` y avisa con una notificación de escritorio.
- Si es0 tiene informes pero el último tiene más de 8 días, fuerza uno nuevo y avisa de que el cron de es0 falla.
- **VPN**: si es0 no responde, pregunta con una notificación si se activa la VPN UCLV (`~/SoftEther/connect_normal.sh`):
  - Si no se contesta en 15 minutos, cuenta como «no», y no vuelve a preguntar hasta pasadas 4 horas.
  - Si se acepta, siempre desconecta al terminar (`disconnect.sh`).
  - No conecta si hay más de una ruta por defecto, porque `connect_normal.sh` las rompería.

Instalación:

```bash
ln -sf "$PWD/Revision/local/elk-revision.service" "$PWD/Revision/local/elk-revision.timer" ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now elk-revision.timer
Revision/local/elk-revision-local.sh --force   # análisis inmediato
```

Los informes y análisis (`Revision/informes/`, `Revision/analisis/`) **no se suben al repositorio**, porque describen el estado interno del cluster.

## Problemas conocidos (pendientes)

- **Credenciales de Logstash**: pasar el output a un usuario con permisos solo de escritura y guardar su contraseña en el keystore de Logstash.
- **Se pierden los logs del switch core 10.12.0.254** (~100.000 eventos/semana) hasta que se despliegue la nueva configuración de Logstash (corregido en el repo).
- Firewall: el ~5 % de los eventos `filterlog` (ICMP, IGMP, IPv6) no se parsean.
- El pfSense del wifi reinicia `syslogd`/`sshguard` varias veces por hora.
- Revisar el intervalo de comprobación de los HAProxy contra el puerto 5555 del VPN (5 balanceadores × cada pocos segundos).
- `cluster.initial_master_nodes` sigue configurado en los 3 nodos; hay que quitarlo una vez formado el cluster.
- Pasar de índices diarios a data streams.
