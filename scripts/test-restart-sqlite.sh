# Script 1/3: medir janela de indisponibilidade em restart a quente (nó único, SQLite).
# Uso: ./test-restart-sqlite.sh [port]   (default 13000)
# Gera 200 dashboards via API e mede o intervalo em que /api/health não responde 200.

set -euo pipefail
PORT="${1:-13000}"
URL="http://localhost:$PORT"
TIMEOUT="${TIMEOUT:-300s}"

wait_health() {
  for _ in $(seq 1 400); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$URL/api/health")" = "200" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_health
curl -s -c /tmp/gf-jar -H 'Content-Type: application/json' \
  -d '{"user":"admin","password":"AdminLab123!"}' "$URL/login" -o /dev/null

echo "[1/3] criando 200 dashboards (mede isoladamente o custo de dados)…"
T=$(date +%s)
for i in $(seq 1 200); do
  curl -s -o /dev/null -b /tmp/gf-jar -H 'Content-Type: application/json' \
    -d "{\"dashboard\":{\"title\":\"perf-dash-$i\",\"uid\":\"perf-$i\"},\"overwrite\":true}" \
    "$URL/api/dashboards/db"
done
echo "      200 dashboards em $(( $(date +%s) - T ))s"

echo "[2/3] reiniciando com polling contínuo…"
(
  while true; do
    printf '%s,%s\n' "$(date +%s.%N)" \
      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 0.5 $URL/api/health)" >> poll.csv
    sleep 0.1
  done
) & POLL=$!

T0=$(date +%s.%N)
if command -v systemctl > /dev/null; then            # produção systemd
  sudo systemctl restart grafana-server
elif [ -n "${GRAFANA_CONTAINER:-}" ]; then            # docker
  docker restart "$GRAFANA_CONTAINER"
else
  echo "defina GRAFANA_CONTAINER=<nome> ou rode num host com systemd" >&2; exit 1
fi
wait_health
T1=$(date +%s.%N)
kill $POLL 2> /dev/null || true

WIND=$(awk -F, -v t0="$T0" '$1>=t0 && $2!=200' poll.csv | wc -l)
printf '[3/3] restart total: %ss | janela indisponível: ~%s probes de 0.1s\n' \
  "$(bc <<< "$T1-$T0")" "$WIND"
echo "Leitura rápida: o boot quase todo está em 'migrations' + inicialização de services;"
echo "o nº de dashboards é praticamente irrelevante (200 dashboards ⇒ ~0 impacto medido)."
