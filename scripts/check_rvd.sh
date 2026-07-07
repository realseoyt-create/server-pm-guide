#!/bin/bash
# ============================================================
# check_rvd.sh - RVD (TIBCO Rendezvous Daemon) 상태 점검
# 실행: root 계정
# ============================================================

LOG=/tmp/check_rvd_$(date +%Y%m%d_%H%M%S).log

echo "================================================" | tee "$LOG"
echo " RVD 상태 점검: $(date)" | tee -a "$LOG"
echo " 서버: $(hostname)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"

OK()   { echo "✅ $*" | tee -a "$LOG"; }
WARN() { echo "⚠️  $*" | tee -a "$LOG"; }
ERR()  { echo "❌ $*" | tee -a "$LOG"; }

# ─── 1. RVD 프로세스 확인 ────────────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 1. RVD 프로세스 ───" | tee -a "$LOG"
RVD_PROCS=$(ps -ef | grep rvd | grep -v grep)
if [ -n "$RVD_PROCS" ]; then
    OK "RVD 프로세스 실행 중"
    echo "$RVD_PROCS" | tee -a "$LOG"
    RVD_PID=$(echo "$RVD_PROCS" | awk '{print $2}' | head -1)
    RVD_START=$(ps -ef | grep rvd | grep -v grep | awk '{print $5}')
    echo "  PID: $RVD_PID, 시작 시각: $RVD_START" | tee -a "$LOG"
else
    ERR "RVD 프로세스 없음"
fi

# ─── 2. RVD 포트 확인 ────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 2. RVD 포트 확인 ───" | tee -a "$LOG"
# RVD 포트는 기본 7500이나 실제 환경에 따라 다를 수 있음
RVD_PORT=$(ps -ef | grep rvd | grep -v grep | grep -oP 'tcp:\K[0-9]+' | head -1)
RVD_PORT=${RVD_PORT:-7500}
echo "  확인 포트: $RVD_PORT" | tee -a "$LOG"

ss -tlnp | grep ":$RVD_PORT" > /dev/null 2>&1 \
    && OK "RVD 포트 $RVD_PORT 오픈 확인" \
    || WARN "RVD 포트 $RVD_PORT 미확인 (UDP 포트일 수 있음)"

# UDP 확인도 시도
ss -ulnp | grep ":$RVD_PORT" > /dev/null 2>&1 \
    && OK "RVD UDP 포트 $RVD_PORT 확인" \
    || true

# ─── 3. RVD 로그 확인 ────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 3. RVD 로그 (최근 에러) ───" | tee -a "$LOG"
RVD_LOG=$(find /var/log /opt/tibco -name "rvd*.log" 2>/dev/null | head -1)
if [ -n "$RVD_LOG" ]; then
    echo "  로그 파일: $RVD_LOG" | tee -a "$LOG"
    ERRORS=$(grep -i "error\|fail\|disconnect\|fatal" "$RVD_LOG" 2>/dev/null | tail -10)
    if [ -n "$ERRORS" ]; then
        WARN "RVD 로그에 오류 발견:"
        echo "$ERRORS" | tee -a "$LOG"
    else
        OK "RVD 로그 이상 없음"
    fi
else
    WARN "RVD 로그 파일을 찾을 수 없음. 위치 수동 확인 필요."
fi

# ─── 4. Oracle DB 연결 전제 확인 ─────────────────────────────
echo "" | tee -a "$LOG"
echo "─── 4. Oracle DB 연결 전제 확인 ───" | tee -a "$LOG"
# RVD가 Oracle에 연결하는 구조라면 Oracle이 먼저 올라와야 함
ps -ef | grep pmon | grep -v grep > /dev/null 2>&1 \
    && OK "Oracle pmon 확인 (RVD 의존성 충족)" \
    || WARN "Oracle pmon 없음 - RVD Oracle 연결 실패 가능"

ss -tlnp | grep ":1621" > /dev/null 2>&1 \
    && OK "Oracle 1621 포트 오픈 확인" \
    || ERR "Oracle 1621 포트 없음 - RVD DB 접속 불가"

# ─── 완료 ────────────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo " RVD 점검 완료: $(date)" | tee -a "$LOG"
echo "================================================" | tee -a "$LOG"
echo ""
echo "✅ check_rvd.sh 완료. 로그: $LOG"
