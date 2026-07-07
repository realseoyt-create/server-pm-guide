#!/bin/bash
# ============================================================
# start_services.sh - 서비스 순차 기동
# 대상: PJTSAP / PJTSEC (각 서버에서 개별 실행)
# 실행: root 계정
# 기동 순서: Oracle DB → Oracle Listener → RVD → Cron
# ============================================================

LOG=/tmp/start_services_$(date +%Y%m%d_%H%M%S).log

echo "================================================" | tee -a "$LOG"
echo " 서비스 기동 시작: $(date)" | tee -a "$LOG"
echo " 서버: $(hostname)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"

# ─── 유틸리티 함수 ───────────────────────────────────────────
OK()   { echo "✅ $*" | tee -a "$LOG"; }
WARN() { echo "⚠️  $*" | tee -a "$LOG"; }
ERR()  { echo "❌ $*" | tee -a "$LOG"; }
STEP() { echo "" | tee -a "$LOG"; echo "─── STEP $* ───" | tee -a "$LOG"; }

wait_proc_up() {
    PROC="$1"
    MAX="${2:-60}"
    WAIT=0
    while ! ps -ef | grep "$PROC" | grep -v grep > /dev/null 2>&1; do
        [ "$WAIT" -ge "$MAX" ] && ERR "$PROC 프로세스 ${MAX}초 내 기동 안됨" && return 1
        sleep 5; WAIT=$((WAIT+5))
        echo "  기동 대기 중... ${WAIT}초 ($PROC)" | tee -a "$LOG"
    done
    return 0
}

# ─── STEP 1: Oracle DB 기동 ──────────────────────────────────
STEP "1: Oracle DB 기동"

# DB가 이미 올라와있지 않은지 확인
if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    WARN "Oracle pmon 이미 실행 중. DB 기동 건너뜀."
else
    su - oracle -c "
sqlplus / as sysdba <<EOF
STARTUP;
EXIT;
EOF
" >> "$LOG" 2>&1

    wait_proc_up pmon 120 \
        && OK "Oracle pmon 기동 확인" \
        || { ERR "Oracle 기동 실패 - Alert Log 확인 필요"; exit 1; }
fi

# DB 상태 확인
DB_STATUS=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT STATUS FROM V\\\$INSTANCE;
EXIT;
EOF
" 2>/dev/null | tr -d ' ')

echo "  DB STATUS: $DB_STATUS" | tee -a "$LOG"
if [ "$DB_STATUS" = "OPEN" ]; then
    OK "Oracle DB OPEN 확인"
else
    ERR "Oracle DB 상태 이상: $DB_STATUS (OPEN 이어야 함)"
    exit 1
fi

# ─── STEP 2: Oracle Listener 기동 (포트 1621) ────────────────
STEP "2: Oracle Listener 기동 (포트 1621)"

su - oracle -c "lsnrctl start" >> "$LOG" 2>&1
sleep 5

# 포트 1621 오픈 확인
ss -tlnp | grep ":1621" > /dev/null 2>&1 \
    && OK "Oracle Listener 1621 포트 오픈 확인" \
    || { ERR "1621 포트 미오픈 - Listener 기동 실패"; exit 1; }

# ─── 핵심 확인: PJOSCD 서비스 등록 여부 ─────────────────────
echo "" | tee -a "$LOG"
echo "  [서비스 등록 확인: PJOSCD]" | tee -a "$LOG"
LISTENER_STATUS=$(su - oracle -c "lsnrctl status" 2>/dev/null)
echo "$LISTENER_STATUS" >> "$LOG"

if echo "$LISTENER_STATUS" | grep -q "PJOSCD"; then
    OK "PJOSCD 서비스 Listener 등록 확인"
else
    WARN "PJOSCD 서비스 Listener 미등록. ALTER SYSTEM REGISTER 시도..."
    su - oracle -c "
sqlplus / as sysdba <<EOF
ALTER SYSTEM REGISTER;
EXIT;
EOF
" >> "$LOG" 2>&1
    sleep 10
    su - oracle -c "lsnrctl reload" >> "$LOG" 2>&1
    sleep 5

    # 재확인
    su - oracle -c "lsnrctl status" 2>/dev/null | grep -q "PJOSCD" \
        && OK "PJOSCD 서비스 등록 완료 (ALTER SYSTEM REGISTER 후)" \
        || ERR "PJOSCD 서비스 등록 실패 - DBA 확인 필요"
fi

# ─── STEP 3: RVD 기동 ────────────────────────────────────────
STEP "3: RVD 기동"

# Oracle이 OPEN 상태인지 최종 확인 후 RVD 기동
DB_OPEN=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT OPEN_MODE FROM V\\\$DATABASE;
EXIT;
EOF
" 2>/dev/null | tr -d ' ')

if [ "$DB_OPEN" = "READWRITE" ]; then
    OK "Oracle READ WRITE 확인 → RVD 기동 진행"
else
    ERR "Oracle OPEN_MODE: $DB_OPEN (READ WRITE 아님) → RVD 기동 전 DB 확인 필요"
    exit 1
fi

# RVD 기동 (실제 스크립트/경로로 교체 필요)
# 방법 1: 전용 기동 스크립트가 있는 경우
# [RVD_START_SCRIPT] 경로 입력 후 주석 해제
# bash /[경로]/rvd_start.sh >> "$LOG" 2>&1

# 방법 2: 직접 기동 (경로/포트는 환경에 맞게 수정)
# /[RVD_HOME]/bin/rvd -listen tcp:7500 -logfile /var/log/rvd.log &

# ↓ 실제 RVD 기동 방법으로 교체하세요 ↓
echo "  [RVD 기동 - 실제 명령으로 교체 필요]" | tee -a "$LOG"
# bash /opt/tibco/rv/bin/rvd_start.sh >> "$LOG" 2>&1

sleep 5
ps -ef | grep rvd | grep -v grep > /dev/null 2>&1 \
    && OK "RVD 기동 확인" \
    || WARN "RVD 프로세스 미확인 - 기동 명령 확인 필요"

# ─── STEP 4: Cron 재활성화 ───────────────────────────────────
STEP "4: Cron 재활성화"

systemctl start crond >> "$LOG" 2>&1
sleep 2
systemctl is-active crond | grep -q "active" \
    && OK "crond 재활성화 확인" \
    || ERR "crond 기동 실패"

# Cron 내용 백업본과 비교
CRON_BAK=$(ls -t /tmp/crontab_backup_*.txt 2>/dev/null | head -1)
if [ -n "$CRON_BAK" ]; then
    # 현재 Cron 덤프
    CURRENT_CRON=/tmp/crontab_current_$(date +%H%M).txt
    for user in $(getent passwd | cut -d: -f1); do
        CRON=$(crontab -l -u "$user" 2>/dev/null)
        [ -n "$CRON" ] && echo "### $user ###" >> "$CURRENT_CRON" && echo "$CRON" >> "$CURRENT_CRON"
    done

    DIFF_RESULT=$(diff "$CRON_BAK" "$CURRENT_CRON" 2>/dev/null)
    if [ -z "$DIFF_RESULT" ]; then
        OK "Cron 내용 백업본과 일치 확인"
    else
        WARN "Cron 내용 차이 발견!"
        echo "$DIFF_RESULT" | tee -a "$LOG"
        echo "  → 백업 파일: $CRON_BAK" | tee -a "$LOG"
        echo "  → 현재 파일: $CURRENT_CRON" | tee -a "$LOG"
    fi
else
    WARN "Cron 백업 파일을 찾을 수 없음. 수동 확인 필요."
fi

# ─── 최종 확인 ───────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo " 서비스 기동 완료: $(date)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "[최종 프로세스 확인]" | tee -a "$LOG"
for PROC in pmon rvd crond; do
    COUNT=$(ps -ef | grep "$PROC" | grep -v grep | wc -l)
    [ "$COUNT" -gt 0 ] \
        && OK "[$PROC] 기동 확인 ($COUNT 개)" \
        || ERR "[$PROC] 미기동 - 확인 필요"
done

echo "" | tee -a "$LOG"
echo "[포트 확인]" | tee -a "$LOG"
for PORT in 1621; do
    ss -tlnp | grep ":$PORT" > /dev/null 2>&1 \
        && OK "포트 $PORT 오픈 확인" \
        || ERR "포트 $PORT 미오픈 - 확인 필요"
done

echo "" | tee -a "$LOG"
echo "[Oracle DB 최종 상태]" | tee -a "$LOG"
su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'STATUS: '||STATUS FROM V\\\$INSTANCE;
SELECT 'OPEN_MODE: '||OPEN_MODE FROM V\\\$DATABASE;
EXIT;
EOF
" 2>/dev/null | tee -a "$LOG"

echo ""
echo "✅ start_services.sh 완료"
echo "   로그 파일: $LOG"
