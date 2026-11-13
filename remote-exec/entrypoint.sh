#!/bin/sh
# entrypoint.sh coordinator [uvicorn options] | migrate | worker [worker.py options] | COMMAND...
set -eu

# A remote cache credential given as the curl config's text goes to a file only this user can read.
if [ -n "${HOLBUILD_REMOTE_CACHE_CURL_CONFIG_CONTENT:-}" ]; then
  config=$(umask 077 && mktemp)
  printf '%s\n' "$HOLBUILD_REMOTE_CACHE_CURL_CONFIG_CONTENT" > "$config"
  unset HOLBUILD_REMOTE_CACHE_CURL_CONFIG_CONTENT
  export HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$config"
fi

case "${1:-}" in
  coordinator)
    shift
    # Open event streams and claim long-polls would otherwise hold shutdown until the supervisor kills the process.
    exec uvicorn --factory remote_exec.app:app --host 0.0.0.0 --port 8090 --timeout-graceful-shutdown 2 "$@" ;;
  migrate)
    exec alembic upgrade head ;;
  worker)
    shift
    exec python3 -m remote_exec.worker "$@" ;;
  *)
    exec "$@" ;;
esac
