#!/bin/sh
# usage: dbcheck.sh warn|die — runs inside the scope environment

mode="$1"
[ -n "${DATABASE_URL-}" ] && exit 0
[ -n "${DB_HOST-}" ] || exit 0

resolves() {
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import socket, sys; socket.gethostbyname(sys.argv[1])' "$1" >/dev/null 2>&1
  else
    return 0
  fi
}

problem=""
if ! resolves "$DB_HOST"; then
  problem="o host $DB_HOST não resolve"
elif [ -n "${DB_PORT-}" ] && command -v nc >/dev/null 2>&1 && ! nc -z -w 2 "$DB_HOST" "$DB_PORT" >/dev/null 2>&1; then
  problem="o host $DB_HOST não aceita conexão na porta $DB_PORT"
fi
[ -n "$problem" ] || exit 0

hint="DB_HOST precisa ser alcançável da máquina local; fora do compose use localhost"
if [ "$mode" = die ]; then
  printf 'commons: %s; %s\n' "$problem" "$hint" >&2
  exit 1
fi
printf 'commons: aviso: %s; %s\n' "$problem" "$hint" >&2
exit 0
