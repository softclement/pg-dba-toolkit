#!/bin/bash

######################################################################
# Tool Name : PostgreSQL DBA Toolkit
# Version   : 1.0.0
# Author    : Clement
# Date      : 2025-06-22
######################################################################

CONFIG_FILE="./pg_settings.conf"
LOG_DIR="./logs"
LOG_FILE="$LOG_DIR/tool_run_$(date +%Y%m%d_%H%M%S).log"
VERSION="1.0.0"

# Define colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m" # No Color

command -v psql >/dev/null 2>&1 || { echo -e "${RED}psql is not installed. Aborting.${NC}"; exit 1; }

mkdir -p "$LOG_DIR"

save_config() {
  cat <<EOF > "$CONFIG_FILE"
PGHOST=$PGHOST
PGPORT=$PGPORT
PGDATABASE=$PGDATABASE
PGUSER=$PGUSER
PGPASSWORD=$PGPASSWORD
PGSCHEMA=$PGSCHEMA
EOF
  echo -e "${GREEN}Configuration saved.${NC}"
}

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    PGHOST=${PGHOST:-localhost}
    PGPORT=${PGPORT:-5432}
  else
    echo -e "${RED}Configuration file not found. Run option [0] to set DB settings.${NC}"
    exit 1
  fi
}

configure_db() {
  PGHOST=${PGHOST:-localhost}
  PGPORT=${PGPORT:-5432}

  echo -e "${YELLOW}Current Configuration:${NC}"
  echo -e "Host     : ${GREEN}$PGHOST${NC}"
  echo -e "Port     : ${GREEN}$PGPORT${NC}"
  echo -e "Database : ${GREEN}$PGDATABASE${NC}"
  echo -e "User     : ${GREEN}$PGUSER${NC}"
  echo -e "Schema   : ${GREEN}$PGSCHEMA${NC}"
  echo

  read -p "Enter Hostname [$PGHOST]: " input; PGHOST=${input:-$PGHOST}
  read -p "Enter Port [$PGPORT]: " input; PGPORT=${input:-$PGPORT}
  read -p "Enter Database Name [$PGDATABASE]: " input; PGDATABASE=${input:-$PGDATABASE}
  read -p "Enter Username [$PGUSER]: " input; PGUSER=${input:-$PGUSER}
  read -s -p "Enter Password (leave blank to retain existing): " input; echo; if [ -n "$input" ]; then PGPASSWORD=$input; fi
  read -p "Enter Default Schema [$PGSCHEMA]: " input; PGSCHEMA=${input:-$PGSCHEMA}

  save_config
}

show_current_config() {
  echo -e "${YELLOW}Current DB Configuration:${NC}"
  echo "Host     : ${PGHOST:-localhost}"
  echo "Port     : ${PGPORT:-5432}"
  echo "Database : $PGDATABASE"
  echo "User     : $PGUSER"
  echo "Schema   : $PGSCHEMA"
  echo
}

psql_cmd() {
  echo -e "\n${BLUE}>> $1${NC}" | tee -a "$LOG_FILE"
  PGPASSWORD=$PGPASSWORD psql -h "$PGHOST" -U "$PGUSER" -p "$PGPORT" -d "$PGDATABASE" -c "$1" | tee -a "$LOG_FILE"
}

vacuum_table()      { read -p "Enter table name to VACUUM: " t; psql_cmd "VACUUM VERBOSE \"$PGSCHEMA\".\"$t\";"; }
analyze_table()     { read -p "Enter table name to ANALYZE: " t; psql_cmd "ANALYZE VERBOSE \"$PGSCHEMA\".\"$t\";"; }
reindex_table()     { read -p "Enter table name to REINDEX: " t; psql_cmd "REINDEX TABLE \"$PGSCHEMA\".\"$t\";"; }
db_table_size()     { psql_cmd "SELECT relname AS table, pg_size_pretty(pg_total_relation_size(relid)) AS total_size FROM pg_catalog.pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 20;"; }
long_running()      { psql_cmd "SELECT pid, now() - pg_stat_activity.query_start AS duration, query FROM pg_stat_activity WHERE state != 'idle' ORDER BY duration DESC;"; }
health_check()      { psql_cmd "SELECT datname, numbackends, deadlocks, temp_files FROM pg_stat_database;"; }
suggest_actions()   { psql_cmd "SELECT relname, n_dead_tup FROM pg_stat_user_tables WHERE n_dead_tup > 10000 ORDER BY n_dead_tup DESC LIMIT 10;"; }
unused_indexes()    { psql_cmd "SELECT relname AS table, indexrelname AS index, idx_scan FROM pg_stat_user_indexes JOIN pg_index USING (indexrelid) WHERE idx_scan = 0;"; }
tables_wo_pk()      { psql_cmd "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary);"; }
autovacuum_activity(){ psql_cmd "SELECT * FROM pg_stat_user_tables WHERE last_autovacuum IS NOT NULL ORDER BY last_autovacuum DESC LIMIT 10;"; }
blocking_queries()  { psql_cmd "SELECT blocked_locks.pid AS blocked_pid, blocking_locks.pid AS blocking_pid, blocked_activity.query AS blocked_query, blocking_activity.query AS blocking_query FROM pg_locks blocked_locks JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.pid != blocked_locks.pid JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid WHERE NOT blocked_locks.granted;"; }
top_queries()       { psql_cmd "SELECT query, calls, total_exec_time, mean_exec_time FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;"; }
extensions_list()   { psql_cmd "SELECT * FROM pg_extension;"; }
lock_waits()        { psql_cmd "SELECT pid, locktype, relation::regclass, mode, granted FROM pg_locks WHERE NOT granted;"; }
replication_status(){ psql_cmd "SELECT * FROM pg_stat_replication;"; }
dead_tuple_tables() { psql_cmd "SELECT relname, n_dead_tup FROM pg_stat_user_tables WHERE n_dead_tup > 0 ORDER BY n_dead_tup DESC;"; }
wal_heavy_tables()  { psql_cmd "SELECT relname, n_tup_ins + n_tup_upd + n_tup_del AS write_load FROM pg_stat_user_tables ORDER BY write_load DESC LIMIT 10;"; }
seq_scans()         { psql_cmd "SELECT relname, seq_scan, idx_scan FROM pg_stat_user_tables ORDER BY seq_scan DESC LIMIT 10;"; }
path_info()         { psql_cmd "SHOW data_directory; SHOW config_file; SHOW log_directory;"; }
cache_hit_ratio()   { psql_cmd "SELECT datname, blks_hit, blks_read, ROUND(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS hit_ratio FROM pg_stat_database ORDER BY hit_ratio DESC;"; }
explain_query()     { read -p "Enter SQL to EXPLAIN: " q; psql_cmd "EXPLAIN $q;"; }
temp_file_usage()   { psql_cmd "SELECT datname, temp_files, temp_bytes, pg_size_pretty(temp_bytes) FROM pg_stat_database ORDER BY temp_bytes DESC;"; }
user_roles_grants() { psql_cmd "\\du+"; }
tablespace_usage()  { psql_cmd "SELECT spc.spcname AS tablespace, pg_tablespace_location(spc.oid) AS location, pg_size_pretty(SUM(pg_relation_size(c.oid))) AS total_size FROM pg_class c JOIN pg_tablespace spc ON c.reltablespace = spc.oid GROUP BY spc.spcname, spc.oid ORDER BY SUM(pg_relation_size(c.oid)) DESC;"; }

# Show config before menu
while true; do
  clear

  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    PGHOST=${PGHOST:-localhost}
    PGPORT=${PGPORT:-5432}
    show_current_config
  else
    echo -e "${RED}DB configuration not found.${NC}"
    echo -e "${YELLOW}Use Option [0] to configure the database settings.${NC}"
    echo
  fi

  echo -e "${YELLOW}========================================= PostgreSQL DBA Toolkit ====================================================${NC}"
  echo -e "+---------------------+  +---------------------+  +------------------------+  +-----------------------+  +----------+"
  echo -e "|   Essential Ops     |  |     Monitoring      |  |   Advanced Analysis    |  |         Other         |  |  System  |"
  echo -e "+---------------------+  +---------------------+  +------------------------+  +-----------------------+  +----------+"
  for i in {0..7}; do
    case $i in
      0) e1="0) Set DB Conn"; e2="9) Unused Idxes"; e3="13) Top Qrys"; e4="21) Path Info"; e5="00) Exit";;
      1) e1="1) Vacuum Tbl"; e2="10) No PK Tbls"; e3="14) Extns List"; e4="22) Cache Ratio"; e5="";;
      2) e1="2) Analyze Tbl"; e2="11) AutoVac Stats"; e3="15) Lock Waits"; e4="23) Explain Qry"; e5="";;
      3) e1="3) Reindex Tbl"; e2="12) Blocking Qrys"; e3="16) Replica Stat"; e4="24) Temp Usage"; e5="";;
      4) e1="4) DB/Table Size"; e2=""; e3="17) Dead Tup Tbls"; e4="25) Roles/Grants"; e5="";;
      5) e1="5) Long Qrys"; e2=""; e3="18) Seq Scans"; e4="26) Tblspc Usage"; e5="";;
      6) e1="6) Health Check"; e2=""; e3=""; e4=""; e5="";;
      7) e1="7) Suggest Actns"; e2=""; e3=""; e4=""; e5="";;
    esac
    printf "| %-19s |  | %-19s |  | %-22s |  | %-21s |  | %-8s |\n" "$e1" "$e2" "$e3" "$e4" "$e5"
  done
  echo -e "+---------------------+  +---------------------+  +------------------------+  +-----------------------+  +----------+"
  echo -e "${YELLOW}=====================================================================================================================${NC}"

  read -p "Choose an option: " choice

  if [[ "$choice" != "0" && "$choice" != "00" && ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Configuration missing. Please run Option [0] to set DB connection.${NC}"
    sleep 2
    continue
  fi

  # Reload config before execution
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

  case "$choice" in
    0) configure_db ;;
    1) vacuum_table ;;
    2) analyze_table ;;
    3) reindex_table ;;
    4) db_table_size ;;
    5) long_running ;;
    6) health_check ;;
    7) suggest_actions ;;
    9) unused_indexes ;;
    10) tables_wo_pk ;;
    11) autovacuum_activity ;;
    12) blocking_queries ;;
    13) top_queries ;;
    14) extensions_list ;;
    15) lock_waits ;;
    16) replication_status ;;
    17) dead_tuple_tables ;;
    18) seq_scans ;;
    19) wal_heavy_tables ;;
    20) echo "Reserved" ;;
    21) path_info ;;
    22) cache_hit_ratio ;;
    23) explain_query ;;
    24) temp_file_usage ;;
    25) user_roles_grants ;;
    26) tablespace_usage ;;
    00) echo "Exiting..."; exit 0 ;;
    *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
  esac

  echo -e "\nPress Enter to continue..."; read
done

