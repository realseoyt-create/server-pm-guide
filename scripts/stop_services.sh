#!/bin/bash
# ============================================================
# stop_services.sh - 서비스 순차 중지
# 대상: PJTSAP / PJTSEC (각 서버에서 개별 실행)
# 실행: root 계정
# 중지 순서: Cron → RVD → Oracle Listener → Oracle DB
# ============================================================

LOG=/tmp/stop_services_$(date +%Y%m%d_%H%M%S).log

echo "================================================" | tee -a "$LOG"
echo " 서비스 중지 시작: $(date)" | tee -a "$LOG"
echo " 서버: $(hostname)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"

# ─── 유틸리티 함수 ───────────────────────────────────────────
OK()   { echo "✅ $*" | tee -a "$LOG"; }
WARN() { echo "⚠️  $*" | tee -a "$LOG"; }
ERR()  { echo "❌ $*" | tee -a "$LOG"; }
STEP() { echo "" | tee -a "$LOG"; echo "─── STEP $* ───" | tee -a "$LOG"; }

wait_proc_gone() {
    PROC="$1"
    MAX=60
    WAIT=0
    while ps -ef | grep "$PROC" | grep -v grep > /dev/null 2>&1; do
        [ "$WAIT" -ge "$MAX" ] && WARN "$PROC 프로세스 ${MAX}초 내 중지 안됨" && return 1
        sleep 5; WAIT=$((WAIT+5))
        echo "  대기 중... ${WAIT}초 ($PROC)" | tee -a "$LOG"
    done
    return 0
}

# ─── STEP 1: Cron 중지 ───────────────────────────────────────
STEP "1: Cron 중지"

# 백업
CRON_BAK=/tmp/crontab_backup_$(date +%Y%m%d%H%M).txt
for user in $(getent passwd | cut -d: -f1); do
    CRON=$(crontab -l -u "$user" 2>/dev/null)
    if [ -n "$CRON" ]; then
        echo "### $user ###" >> "$CRON_BAK"
        echo "$CRON" >> "$CRON_BAK"
    fi
done
OK "Cron 백업 완료: $CRON_BAK"

# crond 중지
systemctl stop crond >> "$LOG" 2>&1
sleep 2
systemctl is-active crond | grep -q "inactive" \
    && OK "crond 중지 확인" \
    || WARN "crond 상태 확인 필요: $(systemctl is-active crond)"

# 실행 중인 배치 잔존 프로세스 확인
BATCH_PROCS=$(ps -ef | grep -E "batch|python|perl|sh /home" | grep -v grep | grep -v "$$")
if [ -n "$BATCH_PROCS" ]; then
    WARN "실행 중인 배치 프로세스 발견:"
    echo "$BATCH_PROCS" | tee -a "$LOG"
    echo "  → 배치 완료 대기 또는 확인 후 진행 결정 필요" | tee -a "$LOG"
fi

# ─── STEP 2: RVD 중지 ────────────────────────────────────────
STEP "2: RVD 중지"

RVD_PID=$(ps -ef | grep rvd | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$RVD_PID" ]; then
    echo "  RVD PID: $RVD_PID" | tee -a "$LOG"
    kill -TERM "$RVD_PID" >> "$LOG" 2>&1
    sleep 5

    if ps -ef | grep rvd | grep -v grep > /dev/null 2>&1; then
        WARN "RVD SIGTERM 후에도 실행 중. 강제 종료 시도..."
        kill -9 "$RVD_PID" >> "$LOG" 2>&1
        sleep 2
    fi

    wait_proc_gone rvd \
        && OK "RVD 중지 확인" \
        || ERR "RVD 강제 종료 실패 - 수동 확인 필요"
else
    OK "RVD 이미 중지 상태"
fi

# ─── STEP 3: Oracle Listener 중지 ────────────────────────────
STEP "3: Oracle Listener 중지 (포트 1621)"

su - oracle -c "lsnrctl stop" >> "$LOG" 2>&1

sleep 3
ss -tlnp | grep ":1621" > /dev/null 2>&1 \
    && WARN "1621 포트 아직 오픈. 추가 확인 필요" \
    || OK "Oracle Listener 1621 포트 닫힘 확인"

# ─── STEP 4: Oracle DB Shutdown ──────────────────────────────
STEP "4: Oracle DB Shutdown"

# 현재 접속 세션 수 확인
SESSION_COUNT=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM V\\\$SESSION WHERE USERNAME IS NOT NULL;
EXIT;
EOF
" 2>/dev/null | tr -d ' ')

echo "  현재 Oracle 세션 수: $SESSION_COUNT" | tee -a "$LOG"
if [ "$SESSION_COUNT" -gt 0 ] 2>/dev/null; then
    WARN "Oracle 세션 ${SESSION_COUNT}개 존재. SHUTDOWN IMMEDIATE로 진행."
fi

# DB Shutdown
su - oracle -c "
sqlplus / as sysdba <<EOF
SHUTDOWN IMMEDIATE;
EXIT;
EOF
" >> "$LOG" 2>&1

# 완전 중지 확인
sleep 10
wait_proc_gone pmon \
    && OK "Oracle 완전 중지 확인 (pmon 없음)" \
    || ERR "Oracle pmon 프로세스 잔존 - 수동 확인 필요"

# ─── 최종 확인 ───────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo " 서비스 중지 완료: $(date)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "[최종 프로세스 확인]" | tee -a "$LOG"
for PROC in pmon rvd crond; do
    COUNT=$(ps -ef | grep "$PROC" | grep -v grep | wc -l)
    [ "$COUNT" -eq 0 ] \
        && OK "[$PROC] 중지 확인" \
        || ERR "[$PROC] 아직 실행 중 ($COUNT 개) - 확인 필요"
done

echo "" | tee -a "$LOG"
echo "[포트 확인]" | tee -a "$LOG"
for PORT in 1621 7500; do
    ss -tlnp | grep ":$PORT" > /dev/null 2>&1 \
        && WARN "포트 $PORT 아직 열려있음" \
        || OK "포트 $PORT 닫힘 확인"
done

echo ""
echo "✅ stop_services.sh 완료"
echo "   로그 파일: $LOG"
echo "   Cron 백업: $CRON_BAK"
