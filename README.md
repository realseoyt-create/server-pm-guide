# 서버 PM 및 Failover 테스트 가이드

> **PM 일정**: 2025년 7월 13일 (일) 오후 13:00 ~ 17:00
>
> 본 문서는 이 작업을 처음 수행하는 담당자도 이 문서만 보고 안전하게 진행할 수 있도록 작성되었습니다.

---

## 대상 서버

| 서버 | VIP | Real IP | OS | DB | Service | Port |
|------|-----|---------|----|----|---------|------|
| **PJTSAP** | 12.230.210.207 | 12.230.210.205 / .206 | RHEL 8.10 (64bit) | Oracle 19C | PJOSCD | 1621 |
| **PJTSEC** | 12.230.210.203 | 12.230.210.201 / .202 | RHEL 8.10 (64bit) | Oracle 19C | PJOSCD | 1621 |

- 제조사: Dell
- 미들웨어: RVD (TIBCO Rendezvous Daemon)
- HA 구성: VIP 기반 Failover

---

## 전체 작업 구조

```
[PRE 시나리오]  D-14 ~ D-1
  계획정전 공지 → 시나리오 초안 → 각종 리스트 점검 → 외부 공지 → CAB 확정

[MAIN 시나리오]  D-Day (7/13 13:00~17:00)
  작업 전 준비 → 서버 작업 (Failover 테스트) → 복구 확인

[POST 시나리오]  작업 완료 후
  데이터 점검 → Post-Mortem → 보고서
```

---

## 문서 목록

| 파일 | 내용 | 시점 |
|------|------|------|
| [01_PRE_시나리오.md](01_PRE_시나리오.md) | 사전 준비 전체 절차 + 각종 리스트 점검 방법 | D-14 ~ D-1 |
| [02_CAB_회의_초안.md](02_CAB_회의_초안.md) | CAB 제출용 작업계획서 | D-3 |
| [03_MAIN_시나리오.md](03_MAIN_시나리오.md) | 작업 당일 단계별 절차 | D-Day |
| [04_POST_시나리오.md](04_POST_시나리오.md) | 데이터 점검 및 Post-Mortem | 완료 후 |
| [05_체크리스트.md](05_체크리스트.md) | Pre/Main/Post 전체 체크리스트 | 전체 |
| [06_이메일_템플릿.md](06_이메일_템플릿.md) | 공지/협조요청/완료 메일 | 각 시점 |
| [07_작업후_보고서_템플릿.md](07_작업후_보고서_템플릿.md) | 결과 보고서 양식 | 완료 후 |
| [scripts/](scripts/) | 자동화 스크립트 모음 | 작업 당일 |

---

## 자동화 스크립트 상세 설명

스크립트는 모두 `root` 계정으로 실행한다. 각 서버(PJTSAP, PJTSEC)에서 개별 실행한다.

```
scripts/
├── dry_run_check.sh            ← 사전 검증 (양산 영향 없음)
├── failover_readiness_check.sh ← Failover 없이 Failover 성공 가능성 검증 (양산 영향 없음)
├── pre_snapshot.sh             ← 작업 전 스냅샷 (양산 영향 없음)
├── stop_services.sh            ← 서비스 중지 (실제 중지 발생)
├── start_services.sh           ← 서비스 기동 (실제 기동 발생)
├── check_oracle.sh             ← Oracle 점검 (양산 영향 없음)
├── check_rvd.sh                ← RVD 점검 (양산 영향 없음)
├── post_compare.sh             ← 전후 비교 (양산 영향 없음)
├── stop_services_example.sh    ← 중지 스크립트 한 줄씩 설명 (참고용)
└── start_services_example.sh   ← 기동 스크립트 한 줄씩 설명 (참고용)
```

---

### 1. `dry_run_check.sh` — 사전 검증 (D-1 권장)

**목적**: 실제 작업 전, 자동화 스크립트가 이 서버에서 정상 동작할지 미리 확인한다.

**양산 영향**: **없음** — 아무것도 중지/기동/변경하지 않는다. 읽기 전용 명령만 사용.

**실행 방법**:
```bash
bash dry_run_check.sh
```

**확인 항목**:

| 항목 | 내용 |
|------|------|
| 필수 명령어 | `ps`, `ss`, `systemctl`, `sqlplus`, `lsnrctl` 등 존재 여부 |
| Oracle 환경 | `oracle` 계정, `ORACLE_HOME`, `ORACLE_SID` 설정 여부 |
| Oracle 접속 | `/ as sysdba` OS 인증 접속 가능 여부, `STATUS = OPEN` |
| PJOSCD 등록 | Listener에 PJOSCD 서비스 등록 여부 |
| root 권한 | `systemctl stop/start` 가능한 계정인지 |
| RVD | 프로세스 실행 여부 및 실행 파일 경로 |
| Cron | `getent passwd`, `crontab -l` 실행 가능 여부 |
| /tmp | 로그/백업 파일 저장 경로 쓰기 가능 여부 |
| DataGuard | MRP0 프로세스(동기화) 존재 여부 |
| VIP | 각 서버에서 VIP 위치 확인 |

**결과 판정**:
- 🟢 전체 정상 → 바로 진행 가능
- 🟡 경고만 있음 → 내용 확인 후 진행 가능
- 🔴 실패 항목 있음 → 작업 전 반드시 해결

**출력 파일**: `/tmp/dry_run_report_YYYYMMDD_HHmmss.txt`

---

### 2. `failover_readiness_check.sh` — Failover 없이 Failover 성공 가능성 검증

**목적**: 실제 Failover를 실행하지 않고, "지금 Failover가 발생한다면 성공할 것인가"를 판단한다.
이번 PM의 핵심 검증 목적으로, Failover를 트리거하지 않고도 동등한 수준의 사전 확인을 제공한다.

**양산 영향**: **없음** — 모든 확인은 읽기 전용이다.

**실행 방법**:
```bash
# 기본 실행 (이 서버만 확인)
bash failover_readiness_check.sh

# 상대 노드 IP를 지정하면 네트워크 도달성도 확인
bash failover_readiness_check.sh --other-node 12.230.210.205
```

**검증 항목 7가지**:

| # | 검증 항목 | 확인 내용 | Failover 관련성 |
|---|-----------|-----------|-----------------|
| 1 | HA 소프트웨어 | Pacemaker/keepalived 상태, VIP 리소스 등록, STONITH 설정 | VIP가 실제로 이동할 수 있는가 |
| 2 | Failover 스크립트 | 파일 존재, `sh -n` 문법 검사, 실행 권한 | 스크립트가 수행 가능한가 |
| 3 | DataGuard 동기화 | Transport/Apply lag, MRP0 프로세스 | Failover 시 데이터 손실량 |
| 4 | 접속 문자열 | tnsnames.ora / RVD 설정에서 VIP vs Real IP | 앱이 Failover 후 자동 연결되는가 |
| 5 | PJOSCD 자동 등록 | listener.ora 정적 등록 여부 | 재기동 후 서비스 등록 보장 여부 |
| 6 | 자동 기동 설정 | systemctl enable, oratab :Y 설정 | 서버 재시작 후 자동 복구 여부 |
| 7 | 상대 노드 상태 | TCP 도달성(포트 1621/22), ARP 테이블 | 인계 서버가 준비됐는가 |

> **핵심 원리**: Failover가 성공하려면 이 7가지가 모두 갖춰져 있어야 한다.
> 이 스크립트는 Failover를 실행하지 않고 이 조건들만 검증한다.
> 7가지 전부 통과 = 실제 Failover를 실행해도 성공할 가능성이 높음.

**판정 기준**:
- 🟢 실패 0, 경고 2 이하 → Failover 진행 추천
- 🟡 실패 0, 경고 다수 → 경고 항목 검토 후 진행 가능
- 🔴 실패 1 이상 → 해결 후 재검증 필요

**출력 파일**: `/tmp/failover_readiness_YYYYMMDD_HHmmss.txt`

---

### 3. `pre_snapshot.sh` — 작업 전 스냅샷 수집

**목적**: 작업 전 서버 상태를 파일로 저장한다. 작업 후 `post_compare.sh`가 이 파일과 비교하여 변경 사항을 리포트한다.

**양산 영향**: **없음** — 서버가 정상 운영 중인 상태에서 실행해도 전혀 문제없다.
읽기 전용 명령(ps, ss, df, crontab -l, ip addr 등)만 사용하며 서비스를 건드리지 않는다.
**D-1 또는 작업 당일 12:30~13:00에 실행 권장.**

**실행 방법**:
```bash
bash pre_snapshot.sh
```

**수집 항목**:

| 항목 | 저장 파일 |
|------|-----------|
| OS 정보 (호스트명, 커널, uptime) | `snapshot_before/01_os_info.txt` |
| 디스크 사용률 (`df -h`) | `snapshot_before/02_disk.txt` |
| 메모리/CPU 사용률 | `snapshot_before/03_memory_cpu.txt` |
| 전체 프로세스 목록 (`ps -ef`) | `snapshot_before/04_process_list.txt` |
| LISTEN 포트 목록 (`ss -tlnp`) | `snapshot_before/05_ports.txt` |
| VIP 위치 (`ip addr show`) | `snapshot_before/06_vip.txt` |
| Cron 등록 내용 (전 계정) | `snapshot_before/07_cron.txt` |
| Oracle 인스턴스 상태 | `snapshot_before/08_oracle_status.txt` |
| Oracle Listener 상태 | `snapshot_before/09_listener_status.txt` |
| 시스템 로그 최근 50줄 | `snapshot_before/10_syslog.txt` |

**저장 경로**: `/tmp/snapshot_before/`

---

### 3. `stop_services.sh` — 서비스 순차 중지

**목적**: PM 작업을 위해 서비스를 안전한 순서로 중지한다.

**양산 영향**: **있음** — 실행 즉시 서비스 중지가 발생한다. **작업 시작 시각 이후에만 실행.**

**중지 순서** (순서 변경 금지):
```
1. Cron 백업 → crond 중지     (배치 스케줄 실행 방지)
2. RVD 중지                    (메시지 브로커 연결 해제)
3. Oracle Listener 중지        (신규 DB 접속 차단, 포트 1621)
4. Oracle DB SHUTDOWN IMMEDIATE (데이터 정합성 보장 종료)
```

**실행 방법**:
```bash
bash stop_services.sh
```

**각 단계 완료 확인**:
```bash
# Cron 중지 확인
systemctl is-active crond       # → inactive

# RVD 중지 확인
ps -ef | grep rvd | grep -v grep  # → 출력 없음

# Listener 중지 확인
ss -tlnp | grep :1621             # → 출력 없음

# Oracle 중지 확인
ps -ef | grep pmon | grep -v grep # → 출력 없음
```

**로그 파일**: `/tmp/stop_YYYYMMDD_HHmmss.log`

---

### 4. `start_services.sh` — 서비스 순차 기동

**목적**: PM 작업 완료 후 서비스를 안전한 순서로 기동한다.

**양산 영향**: **있음** — 서비스가 기동된다. **Failover 테스트 완료 후 실행.**

**기동 순서** (순서 변경 금지):
```
1. Oracle DB STARTUP            (DB 먼저 완전 기동 필수)
2. Oracle Listener 기동         (포트 1621 오픈)
3. PJOSCD 서비스 등록 확인      ← 이 서버는 이 단계가 핵심
4. RVD 기동                    (Oracle OPEN 확인 후 기동)
5. Cron 재활성화                (배치 스케줄 재개)
6. Cron 내용 백업본과 대조      (누락 항목 없는지 확인)
```

> **PJOSCD 등록이 핵심인 이유**: Oracle Listener 기동 후 서비스(PJOSCD)가 자동 등록되지 않는 경우가 있다. 등록이 안 되면 애플리케이션/RVD에서 DB 접속 불가. 스크립트에서 자동으로 확인하며, 미등록 시 `ALTER SYSTEM REGISTER`를 실행해 강제 등록한다.

**실행 방법**:
```bash
bash start_services.sh
```

**각 단계 완료 확인**:
```bash
# Oracle 기동 확인
ps -ef | grep pmon | grep -v grep  # → pmon 프로세스 있음
ss -tlnp | grep :1621              # → 1621 포트 LISTEN

# PJOSCD 등록 확인
su - oracle -c "lsnrctl status" | grep PJOSCD  # → PJOSCD 있음

# RVD 기동 확인
ps -ef | grep rvd | grep -v grep   # → rvd 프로세스 있음

# Cron 확인
systemctl is-active crond          # → active
```

**로그 파일**: `/tmp/start_YYYYMMDD_HHmmss.log`

---

### 5. `check_oracle.sh` — Oracle 종합 점검

**목적**: Oracle 기동 후 상태를 종합적으로 확인한다.

**양산 영향**: **없음** — 읽기 전용 SQL 쿼리만 실행한다.

**실행 방법**:
```bash
bash check_oracle.sh
```

**점검 항목**:

| 항목 | 확인 내용 |
|------|-----------|
| pmon 프로세스 | Oracle 기동 여부 |
| 포트 1621 | Listener 포트 오픈 여부 |
| PJOSCD 서비스 | Listener 등록 여부 |
| V$INSTANCE | STATUS = OPEN |
| V$DATABASE | OPEN_MODE = READ WRITE |
| Tablespace | 사용률 80% 초과 항목 경고 |
| Redo Log | 현재 상태 |
| 접속 세션 수 | V$SESSION COUNT |
| DataGuard lag | transport/apply 지연 시간 |
| ORA- 에러 | Alert Log 최근 에러 |

---

### 6. `check_rvd.sh` — RVD 상태 점검

**목적**: RVD 기동 후 정상 동작 여부를 확인한다.

**양산 영향**: **없음** — 프로세스/포트/로그 조회만 수행한다.

**실행 방법**:
```bash
bash check_rvd.sh
```

**점검 항목**:

| 항목 | 확인 내용 |
|------|-----------|
| rvd 프로세스 | 실행 여부 및 PID |
| 포트 | RVD 리스닝 포트 확인 |
| Oracle 선행 조건 | pmon + 포트 1621 기동 여부 |
| RVD 로그 | 최근 에러 여부 |

---

### 7. `post_compare.sh` — 전후 비교 리포트

**목적**: `pre_snapshot.sh`로 저장한 작업 전 상태와 현재 상태를 비교하여 달라진 점을 자동으로 리포트한다.

**양산 영향**: **없음** — 읽기 전용 조회만 수행한다.

**실행 방법**:
```bash
# pre_snapshot.sh 실행 후, 작업 완료 시점에 실행
bash post_compare.sh
```

**비교 항목**:

| 항목 | 비교 방법 |
|------|-----------|
| 프로세스 목록 | 작업 전 vs 현재 `ps -ef` diff |
| LISTEN 포트 | 포트 1621 포함 전체 포트 비교 |
| 디스크 사용률 | 작업 전후 증감 |
| Cron 내용 | 백업본과 현재 내용 diff |
| VIP 위치 | IP 주소 변경 여부 |
| Oracle 상태 | STATUS, OPEN_MODE |
| PJOSCD 등록 | Listener 등록 여부 |
| DataGuard lag | transport/apply 지연 |

**출력 예시**:
```
=== 전후 비교 리포트 ===
✅ Oracle STATUS: OPEN (정상)
✅ 포트 1621: LISTEN (정상)
✅ PJOSCD 서비스: 등록됨
✅ Cron 내용: 백업본과 동일
⚠️ 프로세스 변화 있음 (diff 내용 참고)
---
✅ 정상: 7   ⚠️ 경고: 1   ❌ 오류: 0
```

**출력 파일**: `/tmp/compare_report_YYYYMMDD_HHmmss.txt`

---

### 8. `stop_services_example.sh` / `start_services_example.sh` — 참고용 예시 스크립트

**목적**: 스크립트를 처음 보는 사람이 각 명령어를 이해하고 수정할 수 있도록 한 줄씩 한국어로 설명한 참고용 파일이다.

**실제 운영에는 사용하지 않는다.** stop_services.sh / start_services.sh 를 사용한다.

**포함 내용**:
- 스크립트에서 자주 쓰는 기초 문법 (`ps`, `grep`, `awk`, `||`, `&&`, `tee`, `kill` 등) 설명
- 각 STEP이 왜 이 순서인지 이유 설명
- RVD 기동 명령처럼 환경마다 다른 부분에 수정 가이드 표시
- 맨 아래에 Q&A 형태 수정 가이드 포함

---

## 스크립트 실행 순서 요약

```
[D-1 또는 작업 며칠 전]
  bash dry_run_check.sh      ← 양산 영향 없음. 문제 있으면 이 시점에 해결.

[D-Day 12:30 ~ 13:00]
  bash pre_snapshot.sh       ← 양산 영향 없음. 서버 운영 중에 실행.

[D-Day 13:00 ~  서비스 중지 시]
  bash stop_services.sh      ← 실제 중지 발생. 시작 시각 이후에만 실행.

[Failover 테스트 완료 후]
  bash start_services.sh     ← 서비스 기동.
  bash check_oracle.sh       ← Oracle 기동 상태 확인.
  bash check_rvd.sh          ← RVD 기동 상태 확인.

[서비스 정상 확인 후]
  bash post_compare.sh       ← 전후 비교 리포트. 이상 없으면 작업 완료.
```

---

## ⚠️ 절대 놓치면 안 되는 핵심

> 🔴 **1. Oracle Listener 포트 1621 확인** — 표준 1521이 아님. 기동 후 반드시 1621 포트 확인
>
> 🔴 **2. PJOSCD 서비스 Listener 등록 확인** — 미등록 시 앱/RVD 접속 불가. start_services.sh가 자동 처리하나 반드시 재확인
>
> 🔴 **3. Cron 재활성화 확인** — 작업 후 복구 시 가장 많이 빠뜨리는 항목
>
> 🔴 **4. DB 동기화 재개 확인** — 양 서버(PJTSAP/PJTSEC) 모두 동기화 상태 확인
>
> 🔴 **5. RVD 기동 순서** — Oracle 완전 기동 후 RVD 기동. 역순 금지
