#!/bin/bash
# ============================================================
# process_cron_compare.sh
# 프로세스 목록 vs Crontab 교차 비교 — 고아 프로세스 선제 탐지
#
# 목적:
#   Failover 전에 "Crontab으로 관리되지 않는 프로세스"를 사전 식별한다.
#   이 프로세스들은 Failover 후 아무도 자동 재기동하지 않아 누락된다.
#   사전에 발견하여 담당자 확인 및 조치 계획을 세우는 것이 목적.
#
# AS-IS: Failover 후 미기동 발견 → 긴급 조사
# TO-BE: Failover 전 고아 프로세스 탐지 → 선제 조치
#
# 양산 영향: 없음 — 읽기 전용, 프로세스 목록과 Crontab만 조회
#
# 실행 방법: bash process_cron_compare.sh
# 출력 파일: /tmp/orphan_process_report_YYYYMMDD_HHmmss.txt
# ============================================================

REPORT=/tmp/orphan_process_report_$(date +%Y%m%d_%H%M%S).txt
CRON_DUMP=/tmp/_pcc_cron_all_$$
PROC_DUMP=/tmp/_pcc_proc_all_$$

# 스크립트 종료 시 임시 파일 자동 삭제
trap "rm -f $CRON_DUMP $PROC_DUMP" EXIT

ORPHAN=0
MANAGED=0
SKIP=0

sep()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$REPORT"; }
warn() { echo "  ⚠️  $*" | tee -a "$REPORT"; }
ok()   { echo "  ✅ $*" | tee -a "$REPORT"; }
info() { echo "  ℹ️  $*" | tee -a "$REPORT"; }

echo "============================================================" | tee "$REPORT"
echo " 프로세스 vs Crontab 교차 비교 - $(date)"                    | tee -a "$REPORT"
echo " 서버: $(hostname)"                                           | tee -a "$REPORT"
echo " 읽기 전용 — 양산 영향 없음"                                 | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"

# ─────────────────────────────────────────────────────────────
# STEP 1: 전 계정 Crontab 수집
# ─────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
sep
echo " STEP 1. 전 계정 Crontab 수집" | tee -a "$REPORT"
sep

> "$CRON_DUMP"  # 파일 초기화

USER_COUNT=0
CRON_USER_COUNT=0

for USER in $(getent passwd | cut -d: -f1); do
    USER_COUNT=$((USER_COUNT + 1))
    CRON=$(crontab -l -u "$USER" 2>/dev/null | grep -v "^#" | grep -v "^$")
    if [ -n "$CRON" ]; then
        CRON_USER_COUNT=$((CRON_USER_COUNT + 1))
        echo "$CRON" >> "$CRON_DUMP"
    fi
done

CRON_ENTRY_COUNT=$(wc -l < "$CRON_DUMP" | tr -d ' ')
echo "  전체 계정: ${USER_COUNT}개" | tee -a "$REPORT"
echo "  Crontab 등록 계정: ${CRON_USER_COUNT}개" | tee -a "$REPORT"
echo "  전체 Crontab 항목: ${CRON_ENTRY_COUNT}줄" | tee -a "$REPORT"

# Crontab에서 실행 명령어(경로) 추출
# 형식 예: "0 * * * * /opt/app/run.sh arg1 arg2"
# → 6번째 필드부터가 명령어
# awk로 5개 필드(분 시 일 월 요일) 이후 전체를 추출
CRON_CMDS_FILE=/tmp/_pcc_cron_cmds_$$
trap "rm -f $CRON_DUMP $PROC_DUMP $CRON_CMDS_FILE" EXIT

awk '{
    # 첫 5필드는 스케줄(분 시 일 월 요일), 6번째부터 명령어
    # @reboot 형태도 처리
    if ($1 == "@reboot") {
        # @reboot 뒤 전체 명령
        cmd = ""
        for(i=2; i<=NF; i++) cmd = cmd " " $i
    } else if (NF >= 6) {
        cmd = ""
        for(i=6; i<=NF; i++) cmd = cmd " " $i
    }
    # 명령어에서 경로의 basename 추출 (비교 단순화)
    # /opt/app/run.sh → run.sh
    n = split(cmd, parts, "/")
    basename = parts[n]
    # 인자 제거 (첫 공백 전까지)
    n2 = split(basename, bparts, " ")
    print bparts[1]
}' "$CRON_DUMP" 2>/dev/null | sort -u > "$CRON_CMDS_FILE"

echo "" | tee -a "$REPORT"
echo "  [Crontab에 등록된 명령어 목록]" | tee -a "$REPORT"
while IFS= read -r cmd; do
    [ -n "$cmd" ] && echo "    - $cmd" | tee -a "$REPORT"
done < "$CRON_CMDS_FILE"

# ─────────────────────────────────────────────────────────────
# STEP 2: 실행 중인 프로세스 수집 (시스템 프로세스 제외)
# ─────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
sep
echo " STEP 2. 실행 중인 프로세스 수집 (사용자 프로세스)" | tee -a "$REPORT"
sep

# 시스템 프로세스 제외 기준 (UID < 1000이면서 well-known 데몬)
# kernel 스레드, 시스템 데몬은 비교 대상 제외
SYSTEM_PROCS="kthreadd kworker ksoftirqd migration watchdog cpuhp \
              kdevtmpfs netns kauditd khungtaskd oom_reaper \
              writeback kcompactd kblockd ata_sff scsi_eh \
              kdmflush bioset kswapd kthrotld irq jbd2 ext4 \
              systemd-journald systemd-udevd systemd-logind \
              dbus-daemon sshd crond rsyslogd tuned polkitd \
              chronyd NetworkManager firewalld auditd \
              zabbix_agentd snmpd ntpd postfix sendmail \
              keepalived corosync pacemaker pcsd \
              agetty login bash sh zsh"

> "$PROC_DUMP"

# ps -eo: 원하는 필드만 출력
# uid,pid,ppid,comm,cmd: 사용자ID, PID, 부모PID, 명령명, 전체명령
ps -eo uid,pid,ppid,comm,cmd --no-headers 2>/dev/null | while read -r UID PID PPID COMM CMD; do

    # PID 1 (systemd/init), PID 2 (kthreadd)는 제외
    [ "$PID" -le 2 ] 2>/dev/null && continue

    # kernel 스레드 (PPID=2인 경우 대부분 커널 스레드)
    [ "$PPID" -eq 2 ] 2>/dev/null && continue

    # 명령어가 [ 또는 ( 로 시작하면 커널 스레드
    echo "$COMM" | grep -qE '^\[|^\(' && continue

    # well-known 시스템 프로세스 제외
    SKIP_FLAG=0
    for SP in $SYSTEM_PROCS; do
        [ "$COMM" = "$SP" ] && SKIP_FLAG=1 && break
    done
    [ "$SKIP_FLAG" -eq 1 ] && continue

    # oracle 관련 주요 백그라운드 프로세스 이름 패턴 (pmon, smon, dbwr, lgwr 등)
    # 이것들은 Oracle 기동으로 자동 생성 — Crontab 비교 대상이 아님
    echo "$COMM" | grep -qE '^(pmon|smon|dbwr|lgwr|ckpt|reco|arc|mman|mmon|lmon|lmd|lms|diag|dbrm|vktm|gen|dmon|rvw|fbda|tmon|w[0-9]|s[0-9]|p[0-9]|q[0-9])' && continue

    # 수집
    echo "$UID|$PID|$PPID|$COMM|$CMD"

done > "$PROC_DUMP"

PROC_COUNT=$(wc -l < "$PROC_DUMP" | tr -d ' ')
echo "  수집된 사용자 프로세스: ${PROC_COUNT}개" | tee -a "$REPORT"

# ─────────────────────────────────────────────────────────────
# STEP 3: 교차 비교 — 고아 프로세스 탐지
# ─────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
sep
echo " STEP 3. 교차 비교 — 고아 프로세스 탐지" | tee -a "$REPORT"
sep
echo "" | tee -a "$REPORT"
echo "  [판단 기준]" | tee -a "$REPORT"
echo "  ✅ Crontab O = 관리되는 프로세스 → Failover 후 Cron이 자동 재기동" | tee -a "$REPORT"
echo "  ⚠️  Crontab X = 고아 프로세스     → Failover 후 아무도 재기동 안 함" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "  ┌──────────────────────────────────────────────────────────────┐" | tee -a "$REPORT"
echo "  │ 고아 프로세스 목록 (Failover 후 미기동 위험)                 │" | tee -a "$REPORT"
echo "  ├──────┬────────────────────────┬──────────────────────────────┤" | tee -a "$REPORT"
echo "  │ PID  │ 프로세스명             │ 전체 명령어                  │" | tee -a "$REPORT"
echo "  ├──────┼────────────────────────┼──────────────────────────────┤" | tee -a "$REPORT"

ORPHAN_LIST=""

while IFS='|' read -r UID PID PPID COMM CMD; do
    [ -z "$COMM" ] && continue

    # 이 프로세스의 basename이 Crontab 명령 목록에 있는지 확인
    FOUND=0

    # 1차: COMM(명령명) 직접 매칭
    if grep -qxF "$COMM" "$CRON_CMDS_FILE" 2>/dev/null; then
        FOUND=1
    fi

    # 2차: CMD(전체 경로) 에서 basename 추출 후 매칭
    if [ "$FOUND" -eq 0 ]; then
        CMD_BASE=$(echo "$CMD" | awk '{print $1}' | awk -F'/' '{print $NF}')
        if grep -qxF "$CMD_BASE" "$CRON_CMDS_FILE" 2>/dev/null; then
            FOUND=1
        fi
    fi

    # 3차: CMD에 포함된 단어 중 Crontab 명령과 일치하는 것이 있는지
    if [ "$FOUND" -eq 0 ]; then
        while IFS= read -r CRON_CMD; do
            [ -z "$CRON_CMD" ] && continue
            if echo "$CMD" | grep -qF "$CRON_CMD" 2>/dev/null; then
                FOUND=1
                break
            fi
        done < "$CRON_CMDS_FILE"
    fi

    if [ "$FOUND" -eq 1 ]; then
        MANAGED=$((MANAGED + 1))
    else
        ORPHAN=$((ORPHAN + 1))
        # CMD 출력 길이 제한 (50자)
        SHORT_CMD=$(echo "$CMD" | cut -c1-50)
        SHORT_COMM=$(printf "%-22s" "$COMM")
        SHORT_PID=$(printf "%-6s" "$PID")
        echo "  │ $SHORT_PID│ $SHORT_COMM │ $SHORT_CMD" | tee -a "$REPORT"
        ORPHAN_LIST="$ORPHAN_LIST\n$PID|$COMM|$CMD"
    fi

done < "$PROC_DUMP"

echo "  └──────┴────────────────────────┴──────────────────────────────┘" | tee -a "$REPORT"

# ─────────────────────────────────────────────────────────────
# STEP 4: 고아 프로세스 상세 분석
# ─────────────────────────────────────────────────────────────
if [ "$ORPHAN" -gt 0 ]; then
    echo "" | tee -a "$REPORT"
    sep
    echo " STEP 4. 고아 프로세스 상세 분석 및 권고 조치" | tee -a "$REPORT"
    sep
    echo "" | tee -a "$REPORT"

    echo "$ORPHAN_LIST" | grep -v "^$" | while IFS='|' read -r PID COMM CMD; do
        [ -z "$PID" ] && continue
        echo "  ┌─ PID: $PID  /  프로세스: $COMM" | tee -a "$REPORT"
        echo "  │  명령어: $CMD" | tee -a "$REPORT"

        # 프로세스 실행 계정 확인
        PROC_USER=$(ps -o user= -p "$PID" 2>/dev/null | tr -d ' ')
        echo "  │  실행 계정: $PROC_USER" | tee -a "$REPORT"

        # 프로세스 기동 시간 확인
        PROC_ETIME=$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')
        echo "  │  실행 경과: $PROC_ETIME" | tee -a "$REPORT"

        # 부모 프로세스 확인
        PPID_VAL=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
        PARENT_CMD=$(ps -o comm= -p "$PPID_VAL" 2>/dev/null | tr -d ' ')
        echo "  │  부모 프로세스: PID $PPID_VAL ($PARENT_CMD)" | tee -a "$REPORT"

        # 권고 조치 추론
        echo "  │" | tee -a "$REPORT"
        echo "  │  [권고 조치] 담당자 확인 후 아래 중 선택:" | tee -a "$REPORT"
        echo "  │   ① Crontab 등록   → 재기동 자동화" | tee -a "$REPORT"
        echo "  │   ② 기동 스크립트에 추가 → start_services.sh에 포함" | tee -a "$REPORT"
        echo "  │   ③ 수동 기동 계획 → 담당자가 Failover 후 직접 기동" | tee -a "$REPORT"
        echo "  │   ④ 종료 가능 여부 확인 → 불필요하면 PM 전에 종료" | tee -a "$REPORT"
        echo "  └────────────────────────────────────────────────────────" | tee -a "$REPORT"
        echo "" | tee -a "$REPORT"
    done
fi

# ─────────────────────────────────────────────────────────────
# STEP 5: Crontab으로 관리되는 프로세스 목록 (참고)
# ─────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
sep
echo " STEP 5. Crontab 관리 프로세스 확인 (안전 목록)" | tee -a "$REPORT"
sep
echo "  이 프로세스들은 Failover 후 Cron이 자동 재기동한다." | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

while IFS='|' read -r UID PID PPID COMM CMD; do
    [ -z "$COMM" ] && continue
    FOUND=0

    CMD_BASE=$(echo "$CMD" | awk '{print $1}' | awk -F'/' '{print $NF}')
    grep -qxF "$COMM" "$CRON_CMDS_FILE" 2>/dev/null && FOUND=1
    grep -qxF "$CMD_BASE" "$CRON_CMDS_FILE" 2>/dev/null && FOUND=1

    if [ "$FOUND" -eq 1 ]; then
        printf "  ✅  PID %-6s  %-20s  %s\n" "$PID" "$COMM" "$(echo "$CMD" | cut -c1-40)" | tee -a "$REPORT"
    fi
done < "$PROC_DUMP"

# ─────────────────────────────────────────────────────────────
# 최종 요약
# ─────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
echo " 최종 요약" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
echo "  Crontab 관리 프로세스 (Failover 후 자동 복구): ${MANAGED}개  ✅" | tee -a "$REPORT"
echo "  고아 프로세스 (Failover 후 수동 조치 필요):    ${ORPHAN}개  ⚠️" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

if [ "$ORPHAN" -eq 0 ]; then
    echo "  → 판정: 🟢 모든 프로세스가 Crontab으로 관리됨." | tee -a "$REPORT"
    echo "           Failover 후 자동 복구 가능. 선제 조치 불필요." | tee -a "$REPORT"
elif [ "$ORPHAN" -le 3 ]; then
    echo "  → 판정: 🟡 고아 프로세스 ${ORPHAN}개 발견." | tee -a "$REPORT"
    echo "           Failover 전 상단 목록의 각 프로세스 담당자 확인 및 조치 필요." | tee -a "$REPORT"
else
    echo "  → 판정: 🔴 고아 프로세스 ${ORPHAN}개 발견." | tee -a "$REPORT"
    echo "           Failover 전 반드시 각 프로세스 처리 방법 확정 필요." | tee -a "$REPORT"
fi

echo "" | tee -a "$REPORT"
echo "  리포트: $REPORT" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
