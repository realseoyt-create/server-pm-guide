# 03. MAIN 시나리오 (작업 당일)

> **작업 일시**: 2025년 7월 13일 (일) 13:00 ~ 17:00
> **대상 서버**: PJTSAP (VIP: 12.230.210.207), PJTSEC (VIP: 12.230.210.203)

---

## 전체 흐름

```
[작업 전]  12:30~13:00
  사전 스냅샷 수집 → Cron 백업 → 모니터링 중단 → DB 동기화 중단

[서버 작업]  13:00~16:00
  RVD 중지 → Oracle 중지 → Failover 테스트 → Oracle 기동 → RVD 기동

[복구 확인]  16:00~17:00
  Cron 재활성화 → RVD 확인 → 시스템 정상 동작 확인 → DB 동기화 재개
  → 프로세스 런 확인 → 프로그램 전송 재개
```

---

## 작업 전 준비 (12:30 ~ 13:00)

### Step 1: 사전 스냅샷 수집 (자동화)

```bash
# 두 서버 각각에서 수행
# pre_snapshot.sh 실행 (scripts/ 디렉토리 참고)
bash /tmp/scripts/pre_snapshot.sh

# 저장 위치 확인
ls -la /tmp/snapshot_before/
```

### Step 2: 현재 접속 세션 수 확인

```bash
# 작업 전 접속자가 있으면 공지 후 대기
# 웹/앱 세션 수 확인
ss -tnp | grep ESTABLISHED | wc -l

# Oracle 접속 세션 확인
su - oracle
sqlplus / as sysdba <<EOF
SELECT COUNT(*) AS "접속 세션 수"
FROM V\$SESSION
WHERE STATUS='ACTIVE' AND USERNAME IS NOT NULL;
EXIT;
EOF
```

> ⚠️ **주의**: Oracle 세션이 남아있으면 DB 중지 시 트랜잭션 손실 가능.
> 세션이 있으면 서비스 공지 후 대기하거나 DBA 확인 후 진행.

### Step 3: Cron 백업 및 중단

```bash
# 두 서버 각각 수행

# 백업
CRON_BAK=/tmp/crontab_backup_$(date +%Y%m%d%H%M).txt
for user in $(getent passwd | cut -d: -f1); do
    CRON=$(crontab -l -u $user 2>/dev/null)
    if [ -n "$CRON" ]; then
        echo "### $user ###" >> $CRON_BAK
        echo "$CRON" >> $CRON_BAK
    fi
done
echo "Cron 백업 완료: $CRON_BAK"

# Cron 중단 (systemd 기반 RHEL 8)
systemctl stop crond
systemctl status crond | grep Active
# Active: inactive (dead) 확인
```

> 🔴 **놓치기 쉬운 포인트**: crond 중단 후 이미 실행 중이던 배치가 있는지 확인.
> ```bash
> ps -ef | grep -E "batch|script|python|perl" | grep -v grep
> ```

### Step 4: 모니터링 시스템 중단

```bash
# 모니터링 에이전트 중단 (Zabbix/Nagios/기타)
# 예: Zabbix 에이전트
systemctl stop zabbix-agent 2>/dev/null || true

# 예: 자체 모니터링 스크립트
ps -ef | grep -i "monitor\|agent\|check" | grep -v grep
# 확인 후 해당 프로세스 중지

# 알람 비활성화 (모니터링 서버에서 수행 - 해당 담당자)
# 작업 시간 동안 알람이 울리지 않도록 모니터링 서버에서 유지보수 모드 설정
```

### Step 5: DB 동기화 중단

```bash
su - oracle

# Data Guard 구성인 경우 - Standby에서 MRP 중지
sqlplus / as sysdba <<EOF
-- 현재 동기화 상태 확인
SELECT DB_UNIQUE_NAME, DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;

-- Redo Apply 중지 (Standby 측에서)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

-- 확인
SELECT PROCESS, STATUS FROM V\$MANAGED_STANDBY;
EXIT;
EOF

# 동기화 프로세스 중지 확인
ps -ef | grep -E "mrp|lns|dmon" | grep -v grep
# MRP 프로세스가 없어야 함
```

---

## 서버 작업 (13:00 ~ 16:00)

### Step 6: 작업 시작 공지

```
[공지 채널: 카카오톡/Slack/이메일]
"[공지] PJTSAP/PJTSEC 서버 PM 작업 시작합니다. (13:00)
 예상 완료: 17:00
 작업 중 비상 연락: [담당자 연락처]"
```

### Step 7: RVD 중지

```bash
# 두 서버 각각 수행 (PJTSAP 먼저, PJTSEC 순서로)

# RVD 프로세스 확인
RVD_PID=$(ps -ef | grep rvd | grep -v grep | awk '{print $2}')
echo "RVD PID: $RVD_PID"

if [ -n "$RVD_PID" ]; then
    # RVD 전용 중지 스크립트가 있으면 사용
    # [RVD 중지 스크립트 경로] 실행
    # 없으면 아래 kill 사용
    kill -TERM $RVD_PID
    sleep 5
    ps -ef | grep rvd | grep -v grep \
        && echo "RVD 아직 실행 중 - 강제 종료" && kill -9 $RVD_PID \
        || echo "RVD 정상 중지 확인"
else
    echo "RVD 이미 중지 상태"
fi

# 포트 확인 (RVD 포트 - 기본 7500 또는 환경 설정값)
ss -tlnp | grep "7500" && echo "경고: RVD 포트 아직 열려있음" || echo "RVD 포트 닫힘 확인"
```

### Step 8: Oracle DB 중지

```bash
su - oracle

# 접속 세션 최종 확인
sqlplus / as sysdba <<EOF
SELECT COUNT(*) AS "남은 세션" FROM V\$SESSION WHERE USERNAME IS NOT NULL;
EXIT;
EOF

# Listener 중지 (포트 1621)
lsnrctl stop
lsnrctl status | grep "TNS-12541" && echo "Listener 중지 확인" || echo "확인 필요"

# DB 종료
sqlplus / as sysdba <<EOF
SHUTDOWN IMMEDIATE;
EXIT;
EOF

# 완전 중지 확인
sleep 10
ps -ef | grep pmon | grep -v grep \
    && echo "경고: pmon 아직 실행 중" \
    || echo "Oracle 완전 중지 확인"

# 포트 1621 닫힘 확인
ss -tlnp | grep "1621" && echo "경고: 1621 포트 아직 열려있음" || echo "1621 포트 닫힘 확인"
```

> 🔴 **중요**: Oracle 포트가 **1621** (표준 1521 아님). 모든 포트 확인 시 1621로 확인할 것.

### Step 9: Failover 테스트

```bash
# ─── PJTSAP Failover (PJTSAP를 내리고 PJTSEC이 VIP를 가져오는 테스트) ───

# 현재 VIP 위치 확인
echo "=== 작업 전 VIP 위치 ==="
# PJTSAP 측
ssh 12.230.210.205 "ip addr show | grep '12.230.210.207' && echo 'PJTSAP가 VIP 보유'"
# PJTSEC 측
ssh 12.230.210.201 "ip addr show | grep '12.230.210.203' && echo 'PJTSEC가 VIP 보유'"

# PJTSAP 서버 중지 (방법은 HA 구성에 따라 다름)
# 방법 1: Pacemaker 패키지 이동
# pcs resource move [리소스명] 12.230.210.201

# 방법 2: 서버 자체 종료
# shutdown -h now  (PJTSAP에서)

# 방법 3: VIP 수동 제거 (keepalived 중지)
# systemctl stop keepalived

# Failover 소요 시간 기록
FAILOVER_START=$(date +%s)
echo "Failover 시작: $(date)"

# PJTSEC에서 VIP 전환 확인
sleep 30
ssh 12.230.210.201 "ip addr show | grep '12.230.210.207'" \
    && echo "PJTSAP VIP → PJTSEC 전환 완료" \
    || echo "VIP 전환 미확인 - 수동 확인 필요"

FAILOVER_END=$(date +%s)
echo "Failover 소요 시간: $((FAILOVER_END - FAILOVER_START))초"
```

> 💡 **TIP**: Failover 전/후 `ip addr show`와 `ping [VIP]` 결과를 반드시 저장.
> 작업 결과 보고서의 근거 자료가 됨.

### Step 10: Oracle 기동 (Failover 완료 후 신규 Active 서버에서)

```bash
# 신규 Active 서버(PJTSEC 또는 원복 후 PJTSAP)에서 수행
su - oracle

# Listener 기동 (포트 1621)
lsnrctl start

# Listener 상태 확인
lsnrctl status
# Service "PJOSCD" has 1 instance(s) 문구 확인 필수!

# DB 기동
sqlplus / as sysdba <<EOF
STARTUP;
EOF

# 기동 상태 확인
sqlplus / as sysdba <<EOF
SELECT STATUS FROM V\$INSTANCE;
SELECT NAME, OPEN_MODE, DB_UNIQUE_NAME FROM V\$DATABASE;
EXIT;
EOF
# STATUS = OPEN, OPEN_MODE = READ WRITE 확인

# 포트 1621 오픈 확인
ss -tlnp | grep "1621" && echo "1621 포트 오픈 확인" || echo "경고: 포트 미오픈"
```

> 🔴 **반드시 확인**: `lsnrctl status`에서 **Service "PJOSCD" has 1 instance(s)** 문구가 있어야 함.
> 없으면 서비스가 Listener에 등록되지 않은 것 → 앱/RVD에서 DB 접속 불가.
>
> ```bash
> # 서비스 수동 등록
> sqlplus / as sysdba <<EOF
> ALTER SYSTEM REGISTER;
> EXIT;
> EOF
> lsnrctl reload
> ```

---

## 서버 작업 완료 후 복구 (16:00 ~ 17:00)

### Step 11: RVD 확인 및 기동

```bash
# Oracle 완전 기동 확인 후 RVD 기동
# (Oracle이 정상 OPEN 상태여야 RVD 기동 가능)

# RVD 기동
# [RVD 기동 스크립트 경로] 실행
# 또는:
/[RVD_HOME]/bin/rvd -listen tcp:[RVD_PORT] -logfile /var/log/rvd.log &

sleep 5

# RVD 기동 확인
ps -ef | grep rvd | grep -v grep && echo "RVD 기동 확인" || echo "경고: RVD 미기동"
ss -tlnp | grep "[RVD_PORT]" && echo "RVD 포트 오픈 확인"
```

### Step 12: 시스템 정상 동작 확인

```bash
# 자동화 스크립트 사용 (scripts/check_oracle.sh)
bash /tmp/scripts/check_oracle.sh

# RVD 확인 (scripts/check_rvd.sh)
bash /tmp/scripts/check_rvd.sh

# 전체 주요 프로세스 확인
echo "=== 주요 프로세스 현황 ==="
ps -ef | grep -E "pmon|rvd" | grep -v grep
ss -tlnp | grep -E "1621|7500"
```

### Step 13: DB 동기화 재개

```bash
su - oracle

# Data Guard Redo Apply 재개 (Standby 측에서)
sqlplus / as sysdba <<EOF
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
USING CURRENT LOGFILE DISCONNECT FROM SESSION;

-- 동기화 상태 확인
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY;
SELECT NAME, VALUE FROM V\$DATAGUARD_STATS
WHERE NAME IN ('transport lag', 'apply lag');
EXIT;
EOF

# 동기화 프로세스 확인
ps -ef | grep mrp | grep -v grep && echo "MRP 프로세스 동기화 중"
```

> ⚠️ **주의**: 동기화 재개 후 즉시 lag이 0이 되지 않을 수 있음.
> 작업 시간(최대 4시간) 분량의 redo를 적용하는 데 시간이 걸릴 수 있음.
> 허용 lag 기준 시간을 DBA에게 확인할 것.

### Step 14: 프로세스 런 확인

```bash
# 전후 비교 실행 (자동화 스크립트)
bash /tmp/scripts/post_compare.sh

# 주요 프로세스 수동 확인
echo "=== 기동되어야 할 프로세스 현황 ==="
for PROC in pmon rvd; do
    COUNT=$(ps -ef | grep $PROC | grep -v grep | wc -l)
    echo "[$PROC] 실행 수: $COUNT"
done

# Cron 재활성화
systemctl start crond
systemctl status crond | grep Active
# Active: active (running) 확인

# Cron 등록 내용 백업본과 대조
diff $CRON_BAK <(for user in $(getent passwd | cut -d: -f1); do
    CRON=$(crontab -l -u $user 2>/dev/null)
    [ -n "$CRON" ] && echo "### $user ###" && echo "$CRON"
done)
echo "Cron 내용 백업본과 일치 확인"
```

> 🔴 **놓치기 쉬운 포인트**: Cron 재활성화 후 등록 내용이 백업본과 동일한지 반드시 확인.
> 작업 중 실수로 일부 계정의 Cron이 날아가는 경우 있음.

### Step 15: 프로그램 전송 재개

- 프로그램 전송 시스템 담당자에게 재개 요청
- 재개 후 첫 전송 건 정상 처리 여부 확인
- 미처리 건 있으면 재처리 방법 협의

### Step 16: 모니터링 재개

```bash
# 모니터링 에이전트 재기동
systemctl start zabbix-agent 2>/dev/null || true

# 모니터링 서버에서 유지보수 모드 해제 (담당자 수행)
```

### Step 17: 작업 완료 공지

```
[공지 채널]
"[완료] PJTSAP/PJTSEC 서버 PM 작업 완료되었습니다. (시각: XX:XX)
 서비스 정상 운영 중입니다.
 문의: [담당자 연락처]"
```

- 06_이메일_템플릿.md **메일 5 (작업 완료 공지)** 발송
- 연계 시스템 담당자에게 재개 가능 공지
