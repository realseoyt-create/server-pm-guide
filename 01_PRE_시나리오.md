# 01. PRE 시나리오 (사전 준비)

> **수행 기간**: D-14 ~ D-1
> **PM 일정**: 2025년 7월 13일 (일) 13:00 ~ 17:00

---

## 전체 PRE 시나리오 흐름

```
D-14  계획정전 공지 전달
D-10  작업 대응 시나리오 초안 작성
D-7   서버 프로세스 / DB동기화 / 파일 인터페이스 / 품질 프로세스 리스트 체크
D-7   프로그램 전송 시스템 사전 공지
D-5   외부 시스템 공지
D-5   Cron 등록 현황 파악 (부서별 확인 요청)
D-3   Failover 스크립트 점검
D-3   CAB 회의 진행 및 시나리오 확정
D-1   최종 점검 및 스크립트 검증
D-1   비상 연락망 최종 배포
```

---

## 1. 계획정전 공지 전달 (D-14)

- 계획정전 일시, 영향 범위, 복구 예상 시간을 포함하여 전체 관련 부서에 공지
- 공지 대상: 내부 팀, 연계 시스템 담당자, 외부 시스템 담당자
- 06_이메일_템플릿.md의 **메일 1** 사용

---

## 2. 작업 대응 시나리오 초안 작성 (D-10)

- 본 문서(MAIN/POST 시나리오) 기반으로 실제 환경에 맞게 커스터마이징
- 롤백 기준 시간 확정: 작업 시작 후 **[X]시간** 이내 완료 안 될 경우 롤백
- 롤백 결정권자 지정: [이름/직책]

---

## 3. 서버 프로세스 리스트 체크 (D-7)

> **목적**: 현재 정상 운영 중인 프로세스를 파악하여 작업 후 비교 기준으로 삼는다.

### PJTSAP (Active 또는 확인 대상)

```bash
# 1. 서버 접속
ssh root@12.230.210.205   # 또는 .206

# 2. OS 기본 정보
uname -a
# 예상: Linux pjtsap 4.18.0-... x86_64 x86_64 x86_64 GNU/Linux

cat /etc/redhat-release
# 예상: Red Hat Enterprise Linux 8.10 (Ootpa)

# 3. 전체 프로세스 스냅샷 저장
ps -ef --forest > /tmp/ps_before_$(date +%Y%m%d).txt
echo "저장 완료: /tmp/ps_before_$(date +%Y%m%d).txt"

# 4. 주요 프로세스 확인
echo "=== Oracle ===" && ps -ef | grep pmon | grep -v grep
echo "=== RVD ===" && ps -ef | grep rvd | grep -v grep
echo "=== 기타 주요 프로세스 ===" && ps -ef | grep -E "java|batch|agent" | grep -v grep

# 5. 리스닝 포트 목록 저장
ss -tlnp > /tmp/ports_before_$(date +%Y%m%d).txt
echo "=== 주요 포트 확인 ==="
ss -tlnp | grep -E "1621|7500"
# 1621: Oracle Listener, 7500: RVD (기본값, 환경 따라 다름)
```

### PJTSEC (동일하게 수행)

```bash
ssh root@12.230.210.201   # 또는 .202
# 위와 동일한 명령어 수행
```

---

## 4. DB 동기화 리스트 체크 (D-7)

> 양 서버(PJTSAP ↔ PJTSEC) 간 DB 동기화 구성을 파악하고 현재 상태를 확인한다.

```bash
# oracle 계정으로 수행
su - oracle

# Oracle 19C Data Guard 구성 여부 확인
sqlplus / as sysdba <<EOF
-- DB 역할 확인 (PRIMARY / PHYSICAL STANDBY / LOGICAL STANDBY)
SELECT DB_UNIQUE_NAME, DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;

-- Data Guard 상태 확인 (구성된 경우)
SELECT DEST_ID, STATUS, TARGET, ARCHIVER, SCHEDULE, DESTINATION
FROM V\$ARCHIVE_DEST WHERE STATUS='VALID';

-- Redo 전송 지연 확인 (Standby 측에서)
SELECT NAME, VALUE FROM V\$DATAGUARD_STATS
WHERE NAME IN ('transport lag', 'apply lag');
EXIT;
EOF
```

> 💡 **TIP**: Data Guard가 아닌 다른 동기화 방식(스크립트 기반, rman 등)을 사용 중이면
> 해당 동기화 프로세스 확인 방법을 사전에 파악해 두어야 함.

```bash
# 동기화 관련 프로세스 확인
ps -ef | grep -E "dgmgrl|dmon|mrp|lns|arc" | grep -v grep
```

---

## 5. 파일 인터페이스 리스트 체크 (D-7)

> 파일 기반으로 데이터를 주고받는 시스템 목록을 파악한다.

```bash
# 인터페이스 관련 디렉토리 확인 (경로는 환경마다 다름)
# 일반적인 인터페이스 디렉토리 패턴
find / -maxdepth 5 -type d -name "interface" 2>/dev/null
find / -maxdepth 5 -type d -name "inbound" 2>/dev/null
find / -maxdepth 5 -type d -name "outbound" 2>/dev/null

# 최근 24시간 내 생성/수정된 인터페이스 파일 확인
find /[인터페이스경로] -mtime -1 -type f | wc -l

# 인터페이스 파일 전송 관련 프로세스 확인
ps -ef | grep -E "ftp|sftp|rsync|scp" | grep -v grep
```

**체크 항목**:
- [ ] 인터페이스 디렉토리 경로 목록
- [ ] 파일 전송 주기 (실시간/배치)
- [ ] 작업 시간 중 전송 건 처리 방법 확정 (대기/폐기/재전송)

---

## 6. 품질 프로세스 리스트 체크 (D-7)

> 품질/QA 관련 배치, 모니터링 프로세스를 파악한다.

```bash
# 품질 관련 프로세스 파악 (계정명/프로세스명은 환경마다 다름)
ps -ef | grep -i "quality\|qa\|check\|monitor" | grep -v grep

# 관련 스케줄 확인
for user in root oracle app qa batch; do
    echo "=== $user crontab ==="
    crontab -l -u $user 2>/dev/null
done
```

**확인 후 정리할 내용**:
- 품질 체크 프로세스명과 실행 계정
- 작업 시간 중 중단 필요 여부
- 중단 방법 (프로세스 kill / Cron 주석 처리)

---

## 7. 프로그램 전송 시스템 사전 공지 (D-7)

- 프로그램 전송 시스템 담당자에게 작업 일정 공지
- 작업 시간 중 전송 중단 요청
- 작업 완료 후 재개 시점 협의
- 06_이메일_템플릿.md의 **메일 3 (연계 시스템 협조 요청)** 참고

---

## 8. 외부 시스템 공지 (D-5)

- 연계된 외부 시스템 담당자에게 개별 공지
- 공지 내용: 중단 시간, 영향 범위, 완료 후 재개 방법
- 확인 회신 수령 및 이슈 없음 확인

---

## 9. Cron 등록 현황 파악 (D-5)

> 🔴 **중요**: 작업 시간대에 실행되는 Cron이 있으면 DB/RVD 중지 상태에서 오류 발생 가능.

```bash
# 두 서버 각각 수행

# 전체 계정 crontab 추출 및 저장
CRON_BACKUP=/tmp/crontab_backup_$(date +%Y%m%d).txt
echo "=== Cron 백업: $(date) ===" > $CRON_BACKUP

for user in $(getent passwd | cut -d: -f1); do
    CRON=$(crontab -l -u $user 2>/dev/null)
    if [ -n "$CRON" ]; then
        echo "" >> $CRON_BACKUP
        echo "### 계정: $user ###" >> $CRON_BACKUP
        echo "$CRON" >> $CRON_BACKUP
    fi
done

echo "저장 완료: $CRON_BACKUP"
cat $CRON_BACKUP

# 작업 시간대(13:00~17:00) 충돌 항목 확인
echo ""
echo "=== 13시~17시 실행 Cron 항목 ==="
grep -v "^#" $CRON_BACKUP | awk '{
    if ($1 ~ /^[0-9*]/ && ($2+0 >= 13 && $2+0 <= 17 || $2 == "*"))
        print "충돌가능:", $0
}'
```

---

## 10. Failover 스크립트 점검 (D-3)

> Failover 스크립트가 있다면 내용을 검토하고 정상 동작 여부를 확인한다.

```bash
# Failover 스크립트 위치 파악
find / -maxdepth 6 -name "*failover*" -o -name "*switchover*" -o -name "*vip*" 2>/dev/null | grep -v proc

# 스크립트 내용 확인
# VIP 전환 스크립트 예시 확인
cat [Failover 스크립트 경로]

# VIP 현재 위치 확인
ip addr show | grep "12.230.210.207"   # PJTSAP VIP
ip addr show | grep "12.230.210.203"   # PJTSEC VIP
```

**점검 항목**:
- [ ] Failover 스크립트 존재 및 위치 확인
- [ ] 스크립트 실행 계정 및 권한 확인
- [ ] VIP 전환 메커니즘 파악 (Pacemaker / keepalived / 자체 스크립트)
- [ ] 수동 Failover 방법 확인 (스크립트 자동 전환 실패 시 대비)

```bash
# Pacemaker 사용 시
pcs status        # 클러스터 전체 상태
pcs resource show # 리소스 목록

# keepalived 사용 시
systemctl status keepalived
cat /etc/keepalived/keepalived.conf
```

---

## 11. CAB 회의 진행 및 시나리오 확정 (D-3)

- 02_CAB_회의_초안.md 기반으로 CAB 문서 제출
- 회의에서 확정할 사항:
  - 작업 시간 최종 확정 (7월 13일 13:00~17:00)
  - 롤백 기준 시간 및 결정권자
  - 참여 인원 및 역할 분담
  - 비상 연락망

---

## 12. D-1 최종 점검

```bash
# 두 서버 각각 수행

# 디스크 사용률 확인
df -h
# 80% 이상인 파티션 있으면 정리

# 메모리 확인
free -h

# Oracle Alert Log 최근 오류 확인
su - oracle
tail -200 $ORACLE_BASE/diag/rdbms/*/*/trace/alert_*.log | grep "ORA-"
# ORA- 에러 없어야 함

# Failover 스크립트 최종 검증
sh -n [Failover 스크립트 경로]

# 비상 연락망 최종 배포
# 06_이메일_템플릿.md 메일 4 (D-1 최종 확인) 발송
```

---

## 13. 추가 사전 점검 항목 (누락 방지)

> 위 10가지 외에 실제 작업에서 놓치기 쉬운 항목들

| 항목 | 확인 내용 | 담당 |
|------|-----------|------|
| 백업 최신 여부 | 작업 전날 백업 정상 완료 확인 | DBA |
| Oracle Redo Log 상태 | V$LOG에서 ARCHIVED=YES 확인 | DBA |
| Tablespace 여유 | 모든 TS 사용률 < 85% | DBA |
| 서버 시간 동기화 | 두 서버 시간 차이 < 1초 | 인프라 |
| iLO/IPMI 접근 | 비상 시 원격 전원 제어 방법 확인 | 인프라 |
| 모니터링 알람 설정 | 작업 시간 중 알람 비활성화 방법 | 운영 |
