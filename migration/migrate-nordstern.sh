#!/bin/bash
# Migrate nordstern.wien (multisite blog 6 on webhost.whlk.at) into the
# single-site Dokploy WordPress (nordstern-wordpress-euxqyd on 10.8.8.8).
# Source is only read. Target DB and uploads are replaced.
#
# Usage: TARGET_URL=https://nordstern.dhw.wien [WORK_DIR=/path/for/dumps] ./migrate-nordstern.sh
set -euo pipefail

SRC=root@webhost.whlk.at
DST=root@10.8.8.8
APP=nordstern-wordpress-euxqyd
SRC_URL=https://nordstern.wien
TARGET_URL=${TARGET_URL:?set TARGET_URL, e.g. https://nordstern.dhw.wien}
SRC_UPLOADS=/var/www/wordpress/wp-content/uploads/sites/6
DST_UPLOADS=/var/lib/docker/volumes/${APP}_wp_app/_data/wp-content/uploads
USER_IDS="1,8"
# Dumps contain subscriber data and password hashes: keep them out of the repo
WORK=${WORK_DIR:-$(mktemp -d -t nordstern-migration-XXXXXX)}
mkdir -p "$WORK"

ssh_src() { ssh -o BatchMode=yes "$SRC" "$@"; }
ssh_dst() { ssh -o BatchMode=yes "$DST" "$@"; }
# Run SQL in the target MariaDB (reads SQL from stdin)
dst_sql() { ssh_dst "docker exec -i \$(docker ps -qf name=${APP}-mariadb) sh -c 'mariadb -uroot -p\"\$MYSQL_ROOT_PASSWORD\" wordpress'"; }
# Run wp-cli in the target WordPress container as the web user
dst_wp() { ssh_dst "docker exec -u nobody \$(docker ps -qf name=${APP}-wordpress) php -d memory_limit=512M /usr/local/bin/wp-cli.phar --path=/var/www/html $*"; }

echo "==> [1/6] Exporting blog 6 tables from source"
TABLES=$(ssh_src "mysql -N wordpress -e \"select table_name from information_schema.tables where table_schema='wordpress' and table_name like 'wp\\_6\\_%' and table_name not like 'wp\\_6\\_statistics\\_%' and table_name not like 'wp\\_6\\_wpmailsmtp\\_%'\"" | tr '\n' ' ')
echo "    $(wc -w <<<"$TABLES") tables"
ssh_src "mysqldump --single-transaction --default-character-set=utf8mb4 --no-tablespaces wordpress $TABLES | gzip" > "$WORK/site6.sql.gz"

echo "==> [2/6] Exporting users $USER_IDS"
ssh_src "mysqldump --single-transaction --default-character-set=utf8mb4 --no-tablespaces wordpress wp_users --where='ID in ($USER_IDS)' | gzip" > "$WORK/users.sql.gz"
# Generic user meta plus blog 6 meta; blog 1 (wp_*) and other blogs (wp_N_*) are dropped
ssh_src "mysqldump --single-transaction --default-character-set=utf8mb4 --no-tablespaces wordpress wp_usermeta --where=\"user_id in ($USER_IDS) and (meta_key like 'wp\\\\_6\\\\_%' or (meta_key not like 'wp\\\\_%' and meta_key not in ('primary_blog','source_domain','session_tokens')))\" | gzip" > "$WORK/usermeta.sql.gz"
gunzip -t "$WORK"/*.sql.gz

echo "==> [3/6] Replacing target database"
{
  echo "SET FOREIGN_KEY_CHECKS=0;"
  ssh_dst "docker exec \$(docker ps -qf name=${APP}-mariadb) sh -c 'mariadb -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N wordpress -e \"show tables\"'" | sed 's/.*/DROP TABLE IF EXISTS `&`;/'
} | dst_sql
{ gunzip -c "$WORK/site6.sql.gz"; gunzip -c "$WORK/users.sql.gz"; gunzip -c "$WORK/usermeta.sql.gz"; } | dst_sql
{
  for t in $TABLES; do echo "RENAME TABLE \`$t\` TO \`wp_${t#wp_6_}\`;"; done
  echo "UPDATE wp_usermeta SET meta_key = CONCAT('wp_', SUBSTRING(meta_key, 6)) WHERE meta_key LIKE 'wp\\_6\\_%';"
  echo "UPDATE wp_options SET option_name = 'wp_user_roles' WHERE option_name = 'wp_6_user_roles';"
} | dst_sql

echo "==> [4/6] Copying uploads"
ssh_dst "rm -rf ${DST_UPLOADS:?}/* && mkdir -p $DST_UPLOADS"
ssh_src "tar c -C $SRC_UPLOADS --exclude=./wp-statistics --exclude=./matomo/tmp ." | ssh_dst "tar x -C $DST_UPLOADS && chown -R 65534:65534 $DST_UPLOADS"
# Matomo checks the request host against trusted_hosts
MATOMO_CFG=$DST_UPLOADS/matomo/config/config.ini.php
TARGET_HOST=${TARGET_URL#https://}
ssh_dst "grep -q 'trusted_hosts\[\] = \"$TARGET_HOST\"' $MATOMO_CFG || sed -i '/^trusted_hosts\[\] = \"https:\/\/nordstern.wien\"/a trusted_hosts[] = \"$TARGET_HOST\"\ntrusted_hosts[] = \"$TARGET_URL\"' $MATOMO_CFG"

echo "==> [5/6] Rewriting paths and URLs"
dst_wp search-replace "wp-content/uploads/sites/6/" "wp-content/uploads/" --all-tables --precise --skip-columns=guid --report-changed-only
if [ "$TARGET_URL" != "$SRC_URL" ]; then
  dst_wp search-replace "$SRC_URL" "$TARGET_URL" --all-tables --precise --skip-columns=guid --report-changed-only
  dst_wp search-replace "http://nordstern.wien" "$TARGET_URL" --all-tables --precise --skip-columns=guid --report-changed-only
  dst_wp search-replace "//www.nordstern.wien" "//$TARGET_HOST" --all-tables --precise --skip-columns=guid --report-changed-only
fi

echo "==> [6/6] Activating theme and plugins, flushing caches"
dst_wp core update-db
dst_wp theme activate twentytwentytwo
dst_wp plugin activate newsletter matomo twentig svg-support iframe wonderm00ns-simple-facebook-open-graph-tags duplicate-page capability-manager-enhanced updraftplus
dst_wp option update WPLANG de_DE
dst_wp rewrite structure "'/%postname%/'"
ssh_dst "docker exec -i -u nobody \$(docker ps -qf name=${APP}-wordpress) sh -c 'cat > /tmp/htaccess-rules.php'" < "$(dirname "$(readlink -f "$0")")/htaccess-rules.php"
dst_wp eval-file /tmp/htaccess-rules.php
dst_wp cache flush
dst_wp litespeed-purge all || true
ssh_dst "docker exec \$(docker ps -qf name=${APP}-valkey) valkey-cli FLUSHALL"

echo "==> Done. Dumps kept in $WORK"
