# shellcheck shell=bash
# Remote job additions for a node-app with offline migrations
# ("migrations": "offline" on its processes in deploy.json).
#
# bin/deploy appends this file after node-app.sh, and sets OFFLINE_SCHEMA_DIR
# in the parameter block, only for such apps; every other app gets neither,
# and node-app.sh's job_main never reaches this code for them. The release
# differs from the online one like this:
#
#   preflight   refuse, before anything changes, unless the database can be
#               backed up and restored by the role the app connects as
#   build       reset and build every process WITHOUT migrating; the old
#               version keeps serving
#   status      `prisma migrate status`: nothing pending -> restart, no pause
#   the pause   pending -> stop every process, dump the database, migrate,
#               start the new version, health check
#   failure     once the dump exists, any failure restores it in one
#               transaction, verifies the result, then rolls the code back
#
# Extra parameter from the generated header:
#   OFFLINE_SCHEMA_DIR   the prisma_schema_dir of the offline processes (one database)

BACKUP_KEEP=5
BACKUP_SPACE_FACTOR=3        # free space needed, as a multiple of the database size
RESTORE_LOCK_TIMEOUT=60s     # how long the restore waits for another session's locks
FINGERPRINT_RESTRICT_KEY=deploy

# Connection settings, filled in by load_database_url.
DB_URL="" DB_HOST="" DB_PORT="" DB_USER="" DB_PASSWORD="" DB_NAME="" DB_SSLMODE=""
# What the database looked like when it was dumped, filled in by dump_database.
DB_FINGERPRINT="" DB_ROW_COUNTS="" DB_SEQUENCES=""
# The schema file (or directory) the preflight checked; prisma is told to use exactly it.
OFFLINE_SCHEMA_PATH=""

# Reads DATABASE_URL from the .env in the schema directory, the way prisma
# does, and prints it as NUL-terminated fields: url, host, port, user,
# password, database, sslmode. Refuses (exit 2, reason on stderr) what the
# PostgreSQL tools could not be given the same way prisma reads it.
read -r -d '' DATABASE_URL_READER <<'JS'
const fs = require("fs");
const util = require("util");
const file = process.argv[1];
const refuse = (message) => {
  console.error(message);
  process.exit(2);
};
// Prisma-only connection parameters; libpq rejects them, so the PostgreSQL tools never see them.
const PRISMA_ONLY = new Set([
  "connection_limit", "pool_timeout", "connect_timeout", "socket_timeout", "pgbouncer",
  "statement_cache_size", "max_connection_lifetime", "max_idle_connection_lifetime",
]);
if (typeof util.parseEnv !== "function") refuse("this node has no util.parseEnv (node 20.12 or newer is needed to read .env files)");
let text;
try { text = fs.readFileSync(file, "utf8"); } catch { refuse(`cannot read ${file}`); }
const url = util.parseEnv(text).DATABASE_URL;
if (!url) refuse(`DATABASE_URL is not set in ${file}`);
if (url.includes("$")) {
  refuse("DATABASE_URL contains '$': it may be built from other variables (prisma expands those). Write the URL out in full; a '$' inside a password is %24.");
}
let parsed, user, password, database;
try {
  parsed = new URL(url);
  user = decodeURIComponent(parsed.username);
  password = decodeURIComponent(parsed.password);
  database = decodeURIComponent(parsed.pathname.replace(/^\//, ""));
} catch {
  refuse("DATABASE_URL is not a valid URL");
}
if (parsed.protocol !== "postgresql:" && parsed.protocol !== "postgres:") refuse("DATABASE_URL is not a PostgreSQL URL");
const host = parsed.hostname.replace(/^\[|\]$/g, "");
if (!host || !user || !database || database.includes("/")) refuse("DATABASE_URL needs a host, a user and one database name");
let sslmode = "";
for (const [key, value] of parsed.searchParams) {
  if (key === "schema") {
    if (value !== "public") refuse(`DATABASE_URL has schema=${value}; only the public schema is supported`);
  } else if (key === "sslmode") {
    sslmode = value;
  } else if (!PRISMA_ONLY.has(key)) {
    refuse(`DATABASE_URL has the parameter "${key}", which the PostgreSQL tools cannot honour the way prisma does`);
  }
}
process.stdout.write([url, host, parsed.port || "5432", user, password, database, sslmode].map((field) => `${field}\0`).join(""));
JS

load_database_url() {
  local env_file="$REMOTE_PATH/$OFFLINE_SCHEMA_DIR/.env" fields_file="$RUN_DIR/database-url.fields" rc
  local -a fields
  # The password passes through a mode-600 file, never an argument or the log.
  (umask 077 && node -e "$DATABASE_URL_READER" "$env_file" >"$fields_file")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$fields_file"
    return 1
  fi
  mapfile -d '' -t fields <"$fields_file"
  rm -f "$fields_file"
  [ "${#fields[@]}" -eq 7 ] || { log "could not read DATABASE_URL from $env_file"; return 1; }
  DB_URL=${fields[0]} DB_HOST=${fields[1]} DB_PORT=${fields[2]} DB_USER=${fields[3]}
  DB_PASSWORD=${fields[4]} DB_NAME=${fields[5]} DB_SSLMODE=${fields[6]}
}

# Runs a PostgreSQL client tool against the app's database. Connection
# settings reach it through its environment only: never its arguments (ps
# shows those to every user) and never the log. Anything inherited is dropped.
db_tool() {
  (
    unset "${!PG@}"
    export PGHOST=$DB_HOST PGPORT=$DB_PORT PGUSER=$DB_USER PGDATABASE=$DB_NAME PGPASSWORD=$DB_PASSWORD PGCONNECT_TIMEOUT=10
    [ -z "$DB_SSLMODE" ] || export PGSSLMODE=$DB_SSLMODE
    exec "$@"
  )
}

# One query, one value on stdout.
sql() { db_tool psql -X -w -q -A -t -v ON_ERROR_STOP=1 -c "$1"; }

# Prisma gets exactly the URL the PostgreSQL tools were built from, so the
# backup and the migrations always target the same database.
prisma_tool() {
  (
    export DATABASE_URL=$DB_URL
    cd "$REMOTE_PATH/$OFFLINE_SCHEMA_DIR" && exec npx prisma "$@"
  )
}

# A hash of the schema (objects, owners, privileges). The restrict key pins
# the random one pg_dump would otherwise put in every dump. pg_dump prints one
# GRANT or REVOKE line per entry of an object's ACL, in ACL order, and the
# order of the entries is not part of the schema: DROP OWNED leaves an object
# the role does not own (schema public) in place and the restore appends the
# role's entries again at the end of its ACL. So the privilege lines are put
# in a fixed order (C locale) and every other line keeps its place. A failed
# pg_dump gives no fingerprint.
schema_fingerprint() {
  local dump out
  dump=$(db_tool pg_dump -w --schema-only --restrict-key="$FINGERPRINT_RESTRICT_KEY") || return 1
  out=$({ awk '!/^(GRANT|REVOKE) /' <<<"$dump"; awk '/^(GRANT|REVOKE) /' <<<"$dump" | LC_ALL=C sort; } | sha256sum) || return 1
  printf '%s' "${out%% *}"
}

table_row_counts() {
  sql "select tablename || '=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text from pg_tables where schemaname = 'public' order by tablename"
}

sequence_positions() {
  sql "select schemaname || '.' || sequencename || '=' || coalesce(last_value::text, 'unused') from pg_sequences where schemaname = 'public' order by 1"
}

# Objects in schema public that the connecting role does not own. The
# restore drops what the role owns and recreates it from the dump; anything
# else could not be dropped, or recreated with the same owner.
FOREIGN_OWNER_QUERY=$(
  cat <<'SQL'
with me as (select oid from pg_roles where rolname = current_user),
public_ns as (select oid from pg_namespace where nspname = 'public')
select coalesce(string_agg(kind || ' ' || name, ', ' order by kind, name), '') from (
  select 'relation' as kind, relname::text as name from pg_class, me, public_ns where relnamespace = public_ns.oid and relowner <> me.oid
  union all select 'function', proname::text from pg_proc, me, public_ns where pronamespace = public_ns.oid and proowner <> me.oid
  union all select 'type', typname::text from pg_type, me, public_ns where typnamespace = public_ns.oid and typowner <> me.oid
  union all select 'operator', oprname::text from pg_operator, me, public_ns where oprnamespace = public_ns.oid and oprowner <> me.oid
  union all select 'collation', collname::text from pg_collation, me, public_ns where collnamespace = public_ns.oid and collowner <> me.oid
  union all select 'conversion', conname::text from pg_conversion, me, public_ns where connamespace = public_ns.oid and conowner <> me.oid
  union all select 'operator class', opcname::text from pg_opclass, me, public_ns where opcnamespace = public_ns.oid and opcowner <> me.oid
  union all select 'operator family', opfname::text from pg_opfamily, me, public_ns where opfnamespace = public_ns.oid and opfowner <> me.oid
  union all select 'text search configuration', cfgname::text from pg_ts_config, me, public_ns where cfgnamespace = public_ns.oid and cfgowner <> me.oid
  union all select 'text search dictionary', dictname::text from pg_ts_dict, me, public_ns where dictnamespace = public_ns.oid and dictowner <> me.oid
  union all select 'statistics', stxname::text from pg_statistic_ext, me, public_ns where stxnamespace = public_ns.oid and stxowner <> me.oid
) objects
SQL
)

# Reads a Prisma schema on stdin; refuses (exit 2, reason on stderr) unless its one datasource
# is `url = env("DATABASE_URL")` with no directUrl. Prisma migrates through directUrl when there
# is one, and through whatever variable `url` names, so the backup (built from DATABASE_URL)
# would otherwise be of another database than the one the migrations change.
read -r -d '' PRISMA_DATASOURCE_CHECK <<'JS'
const text = require("fs").readFileSync(0, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
const refuse = (message) => {
  console.error(message);
  process.exit(2);
};
const blocks = [...text.matchAll(/^[ \t]*datasource[ \t]+\w+[ \t]*\{([^}]*)\}/gm)];
if (blocks.length !== 1) refuse(`the schema declares ${blocks.length} datasources; exactly one is supported`);
const body = blocks[0][1];
if (/^[ \t]*directUrl[ \t]*=/m.test(body)) refuse("the datasource has a directUrl, through which prisma migrates instead of DATABASE_URL");
if (!/^[ \t]*url[ \t]*=[ \t]*env\(\s*"DATABASE_URL"\s*\)[ \t]*$/m.test(body)) {
  refuse('the datasource url is not env("DATABASE_URL"), the variable the backup is built from');
}
JS

# The schema location configured in package.json ("prisma": { "schema": ... }), if any.
read -r -d '' PRISMA_SCHEMA_SETTING <<'JS'
let input = "";
process.stdin.on("data", (chunk) => (input += chunk)).on("end", () => {
  const setting = JSON.parse(input).prisma;
  if (setting && typeof setting.schema === "string") process.stdout.write(setting.schema.replace(/^\.\//, ""));
});
JS

# Checks the Prisma schema of the commit being deployed, the one `prisma migrate deploy` will load from
# its default locations (or from package.json), against what the backup is built from.
check_prisma_schema() {
  local prefix="$OFFLINE_SCHEMA_DIR/" setting candidate path existing=0 type
  local -a files=()
  [ "$OFFLINE_SCHEMA_DIR" != . ] || prefix=""

  if git -C "$REMOTE_PATH" ls-tree --name-only "$SHA" ${prefix:+"$prefix"} | grep -Eq '(^|/)prisma\.config\.[a-z]+$'; then
    log "PREFLIGHT: a prisma.config file exists in $OFFLINE_SCHEMA_DIR; it can change the schema and the datasource, which this tool does not follow"
    return 1
  fi
  if git -C "$REMOTE_PATH" ls-tree --name-only "$SHA" "${prefix}.config/" | grep -Eq '(^|/)prisma\.[a-z]+$'; then
    log "PREFLIGHT: a .config/prisma file exists in $OFFLINE_SCHEMA_DIR; it can change the schema and the datasource, which this tool does not follow"
    return 1
  fi
  setting=$(git -C "$REMOTE_PATH" show "$SHA:${prefix}package.json" 2>/dev/null | node -e "$PRISMA_SCHEMA_SETTING") ||
    { log "PREFLIGHT: could not read package.json in $OFFLINE_SCHEMA_DIR"; return 1; }
  if [ -n "$setting" ]; then
    path="$prefix$setting"
    existing=1
  else
    for candidate in "${prefix}prisma/schema.prisma" "${prefix}schema.prisma" "${prefix}prisma/schema"; do
      if git -C "$REMOTE_PATH" cat-file -e "$SHA:$candidate" 2>/dev/null; then
        path=$candidate
        existing=$((existing + 1))
      fi
    done
  fi
  [ "$existing" -eq 1 ] || { log "PREFLIGHT: found $existing Prisma schema locations in $OFFLINE_SCHEMA_DIR; exactly one is needed"; return 1; }

  type=$(git -C "$REMOTE_PATH" cat-file -t "$SHA:$path") || { log "PREFLIGHT: the Prisma schema $path is not in the commit"; return 1; }
  if [ "$type" = tree ]; then
    mapfile -t files < <(git -C "$REMOTE_PATH" ls-tree -r --name-only "$SHA" "$path/" | grep '\.prisma$')
  else
    files=("$path")
  fi
  [ "${#files[@]}" -gt 0 ] || { log "PREFLIGHT: no .prisma file under $path"; return 1; }
  for candidate in "${files[@]}"; do git -C "$REMOTE_PATH" show "$SHA:$candidate"; done |
    node -e "$PRISMA_DATASOURCE_CHECK" || { log "PREFLIGHT: the Prisma schema in $path cannot be backed up reliably (see above)"; return 1; }
  OFFLINE_SCHEMA_PATH="$REMOTE_PATH/$path" # what migrate status and migrate deploy are told to load
  log "ok: the Prisma schema ($path) uses env(\"DATABASE_URL\") and no directUrl"
}

# Everything that must hold before the first change, or the backup could not be restored. Prints what it checked.
offline_preflight() {
  local backup_dir="$DEPLOY_HOME/backups/$NAME" trial="$DEPLOY_HOME/backups/$NAME/$RUN_ID.trial"
  local cmd value version server_version_num blocks block_size free size

  section "preflight: can the database be backed up and restored?"
  if [ -e "$DEPLOY_HOME/state/$NAME.recovery" ]; then
    value=$(cat "$DEPLOY_HOME/state/$NAME.recovery" 2>/dev/null)
    log "PREFLIGHT: the release of run ${value:-?} is not settled: its database restore or code rollback did not finish."
    log "    Finish it with: bash $DEPLOY_HOME/runs/${value:-<run id>}/job.sh --recover"
    log "    If you settled the database by hand instead, delete $DEPLOY_HOME/state/$NAME.recovery and deploy again."
    return 1
  fi
  for cmd in pg_dump pg_restore psql node; do
    command -v "$cmd" >/dev/null 2>&1 || { log "PREFLIGHT: $cmd is not installed on this host"; return 1; }
  done
  log "ok: pg_dump, pg_restore, psql and node are installed"

  load_database_url || { log "PREFLIGHT: DATABASE_URL could not be used (see above)"; return 1; }
  check_prisma_schema || return 1
  log "ok: DATABASE_URL read from $OFFLINE_SCHEMA_DIR/.env ($DB_USER@$DB_HOST:$DB_PORT/$DB_NAME)"

  server_version_num=$(sql 'show server_version_num') ||
    { log "PREFLIGHT: the database at $DB_HOST:$DB_PORT does not answer with this DATABASE_URL"; return 1; }
  version=$(pg_dump --version) || { log "PREFLIGHT: pg_dump --version failed"; return 1; }
  if [[ $version =~ ^pg_dump\ \(PostgreSQL\)\ ([0-9]+) ]]; then
    if [ "${BASH_REMATCH[1]}" -lt $((server_version_num / 10000)) ]; then
      log "PREFLIGHT: pg_dump is version ${BASH_REMATCH[1]} but the server is version $((server_version_num / 10000)); pg_dump must not be older"
      return 1
    fi
  else
    log "PREFLIGHT: cannot read the version pg_dump reports: $version"
    return 1
  fi
  log "ok: the database answers (server version $server_version_num); pg_dump $version"

  value=$(sql "select count(*) from pg_namespace where nspname = 'public'") || { log "PREFLIGHT: could not look for the schema public"; return 1; }
  [ "$value" = 1 ] || { log "PREFLIGHT: the database has no schema public"; return 1; }
  value=$(sql "select coalesce(string_agg(nspname, ', ' order by nspname), '') from pg_namespace where nspname not in ('public', 'information_schema') and nspname !~ '^pg_'") ||
    { log "PREFLIGHT: could not list the schemas"; return 1; }
  [ -z "$value" ] || { log "PREFLIGHT: the database has schemas besides public ($value); offline migrations support one schema"; return 1; }
  value=$(sql "select coalesce(string_agg(extname, ', ' order by extname), '') from pg_extension where extname <> 'plpgsql'") ||
    { log "PREFLIGHT: could not list the extensions"; return 1; }
  [ -z "$value" ] || { log "PREFLIGHT: the database has extensions ($value); a restore without a superuser cannot recreate them"; return 1; }
  value=$(sql 'select count(*) from pg_largeobject_metadata') || { log "PREFLIGHT: could not count large objects"; return 1; }
  [ "$value" = 0 ] || { log "PREFLIGHT: the database has $value large object(s); the restore does not support them"; return 1; }
  log "ok: the only schema is public, it holds no extension and the database has no large objects"

  value=$(sql "select count(*) from pg_database where datname = current_database() and datdba = (select oid from pg_roles where rolname = current_user)") ||
    { log "PREFLIGHT: could not read the database owner"; return 1; }
  [ "$value" = 1 ] || { log "PREFLIGHT: $DB_USER does not own the database $DB_NAME"; return 1; }
  value=$(sql "$FOREIGN_OWNER_QUERY") || { log "PREFLIGHT: could not read the owners of the objects in public"; return 1; }
  [ -z "$value" ] || { log "PREFLIGHT: objects in public owned by another role than $DB_USER: $value"; return 1; }
  # DROP OWNED also revokes what was granted to the role on shared objects (databases, tablespaces),
  # and no dump of this database could put that back.
  value=$(sql "select count(*) from pg_shdepend where dbid = 0 and deptype = 'a' and refclassid = 'pg_authid'::regclass and refobjid = (select oid from pg_roles where rolname = current_user)") ||
    { log "PREFLIGHT: could not read the privileges granted to $DB_USER"; return 1; }
  [ "$value" = 0 ] || { log "PREFLIGHT: $DB_USER was granted privileges on $value database(s) or tablespace(s); the restore would revoke them"; return 1; }
  log "ok: $DB_USER owns the database and every object in public, and holds no grant on a shared object"

  value=$(sql "select to_regclass('public._prisma_migrations') is not null") || { log "PREFLIGHT: could not look for _prisma_migrations"; return 1; }
  if [ "$value" = t ]; then
    value=$(sql 'select count(*) from public._prisma_migrations where finished_at is null and rolled_back_at is null') ||
      { log "PREFLIGHT: could not read _prisma_migrations"; return 1; }
    [ "$value" = 0 ] || { log "PREFLIGHT: $value failed migration(s) are recorded; resolve them first (prisma migrate resolve), then deploy again"; return 1; }
  fi
  log "ok: no failed migration is recorded"

  mkdir -p "$DEPLOY_HOME/backups" "$backup_dir" && chmod 700 "$DEPLOY_HOME/backups" "$backup_dir" ||
    { log "PREFLIGHT: cannot create the backup directory $backup_dir"; return 1; }
  size=$(sql 'select pg_database_size(current_database())') || { log "PREFLIGHT: could not read the database size"; return 1; }
  value=$(stat -f -c '%a %S' "$backup_dir") || { log "PREFLIGHT: cannot read the free space of $backup_dir"; return 1; }
  read -r blocks block_size <<<"$value"
  free=$((blocks * block_size))
  if [ "$free" -lt $((size * BACKUP_SPACE_FACTOR)) ]; then
    log "PREFLIGHT: $backup_dir has $free bytes free; ${BACKUP_SPACE_FACTOR}x the database ($size bytes) is required"
    return 1
  fi
  log "ok: $free bytes free in $backup_dir for a $size byte database"

  if ! { (umask 077 && db_tool pg_dump -w -Fc -f "$trial") && pg_restore -l "$trial" >/dev/null && schema_fingerprint >/dev/null; }; then
    rm -f "$trial"
    log "PREFLIGHT: a trial backup of the database failed (see above)"
    return 1
  fi
  value=$(stat -c %s "$trial")
  rm -f "$trial" || { log "PREFLIGHT: could not remove the trial backup $trial"; return 1; }
  log "ok: a trial dump of $value bytes was written, listed and deleted; the schema fingerprint can be taken"
  log "preflight passed"
}

# Backs up the database to <file> after recording what it looks like.
dump_database() {
  local file=$1 size
  DB_FINGERPRINT=$(schema_fingerprint) || { log "could not take the schema fingerprint"; return 1; }
  DB_ROW_COUNTS=$(table_row_counts) || { log "could not count the rows"; return 1; }
  DB_SEQUENCES=$(sequence_positions) || { log "could not read the sequence positions"; return 1; }
  (umask 077 && db_tool pg_dump -w -Fc -f "$file") || { log "pg_dump failed"; return 1; }
  pg_restore -l "$file" >/dev/null || { log "the dump cannot be listed by pg_restore"; return 1; }
  size=$(stat -c %s "$file") || return 1
  log "backup: $file ($size bytes); schema fingerprint ${DB_FINGERPRINT:0:16}; $(wc -l <<<"$DB_ROW_COUNTS") tables and $(wc -l <<<"$DB_SEQUENCES") sequences recorded"
}

# What a recovery (job.sh --recover) needs, kept in the run directory. No password.
save_recovery_state() {
  local prev=$1 dump=$2 dir="$RUN_DIR/recovery"
  (
    umask 077
    mkdir -p "$dir" &&
      printf '%s\n' "$dump" >"$dir/dump" &&
      printf '%s\n' "$prev" >"$dir/prev" &&
      printf '%s\n' "$DB_FINGERPRINT" >"$dir/fingerprint" &&
      printf '%s\n' "$DB_ROW_COUNTS" >"$dir/row-counts" &&
      printf '%s\n' "$DB_SEQUENCES" >"$dir/sequences" &&
      printf '%s\n' "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USER" >"$dir/database" &&
      printf '%s\n' "$RUN_ID" >"$DEPLOY_HOME/state/$NAME.recovery" # opens this run's recovery; the preflight refuses while one is open
  ) || { log "could not save the recovery state in $dir"; return 1; }
}

# The recovery of the release that ended well is over: there is nothing to recover to.
close_recovery() {
  rm -f "$DEPLOY_HOME/state/$NAME.recovery" ||
    log "WARNING: could not delete $DEPLOY_HOME/state/$NAME.recovery. Delete it by hand, and do NOT run --recover for run $RUN_ID: it would restore an old backup over live data."
}

# Sets REC_DUMP REC_PREV REC_DATABASE (host, port, name, user) and the recorded database state from a run's recovery state.
load_recovery_state() {
  local dir="$RUN_DIR/recovery"
  [ -f "$dir/dump" ] || return 1
  REC_DUMP=$(<"$dir/dump") && REC_PREV=$(<"$dir/prev") && DB_FINGERPRINT=$(<"$dir/fingerprint") &&
    DB_ROW_COUNTS=$(<"$dir/row-counts") && DB_SEQUENCES=$(<"$dir/sequences") &&
    mapfile -t REC_DATABASE <"$dir/database"
}

# Keeps the BACKUP_KEEP newest dumps of this app, the current one always among
# them. "Newest" is this host's modification time: a run id carries the
# deploying Mac's clock, which may be wrong. A failed removal is only a warning.
prune_dumps() {
  local current=$1 backup_dir="$DEPLOY_HOME/backups/$NAME" name
  local -a others
  mapfile -t others < <(find "$backup_dir" -maxdepth 1 -type f -name '*.dump' ! -name "$current" -printf '%T@ %f\n' | sort -rn | cut -d' ' -f2-)
  for name in "${others[@]:BACKUP_KEEP-1}"; do
    if rm -f -- "$backup_dir/$name"; then
      log "removed the old backup $name (the newest $BACKUP_KEEP are kept)"
    else
      log "WARNING: could not remove the old backup $backup_dir/$name"
    fi
  done
}

# Puts the database back to the dump in ONE transaction: drops everything the
# role owns (the objects of the failed release included), then replays the
# dump. COMMIT is only sent when pg_restore read the whole dump, so a
# truncated or unreadable dump rolls back and leaves the database as it was.
restore_database() {
  local file=$1 producer consumer
  {
    printf "BEGIN;\nSET LOCAL lock_timeout = '%s';\nDROP OWNED BY CURRENT_USER;\n" "$RESTORE_LOCK_TIMEOUT"
    pg_restore -f - "$file" || exit 1
    printf 'COMMIT;\n'
  } | db_tool psql -X -w -q -o /dev/null -v ON_ERROR_STOP=1 -f -
  producer=${PIPESTATUS[0]} consumer=${PIPESTATUS[1]}
  [ "$producer" -eq 0 ] || { log "pg_restore could not read the dump $file; nothing was committed"; return 1; }
  [ "$consumer" -eq 0 ] || { log "psql failed while restoring; nothing was committed"; return 1; }
}

# The restored database must be the one that was dumped.
verify_restore() {
  local fingerprint counts sequences
  fingerprint=$(schema_fingerprint) || { log "could not take the schema fingerprint after the restore"; return 1; }
  counts=$(table_row_counts) || { log "could not count the rows after the restore"; return 1; }
  sequences=$(sequence_positions) || { log "could not read the sequence positions after the restore"; return 1; }
  if [ "$fingerprint" != "$DB_FINGERPRINT" ]; then
    log "the restored schema (${fingerprint:0:16}) differs from the one that was dumped (${DB_FINGERPRINT:0:16})"
    return 1
  fi
  if [ "$counts" != "$DB_ROW_COUNTS" ]; then
    log "the restored row counts differ from the dumped ones (expected < > restored):"
    diff <(printf '%s\n' "$DB_ROW_COUNTS") <(printf '%s\n' "$counts") | sed 's/^/    /'
    return 1
  fi
  if [ "$sequences" != "$DB_SEQUENCES" ]; then
    log "the restored sequence positions differ from the dumped ones (expected < > restored):"
    diff <(printf '%s\n' "$DB_SEQUENCES") <(printf '%s\n' "$sequences") | sed 's/^/    /'
    return 1
  fi
  log "verified: the schema fingerprint, the row counts of every table and every sequence position equal the dump's"
}

stop_processes() {
  local i status
  for i in "${!PROC_NAMES[@]}"; do
    section "pm2 stop ${PROC_NAMES[$i]}"
    (cd "$REMOTE_PATH/${PROC_DIRS[$i]}" && pm2 stop "${PROC_NAMES[$i]}") || return 1
    status=$(pm2_status "${PROC_NAMES[$i]}")
    [ "$status" = stopped ] || { log "${PROC_NAMES[$i]} is $status after pm2 stop, expected stopped"; return 1; }
  done
}

# Prisma exits 0 only when the database is up to date. Its other cases (a
# migration pending, a failed one recorded, the database unreachable) all exit
# 1; the preflight has already ruled out the last two, which leaves pending.
migrations_pending() {
  section "prisma migrate status (in $OFFLINE_SCHEMA_DIR)"
  prisma_tool migrate status --schema "$OFFLINE_SCHEMA_PATH"
  [ $? -ne 0 ]
}

# After a failed restore: the true state of every process, and the one command that finishes the job.
report_recovery() {
  local headline=$1 dump=$2 i
  log "$headline"
  log "State of the processes now, as pm2 reports it:"
  for i in "${!PROC_NAMES[@]}"; do
    log "    ${PROC_NAMES[$i]}: $(pm2_status "${PROC_NAMES[$i]}")"
  done
  log "The backup taken before the migrations: $dump"
  log "To finish (it takes the app's lock, then does the same stop, restore, verification, code rollback and"
  log "health check as this job, with the same exit codes; run it again after fixing what failed):"
  log "    bash $RUN_DIR/job.sh --recover"
}

# A failure after the dump: stop everything, restore, verify, then the usual code rollback.
offline_restore_and_rollback() {
  local prev=$1 dump=$2 rc
  section "RESTORE the database from $dump"
  if stop_processes && restore_database "$dump" && verify_restore; then
    log "RESTORED: the database is back to what it was before the migrations."
  else
    log "RESTORE FAILED: the database may not be in the state it was dumped in."
    report_recovery "The database could not be put back. Nothing was started: the old code must not run on a database in an unknown state." "$dump"
    record_history restore-failed
    return "$EXIT_ROLLBACK_FAILED"
  fi
  rollback "$prev"
  rc=$?
  case $rc in
    "$EXIT_ROLLED_BACK") close_recovery ;;
    "$EXIT_ROLLBACK_FAILED")
      report_recovery "The database was restored, but the code rollback failed. The app is not serving a half state of the database." "$dump" ;;
  esac
  return "$rc"
}

offline_deployed() {
  local prev=$1
  log "DEPLOYED: $NAME is on ${SHA:0:12} and healthy (was ${prev:0:12})."
  close_recovery
  record_history deployed
  return "$EXIT_OK"
}

# The pause: stop, back up, migrate, start, health check.
offline_window() {
  local prev=$1 dump="$DEPLOY_HOME/backups/$NAME/$RUN_ID.dump"

  section "migrations are pending: pausing $NAME"
  if ! stop_processes; then
    log "FAILED: could not stop every process. The database was not touched."
    rollback "$prev"
    return
  fi

  section "back up the database"
  if ! dump_database "$dump"; then
    log "FAILED: the backup failed. The database was not touched."
    rm -f "$dump"
    rollback "$prev"
    return
  fi
  if ! save_recovery_state "$prev" "$dump"; then
    log "FAILED: the recovery state could not be saved. The database was not touched."
    rollback "$prev"
    return
  fi
  prune_dumps "$(basename "$dump")"

  # From here the database changes, so every failure restores the backup.
  section "prisma migrate deploy (in $OFFLINE_SCHEMA_DIR)"
  if prisma_tool migrate deploy --schema "$OFFLINE_SCHEMA_PATH" && restart_processes; then
    section "health check"
    if check_health; then
      offline_deployed "$prev"
      return
    fi
    log "FAILED: the health check did not pass."
  else
    log "FAILED: the migrations or the start of the new version failed (see above)."
  fi
  offline_restore_and_rollback "$prev" "$dump"
}

offline_release() {
  local prev=$1

  offline_preflight || { refuse "offline migrations cannot be run safely here (see the preflight above)"; return; }

  section "checkout ${SHA:0:12} and build (no migrations yet; the old version keeps serving)"
  if ! { git -C "$REMOTE_PATH" reset --hard "$SHA" && install_and_build no-migrate; }; then
    log "FAILED: a release step failed (see above). The database was not touched and $NAME was not stopped."
    rollback "$prev"
    return
  fi

  if migrations_pending; then
    offline_window "$prev"
    return
  fi

  log "no migration is pending: restarting without a pause or a backup"
  if restart_processes; then
    section "health check"
    if check_health; then
      offline_deployed "$prev"
      return
    fi
    log "FAILED: the health check did not pass."
  else
    log "FAILED: the restart failed (see above)."
  fi
  rollback "$prev"
}

# job.sh --recover: finishes a release whose restore failed. The same sequence
# as a failure in the pause, from the state saved when the dump was taken.
job_recover() {
  local head open
  section "RECOVER run $RUN_ID: restore the backup, then put the previous code back"
  # Everything is checked before a process is stopped; any problem leaves the app as it is.
  open=$(cat "$DEPLOY_HOME/state/$NAME.recovery" 2>/dev/null)
  [ "$open" = "$RUN_ID" ] || { refuse "run $RUN_ID has no open recovery (open: ${open:-none}); it succeeded, was recovered already, or a newer release superseded it"; return; }
  load_recovery_state || { refuse "the recovery state of run $RUN_ID is missing or incomplete"; return; }
  [[ $DB_FINGERPRINT =~ ^[0-9a-f]{64}$ ]] && git -C "$REMOTE_PATH" cat-file -e "$REC_PREV^{commit}" 2>/dev/null &&
    [ "${#REC_DATABASE[@]}" -eq 4 ] || { refuse "the recovery state of run $RUN_ID is not well formed"; return; }
  head=$(git -C "$REMOTE_PATH" rev-parse HEAD) || { refuse "$REMOTE_PATH is not a git checkout"; return; }
  if [ "$head" != "$SHA" ] && [ "$head" != "$REC_PREV" ]; then
    refuse "production is at ${head:0:12}, not on run $RUN_ID's ${SHA:0:12} or ${REC_PREV:0:12}; a later deploy happened, so this backup is out of date"
    return
  fi
  [ -f "$REC_DUMP" ] || { refuse "the backup $REC_DUMP does not exist"; return; }
  pg_restore -l "$REC_DUMP" >/dev/null || { refuse "pg_restore cannot read the backup $REC_DUMP"; return; }
  load_database_url || { refuse "DATABASE_URL could not be used (see above)"; return; }
  if [ "${REC_DATABASE[0]}" != "$DB_HOST" ] || [ "${REC_DATABASE[1]}" != "$DB_PORT" ] ||
    [ "${REC_DATABASE[2]}" != "$DB_NAME" ] || [ "${REC_DATABASE[3]}" != "$DB_USER" ]; then
    refuse "DATABASE_URL now names $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME, not the database that was backed up (${REC_DATABASE[3]}@${REC_DATABASE[0]}:${REC_DATABASE[1]}/${REC_DATABASE[2]})"
    return
  fi
  offline_restore_and_rollback "$REC_PREV" "$REC_DUMP"
}

# Entry point of an offline app's job: the normal one, plus --recover.
offline_entry() {
  local rc
  case ${1:-} in
    --recover)
      mkdir -p "$DEPLOY_HOME/locks"
      flock -n -o -E "$EXIT_LOCKED" "$DEPLOY_HOME/locks/$NAME.lock" bash "$RUN_DIR/job.sh" --recover-locked
      rc=$?
      if [ "$rc" -eq "$EXIT_LOCKED" ]; then
        log "REFUSED: another deploy of $NAME is running; nothing was changed."
      fi
      printf '%s\n' "$rc" >"$RUN_DIR/recover-exit-code"
      exit "$rc" ;;
    --recover-locked)
      printf 'run:   %s (recover)\nby:    %s\nsince: %s\n' "$RUN_ID" "$DEPLOYED_BY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >"$DEPLOY_HOME/locks/$NAME.holder"
      job_recover
      exit $? ;;
    *) job_entry "$@" ;;
  esac
}
