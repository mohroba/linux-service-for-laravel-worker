# Laravel Services Setup (Queue Workers, Reverb, Scheduler)

This repository contains a **bash script** to automate the setup and management of Laravel background services with **systemd**.
It configures and manages:

* **Queue Workers** (per queue, multiple instances supported)
* **Reverb WebSocket server**
* **Laravel Scheduler** (via systemd `timer` or long-running `work`)

The script ensures your Laravel app runs production-ready services in the background, with proper user permissions, restart policies, and logging.

---

## 🚀 Features

* Interactive setup with sensible defaults
* Creates **systemd service units** for:

  * Laravel Queue workers (`queue:work`)
  * Laravel Reverb (`reverb:start`)
  * Laravel Scheduler (`schedule:run` via timer or `schedule:work`)
* Supports multiple queues and multiple worker instances per queue
* Ensures storage and cache directories are writable
* Cleans up old services before creating new ones
* Configurable:

  * PHP binary path
  * Worker timeout / tries / sleep
  * Reverb host & port
  * Scheduler mode (`timer` or `work`)

---

## 📋 Requirements

* Linux system with `systemd` (Ubuntu/Debian, CentOS, etc.)
* PHP installed and accessible (e.g. `/usr/bin/php`)
* Laravel project with `artisan` available
* `sudo` privileges for writing to `/etc/systemd/system`

---

## ⚡ Usage

1. Save the script to a file, for example:

   ```bash
   curl -O https://example.com/laravel-services-setup.sh
   chmod +x laravel-services-setup.sh
   ```

2. Run the script:

   ```bash
   ./laravel-services-setup.sh
   ```

3. Follow the prompts:

   * Project path (`/var/www/my-laravel-app`)
   * Service user & group (default: `www-data`)
   * PHP binary path (default auto-detected)
   * Queue names (`default,email,notifications,...`)
   * Number of workers per queue
   * Reverb host & port (default: `127.0.0.1:6001`)
   * Scheduler mode (`timer` or `work`)

The script will then:

* Create systemd service files
* Enable and start services
* Provide instructions for managing logs and status

---

## ⚙️ Example

### Example Setup

```
Enter the path to your Laravel project [/var/www/sajed-backend/program]:
Enter the user to run the services as [www-data]:
APP_ENV to export for services [production]:
Path to PHP binary [/usr/bin/php]:
Queue worker --timeout (seconds) [180]:
Queue worker --tries [5]:
Queue worker --sleep [3]:
Reverb host [127.0.0.1]:
Reverb port [6001]:
Scheduler mode: 'timer' (recommended) or 'work' [timer]:
Enter queue names (comma-separated, include 'default' if used): default,email
How many workers for queue 'default'? [1]: 2
How many workers for queue 'email'? [1]: 1
```

This creates:

* `laravel-worker-default-1.service`
* `laravel-worker-default-2.service`
* `laravel-worker-email-1.service`
* `reverb.service`
* `laravel-schedule.timer` + `laravel-schedule.service`

---

## 🔍 Logs & Monitoring

### Queue Workers

```bash
journalctl -u laravel-worker-<queue>-<instance> -n 200 --no-pager
systemctl status laravel-worker-<queue>-<instance>
```

### Reverb

```bash
journalctl -u reverb -n 200 --no-pager
systemctl status reverb
```

### Scheduler

* **Timer mode**

  ```bash
  journalctl -u laravel-schedule.service -n 200 --no-pager
  systemctl status laravel-schedule.timer
  ```
* **Work mode**

  ```bash
  journalctl -u laravel-scheduler -n 200 --no-pager
  systemctl status laravel-scheduler
  ```

---

## 🔄 Deployment Tips

For zero-downtime deploys, gracefully reload workers:

```bash
sudo systemctl reload laravel-worker-<queue>-<instance>
```

This runs:

```bash
php artisan queue:restart
```

---

## 🧹 Cleanup

To remove all Laravel-related services created by the script:

```bash
sudo systemctl disable --now 'laravel-worker-*' reverb laravel-scheduler laravel-schedule.timer
sudo rm -f /etc/systemd/system/laravel-worker-*.service
sudo rm -f /etc/systemd/system/reverb.service
sudo rm -f /etc/systemd/system/laravel-scheduler.service
sudo rm -f /etc/systemd/system/laravel-schedule.service /etc/systemd/system/laravel-schedule.timer
sudo systemctl daemon-reload
```

---

## ✅ Summary

This script makes it easy to:

* Run Laravel **queue workers** per queue with scaling
* Run **Reverb WebSocket server**
* Run **Laravel Scheduler** with robust systemd integration

All services are **persistent**, auto-restarting, and fully **logged with journald**.

---

Would you like me to also include a **diagram showing how workers, scheduler, and Reverb fit into the Laravel ecosystem** (queues + scheduler + websocket flow) in the README? That could make it easier for new developers.
