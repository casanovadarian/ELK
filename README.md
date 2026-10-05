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
| `Logstash/conf.d/` | Pipeline de Logstash (syslog UDP 5514 → índices diarios `uclv-<categoría>-YYYY.MM.dd`) |
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

`uclv-ha-inverso` es el ~74 % del volumen. Eliminar los campos duplicados del log de HAProxy (`message`, `syslog_message` y `haproxy_raw_message`) y usar `index.codec: best_compression` permitiría ampliar la retención sin añadir disco.

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
- **Se pierden los logs del switch core 10.12.0.254** (~100.000 eventos/semana). `20-filter-sw-core-puerta-254.conf` pone `index_name`, y después `60-`/`90-` lo **añaden** otra vez. El índice resultante (`uclv-core-switch-254,uclv-sistema-…`) no es válido y ES lo rechaza con un 400.
- `cluster.initial_master_nodes` sigue configurado en los 3 nodos; hay que quitarlo una vez formado el cluster.
- Pasar de índices diarios a data streams.
