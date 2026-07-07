#!/bin/bash
# ============================================================
# start_services_example.sh
# 서비스 기동 예시 스크립트 (한 줄씩 설명 포함)
#
# 대상 서버: PJTSAP / PJTSEC (각 서버에서 개별 실행)
# 실행 계정: root
# 실행 방법: bash start_services_example.sh
#
# 기동 순서: Oracle DB → Listener → (PJOSCD 등록 확인) → RVD → Cron
#
# ※ 기동 순서가 매우 중요합니다.
#    Oracle 없이 RVD 먼저 올리면 DB 접속 오류 발생.
# ============================================================

LOG=/tmp/start_$(date +%Y%m%d_%H%M%S).log
echo "=== 기동 시작: $(date) ===" | tee "$LOG"

# ─── STEP 1: Oracle DB 기동 ──────────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 1] Oracle DB 기동" | tee -a "$LOG"

# Oracle이 이미 기동 중인지 확인 (이중 기동 방지)
# pmon 프로세스가 있으면 Oracle이 이미 실행 중
if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    echo "⚠️ Oracle pmon 이미 실행 중. DB 기동 건너뜀." | tee -a "$LOG"
else
    # sqlplus -S: Silent 모드 (불필요한 배너 메시지 숨김)
    # STARTUP: Oracle DB를 기동하는 SQL 명령
    #   - STARTUP = mount + open 을 한 번에
    #   - STARTUP MOUNT: 데이터파일 열지 않고 마운트만
    #   - STARTUP NOMOUNT: 인스턴스만 기동 (복구 시 사용)
    su - oracle -c "
sqlplus / as sysdba <<EOF
STARTUP;
EXIT;
EOF
" >> "$LOG" 2>&1

    # pmon이 뜰 때까지 최대 120초 대기
    WAIT=0
    until ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; do
        # until: 조건이 참이 될 때까지 반복 (while과 반대)
        sleep 5
        WAIT=$((WAIT + 5))  # 산술 연산: WAIT = WAIT + 5
        [ "$WAIT" -ge 120 ] && echo "❌ Oracle 120초 내 미기동" | tee -a "$LOG" && exit 1
        echo "  기동 대기 중... ${WAIT}초" | tee -a "$LOG"
    done

    echo "✅ Oracle pmon 기동 확인" | tee -a "$LOG"
fi

# DB STATUS 확인: OPEN 이어야 정상
# sqlplus -S: 배너 없이 조용히 실행
# SET HEADING OFF FEEDBACK OFF PAGESIZE 0: 헤더/행수/페이지 표시 없애기 (순수 값만 출력)
DB_STATUS=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT STATUS FROM V\\\$INSTANCE;
EXIT;
EOF
" 2>/dev/null | tr -d ' \n')  # tr -d ' \n': 공백과 줄바꿈 제거

echo "DB STATUS: [$DB_STATUS]" | tee -a "$LOG"
if [ "$DB_STATUS" = "OPEN" ]; then
    echo "✅ Oracle DB OPEN 확인" | tee -a "$LOG"
else
    echo "❌ DB STATUS가 OPEN이 아님: $DB_STATUS" | tee -a "$LOG"
    echo "   Alert Log 확인 필요: \$ORACLE_BASE/diag/rdbms/*/*/trace/alert_*.log" | tee -a "$LOG"
    exit 1  # 비정상이면 스크립트 중단 (이후 단계 실행하지 않음)
fi

# ─── STEP 2: Oracle Listener 기동 (포트 1621) ────────────────

echo "" | tee -a "$LOG"
echo "[STEP 2] Oracle Listener 기동" | tee -a "$LOG"

# lsnrctl start: Oracle Net Listener 기동
# Listener가 있어야 외부에서 Oracle에 접속 가능
# 이 서버는 표준 포트(1521)가 아닌 1621을 사용
su - oracle -c "lsnrctl start" >> "$LOG" 2>&1

sleep 5  # Listener 완전 기동까지 대기

# 포트 1621이 열렸는지 확인
ss -tlnp | grep ":1621" > /dev/null 2>&1 \
    && echo "✅ Oracle Listener 1621 포트 오픈 확인" | tee -a "$LOG" \
    || { echo "❌ 1621 포트 미오픈 - Listener 기동 실패" | tee -a "$LOG"; exit 1; }
# { 명령1; 명령2; }: 여러 명령을 한 블록으로 묶기

# ─── STEP 3: PJOSCD 서비스 등록 확인 (핵심!) ─────────────────

echo "" | tee -a "$LOG"
echo "[STEP 3] PJOSCD 서비스 Listener 등록 확인 (핵심)" | tee -a "$LOG"

# lsnrctl status: Listener 상태와 등록된 서비스 목록 출력
# grep -q: 조용히 검색 (찾으면 성공, 못 찾으면 실패 - 화면 출력 없음)
LISTENER_OUT=$(su - oracle -c "lsnrctl status" 2>/dev/null)
echo "$LISTENER_OUT" >> "$LOG"

if echo "$LISTENER_OUT" | grep -q "PJOSCD"; then
    echo "✅ PJOSCD 서비스 Listener 등록 확인" | tee -a "$LOG"
else
    # 서비스가 자동 등록 안 됐을 때 수동으로 등록시키는 방법
    echo "⚠️ PJOSCD 미등록 → ALTER SYSTEM REGISTER 실행" | tee -a "$LOG"

    # ALTER SYSTEM REGISTER: Oracle에게 Listener에 서비스 등록하라고 명령
    su - oracle -c "
sqlplus / as sysdba <<EOF
ALTER SYSTEM REGISTER;
EXIT;
EOF
" >> "$LOG" 2>&1

    sleep 10  # 등록 반영 대기

    # lsnrctl reload: Listener가 DB 정보를 다시 읽어오게 강제 새로고침
    su - oracle -c "lsnrctl reload" >> "$LOG" 2>&1
    sleep 5

    # 재확인
    su - oracle -c "lsnrctl status" 2>/dev/null | grep -q "PJOSCD" \
        && echo "✅ PJOSCD 등록 완료 (수동 등록 성공)" | tee -a "$LOG" \
        || echo "❌ PJOSCD 등록 실패 - DBA 확인 필요" | tee -a "$LOG"
fi

# ─── STEP 4: RVD 기동 ────────────────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 4] RVD 기동 (Oracle 기동 확인 후 진행)" | tee -a "$LOG"

# Oracle이 READ WRITE 상태인지 최종 확인
# RVD가 Oracle에 접속해야 하므로 Oracle이 완전히 열려있어야 함
DB_OPEN=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT OPEN_MODE FROM V\\\$DATABASE;
EXIT;
EOF
" 2>/dev/null | tr -d ' \n')

if [ "$DB_OPEN" = "READWRITE" ]; then
    echo "✅ Oracle READ WRITE 확인 → RVD 기동 진행" | tee -a "$LOG"
else
    echo "❌ Oracle OPEN_MODE: $DB_OPEN (READ WRITE 아님)" | tee -a "$LOG"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# 아래 두 줄 중 하나를 선택하여 주석 해제(# 제거)
# ─────────────────────────────────────────────────────────────

# [방법 A] RVD 전용 기동 스크립트가 있는 경우 (권장)
# bash /실제경로/rvd_start.sh >> "$LOG" 2>&1

# [방법 B] 직접 RVD 데몬 실행
# /[RVD_HOME]/bin/rvd \          # rvd 실행 파일 경로
#     -listen tcp:7500 \          # 리스닝 포트 (환경에 맞게 수정)
#     -logfile /var/log/rvd.log & # 로그 파일 경로, &: 백그라운드 실행
# ─────────────────────────────────────────────────────────────
echo "  [주의] RVD 기동 명령을 실제 환경에 맞게 위 방법 A 또는 B로 교체하세요" | tee -a "$LOG"

sleep 5

# RVD 기동 확인
ps -ef | grep rvd | grep -v grep > /dev/null 2>&1 \
    && echo "✅ RVD 기동 확인" | tee -a "$LOG" \
    || echo "⚠️ RVD 프로세스 미확인 - 기동 명령 확인 필요" | tee -a "$LOG"

# ─── STEP 5: Cron 재활성화 ───────────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 5] Cron 재활성화" | tee -a "$LOG"

# systemctl start crond: crond 서비스 기동
systemctl start crond
sleep 2

systemctl is-active crond | grep -q "active" \
    && echo "✅ crond 기동 확인" | tee -a "$LOG" \
    || echo "❌ crond 기동 실패" | tee -a "$LOG"

# ─── STEP 6: Cron 내용 백업본과 대조 ────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 6] Cron 내용 백업본과 대조 확인" | tee -a "$LOG"

# 가장 최근에 만든 crontab 백업 파일 찾기
# ls -t: 수정 시간 기준 최신 순으로 정렬
# head -1: 첫 번째(최신) 파일
CRON_BAK=$(ls -t /tmp/crontab_backup_*.txt 2>/dev/null | head -1)

if [ -n "$CRON_BAK" ]; then
    # 현재 Cron 상태를 임시 파일에 저장
    CURRENT=/tmp/crontab_now.txt
    for user in $(getent passwd | cut -d: -f1); do
        CRON=$(crontab -l -u "$user" 2>/dev/null)
        [ -n "$CRON" ] && echo "### $user ###" >> "$CURRENT" && echo "$CRON" >> "$CURRENT"
    done

    # diff: 두 파일을 비교해서 다른 부분 출력
    # diff가 아무것도 출력 안하면(비어있으면) = 두 파일이 동일
    DIFF=$(diff "$CRON_BAK" "$CURRENT" 2>/dev/null)
    if [ -z "$DIFF" ]; then
        # -z: 변수가 비어있으면(empty) true
        echo "✅ Cron 내용 이상 없음 (백업본과 동일)" | tee -a "$LOG"
    else
        echo "❌ Cron 내용 차이 발견!" | tee -a "$LOG"
        echo "$DIFF" | tee -a "$LOG"
        # < 로 시작: 백업에는 있었는데 지금 없음 (누락됨!)
        # > 로 시작: 지금은 있는데 백업에 없었음 (새로 추가됨)
    fi
else
    echo "⚠️ Cron 백업 파일 없음. 수동으로 crontab -l 확인 필요." | tee -a "$LOG"
fi

# ─── 최종 확인 ───────────────────────────────────────────────

echo "" | tee -a "$LOG"
echo "=== 기동 완료 최종 확인 ===" | tee -a "$LOG"

# 프로세스 확인
for PROC in pmon rvd crond; do
    COUNT=$(ps -ef | grep "$PROC" | grep -v grep | wc -l | tr -d ' ')
    if [ "$COUNT" -gt 0 ]; then
        echo "✅ [$PROC] 기동 확인 ($COUNT개)" | tee -a "$LOG"
    else
        echo "❌ [$PROC] 미기동 - 확인 필요" | tee -a "$LOG"
    fi
done

# 포트 확인
echo "" | tee -a "$LOG"
for PORT in 1621; do
    ss -tlnp | grep ":$PORT" > /dev/null 2>&1 \
        && echo "✅ 포트 $PORT 오픈 확인" | tee -a "$LOG" \
        || echo "❌ 포트 $PORT 미오픈" | tee -a "$LOG"
done

echo "" | tee -a "$LOG"
echo "=== 기동 완료: $(date) ===" | tee -a "$LOG"
echo "로그 파일: $LOG"

# ─────────────────────────────────────────────────────────────
# [수정 가이드]
# ─────────────────────────────────────────────────────────────
# Q: RVD 기동 명령이 어디 있는지 모른다면?
# A: 터미널에서 아래 명령으로 찾기:
#    find / -maxdepth 6 -name "rvd" -o -name "rvd_start.sh" 2>/dev/null
#
# Q: ORACLE_HOME 경로를 확인하고 싶다면?
# A: oracle 계정으로 접속 후 'echo $ORACLE_HOME' 실행
#
# Q: DB 기동 시간이 오래 걸려서 120초 대기가 부족하다면?
# A: STEP 1의 [ "$WAIT" -ge 120 ] 에서 120을 더 큰 값으로 변경
#    예: [ "$WAIT" -ge 300 ]  → 300초(5분)까지 대기
#
# Q: 기동 순서에 추가 서비스를 넣고 싶다면?
# A: STEP 4 이후에 동일한 패턴으로 추가:
#    echo "[STEP X] 서비스명 기동"
#    명령어 실행
#    확인 명령어
# ─────────────────────────────────────────────────────────────
