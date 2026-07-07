# 04. Failover 테스트 시나리오

> **목적**: HP-UX Active 서버 장애 시 Standby 서버로 자동/수동 전환이 정상 동작하는지 검증한다.
>
> **전제조건**: 사전 점검 완료, 서비스 중지 완료, CAB 승인 완료

---

## 목차
1. [Failover 전 최종 상태 확인](#1-failover-전-최종-상태-확인)
2. [Failover 시나리오 A: 서비스 정상 중지 후 Failover](#2-failover-시나리오-a-서비스-정상-중지-후-failover)
3. [Failover 검증 항목](#3-failover-검증-항목)
4. [기동 후 서비스 검증](#4-기동-후-서비스-검증)
5. [Failback (원래 Active로 복구)](#5-failback-원래-active로-복구)
6. [이슈 발생 시 대응 절차](#6-이슈-발생-시-대응-절차)

---

## 1. Failover 전 최종 상태 확인

> ⚠️ **주의**: 아래 항목이 모두 확인된 후에만 다음 단계로 진행한다.

```bash
# HP-UX Active 서버에서 수행

echo "=== Failover 전 상태 확인 ===" 

# 1. ServiceGuard 클러스터 상태
cmviewcl -v
# → 두 노드 모두 STATUS: up 이어야 함
# → 패키지가 Active 서버에서 실행 중이어야 함

# 2. 서비스 중지 여부 확인
echo "[ORACLE]"
ps -ef | grep pmon | grep -v grep && echo "ORACLE 실행 중 - 중지 필요!" || echo "ORACLE 중지 확인"

echo "[RV]"
ps -ef | grep rvd | grep -v grep && echo "RV 실행 중 - 중지 필요!" || echo "RV 중지 확인"

echo "[JAVA WAS]"
ps -ef | grep java | grep -v grep && echo "WAS 실행 중 - 중지 필요!" || echo "WAS 중지 확인"

# 3. 현재 VIP (Virtual IP) 확인
# VIP가 Active 서버에 있는지 확인
ifconfig -a | grep -A2 "lo0\|lan"
# VIP 주소를 알고 있다면: ping [VIP주소] -c 3

# 4. Cron 중지 여부 확인
crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" \
    && echo "주의: 활성 Cron 항목 있음!" \
    || echo "Cron 중지 확인"
```

---

## 2. Failover 시나리오 A: 서비스 정상 중지 후 Failover

> 💡 **이 시나리오**: PM 작업 중 가장 일반적인 방식.
> Active 서버의 서비스를 먼저 내린 후, 서버를 중지하여 Failover 발생 여부 확인.

### Step 1: ServiceGuard 자동 Failover 설정 확인

```bash
# Active 서버에서 수행 (root 권한)

# 현재 패키지 목록 확인
cmviewcl -p
# 출력 예시:
# CLUSTER    STATUS
# my_cluster  up
#
# PACKAGE          STATUS     STATE    AUTO_RUN  NODE
# app_pkg          up         running  enabled   hpux01   ← 현재 Active

# 패키지 설정 확인 (AUTO_RUN이 enabled면 자동 Failover)
cmgetconf -p app_pkg | grep -i "auto_run\|failover"
```

> 💡 **TIP**: 테스트 중 의도치 않은 자동 재기동을 막으려면 AUTO_RUN을 disabled로 변경.
> 하지만 Failover 테스트 목적이라면 enabled 상태를 유지한 채 진행하는 것이 맞다.

### Step 2: Active 서버 중지

```bash
# 방법 1: OS graceful shutdown (권장)
# root 권한으로 수행
shutdown -h now   # HP-UX

# 방법 2: 네트워크 차단 (실제 장애 시뮬레이션)
# → 네트워크 팀 협조 필요, 위험도 높음

# 방법 3: ServiceGuard 패키지 수동 이동 (가장 안전)
# Active 서버에서
cmhaltpkg app_pkg   # 패키지 중지 → Standby에서 기동됨
```

> ⚠️ **주의**: 방법 1(OS 중지)은 서버가 완전히 내려가므로
> 물리적 접근 또는 IPMI/ILO 콘솔 접근 방법을 미리 확인해 두어야 한다.

### Step 3: Standby 서버에서 Failover 확인

```bash
# HP-UX Standby 서버에서 수행
# Active 서버 중지 후 최대 3~5분 내에 자동 전환 발생

# Failover 완료 여부 확인
cmviewcl -v
# → 구 Standby 서버의 패키지 STATUS가 up으로 변경되면 성공
#
# 예상 출력:
# PACKAGE          STATUS     STATE    AUTO_RUN  NODE
# app_pkg          up         running  enabled   hpux02   ← Standby가 Active로 전환

# VIP 전환 확인
ifconfig -a | grep "[VIP주소]"
# 또는
ping [VIP주소] -c 3
# VIP가 이 서버(구 Standby)에 할당되어야 함

# syslog에서 Failover 이벤트 확인
tail -50 /var/adm/syslog/syslog.log | grep -i "cmcld\|failover\|package"
```

---

## 3. Failover 검증 항목

> 아래 항목을 모두 확인하고 결과를 기록한다.

| # | 확인 항목 | 확인 방법 | 예상 결과 | 실제 결과 |
|---|-----------|-----------|-----------|-----------|
| 1 | Standby 서버 Active 전환 | `cmviewcl -p` | 패키지 STATUS: up | |
| 2 | VIP 전환 | `ifconfig -a \| grep [VIP]` | VIP가 신규 Active에 할당 | |
| 3 | 서비스 자동 기동 여부 | `ps -ef \| grep pmon,rvd,java` | MC/SG 설정에 따라 다름 | |
| 4 | Failover 소요 시간 | syslog 타임스탬프 확인 | [목표 시간] 이내 | |
| 5 | 구 Active 서버 상태 | `cmviewcl -v` | STATUS: down | |

---

## 4. 기동 후 서비스 검증

Failover 완료 후 서비스를 기동하고 검증한다.

### 4-1. 신규 Active 서버(구 Standby)에서 서비스 기동

```bash
# 03_StartStop_스크립트_가이드.md의 기동 순서대로 실행
# 1. ORACLE 기동
# 2. Listener 확인
# 3. RV 기동
# 4. WAS 기동
# (Windows IIS는 별도 수행)
```

### 4-2. ORACLE 기동 후 필수 확인

```bash
su - oracle
sqlplus / as sysdba <<EOF
-- DB 상태
SELECT STATUS FROM V\$INSTANCE;

-- 데이터 무결성 확인
SELECT NAME, OPEN_MODE FROM V\$DATABASE;

-- Redo Log 상태
SELECT GROUP#, STATUS, ARCHIVED FROM V\$LOG;

-- 최근 Archive Log (정상 아카이브 여부)
SELECT MAX(SEQUENCE#), MAX(NEXT_TIME) FROM V\$ARCHIVED_LOG;
EXIT;
EOF

# Listener 서비스 등록 확인
lsnrctl status | grep "instance"
```

### 4-3. WAS 기동 후 확인

```bash
# WAS 프로세스 확인
ps -ef | grep java | grep -v grep

# 포트 오픈 확인
netstat -an | grep -E "8080|7001" | grep LISTEN

# WAS 로그에서 기동 완료 메시지 확인
grep -i "started\|running" [WAS_LOG_PATH] | tail -5
```

### 4-4. 서비스 End-to-End 검증

```bash
# Web 서버에서 HP-UX VIP로 연결 가능한지 확인
# (Windows Web 서버에서 수행)
ping [HP-UX VIP주소]

# 실제 서비스 URL 접근 테스트
# curl 또는 브라우저로 서비스 페이지 접근
curl -o /dev/null -s -w "%{http_code}" http://[VIP주소]:[포트]/[경로]
# 200이면 정상
```

### 4-5. Cron 재활성화 후 확인

```bash
# Cron 재활성화
/sbin/init.d/cron start

# 등록 내용 확인 (백업본과 비교)
crontab -l

# 각 계정 cron 확인
for user in root oracle app batch; do
    echo "=== $user ==="
    crontab -l -u $user 2>/dev/null
done
```

> 🔴 **놓치기 쉬운 포인트**: Cron 재활성화 후 등록된 항목이 백업본과 동일한지 반드시 비교.
> 작업 중 실수로 일부 항목이 누락되는 경우가 있다.

---

## 5. Failback (원래 Active로 복구)

> 테스트 완료 후 원래 서버 구성으로 돌아오는 절차.
> 구 Active 서버를 재기동하고 패키지를 원복한다.

### Step 1: 구 Active 서버 재기동

```bash
# 물리 서버 전원 On (또는 iLO/IPMI 콘솔에서 기동)
# 또는 shutdown 했던 경우 서버 부팅

# 부팅 완료 후 서버에서 확인
uname -a
cmviewcl -v   # 클러스터 합류 여부 확인
```

### Step 2: 패키지 원복

```bash
# 현재 Active(구 Standby)에서 패키지 이동
# 방법 1: 패키지를 원래 서버로 이동
cmmodpkg -m [원래_Active_서버명] app_pkg

# 방법 2: 현재 Active에서 패키지 중지 → 원래 서버에서 기동
cmhaltpkg app_pkg   # 현재 Active에서
# → 자동으로 원래 서버에서 기동 (AUTO_RUN enabled인 경우)

# 확인
cmviewcl -p
# 원래 Active 서버에서 패키지가 실행 중이어야 함
```

> ⚠️ **주의**: Failback 시에도 서비스 중지 → Failback → 서비스 기동 순서를 지킬 것.
> 운영 중 패키지 이동은 짧은 서비스 단절을 유발할 수 있다.

---

## 6. 이슈 발생 시 대응 절차

### 케이스 A: Failover가 자동으로 일어나지 않은 경우

```bash
# Standby 서버에서 수동으로 패키지 기동
cmrunpkg app_pkg

# 안 되면 클러스터 로그 확인
tail -100 /var/adm/syslog/syslog.log | grep -i "cmcld\|error"

# ServiceGuard 데몬 상태 확인
ps -ef | grep cmcld | grep -v grep
```

### 케이스 B: ORACLE DB 기동 실패

```bash
su - oracle
# Alert Log 확인
tail -100 $ORACLE_BASE/diag/rdbms/orcl/orcl1/trace/alert_orcl1.log

# 일반적인 원인 및 조치
# ORA-00313: 컨트롤 파일 문제 → DBA 연락
# ORA-01078: 파라미터 파일 문제 → $ORACLE_HOME/dbs/ 확인
# Mount 단계 실패 → 데이터파일 경로 확인

# 강제 복구 시도 (DBA 확인 후 수행)
sqlplus / as sysdba <<EOF
STARTUP MOUNT;
RECOVER DATABASE;   -- 필요 시
ALTER DATABASE OPEN;
EOF
```

### 케이스 C: WAS 기동 후 DB 접속 오류

```bash
# Listener 상태 재확인
su - oracle -c "lsnrctl status"

# 서비스 수동 등록
su - oracle -c "sqlplus / as sysdba <<EOF
ALTER SYSTEM REGISTER;
EXIT;
EOF"

# WAS의 JDBC URL과 Listener 포트 일치 여부 확인
grep -r "jdbc:oracle" [WAS_CONFIG_PATH] | head -5
```

### 케이스 D: 롤백 결정 시

```bash
# 1. 작업 중단 선언 및 팀 공지
# 2. 현재 신규 Active에서 서비스 중지 (stop 순서대로)
# 3. 구 Active 서버 재기동
# 4. 구 Active 서버에서 서비스 기동 (start 순서대로)
# 5. 서비스 검증
# 6. 원인 분석 후 재작업 일정 수립
```
