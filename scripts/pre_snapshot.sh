#!/bin/bash
# ============================================================
# pre_snapshot.sh - 작업 전 전체 상태 스냅샷 수집
# 대상: PJTSAP (12.230.210.205/206), PJTSEC (12.230.210.201/202)
# 실행: root 또는 oracle 계정
# 실행 시점: 작업 시작 직전 (PM 당일 12:30~13:00)
# 저장 위치: /tmp/snapshot_before/
# ============================================================

SNAP_DIR=/tmp/snapshot_before
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="$SNAP_DIR/snapshot_$TIMESTAMP.log"

echo "================================================"
echo " 사전 스냅샷 수집 시작: $(date)"
echo " 저장 위치: $SNAP_DIR"
echo "================================================"

mkdir -p "$SNAP_DIR"

# ─── 함수 정의 ───────────────────────────────────────────────
section() {
    echo "" | tee -a "$LOG"
    echo "===== $1 =====" | tee -a "$LOG"
}

run() {
    echo "$ $*" >> "$LOG"
    eval "$@" >> "$LOG" 2>&1
    echo "" >> "$LOG"
}

# ─── 1. OS 기본 정보 ─────────────────────────────────────────
section "OS 기본 정보"
run "hostname"
run "uname -a"
run "cat /etc/redhat-release"
run "date"
run "uptime"

# ─── 2. 디스크 사용률 ────────────────────────────────────────
section "디스크 사용률"
run "df -h"
df -h > "$SNAP_DIR/disk_before.txt"
echo "저장: $SNAP_DIR/disk_before.txt"

# 80% 이상 파티션 경고
WARN=$(df -h | awk 'NR>1 {gsub(/%/,"",$5); if($5+0 >= 80) print "경고: "$6" "$5"% 사용 중"}')
if [ -n "$WARN" ]; then
    echo "⚠️  디스크 경고:" | tee -a "$LOG"
    echo "$WARN" | tee -a "$LOG"
else
    echo "✅ 디스크 사용률 정상 (모두 80% 미만)" | tee -a "$LOG"
fi

# ─── 3. 메모리/CPU ───────────────────────────────────────────
section "메모리 및 CPU"
run "free -h"
run "vmstat 1 3"

# ─── 4. 프로세스 목록 ────────────────────────────────────────
section "전체 프로세스 목록"
ps -ef --forest > "$SNAP_DIR/process_before.txt"
echo "저장: $SNAP_DIR/process_before.txt"

# 주요 프로세스 확인
echo "" | tee -a "$LOG"
echo "[주요 프로세스 현황]" | tee -a "$LOG"
for PROC in pmon rvd crond; do
    COUNT=$(ps -ef | grep "$PROC" | grep -v grep | wc -l)
    STATUS="✅"
    [ "$COUNT" -eq 0 ] && STATUS="❌"
    echo "$STATUS [$PROC] 실행 수: $COUNT" | tee -a "$LOG"
done

# ─── 5. 네트워크 포트 ────────────────────────────────────────
section "리스닝 포트"
ss -tlnp > "$SNAP_DIR/ports_before.txt"
echo "저장: $SNAP_DIR/ports_before.txt"

echo "[주요 포트 확인]" | tee -a "$LOG"
# Oracle Listener (비표준 포트 1621)
ss -tlnp | grep ":1621" \
    && echo "✅ Oracle Listener 1621 오픈" | tee -a "$LOG" \
    || echo "❌ Oracle 1621 포트 없음" | tee -a "$LOG"
# RVD (기본 7500, 환경마다 다를 수 있음)
ss -tlnp | grep ":7500" \
    && echo "✅ RVD 7500 포트 오픈" | tee -a "$LOG" \
    || echo "⚠️  RVD 7500 포트 없음 (포트 확인 필요)" | tee -a "$LOG"

# ─── 6. VIP 위치 확인 ────────────────────────────────────────
section "VIP 현황"
echo "[PJTSAP VIP: 12.230.210.207]" | tee -a "$LOG"
ip addr show | grep "12.230.210.207" \
    && echo "→ 이 서버가 PJTSAP VIP 보유 중" | tee -a "$LOG" \
    || echo "→ PJTSAP VIP 없음 (다른 서버에 있음)" | tee -a "$LOG"

echo "[PJTSEC VIP: 12.230.210.203]" | tee -a "$LOG"
ip addr show | grep "12.230.210.203" \
    && echo "→ 이 서버가 PJTSEC VIP 보유 중" | tee -a "$LOG" \
    || echo "→ PJTSEC VIP 없음 (다른 서버에 있음)" | tee -a "$LOG"

ip addr show > "$SNAP_DIR/ip_before.txt"

# ─── 7. Cron 등록 현황 ───────────────────────────────────────
section "Cron 등록 현황"
CRON_FILE="$SNAP_DIR/crontab_before.txt"
echo "" > "$CRON_FILE"
for user in $(getent passwd | cut -d: -f1); do
    CRON=$(crontab -l -u "$user" 2>/dev/null)
    if [ -n "$CRON" ]; then
        echo "### 계정: $user ###" >> "$CRON_FILE"
        echo "$CRON" >> "$CRON_FILE"
        echo "" >> "$CRON_FILE"
    fi
done
echo "저장: $CRON_FILE"
cat "$CRON_FILE" | tee -a "$LOG"

# ─── 8. Oracle 상태 ──────────────────────────────────────────
section "Oracle DB 상태"
if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET PAGESIZE 50
SET LINESIZE 120
PROMPT [DB 인스턴스 상태]
SELECT STATUS FROM V\\\$INSTANCE;

PROMPT [DB 모드]
SELECT NAME, OPEN_MODE FROM V\\\$DATABASE;

PROMPT [Tablespace 사용률]
SELECT ts.tablespace_name,
       ROUND((1 - NVL(fs.bytes,0)/ts.bytes)*100, 1) AS use_pct
FROM (SELECT tablespace_name, SUM(bytes) bytes FROM dba_data_files GROUP BY tablespace_name) ts,
     (SELECT tablespace_name, SUM(bytes) bytes FROM dba_free_space GROUP BY tablespace_name) fs
WHERE ts.tablespace_name = fs.tablespace_name(+)
ORDER BY 2 DESC;

PROMPT [Redo Log 상태]
SELECT GROUP#, STATUS, ARCHIVED FROM V\\\$LOG;

PROMPT [Data Guard 상태]
SELECT NAME, VALUE FROM V\\\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag');

EXIT;
EOF
" 2>&1 | tee -a "$LOG" | tee "$SNAP_DIR/oracle_before.txt"

    # Listener 상태 (포트 1621)
    echo "" | tee -a "$LOG"
    echo "[Oracle Listener 상태 - 포트 1621]" | tee -a "$LOG"
    su - oracle -c "lsnrctl status" 2>&1 | tee -a "$LOG" | tee "$SNAP_DIR/listener_before.txt"
else
    echo "❌ Oracle pmon 프로세스 없음 - DB 중지 상태" | tee -a "$LOG"
fi

# ─── 9. 시스템 로그 최근 오류 ───────────────────────────────
section "시스템 오류 로그 (최근 1시간)"
journalctl --since "1 hour ago" -p err --no-pager 2>/dev/null | head -30 | tee -a "$LOG"

# ─── 완료 ───────────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo " 스냅샷 수집 완료: $(date)" | tee -a "$LOG"
echo " 저장 파일 목록:" | tee -a "$LOG"
ls -lh "$SNAP_DIR/" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"

echo ""
echo "✅ pre_snapshot.sh 완료. 저장 위치: $SNAP_DIR"
echo "   메인 로그: $LOG"
