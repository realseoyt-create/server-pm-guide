# 03. Start/Stop 스크립트 가이드

> **목적**: 현재 환경에 맞는 Start/Stop 스크립트를 직접 만들 수 있도록 예시와 설명을 제공한다.
>
> **중요**: 아래 스크립트는 **예시**다. 실제 환경의 경로, 계정명, SID, 포트 등을
> 반드시 실제 값으로 수정하여 사용해야 한다.

---

## 목차
1. [기동/중지 순서 원칙](#1-기동중지-순서-원칙)
2. [컴포넌트별 기동/중지 명령어](#2-컴포넌트별-기동중지-명령어)
3. [통합 Stop 스크립트 예시](#3-통합-stop-스크립트-예시)
4. [통합 Start 스크립트 예시](#4-통합-start-스크립트-예시)
5. [스크립트 작성 시 주의사항](#5-스크립트-작성-시-주의사항)
6. [스크립트 검증 방법](#6-스크립트-검증-방법)

---

## 1. 기동/중지 순서 원칙

> ⚠️ **핵심 원칙**: 순서를 지키지 않으면 데이터 손실 또는 복구 불가 상황이 발생할 수 있다.

### 중지 순서 (위에서 아래로)

```
① Web 서버 (IIS)         ← 외부 요청 차단
      ↓
② JAVA WAS               ← 애플리케이션 로직 중지
      ↓
③ RV (TIBCO Rendezvous)  ← 메시지 미들웨어 중지
      ↓
④ ORACLE DB              ← DB 안전 종료
      ↓
⑤ Cron                   ← 배치 중지 (DB 중지 전에 해도 됨)
      ↓
⑥ OS 중지 (필요 시)
```

**이유**: 위 계층이 돌아가는 상태에서 DB를 먼저 내리면 WAS에서 DB 접속 오류가 발생하며,
트랜잭션 중이던 데이터가 손상될 수 있다.

### 기동 순서 (중지의 역순)

```
① OS 기동 (이미 켜져 있으면 생략)
      ↓
② ORACLE DB              ← DB 먼저 기동
      ↓
③ Listener 확인          ← DB가 올라도 Listener 없으면 접속 불가
      ↓
④ RV (TIBCO Rendezvous)  ← 미들웨어 기동
      ↓
⑤ JAVA WAS               ← WAS 기동
      ↓
⑥ Web 서버 (IIS)         ← 외부 요청 오픈
      ↓
⑦ Cron 재활성화          ← 배치 재개
```

---

## 2. 컴포넌트별 기동/중지 명령어

### 2-1. ORACLE DB

#### 중지

```bash
# oracle 계정으로 수행
su - oracle

# 현재 접속 세션 수 확인 (0이 되면 중지)
sqlplus / as sysdba <<EOF
SELECT COUNT(*) AS "접속 세션 수" FROM V\$SESSION WHERE STATUS='ACTIVE' AND USERNAME IS NOT NULL;
EOF

# DB 정상 종료 (처리 중 트랜잭션 완료 후 종료 - 권장)
sqlplus / as sysdba <<EOF
SHUTDOWN NORMAL;
EOF
# ※ NORMAL은 모든 접속이 끊길 때까지 대기. 오래 걸리면 IMMEDIATE 사용.

# DB 즉시 종료 (진행 중 트랜잭션 롤백 후 종료)
sqlplus / as sysdba <<EOF
SHUTDOWN IMMEDIATE;
EOF

# Listener 중지
lsnrctl stop

# 확인
ps -ef | grep pmon | grep -v grep
# 출력 없으면 DB 정상 종료
```

#### 기동

```bash
su - oracle

# Listener 먼저 기동
lsnrctl start

# DB 기동
sqlplus / as sysdba <<EOF
STARTUP;
EOF

# 상태 확인 (OPEN 이어야 정상)
sqlplus / as sysdba <<EOF
SELECT STATUS FROM V\$INSTANCE;
SELECT NAME, OPEN_MODE FROM V\$DATABASE;
EOF

# Listener에 서비스 등록 확인 (핵심!)
lsnrctl status
# "Service ... has 1 instance(s)" 문구 확인 필수
```

> 🔴 **놓치기 쉬운 포인트**: DB를 기동했는데 Listener에 서비스가 등록되지 않으면
> WAS에서 `ORA-12514: TNS:listener does not currently know of service` 오류 발생.
> `lsnrctl status` 결과에서 서비스 등록 여부 반드시 확인.
>
> 자동 등록이 안 된다면:
> ```bash
> lsnrctl reload   # Listener 재로드
> # 또는 sqlplus에서
> ALTER SYSTEM REGISTER;  # 수동 서비스 등록
> ```

---

### 2-2. RV (TIBCO Rendezvous)

#### 중지

```bash
# RV 데몬 PID 확인
RV_PID=$(ps -ef | grep rvd | grep -v grep | awk '{print $2}')
echo "RV PID: $RV_PID"

# 정상 종료 시도
if [ -n "$RV_PID" ]; then
    kill -TERM $RV_PID
    sleep 5
    # 아직 살아있으면 강제 종료
    ps -ef | grep rvd | grep -v grep && kill -9 $RV_PID
fi

# 확인
ps -ef | grep rvd | grep -v grep
```

> 💡 **TIP**: RV 전용 중지 스크립트가 있다면 kill 대신 스크립트를 사용한다.
> 스크립트 위치 예시: `/opt/tibco/rv/bin/rvd_stop.sh` (환경마다 다름)

#### 기동

```bash
# RV 환경 변수 로드 (필요 시)
# source /opt/tibco/rv/bin/tibrvenv.sh  # 경로는 환경마다 다름

# RV 데몬 기동
# 방법 1: 기동 스크립트가 있는 경우
/opt/tibco/rv/bin/rvd_start.sh   # 경로는 환경마다 다름

# 방법 2: 직접 기동
/opt/tibco/rv/bin/rvd \
    -listen tcp:7500 \
    -logfile /var/log/rvd.log &

# 기동 확인
sleep 3
ps -ef | grep rvd | grep -v grep
netstat -an | grep 7500
```

---

### 2-3. JAVA WAS

> ⚠️ WAS 종류(WebLogic/JBoss/Tomcat 등)에 따라 명령어가 다름.
> 아래는 각 WAS별 일반적인 방법이며 실제 경로와 서버명을 확인 후 수정할 것.

#### WebLogic 기준

```bash
# WAS 계정으로 수행 (weblogic, wasadm 등 - 환경마다 다름)
su - weblogic

# 중지
$DOMAIN_HOME/bin/stopWebLogic.sh

# 또는 관리 콘솔에서 중지 후 WLST로 확인
# nohup $WL_HOME/server/bin/wlst.sh << EOF
# connect('weblogic', 'password', 't3://localhost:7001')
# shutdown('서버명', 'Server', ignoreSessions=true)
# EOF

# 확인
ps -ef | grep java | grep -v grep
netstat -an | grep 7001

# 기동
nohup $DOMAIN_HOME/bin/startWebLogic.sh &
sleep 30
# 로그에서 기동 완료 메시지 확인
tail -f $DOMAIN_HOME/servers/AdminServer/logs/AdminServer.log
# "Server started in RUNNING mode" 메시지 확인
```

#### JBoss/WildFly 기준

```bash
su - jboss

# 중지
$JBOSS_HOME/bin/jboss-cli.sh --connect command=:shutdown

# 기동
nohup $JBOSS_HOME/bin/standalone.sh \
    -c standalone.xml \
    -b 0.0.0.0 >> /var/log/jboss/startup.log 2>&1 &

# 기동 확인 (포트 오픈 확인)
sleep 30
netstat -an | grep 8080
```

#### Tomcat 기준

```bash
su - tomcat

# 중지
$CATALINA_HOME/bin/shutdown.sh

# 30초 후에도 살아있으면 강제 종료
sleep 30
TOMCAT_PID=$(ps -ef | grep catalina | grep -v grep | awk '{print $2}')
[ -n "$TOMCAT_PID" ] && kill -9 $TOMCAT_PID

# 기동
$CATALINA_HOME/bin/startup.sh

# 기동 확인
sleep 20
netstat -an | grep 8080
tail -50 $CATALINA_HOME/logs/catalina.out
```

---

### 2-4. Web 서버 (Windows IIS)

**CMD(관리자 권한)로 실행**:

```cmd
:: IIS 전체 중지
iisreset /stop

:: 또는 특정 사이트만 중지
%systemroot%\system32\inetsrv\appcmd.exe stop site /site.name:"Default Web Site"

:: W3SVC 서비스 중지
net stop W3SVC

:: 확인
sc query W3SVC | findstr STATE

:: IIS 전체 기동
iisreset /start

:: 또는 특정 사이트만 기동
%systemroot%\system32\inetsrv\appcmd.exe start site /site.name:"Default Web Site"

:: 기동 확인
netstat -an | findstr ":80 "
netstat -an | findstr ":443 "
```

---

### 2-5. Cron 일시 중지/재활성화

```bash
# 중지 전 백업
crontab -l > /tmp/crontab_bak_$(date +%Y%m%d%H%M).txt
echo "crontab 백업: /tmp/crontab_bak_$(date +%Y%m%d%H%M).txt"

# 방법 1 (권장): 편집하여 주석 처리
# crontab -e 실행 후 실행될 항목 앞에 # 추가

# 방법 2: crond 서비스 중지 (HP-UX)
/sbin/init.d/cron stop

# 재활성화 (방법 1의 경우)
# crontab -e 실행 후 # 제거

# 재활성화 (방법 2의 경우)
/sbin/init.d/cron start

# 확인
crontab -l   # 등록 내용 확인
```

---

## 3. 통합 Stop 스크립트 예시

> 아래 스크립트를 참고하여 실제 환경에 맞게 수정할 것.
> 경로, 계정명, SID, 포트 등은 모두 **[실제값]** 으로 교체 필요.

```bash
#!/bin/sh
# stop_all.sh - 전체 서비스 순차 중지 스크립트
# 작성일: [날짜]
# 용도: PM 작업 전 서비스 정상 중지
# 실행: root 또는 담당 계정으로 실행

LOG=/tmp/stop_all_$(date +%Y%m%d%H%M).log
echo "=== 서비스 중지 시작: $(date) ===" | tee -a $LOG

# ─── 함수 정의 ──────────────────────────────────────────
check_process() {
    PROC_NAME=$1
    COUNT=$(ps -ef | grep "$PROC_NAME" | grep -v grep | wc -l | tr -d ' ')
    echo "[$PROC_NAME] 프로세스 수: $COUNT" | tee -a $LOG
    return $COUNT
}

wait_stop() {
    PROC_NAME=$1
    MAX_WAIT=60   # 최대 대기 시간 (초)
    WAIT=0
    while ps -ef | grep "$PROC_NAME" | grep -v grep > /dev/null 2>&1; do
        if [ $WAIT -ge $MAX_WAIT ]; then
            echo "[$PROC_NAME] 경고: ${MAX_WAIT}초 내 중지 안됨. 강제 종료 검토 필요." | tee -a $LOG
            return 1
        fi
        sleep 5
        WAIT=$((WAIT+5))
        echo "[$PROC_NAME] 중지 대기 중... (${WAIT}초)" | tee -a $LOG
    done
    echo "[$PROC_NAME] 중지 완료." | tee -a $LOG
    return 0
}

# ─── Step 1: Cron 중지 ──────────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 1] Cron 중지" | tee -a $LOG
crontab -l > /tmp/crontab_bak_$(date +%Y%m%d%H%M).txt
/sbin/init.d/cron stop
echo "Cron 중지 완료" | tee -a $LOG

# ─── Step 2: JAVA WAS 중지 ──────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 2] JAVA WAS 중지" | tee -a $LOG
# ※ 실제 WAS 중지 명령으로 변경 필요
su - wasadmin -c "$DOMAIN_HOME/bin/stopWebLogic.sh" >> $LOG 2>&1
wait_stop "java"

# ─── Step 3: RV 중지 ────────────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 3] RV 데몬 중지" | tee -a $LOG
RV_PID=$(ps -ef | grep rvd | grep -v grep | awk '{print $2}')
if [ -n "$RV_PID" ]; then
    kill -TERM $RV_PID
    wait_stop "rvd"
else
    echo "[RV] 이미 중지 상태" | tee -a $LOG
fi

# ─── Step 4: ORACLE DB 중지 ─────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 4] ORACLE DB 중지" | tee -a $LOG
su - oracle -c "lsnrctl stop" >> $LOG 2>&1
su - oracle -c "sqlplus / as sysdba <<EOF
SHUTDOWN IMMEDIATE;
EXIT;
EOF" >> $LOG 2>&1
wait_stop "pmon"

# ─── 완료 ───────────────────────────────────────────────
echo "" | tee -a $LOG
echo "=== 서비스 중지 완료: $(date) ===" | tee -a $LOG
echo "로그 파일: $LOG"

# 최종 프로세스 상태 확인
echo "" | tee -a $LOG
echo "[최종 상태 확인]" | tee -a $LOG
check_process "pmon"    # ORACLE
check_process "rvd"     # RV
check_process "java"    # WAS
```

---

## 4. 통합 Start 스크립트 예시

```bash
#!/bin/sh
# start_all.sh - 전체 서비스 순차 기동 스크립트
# 작성일: [날짜]
# 용도: PM 작업 후 서비스 정상 기동

LOG=/tmp/start_all_$(date +%Y%m%d%H%M).log
echo "=== 서비스 기동 시작: $(date) ===" | tee -a $LOG

wait_start() {
    PROC_NAME=$1
    PORT=$2
    MAX_WAIT=120
    WAIT=0
    while ! ps -ef | grep "$PROC_NAME" | grep -v grep > /dev/null 2>&1; do
        if [ $WAIT -ge $MAX_WAIT ]; then
            echo "[$PROC_NAME] 경고: ${MAX_WAIT}초 내 기동 안됨." | tee -a $LOG
            return 1
        fi
        sleep 10
        WAIT=$((WAIT+10))
        echo "[$PROC_NAME] 기동 대기 중... (${WAIT}초)" | tee -a $LOG
    done
    echo "[$PROC_NAME] 기동 확인 완료." | tee -a $LOG
    return 0
}

# ─── Step 1: ORACLE DB 기동 ─────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 1] ORACLE DB 기동" | tee -a $LOG
su - oracle -c "lsnrctl start" >> $LOG 2>&1
su - oracle -c "sqlplus / as sysdba <<EOF
STARTUP;
EXIT;
EOF" >> $LOG 2>&1
wait_start "pmon"

# Listener 서비스 등록 확인 (중요!)
sleep 10
su - oracle -c "lsnrctl status" | tee -a $LOG
su - oracle -c "lsnrctl status" | grep -q "instance(s)" \
    && echo "[ORACLE] Listener 서비스 등록 확인 완료" | tee -a $LOG \
    || echo "[ORACLE] 경고: Listener 서비스 미등록! 수동 확인 필요" | tee -a $LOG

# ─── Step 2: RV 기동 ────────────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 2] RV 데몬 기동" | tee -a $LOG
# ※ 실제 RV 기동 명령으로 변경 필요
/opt/tibco/rv/bin/rvd -listen tcp:7500 -logfile /var/log/rvd.log &
sleep 5
wait_start "rvd"

# ─── Step 3: JAVA WAS 기동 ──────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 3] JAVA WAS 기동" | tee -a $LOG
su - wasadmin -c "nohup $DOMAIN_HOME/bin/startWebLogic.sh >> /var/log/was_startup.log 2>&1 &"
wait_start "java"

# ─── Step 4: Cron 재활성화 ──────────────────────────────
echo "" | tee -a $LOG
echo "[STEP 4] Cron 재활성화" | tee -a $LOG
/sbin/init.d/cron start
crontab -l | tee -a $LOG
echo "[Cron] 재활성화 완료" | tee -a $LOG

# ─── 완료 ───────────────────────────────────────────────
echo "" | tee -a $LOG
echo "=== 서비스 기동 완료: $(date) ===" | tee -a $LOG
echo "로그 파일: $LOG"

# 최종 상태 확인
echo "" | tee -a $LOG
echo "[최종 프로세스 확인]" | tee -a $LOG
ps -ef | grep -E "pmon|rvd|java" | grep -v grep | tee -a $LOG

echo "" | tee -a $LOG
echo "[최종 포트 확인]" | tee -a $LOG
netstat -an | grep -E "1521|7500|8080|7001" | grep LISTEN | tee -a $LOG
```

---

## 5. 스크립트 작성 시 주의사항

> 🔴 **반드시 확인해야 할 항목들**

| 항목 | 확인 방법 | 비고 |
|------|-----------|------|
| 실행 계정 | `id` 명령으로 확인 | oracle은 oracle 계정, WAS는 WAS 계정으로 |
| ORACLE SID | `echo $ORACLE_SID` | oracle 계정 환경변수 |
| ORACLE_HOME 경로 | `echo $ORACLE_HOME` | oracle 계정 환경변수 |
| DOMAIN_HOME 경로 | WAS 기동 스크립트에서 확인 | WebLogic 기준 |
| RV 설치 경로 | `find / -name rvd 2>/dev/null` | 실제 경로 확인 |
| WAS 포트 | `netstat -an \| grep LISTEN \| grep java` | 기동 후 포트 확인 |

---

## 6. 스크립트 검증 방법

### 스크립트 실행 전 문법 검사

```bash
# sh 문법 검사 (실행 없이)
sh -n stop_all.sh
sh -n start_all.sh
echo $?   # 0이면 문법 정상
```

### Dry Run (실제 실행 전 흐름 확인)

```bash
# 스크립트 내 실제 명령어 앞에 echo를 붙여서 실제로 실행되지 않게 확인
# 예: 
#  su - oracle -c "sqlplus / as sysdba ..."
# 를
#  echo "su - oracle -c 'sqlplus / as sysdba ...'"
# 으로 바꿔서 실행

# 또는 set -x 옵션으로 실행 흐름 추적
bash -x stop_all.sh 2>&1 | head -50
```

### 테스트 환경에서 먼저 검증

> 💡 **TIP**: 가능하다면 동일한 구성의 테스트 서버에서 스크립트를 먼저 실행해보고,
> 문제 없을 때 운영 서버에 적용한다.
