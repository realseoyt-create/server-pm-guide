#!/bin/bash
# ============================================================
# stop_services_example.sh
# 서비스 중지 예시 스크립트 (한 줄씩 설명 포함)
#
# 대상 서버: PJTSAP / PJTSEC (각 서버에서 개별 실행)
# 실행 계정: root
# 실행 방법: bash stop_services_example.sh
#
# ※ 이 파일은 각 명령어가 무엇인지 설명하기 위한 예시입니다.
#    실제 운영 시에는 stop_services.sh 를 사용하세요.
# ============================================================

# ─────────────────────────────────────────────────────────────
# [기초 지식] 이 스크립트에서 자주 쓰는 문법 설명
# ─────────────────────────────────────────────────────────────
#
# echo "텍스트"          → 화면에 텍스트 출력
# $( 명령어 )           → 명령어 실행 결과를 변수에 저장
# | grep "단어"         → 앞 명령어 결과에서 "단어"가 포함된 줄만 필터
# | grep -v "단어"      → "단어"가 포함된 줄을 제외하고 출력
# | wc -l              → 줄 수(개수) 세기
# | awk '{print $2}'   → 공백으로 구분된 2번째 컬럼 출력
# 2>/dev/null           → 오류 메시지를 화면에 표시하지 않음
# && echo "성공"         → 앞 명령어가 성공하면 "성공" 출력
# || echo "실패"         → 앞 명령어가 실패하면 "실패" 출력
# sleep 5              → 5초 대기
# -n "$변수"            → 변수가 비어있지 않으면 true
#
# ─────────────────────────────────────────────────────────────

# ─── 로그 파일 설정 ───────────────────────────────────────────

# date +%Y%m%d_%H%M%S → 현재 날짜시간 (예: 20250713_130000)
LOG=/tmp/stop_$(date +%Y%m%d_%H%M%S).log

# tee 명령어: 화면에도 출력하면서 파일에도 저장
echo "=== 중지 시작: $(date) ===" | tee "$LOG"

# ─── STEP 1: Cron 백업 ───────────────────────────────────────

echo "" | tee -a "$LOG"  # -a: 기존 파일에 추가(append)
echo "[STEP 1] Cron 백업" | tee -a "$LOG"

# getent passwd: 서버에 있는 모든 계정 목록 조회
# cut -d: -f1: ':'로 구분해서 1번째 컬럼(계정명)만 추출
# for user in ...: 각 계정마다 반복 실행
CRON_BAK=/tmp/crontab_backup_$(date +%Y%m%d%H%M).txt

for user in $(getent passwd | cut -d: -f1); do
    # crontab -l -u $user: 해당 계정의 crontab 내용 출력
    # 2>/dev/null: "crontab이 없습니다" 오류 메시지 숨김
    CRON=$(crontab -l -u "$user" 2>/dev/null)

    # -n "$CRON": Cron 내용이 비어있지 않으면 저장
    if [ -n "$CRON" ]; then
        # >>: 파일에 추가 (덮어쓰기 아님)
        echo "### 계정: $user ###" >> "$CRON_BAK"
        echo "$CRON" >> "$CRON_BAK"
    fi
done

echo "백업 완료: $CRON_BAK" | tee -a "$LOG"

# ─── STEP 2: Cron 서비스 중지 ────────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 2] Cron 서비스(crond) 중지" | tee -a "$LOG"

# systemctl stop crond: crond 서비스 중지 (RHEL 8 기준)
# crond = Cron 데몬, 이걸 중지하면 모든 스케줄 배치가 실행 안됨
systemctl stop crond

sleep 2  # 중지 완료까지 2초 대기

# is-active: 서비스가 실행 중(active)인지 아닌지(inactive) 확인
systemctl is-active crond | grep -q "inactive" \
    && echo "✅ Cron 중지 확인" | tee -a "$LOG" \
    || echo "⚠️ Cron 상태 재확인 필요" | tee -a "$LOG"

# ─── STEP 3: RVD 중지 ────────────────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 3] RVD 중지" | tee -a "$LOG"

# ps -ef: 현재 실행 중인 모든 프로세스 목록 출력
# grep rvd: 'rvd'가 포함된 줄만 필터 (RVD 프로세스 찾기)
# grep -v grep: grep 명령어 자신이 목록에 나오는 걸 제외
# awk '{print $2}': 공백 구분 2번째 컬럼 = PID(프로세스ID) 출력
# head -1: 여러 개일 경우 첫 번째만 가져옴
RVD_PID=$(ps -ef | grep rvd | grep -v grep | awk '{print $2}' | head -1)

echo "RVD PID: $RVD_PID" | tee -a "$LOG"

# -n "$RVD_PID": PID가 비어있지 않으면 (= RVD가 실행 중이면)
if [ -n "$RVD_PID" ]; then

    # kill -TERM: 프로세스에게 '정상 종료' 신호를 보냄 (부드럽게 종료)
    # TERM(15)보다 강한 건 KILL(9): kill -9 는 강제 종료 (마지막 수단)
    kill -TERM "$RVD_PID"
    sleep 5  # 정상 종료 기다리기

    # 5초 후에도 아직 실행 중이면 강제 종료
    if ps -ef | grep rvd | grep -v grep > /dev/null 2>&1; then
        echo "SIGTERM 후에도 살아있음 → 강제 종료(kill -9)" | tee -a "$LOG"
        kill -9 "$RVD_PID"
        sleep 2
    fi

    # 최종 확인: ps에서 rvd가 없으면 성공
    ps -ef | grep rvd | grep -v grep > /dev/null 2>&1 \
        && echo "⚠️ RVD 아직 실행 중 - 수동 확인 필요" | tee -a "$LOG" \
        || echo "✅ RVD 중지 확인" | tee -a "$LOG"
else
    echo "✅ RVD 이미 중지 상태" | tee -a "$LOG"
fi

# ─── STEP 4: Oracle Listener 중지 ────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 4] Oracle Listener 중지 (포트 1621)" | tee -a "$LOG"

# oracle 계정으로 전환하여 lsnrctl stop 실행
# su - oracle -c "명령어": oracle 계정으로 해당 명령어 실행
# lsnrctl: Oracle Net Listener 관리 도구
# lsnrctl stop: Listener 중지 → 이후 DB 접속 불가 (기존 연결은 유지)
su - oracle -c "lsnrctl stop" >> "$LOG" 2>&1

sleep 3

# ss -tlnp: 현재 열려 있는 TCP 포트 목록 조회
# -t: TCP, -l: LISTEN 상태, -n: 포트 번호로 표시, -p: 프로세스 정보
# grep ":1621": 1621 포트를 사용 중인 항목만 필터
# 결과가 없으면(||) 정상 종료
ss -tlnp | grep ":1621" > /dev/null 2>&1 \
    && echo "⚠️ 1621 포트 아직 열림" | tee -a "$LOG" \
    || echo "✅ Oracle Listener 1621 포트 닫힘 확인" | tee -a "$LOG"

# ─── STEP 5: Oracle DB Shutdown ──────────────────────────────

echo "" | tee -a "$LOG"
echo "[STEP 5] Oracle DB Shutdown" | tee -a "$LOG"

# su - oracle -c "": oracle 계정으로 여러 줄 명령 실행
# <<EOF ~ EOF: 여러 줄 텍스트를 명령어의 입력으로 전달 (heredoc)
# sqlplus / as sysdba: OS 인증으로 DBA 권한으로 Oracle 접속
# SHUTDOWN IMMEDIATE: 진행 중 트랜잭션 롤백 후 즉시 DB 종료
#   (SHUTDOWN NORMAL보다 빠름, SHUTDOWN ABORT보다 안전)
su - oracle -c "
sqlplus / as sysdba <<EOF
SHUTDOWN IMMEDIATE;
EXIT;
EOF
" >> "$LOG" 2>&1

echo "Shutdown 명령 전송 완료. 완전 종료 대기 중..." | tee -a "$LOG"
sleep 10  # DB 완전 종료까지 대기

# pmon: Oracle Background Process
# pmon 이 없으면 Oracle이 완전히 내려간 것
ps -ef | grep pmon | grep -v grep > /dev/null 2>&1 \
    && echo "⚠️ Oracle pmon 아직 실행 중" | tee -a "$LOG" \
    || echo "✅ Oracle 완전 중지 확인 (pmon 없음)" | tee -a "$LOG"

# ─── 최종 상태 출력 ──────────────────────────────────────────

echo "" | tee -a "$LOG"
echo "=== 중지 완료 최종 확인 ===" | tee -a "$LOG"

# 프로세스 확인
for PROC in pmon rvd crond; do
    # wc -l: 줄 수 → 프로세스 개수
    COUNT=$(ps -ef | grep "$PROC" | grep -v grep | wc -l | tr -d ' ')
    # tr -d ' ': 공백 제거 (wc -l이 앞에 공백 붙일 때 있음)

    if [ "$COUNT" -eq 0 ]; then
        echo "✅ [$PROC] 중지 확인" | tee -a "$LOG"
    else
        echo "❌ [$PROC] 아직 실행 중 ($COUNT개) - 확인 필요" | tee -a "$LOG"
    fi
done

echo "" | tee -a "$LOG"
echo "=== 중지 완료: $(date) ===" | tee -a "$LOG"
echo "로그 파일: $LOG"

# ─────────────────────────────────────────────────────────────
# [수정 가이드]
# ─────────────────────────────────────────────────────────────
# Q: RVD 포트가 7500이 아닌 다른 포트를 쓴다면?
# A: STEP 3에서 아래 줄 추가:
#    ss -tlnp | grep ":실제포트번호"
#
# Q: RVD 전용 중지 스크립트가 있다면?
# A: STEP 3의 kill -TERM 대신:
#    bash /실제경로/rvd_stop.sh >> "$LOG" 2>&1
#
# Q: 중지 후 특정 프로세스를 추가로 확인하고 싶다면?
# A: 최종 확인 부분의 for 루프에 프로세스명 추가:
#    for PROC in pmon rvd crond 내_프로세스명; do
# ─────────────────────────────────────────────────────────────
