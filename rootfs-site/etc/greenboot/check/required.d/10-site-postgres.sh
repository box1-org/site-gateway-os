#!/bin/bash
# box1-docs#133 required check: the site PostgreSQL accepts connections (bounded wait).
[ -f /etc/box1/site.env ] || { echo "not a site instance"; exit 0; }
for _ in $(seq 1 120); do
  if podman exec site-postgres pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null; then echo "site PostgreSQL ready"; exit 0; fi
  sleep 5
done
echo "site PostgreSQL not ready after 600 s" >&2
exit 1
