#!/usr/bin/env bash
set -Eeuo pipefail

# ─────────────────────────────  Helpers  ─────────────────────────────
prompt_default() {
  local PROMPT_TEXT=$1
  local DEFAULT_VALUE=$2
  local INPUT_VALUE
  read -r -p "$PROMPT_TEXT [$DEFAULT_VALUE]: " INPUT_VALUE || true
  echo "${INPUT_VALUE:-$DEFAULT_VALUE}"
}

fatal() { echo "ERROR: $*" >&2; exit 1; }

# ─────────────────────────────  Intro  ─────────────────────────────
echo "=== Laravel Services Setup (Queue Workers, Reverb, Scheduler) ==="

# ───────────────────────────  Collect Inputs  ───────────────────────────
PROJECT_PATH=$(prompt_default "Enter the path to your Laravel project" "/var/www/sajed-backend/program")
[[ -d "$PROJECT_PATH" ]] || fatal "Project path not found: $PROJECT_PATH"

SERVICE_USER=$(prompt_default "Enter the user to run the services as" "www-data")
SERVICE_GROUP=$(prompt_default "Enter the group to run the services as" "$SERVICE_USER")

APP_ENV=$(prompt_default "APP_ENV to export for services" "production")

PHP_BIN_DEFAULT="$(command -v php || true)"
PHP_BIN=$(prompt_default "Path to PHP binary" "${PHP_BIN_DEFAULT:-/usr/bin/php}")
[[ -x "$PHP_BIN" ]] || fatal "php binary not found/executable at $PHP_BIN"

[[ -f "$PROJECT_PATH/artisan" ]] || fatal "artisan not found at $PROJECT_PATH/artisan"

WORKER_TIMEOUT=$(prompt_default "Queue worker --timeout (seconds)" "180")
WORKER_TRIES=$(prompt_default "Queue worker --tries" "5")
WORKER_SLEEP=$(prompt_default "Queue worker --sleep" "3")

REVERB_HOST=$(prompt_default "Reverb host" "127.0.0.1")
REVERB_PORT=$(prompt_default "Reverb port" "6001")

SCHEDULER_MODE=$(prompt_default "Scheduler mode: 'timer' (recommended) or 'work'" "timer")

read -r -p "Enter queue names (comma-separated, include 'default' if used): " QUEUES
IFS=',' read -ra QUEUE_ARRAY <<< "${QUEUES:-default}"

declare -A WORKER_COUNTS
for QUEUE in "${QUEUE_ARRAY[@]}"; do
  QN=$(echo "$QUEUE" | xargs)
  [[ -n "$QN" ]] || continue
  COUNT=$(prompt_default "How many workers for queue '$QN'?" "1")
  WORKER_COUNTS[$QN]=$COUNT
done

# ───────────────────────────  Prepare Folders  ───────────────────────────
echo "Ensuring storage & cache are writable by $SERVICE_USER:$SERVICE_GROUP..."
sudo mkdir -p "$PROJECT_PATH/storage/logs" "$PROJECT_PATH/bootstrap/cache"
sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"
sudo chmod -R ug+rwx "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"

# ─────────────────────────────  Clean Old  ─────────────────────────────
echo "Stopping & removing old worker services (if any)..."
sudo systemctl disable --now 'laravel-worker-*' 2>/dev/null || true
sudo rm -f /etc/systemd/system/laravel-worker-*.service 2>/dev/null || true

echo "Stopping & removing old Reverb service (if any)..."
sudo systemctl disable --now reverb 2>/dev/null || true
sudo rm -f /etc/systemd/system/reverb.service 2>/dev/null || true

if [[ "$SCHEDULER_MODE" == "timer" ]]; then
  echo "Removing any prior Scheduler services and timers (creating timer-based)…"
  sudo systemctl disable --now laravel-scheduler 2>/dev/null || true
  sudo rm -f /etc/systemd/system/laravel-scheduler.service 2>/dev/null || true
  sudo systemctl disable --now laravel-schedule.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/laravel-schedule.timer /etc/systemd/system/laravel-schedule.service 2>/dev/null || true
else
  echo "Removing any prior timer-based Scheduler (creating long-running service)…"
  sudo systemctl disable --now laravel-schedule.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/laravel-schedule.timer /etc/systemd/system/laravel-schedule.service 2>/dev/null || true
  sudo systemctl disable --now laravel-scheduler 2>/dev/null || true
  sudo rm -f /etc/systemd/system/laravel-scheduler.service 2>/dev/null || true
fi

# ─────────────────────────  Create Worker Units  ─────────────────────────
for QUEUE in "${!WORKER_COUNTS[@]}"; do
  COUNT=${WORKER_COUNTS[$QUEUE]}
  for (( i=1; i<=COUNT; i++ )); do
    SERVICE_NAME="laravel-worker-${QUEUE}-${i}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    echo "Creating worker unit: ${SERVICE_NAME}"

    sudo tee "$SERVICE_FILE" >/dev/null <<EOL
[Unit]
Description=Laravel Queue Worker for '${QUEUE}' (instance ${i})
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_PATH}
Environment=APP_ENV=${APP_ENV}
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=${PHP_BIN} ${PROJECT_PATH}/artisan queue:work --queue=${QUEUE} --sleep=${WORKER_SLEEP} --tries=${WORKER_TRIES} --timeout=${WORKER_TIMEOUT} --verbose
ExecReload=${PHP_BIN} ${PROJECT_PATH}/artisan queue:restart
Restart=always
RestartSec=5
UMask=0002
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl enable "$SERVICE_NAME"
  done
done

# ─────────────────────────  Create Reverb Unit  ─────────────────────────
echo "Creating Reverb service unit..."
sudo tee /etc/systemd/system/reverb.service >/dev/null <<EOL
[Unit]
Description=Reverb WebSocket Server
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_PATH}
Environment=APP_ENV=${APP_ENV}
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=${PHP_BIN} ${PROJECT_PATH}/artisan reverb:start --host=${REVERB_HOST} --port=${REVERB_PORT}
Restart=always
RestartSec=5
UMask=0002
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# ────────────────────  Scheduler (timer or work)  ────────────────────
if [[ "$SCHEDULER_MODE" == "timer" ]]; then
  echo "Creating timer-based Scheduler (schedule:run every minute)..."

  sudo tee /etc/systemd/system/laravel-schedule.service >/dev/null <<EOL
[Unit]
Description=Run Laravel Scheduler (schedule:run) once

[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_PATH}
Environment=APP_ENV=${APP_ENV}
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=${PHP_BIN} ${PROJECT_PATH}/artisan schedule:run --no-interaction
UMask=0002
StandardOutput=journal
StandardError=journal
EOL

  sudo tee /etc/systemd/system/laravel-schedule.timer >/dev/null <<EOL
[Unit]
Description=Run Laravel Scheduler every minute

[Timer]
OnCalendar=*:0/1
AccuracySec=10s
Unit=laravel-schedule.service
Persistent=true

[Install]
WantedBy=timers.target
EOL

else
  echo "Creating long-running Scheduler (schedule:work)..."

  sudo tee /etc/systemd/system/laravel-scheduler.service >/dev/null <<EOL
[Unit]
Description=Laravel Scheduler (schedule:work)
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_PATH}
Environment=APP_ENV=${APP_ENV}
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=${PHP_BIN} ${PROJECT_PATH}/artisan schedule:work --no-interaction
Restart=always
RestartSec=5
UMask=0002
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

fi

# ───────────────────────────  Reload & Start  ───────────────────────────
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting & enabling workers..."
for QUEUE in "${!WORKER_COUNTS[@]}"; do
  COUNT=${WORKER_COUNTS[$QUEUE]}
  for (( i=1; i<=COUNT; i++ )); do
    sudo systemctl restart "laravel-worker-${QUEUE}-${i}"
  done
done

echo "Starting & enabling Reverb..."
sudo systemctl restart reverb
sudo systemctl enable reverb

if [[ "$SCHEDULER_MODE" == "timer" ]]; then
  echo "Starting & enabling Scheduler timer..."
  sudo systemctl start laravel-schedule.timer
  sudo systemctl enable laravel-schedule.timer
else
  echo "Starting & enabling long-running Scheduler..."
  sudo systemctl restart laravel-scheduler
  sudo systemctl enable laravel-scheduler
fi

# ─────────────────────────────  Summary  ─────────────────────────────
cat <<'OUT'

Setup complete ✅

Logs (journald):
  # Workers
  journalctl -u laravel-worker-<queue>-<instance> -n 200 --no-pager
  # Reverb
  journalctl -u reverb -n 200 --no-pager
  # Scheduler
  #   If timer mode:
  journalctl -u laravel-schedule.service -n 200 --no-pager
  #   If work mode:
  journalctl -u laravel-scheduler -n 200 --no-pager

Health:
  systemctl --no-pager --full status reverb
  systemctl --no-pager --full status laravel-worker-<queue>-<instance>
  systemctl --no-pager --full status laravel-schedule.timer   # (timer mode)
  systemctl --no-pager --full status laravel-scheduler        # (work mode)

Graceful worker reload after deploy:
  sudo systemctl reload laravel-worker-<queue>-<instance>
  # (ExecReload runs: php artisan queue:restart)

OUT
