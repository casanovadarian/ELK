#!/usr/bin/env bash
# Descarga de es0 los informes semanales pendientes y los analiza con Claude.
#
# El timer lo lanza cada hora (y al encender, si se perdió alguna ejecución).
# Si el último informe analizado tiene menos de 7 días, termina sin tocar la red.
# Si es0 no es alcanzable (fuera de la red de la UCLV), lo reintenta en la siguiente hora,
# así que la revisión no se pierde aunque te conectes a los 9 días: se analizan todos
# los informes acumulados.
# Uso: elk-revision-local.sh [--force]
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"   # .../Elastic/Revision
INFORMES="$REPO/informes"
ANALISIS="$REPO/analisis"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/elk-revision"
ULTIMO="$STATE_DIR/ultimo_informe"            # nombre del último informe analizado
HOST="uclv@10.12.1.37"
REMOTO="/var/log/elk-revision"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=40)

mkdir -p "$STATE_DIR" "$INFORMES" "$ANALISIS"
log() { echo "[$(date '+%F %T')] $*"; }
avisar() { notify-send -a "Revisión ELK" "$1" "$2" 2>/dev/null || true; }

fecha_de() { sed -E 's/^revision-([0-9-]+)\.txt$/\1/' <<<"$1"; }

ultimo=$(cat "$ULTIMO" 2>/dev/null || true)
if [[ "${1:-}" != "--force" && -n "$ultimo" ]]; then
  siguiente=$(date -d "$(fecha_de "$ultimo") + 7 days" +%s)
  if (( $(date +%s) < siguiente )); then
    exit 0   # aún no toca
  fi
fi

listar() { timeout 90 "${SSH[@]}" "$HOST" "ls -1 $REMOTO" 2>/dev/null; }

# VPN de la UCLV (SoftEther): solo se usa si es0 no responde y siempre preguntando antes.
VPN_DIR="$HOME/SoftEther"
PREGUNTA_VPN="$STATE_DIR/ultima_pregunta_vpn"
desconectar_vpn() {
  log "Desconectando VPN"
  (cd "$VPN_DIR" && ./disconnect.sh) >/dev/null 2>&1 || avisar "Revisión ELK" "Falló disconnect.sh: revisa la red"
}
pedir_vpn() {
  # Como mucho una pregunta cada 4 horas
  if [[ -f "$PREGUNTA_VPN" ]] && (( $(date +%s) - $(stat -c %Y "$PREGUNTA_VPN") < 4 * 3600 )); then
    return 1
  fi
  touch "$PREGUNTA_VPN"
  if (( $(ip route show default | wc -l) != 1 )); then
    avisar "Revisión ELK pendiente" "es0 no accesible y hay varias rutas por defecto: no se activa la VPN automáticamente (connect_normal.sh rompería las rutas)."
    return 1
  fi
  respuesta=$(timeout 900 notify-send -a "Revisión ELK" -u critical -t 0 \
    -A conectar="Conectar VPN" -A no="Ahora no" \
    "Revisión ELK pendiente" "es0 no es accesible. ¿Activo la VPN UCLV para descargar el informe y la desconecto al terminar?" 2>/dev/null || true)
  [[ "$respuesta" == "conectar" ]]
}

if ! listado=$(listar); then
  if ! pedir_vpn; then
    log "es0 no accesible; se reintentará en la próxima ejecución"
    exit 0
  fi
  log "Conectando VPN (aceptado por el usuario)"
  trap desconectar_vpn EXIT
  (cd "$VPN_DIR" && ./connect_normal.sh) >/dev/null 2>&1 || true
  if ! listado=$(listar); then
    log "es0 sigue sin responder con la VPN"
    avisar "Revisión ELK" "Ni con la VPN se llega a es0; se reintentará más tarde."
    exit 0
  fi
fi

pendientes=()
while read -r f; do
  [[ -n "$f" && ( -z "$ultimo" || "$f" > "$ultimo" ) ]] && pendientes+=("$f")
done < <(grep -E '^revision-[0-9-]+\.txt$' <<<"$listado" | sort)

# Sin informe nuevo: si el último de es0 tiene menos de 8 días, todavía no le toca (cron a las 07:30);
# si tiene más, el cron de es0 está fallando y se fuerza uno.
if (( ${#pendientes[@]} == 0 )); then
  reciente=$(grep -E '^revision-[0-9-]+\.txt$' <<<"$listado" | sort | tail -1)
  if [[ -n "$reciente" ]] && (( $(date +%s) < $(date -d "$(fecha_de "$reciente") + 8 days" +%s) )); then
    exit 0
  fi
  log "No hay informes nuevos en es0; se fuerza la generación"
  nuevo=$(timeout 300 "${SSH[@]}" "$HOST" "sudo -n /usr/local/sbin/elk-revision --force" | awk '{print $2}')
  [[ -n "$nuevo" ]] && pendientes+=("$(basename "$nuevo")")
  avisar "es0 no generó el informe semanal" "Se generó a mano. Revisa el cron de es0 (/var/log/elk-revision/cron.log)."
fi
(( ${#pendientes[@]} )) || { log "No se pudo obtener ningún informe"; exit 1; }

for f in "${pendientes[@]}"; do
  timeout 120 scp -q -o BatchMode=yes -o ConnectTimeout=40 "$HOST:$REMOTO/$f" "$INFORMES/$f"
  log "Descargado $f"
done

anterior=$(ls -1 "$ANALISIS"/analisis-*.md 2>/dev/null | tail -1 || true)
salida="$ANALISIS/analisis-$(fecha_de "${pendientes[-1]}").md"

{
  echo "Eres el administrador del cluster Elastic 9.5 'uclv-elk-cluster' de la UCLV:"
  echo "3 nodos master+data (10.12.1.34-36, 302 GB de disco y 7,6 GB de RAM cada uno) y es0 (10.12.1.37) con Kibana y Logstash."
  echo "Logstash recibe syslog UDP y crea índices diarios uclv-<categoria>-YYYY.MM.dd con la política ILM uclv-logs-45d (borrado a los 45 días)."
  echo "Los ficheros de configuración de Logstash están en $(dirname "$REPO")/Logstash/conf.d."
  echo
  echo "Analiza los informes semanales que siguen (${#pendientes[@]}) y escribe en español, en Markdown:"
  echo "1. Estado global (OK / AVISO / CRÍTICO) en una línea."
  echo "2. Qué ha cambiado respecto al análisis anterior (tendencias de disco, ingesta por categoría, errores)."
  echo "3. Problemas detectados, ordenados por gravedad, con la causa probable."
  echo "4. Acciones recomendadas concretas (comandos o cambios de configuración)."
  echo "Sé breve y no repitas tablas enteras del informe. Responde solo con el Markdown del análisis."
  if [[ -n "$anterior" ]]; then
    echo; echo "===== ANÁLISIS ANTERIOR ($(basename "$anterior")) ====="; cat "$anterior"
  fi
  for f in "${pendientes[@]}"; do
    echo; echo "===== INFORME $f ====="; cat "$INFORMES/$f"
  done
} | "$CLAUDE" -p --allowedTools "Read" --add-dir "$(dirname "$REPO")/Logstash" > "$salida.tmp"

mv "$salida.tmp" "$salida"
echo "${pendientes[-1]}" > "$ULTIMO"
estado=$(grep -m1 -oiE 'CR[IÍ]TICO|AVISO|OK' "$salida" || echo "?")
log "Análisis guardado en $salida ($estado)"
avisar "Revisión ELK semanal: $estado" "Análisis en $salida"
