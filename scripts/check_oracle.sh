#!/bin/bash
# ============================================================
# check_oracle.sh - Oracle 19C 상태 종합 점검
# 대상 서버: PJTSAP / PJTSEC
# DB Service: PJOSCD, Listener Port: 1621
# 실행: root 또는 oracle 계정
# ============================================================

LOG=/tmp/check_oracle_$(date +%Y%m%d_%H%M%S).log

echo "================================================" | tee "$LOG"
echo " Oracle 19C 상태 점검: $(date)" | tee -a "$LOG"
echo " 서버: $(hostname)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"

OK()   { echo "✅ $*" | tee -a "$LOG"; }
WARN() { echo "⚠️  $*" | tee -a "$LOG"; }
ERR()  { echo "❌ $*" | tee -a "$LOG"; }

# ─── 1. Oracle 프로세스 확인 ─────────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 1. Oracle 프로세스 ───" | tee -a "$LOG"
PMON=$(ps -ef | grep pmon | grep -v grep)
if [ -n "$PMON" ]; then
    OK "pmon 실행 중"
    echo "  $PMON" | tee -a "$LOG"
else
    ERR "pmon 없음 - Oracle DB 중지 상태"
    exit 1
fi

# ─── 2. Listener 포트 확인 (1621) ────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 2. Oracle Listener (포트 1621) ───" | tee -a "$LOG"
ss -tlnp | grep ":1621" > /dev/null 2>&1 \
    && OK "1621 포트 오픈 확인" \
    || ERR "1621 포트 없음 - Listener 중지 상태"

# Listener 상세 상태
LISTENER_OUT=$(su - oracle -c "lsnrctl status" 2>/dev/null)
echo "$LISTENER_OUT" >> "$LOG"

# PJOSCD 서비스 등록 확인 (핵심!)
if echo "$LISTENER_OUT" | grep -q "PJOSCD"; then
    OK "PJOSCD 서비스 Listener 등록 확인"
else
    ERR "PJOSCD 서비스 미등록!"
    echo "  조치: sqlplus / as sysdba → ALTER SYSTEM REGISTER;" | tee -a "$LOG"
fi

# ─── 3. DB 인스턴스 상태 ─────────────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 3. DB 인스턴스 상태 ───" | tee -a "$LOG"
ORACLE_CHECK=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET PAGESIZE 100 LINESIZE 120 FEEDBACK OFF HEADING ON
PROMPT ★ DB 인스턴스 상태
SELECT INSTANCE_NAME, STATUS, DATABASE_STATUS FROM V\\\$INSTANCE;

PROMPT ★ DB 모드
SELECT NAME, DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\\\$DATABASE;

PROMPT ★ Tablespace 사용률 (90% 이상 경고)
SELECT ts.tablespace_name,
       ROUND(ts.bytes/1024/1024,0) AS total_mb,
       ROUND(NVL(fs.bytes,0)/1024/1024,0) AS free_mb,
       ROUND((1-NVL(fs.bytes,0)/ts.bytes)*100,1) AS use_pct
FROM (SELECT tablespace_name, SUM(bytes) bytes FROM dba_data_files GROUP BY tablespace_name) ts,
     (SELECT tablespace_name, SUM(bytes) bytes FROM dba_free_space GROUP BY tablespace_name) fs
WHERE ts.tablespace_name = fs.tablespace_name(+)
ORDER BY 4 DESC;

PROMPT ★ Redo Log 상태
SELECT GROUP#, STATUS, ARCHIVED, MEMBERS FROM V\\\$LOG;

PROMPT ★ 접속 세션 수
SELECT COUNT(*) AS active_sessions FROM V\\\$SESSION WHERE STATUS='ACTIVE' AND USERNAME IS NOT NULL;

PROMPT ★ Data Guard 동기화 상태
SELECT NAME, VALUE FROM V\\\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag');

PROMPT ★ Alert Log 최근 ORA- 에러 (최근 2시간)
SELECT TO_CHAR(ORIGINATING_TIMESTAMP,'YYYY-MM-DD HH24:MI:SS') AS ts,
       SUBSTR(MESSAGE_TEXT,1,100) AS message
FROM V\\\$DIAG_ALERT_EXT
WHERE MESSAGE_TEXT LIKE '%ORA-%'
  AND ORIGINATING_TIMESTAMP > SYSDATE - 2/24
ORDER BY ORIGINATING_TIMESTAMP DESC
FETCH FIRST 10 ROWS ONLY;

EXIT;
EOF
" 2>/dev/null)

echo "$ORACLE_CHECK" | tee -a "$LOG"

# STATUS 확인
if echo "$ORACLE_CHECK" | grep -q "OPEN"; then
    OK "DB STATUS = OPEN 확인"
else
    ERR "DB STATUS가 OPEN이 아님 - 확인 필요"
fi

# Tablespace 90% 이상 경고
if echo "$ORACLE_CHECK" | awk '/use_pct/{next} /^[A-Z]/{val=$NF+0; if(val>=90) print "경고: "$0}' | grep -q "경고"; then
    WARN "Tablespace 90% 이상 항목 있음 - DBA 확인 필요"
fi

# ORA- 에러 확인
ORA_COUNT=$(echo "$ORACLE_CHECK" | grep -c "ORA-" 2>/dev/null || echo 0)
[ "$ORA_COUNT" -gt 0 ] \
    && WARN "최근 2시간 내 ORA- 에러 ${ORA_COUNT}건 발견 - 상세 확인 필요" \
    || OK "최근 ORA- 에러 없음"

# ─── 완료 ────────────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo " Oracle 점검 완료: $(date)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo ""
echo "✅ check_oracle.sh 완료. 로그: $LOG"
