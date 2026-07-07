#!/bin/bash
# ============================================================
# dry_run_check.sh
# 양산 영향 없이 스크립트 사전 동작 검증
#
# 목적: 실제 작업 전, 자동화 스크립트(stop/start/check)가
#       이 서버에서 정상 동작할지 미리 검증한다.
#
# 이 스크립트는 아무것도 중지/기동/변경하지 않는다.
# 읽기 전용 명령만 사용하며 양산에 영향을 주지 않는다.
#
# 실행 방법: bash dry_run_check.sh
# 출력 파일: /tmp/dry_run_report_YYYYMMDD.txt
# ============================================================

REPORT=/tmp/dry_run_report_$(date +%Y%m%d_%H%M%S).txt
OK=0
WARN=0
FAIL=0

# ─────────────────────────────────────────────────────────────
# 출력 함수 정의
# ─────────────────────────────────────────────────────────────

ok()   { echo "  ✅ $*" | tee -a "$REPORT"; OK=$((OK+1)); }
warn() { echo "  ⚠️  $*" | tee -a "$REPORT"; WARN=$((WARN+1)); }
fail() { echo "  ❌ $*" | tee -a "$REPORT"; FAIL=$((FAIL+1)); }
section() { echo "" | tee -a "$REPORT"; echo "━━━ $* ━━━" | tee -a "$REPORT"; }

# ─────────────────────────────────────────────────────────────

echo "============================================================" | tee "$REPORT"
echo " DRY RUN CHECK - $(date)" | tee -a "$REPORT"
echo " 실제 서비스 중지/기동 없음. 읽기 전용 검증." | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"

# ─── 1. 기본 명령어 존재 여부 ────────────────────────────────

section "1. 필수 명령어 존재 여부"

for CMD in ps grep awk wc systemctl ss ip diff tee date getent crontab; do
    if command -v "$CMD" > /dev/null 2>&1; then
        ok "$CMD 명령어 확인"
    else
        fail "$CMD 명령어 없음 - 스크립트 동작 불가"
    fi
done

# kill 명령어는 stop_services.sh에서 사용
if command -v kill > /dev/null 2>&1; then
    ok "kill 명령어 확인"
else
    fail "kill 명령어 없음"
fi

# ─── 2. Oracle 환경 변수 및 실행 파일 ────────────────────────

section "2. Oracle 환경 설정"

# oracle 계정 존재 여부
if id oracle > /dev/null 2>&1; then
    ok "oracle 계정 존재"
else
    fail "oracle 계정 없음 - su - oracle 실행 불가"
fi

# oracle 계정으로 ORACLE_HOME 확인 (변경 없는 읽기 전용)
ORACLE_HOME_VAL=$(su - oracle -c "echo \$ORACLE_HOME" 2>/dev/null)
if [ -n "$ORACLE_HOME_VAL" ] && [ -d "$ORACLE_HOME_VAL" ]; then
    ok "ORACLE_HOME 설정됨: $ORACLE_HOME_VAL"
else
    fail "ORACLE_HOME 미설정 또는 경로 없음: [$ORACLE_HOME_VAL]"
fi

# ORACLE_SID 확인
ORACLE_SID_VAL=$(su - oracle -c "echo \$ORACLE_SID" 2>/dev/null)
if [ -n "$ORACLE_SID_VAL" ]; then
    ok "ORACLE_SID 설정됨: $ORACLE_SID_VAL"
else
    warn "ORACLE_SID 미설정 (환경에 따라 필요 없을 수 있음)"
fi

# sqlplus 실행 파일 확인
SQLPLUS=$(su - oracle -c "which sqlplus" 2>/dev/null)
if [ -n "$SQLPLUS" ]; then
    ok "sqlplus 위치: $SQLPLUS"
else
    fail "sqlplus 없음 - Oracle DB 기동/중지 명령 실행 불가"
fi

# lsnrctl 실행 파일 확인
LSNRCTL=$(su - oracle -c "which lsnrctl" 2>/dev/null)
if [ -n "$LSNRCTL" ]; then
    ok "lsnrctl 위치: $LSNRCTL"
else
    fail "lsnrctl 없음 - Listener 제어 불가"
fi

# ─── 3. Oracle 현재 상태 확인 ────────────────────────────────

section "3. Oracle 현재 상태 (읽기 전용)"

# pmon 프로세스 존재 여부 (변경 없음)
if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    PMON_LINE=$(ps -ef | grep pmon | grep -v grep | head -1)
    ok "Oracle pmon 실행 중: $PMON_LINE"

    # sqlplus 접속 테스트 (읽기 전용 쿼리)
    DB_STATUS=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT STATUS FROM V\\\$INSTANCE;
EXIT;
EOF
" 2>/dev/null | tr -d ' \n')

    if [ "$DB_STATUS" = "OPEN" ]; then
        ok "Oracle STATUS = OPEN (정상)"
    elif [ -n "$DB_STATUS" ]; then
        warn "Oracle STATUS = $DB_STATUS (OPEN이 아님)"
    else
        fail "Oracle sqlplus 접속 실패 (/ as sysdba OS 인증 안됨)"
    fi

    # OPEN_MODE 확인 (READ WRITE여야 정상)
    OPEN_MODE=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT OPEN_MODE FROM V\\\$DATABASE;
EXIT;
EOF
" 2>/dev/null | tr -d ' \n')
    ok "Oracle OPEN_MODE = $OPEN_MODE"

else
    warn "Oracle pmon 없음 (현재 DB 중지 상태 - 스크립트 기동 테스트 불가)"
fi

# 포트 1621 확인 (이 서버는 표준 1521이 아닌 1621 사용)
if ss -tlnp | grep ":1621" > /dev/null 2>&1; then
    ok "포트 1621 LISTEN 중 (Listener 기동 상태)"
else
    warn "포트 1621 미오픈 (Listener 중지 상태 또는 DB 중지 중)"
fi

# lsnrctl status 테스트 (읽기 전용)
LISTENER_STATUS=$(su - oracle -c "lsnrctl status" 2>/dev/null)
if [ -n "$LISTENER_STATUS" ]; then
    ok "lsnrctl status 실행 가능"

    # PJOSCD 서비스 등록 여부 확인
    if echo "$LISTENER_STATUS" | grep -q "PJOSCD"; then
        ok "PJOSCD 서비스 Listener에 등록됨"
    else
        warn "PJOSCD 서비스 Listener 미등록 (DB가 기동 상태라면 ALTER SYSTEM REGISTER 필요)"
    fi
else
    warn "lsnrctl status 실행 실패 (oracle 계정 권한 또는 Listener 경로 확인)"
fi

# ─── 4. systemctl 권한 확인 ──────────────────────────────────

section "4. systemctl 권한 (crond 제어)"

# crond 서비스 상태 확인 (읽기 전용 - stop/start 아님)
if systemctl is-active crond > /dev/null 2>&1; then
    ok "crond 현재 active 상태"
else
    warn "crond 현재 inactive 상태"
fi

# systemctl status는 권한 필요 없이 가능 - stop/start는 root 필요
if [ "$(id -u)" -eq 0 ]; then
    ok "실행 계정: root (systemctl stop/start crond 가능)"
else
    CURRENT_USER=$(id -un)
    fail "실행 계정: $CURRENT_USER (root 아님 - systemctl stop/start 실패 가능)"
fi

# ─── 5. RVD 환경 확인 ────────────────────────────────────────

section "5. RVD 환경"

# RVD 프로세스 확인
RVD_PID=$(ps -ef | grep rvd | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$RVD_PID" ]; then
    RVD_LINE=$(ps -ef | grep rvd | grep -v grep | head -1)
    ok "RVD 현재 실행 중 (PID: $RVD_PID)"
    echo "     $RVD_LINE" | tee -a "$REPORT"

    # RVD 실행 파일 경로 추출
    RVD_BIN=$(ps -ef | grep rvd | grep -v grep | awk '{print $8}' | head -1)
    if [ -n "$RVD_BIN" ] && [ -f "$RVD_BIN" ]; then
        ok "RVD 실행 파일 위치 확인: $RVD_BIN"
        echo "     → start_services.sh STEP 4의 RVD 기동 명령에 이 경로 입력 필요" | tee -a "$REPORT"
    fi
else
    warn "RVD 현재 중지 상태 (실행 파일 경로를 사전에 파악해야 함)"
    echo "     → 찾는 방법: find / -maxdepth 8 -name \"rvd\" 2>/dev/null" | tee -a "$REPORT"
fi

# RVD 포트 확인 (기본값 7500, 환경마다 다를 수 있음)
if ss -tlnp | grep ":7500" > /dev/null 2>&1; then
    ok "RVD 포트 7500 LISTEN 중"
else
    # 다른 포트 시도
    RVD_PORT=$(ss -tlnp 2>/dev/null | grep -i rvd | awk '{print $4}' | cut -d: -f2 | head -1)
    if [ -n "$RVD_PORT" ]; then
        warn "RVD 포트 7500 미사용. 실제 포트: $RVD_PORT"
    else
        warn "RVD 포트 확인 불가 (RVD 미실행이거나 포트를 알 수 없음)"
    fi
fi

# ─── 6. Cron 백업/비교 기능 테스트 ──────────────────────────

section "6. Cron 백업/비교 기능 사전 검증"

# getent passwd 실행 가능 여부
if getent passwd > /dev/null 2>&1; then
    ACCOUNT_COUNT=$(getent passwd | wc -l | tr -d ' ')
    ok "getent passwd 실행 가능 (계정 수: $ACCOUNT_COUNT)"
else
    fail "getent passwd 실패"
fi

# root 계정 Cron 읽기 테스트
ROOT_CRON=$(crontab -l 2>/dev/null)
if [ -n "$ROOT_CRON" ]; then
    ok "root crontab 읽기 가능 (등록 있음)"
else
    ok "root crontab 읽기 가능 (등록 없음)"
fi

# /tmp 쓰기 테스트 (로그 파일/백업 파일 저장 경로)
TEST_FILE=/tmp/dry_run_write_test_$$
if echo "test" > "$TEST_FILE" 2>/dev/null; then
    ok "/tmp 쓰기 가능 (로그/백업 파일 저장 경로 정상)"
    rm -f "$TEST_FILE"
else
    fail "/tmp 쓰기 불가 - 스크립트 로그 저장 실패"
fi

# diff 명령어 동작 테스트
echo "aaa" > /tmp/_drytest_a_$$ && echo "bbb" > /tmp/_drytest_b_$$
DIFF_RESULT=$(diff /tmp/_drytest_a_$$ /tmp/_drytest_b_$$ 2>/dev/null)
if [ -n "$DIFF_RESULT" ]; then
    ok "diff 명령어 정상 동작 (Cron 전후 비교 기능 사용 가능)"
else
    fail "diff 명령어 동작 이상"
fi
rm -f /tmp/_drytest_a_$$ /tmp/_drytest_b_$$

# ─── 7. VIP / 네트워크 확인 ──────────────────────────────────

section "7. VIP / 네트워크 (읽기 전용)"

# ip 명령어 확인
if command -v ip > /dev/null 2>&1; then
    ok "ip 명령어 사용 가능"

    # PJTSAP VIP: 12.230.210.207 / PJTSEC VIP: 12.230.210.203
    for VIP in "12.230.210.207" "12.230.210.203"; do
        if ip addr show | grep -q "$VIP"; then
            ok "VIP $VIP 이 이 서버에 있음"
        else
            ok "VIP $VIP 이 이 서버에 없음 (다른 노드에 있음 - 정상)"
        fi
    done

    # 현재 서버의 IP 목록 표시
    echo "  현재 서버 IP 목록:" | tee -a "$REPORT"
    ip addr show | grep "inet " | awk '{print "    -", $2}' | tee -a "$REPORT"
else
    warn "ip 명령어 없음 - VIP 확인 불가"
fi

# ping 없이 연결 가능 여부 (ss로 대체)
ok "VIP 상태 확인은 ip addr show 명령으로 가능 (post_compare.sh에서 사용)"

# ─── 8. snapshot 저장 경로 테스트 ────────────────────────────

section "8. pre_snapshot.sh 동작 사전 검증"

SNAP_DIR=/tmp/snapshot_before
if mkdir -p "$SNAP_DIR" 2>/dev/null; then
    ok "snapshot 저장 경로 생성 가능: $SNAP_DIR"
else
    fail "snapshot 저장 경로 생성 불가: $SNAP_DIR"
fi

# 디스크 사용률 확인 명령어 테스트
if df -h > /dev/null 2>&1; then
    ok "df -h 명령어 실행 가능 (디스크 스냅샷 기능 정상)"
fi

# 메모리 확인
if free -m > /dev/null 2>&1; then
    ok "free -m 명령어 실행 가능 (메모리 스냅샷 기능 정상)"
fi

# ─── 9. DB 동기화(DataGuard) 확인 ────────────────────────────

section "9. Oracle DataGuard (MRP) 확인 - 읽기 전용"

if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    MRP_COUNT=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM V\\\$MANAGED_STANDBY WHERE PROCESS='MRP0';
EXIT;
EOF
" 2>/dev/null | tr -d ' \n')

    if [ "$MRP_COUNT" = "1" ]; then
        ok "MRP0 프로세스 확인 (DataGuard 동기화 중)"
        echo "     → stop_services 전 MRP 중지 필요" | tee -a "$REPORT"
    elif [ "$MRP_COUNT" = "0" ]; then
        warn "MRP0 없음 (DataGuard 동기화 중지 상태이거나 Primary 서버)"
    else
        warn "MRP0 상태 확인 불가 (DataGuard 미사용 환경일 수 있음)"
    fi
else
    warn "Oracle 미기동 - DataGuard 상태 확인 불가"
fi

# ─── 최종 요약 ───────────────────────────────────────────────

echo "" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
echo " 검증 결과 요약" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
echo "  ✅ 정상: $OK 항목" | tee -a "$REPORT"
echo "  ⚠️  경고: $WARN 항목  (확인 필요하지만 실행 가능)" | tee -a "$REPORT"
echo "  ❌ 실패: $FAIL 항목  (작업 전 반드시 해결)" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo "  → 판정: 🟢 모든 항목 정상. 스크립트 실행 준비 완료." | tee -a "$REPORT"
elif [ "$FAIL" -eq 0 ]; then
    echo "  → 판정: 🟡 경고 $WARN 건. 확인 후 진행 가능." | tee -a "$REPORT"
    echo "     경고 항목은 환경에 따라 정상일 수 있습니다." | tee -a "$REPORT"
else
    echo "  → 판정: 🔴 실패 $FAIL 건. 작업 전 반드시 해결 필요." | tee -a "$REPORT"
fi

echo "" | tee -a "$REPORT"
echo "  리포트 저장 경로: $REPORT" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"

# 경고/실패 항목이 있을 때 해결 힌트 출력
if [ "$FAIL" -gt 0 ]; then
    echo "" | tee -a "$REPORT"
    echo "[자주 발생하는 실패 항목 해결 방법]" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"
    echo "❌ 'oracle 계정 없음' → Oracle이 설치된 서버에서 실행하는지 확인" | tee -a "$REPORT"
    echo "❌ 'root 아님' → sudo -i 또는 root로 전환 후 재실행" | tee -a "$REPORT"
    echo "❌ 'sqlplus 없음' → oracle 계정 .bash_profile에 PATH 설정 확인" | tee -a "$REPORT"
    echo "❌ '/tmp 쓰기 불가' → df -h /tmp 로 공간 확인, 또는 chmod /tmp" | tee -a "$REPORT"
fi
