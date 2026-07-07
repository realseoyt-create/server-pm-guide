#!/bin/bash
# ============================================================
# failover_readiness_check.sh
# Failover 실행 없이 Failover 성공 가능성 사전 검증
#
# 목적: 실제 Failover를 트리거하지 않고,
#       "지금 Failover가 발생한다면 성공할 것인가"를 판단한다.
#
# 양산 영향: 없음 — 모든 확인은 읽기 전용
#
# 실행 방법: 양 서버에서 각각 실행
#   bash failover_readiness_check.sh
#   bash failover_readiness_check.sh --other-node 12.230.210.205  # 상대 노드 지정 시
#
# 출력: /tmp/failover_readiness_YYYYMMDD_HHmmss.txt
#
# ─────────────────────────────────────────────────────────────
# Failover가 성공하기 위한 전제 조건 7가지
# ─────────────────────────────────────────────────────────────
# 1. HA 소프트웨어(keepalived/Pacemaker)가 VIP를 제어 중인가
# 2. Failover 스크립트가 존재하고 문법이 올바른가
# 3. 상대 노드(인계 서버)가 Oracle을 받을 준비가 됐는가
# 4. DataGuard 동기화 lag이 허용 범위인가 (데이터 손실 없는가)
# 5. VIP로 접속 중인가 (Real IP 하드코딩이면 Failover 의미 없음)
# 6. Oracle이 재기동 후 Listener에 PJOSCD 서비스를 등록하는가
# 7. 각 서비스의 자동 기동 설정이 올바른가
# ============================================================

OTHER_NODE=""
if [ "$1" = "--other-node" ] && [ -n "$2" ]; then
    OTHER_NODE="$2"
fi

REPORT=/tmp/failover_readiness_$(date +%Y%m%d_%H%M%S).txt
OK=0; WARN=0; FAIL=0; INFO=0

ok()      { echo "  ✅ $*"   | tee -a "$REPORT"; OK=$((OK+1)); }
warn()    { echo "  ⚠️  $*"  | tee -a "$REPORT"; WARN=$((WARN+1)); }
fail()    { echo "  ❌ $*"   | tee -a "$REPORT"; FAIL=$((FAIL+1)); }
info()    { echo "  ℹ️  $*"   | tee -a "$REPORT"; INFO=$((INFO+1)); }
section() { echo "" | tee -a "$REPORT"; echo "━━━ $* ━━━" | tee -a "$REPORT"; }

echo "============================================================" | tee "$REPORT"
echo " FAILOVER READINESS CHECK - $(date)"                         | tee -a "$REPORT"
echo " 서버: $(hostname)"                                           | tee -a "$REPORT"
echo " 양산 영향 없음 — 읽기 전용 검증"                            | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"

# ─────────────────────────────────────────────────────────────
# CHECK 1. HA 소프트웨어 및 VIP 제어
# ─────────────────────────────────────────────────────────────
section "1. HA 소프트웨어 및 VIP 제어"

HA_TYPE=""

# Pacemaker 확인
if systemctl is-active pacemaker > /dev/null 2>&1; then
    ok "Pacemaker 서비스 active"
    HA_TYPE="pacemaker"

    # pcs status: 클러스터 전체 상태 조회 (읽기 전용)
    if command -v pcs > /dev/null 2>&1; then
        PCS_OUT=$(pcs status 2>/dev/null)
        echo "$PCS_OUT" >> "$REPORT"

        # VIP 리소스 Online 확인
        if echo "$PCS_OUT" | grep -q "Started\|Online"; then
            ok "Pacemaker 클러스터 Online 상태"
        else
            fail "Pacemaker 클러스터 Online 아님 — pcs status 확인 필요"
        fi

        # STONITH(펜싱) 설정 확인 — split-brain 방지 핵심
        if echo "$PCS_OUT" | grep -qi "stonith"; then
            ok "STONITH 설정 확인됨 (split-brain 방지)"
        else
            warn "STONITH 설정 불명확 — pcs stonith show 로 직접 확인 권장"
        fi

        # VIP 리소스 존재 여부
        for VIP in "12.230.210.207" "12.230.210.203"; do
            if echo "$PCS_OUT" | grep -q "$VIP"; then
                ok "VIP $VIP Pacemaker 리소스에 등록됨"
            else
                warn "VIP $VIP Pacemaker 리소스에 미확인"
            fi
        done
    fi

# keepalived 확인
elif systemctl is-active keepalived > /dev/null 2>&1; then
    ok "keepalived 서비스 active"
    HA_TYPE="keepalived"

    # keepalived 설정 파일에서 VIP 확인 (읽기 전용)
    KA_CONF=""
    for F in /etc/keepalived/keepalived.conf /etc/keepalived.conf; do
        [ -f "$F" ] && KA_CONF="$F" && break
    done

    if [ -n "$KA_CONF" ]; then
        ok "keepalived 설정 파일: $KA_CONF"

        for VIP in "12.230.210.207" "12.230.210.203"; do
            if grep -q "$VIP" "$KA_CONF" 2>/dev/null; then
                ok "VIP $VIP keepalived 설정에 등록됨"
            else
                warn "VIP $VIP keepalived 설정에 미확인"
            fi
        done

        # 현재 상태 (MASTER/BACKUP)
        KA_STATE=$(grep -i "state" "$KA_CONF" | head -1 | awk '{print $2}')
        info "이 노드의 keepalived 상태 설정: $KA_STATE"

        # priority 값 확인 — Failover 방향을 결정
        KA_PRIO=$(grep -i "priority" "$KA_CONF" | head -1 | awk '{print $2}')
        info "keepalived priority: $KA_PRIO (높을수록 MASTER 우선)"
    else
        warn "keepalived 설정 파일 위치 불명확 — 직접 확인 필요"
    fi

else
    fail "Pacemaker / keepalived 모두 미실행 — HA 소프트웨어 확인 필요"
    info "확인 명령: systemctl status pacemaker keepalived"
fi

# 이 서버가 현재 VIP를 보유 중인지 확인
echo "" | tee -a "$REPORT"
echo "  [현재 이 서버의 VIP 보유 현황]" | tee -a "$REPORT"
for VIP in "12.230.210.207" "12.230.210.203"; do
    if ip addr show | grep -q "$VIP"; then
        ok "  이 서버가 VIP $VIP 를 현재 보유 중 (Active 노드)"
    else
        info "  VIP $VIP 는 현재 다른 노드가 보유 중"
    fi
done

# ─────────────────────────────────────────────────────────────
# CHECK 2. Failover 스크립트 검증
# ─────────────────────────────────────────────────────────────
section "2. Failover 스크립트 문법 및 존재 여부"

# 일반적인 Failover 스크립트 위치 탐색
FO_SCRIPT=""
for CANDIDATE in \
    /etc/init.d/failover \
    /usr/local/bin/failover.sh \
    /opt/cluster/failover.sh \
    /home/oracle/failover.sh \
    /root/failover.sh; do
    if [ -f "$CANDIDATE" ]; then
        FO_SCRIPT="$CANDIDATE"
        break
    fi
done

# Pacemaker 환경이면 별도 스크립트 없이 pcs/crm 명령으로 처리
if [ "$HA_TYPE" = "pacemaker" ]; then
    info "Pacemaker 환경: Failover는 pcs resource move / crm resource move 로 처리"
    info "스크립트 없이 pcs 명령으로 VIP 이동 가능 — 스크립트 없어도 정상"

    if command -v pcs > /dev/null 2>&1; then
        ok "pcs 명령어 사용 가능 — Failover 제어 준비됨"
    else
        fail "pcs 명령어 없음"
    fi
elif [ -n "$FO_SCRIPT" ]; then
    ok "Failover 스크립트 발견: $FO_SCRIPT"

    # sh -n: 스크립트를 실제로 실행하지 않고 문법만 검사 (드라이런)
    if sh -n "$FO_SCRIPT" 2>/dev/null; then
        ok "스크립트 문법 이상 없음 (sh -n 통과)"
    else
        fail "스크립트 문법 오류 발견 — sh -n $FO_SCRIPT 로 확인"
    fi

    # 실행 권한 확인
    if [ -x "$FO_SCRIPT" ]; then
        ok "실행 권한(+x) 있음"
    else
        warn "실행 권한 없음 — chmod +x $FO_SCRIPT 필요"
    fi
else
    warn "Failover 스크립트를 찾지 못함 — 위치를 직접 확인하여 아래를 수정"
    info "  스크립트 찾기: find / -maxdepth 6 -name '*failover*' 2>/dev/null"
fi

# ─────────────────────────────────────────────────────────────
# CHECK 3. Oracle DataGuard 동기화 상태 (데이터 손실 가능성)
# ─────────────────────────────────────────────────────────────
section "3. Oracle DataGuard 동기화 상태"

if ! ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    warn "Oracle 미기동 — DataGuard 상태 확인 불가 (DB 기동 후 재실행)"
else
    # Transport lag: Primary → Standby 전송 지연
    # Apply lag: Standby가 받은 Redo를 적용하는 지연
    # 둘 다 0이어야 Failover 시 데이터 손실 없음
    DG_OUT=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT NAME, VALUE, TIME_COMPUTED
FROM   V\\\$DATAGUARD_STATS
WHERE  NAME IN ('transport lag','apply lag');
EXIT;
EOF
" 2>/dev/null)

    if [ -n "$DG_OUT" ]; then
        echo "$DG_OUT" | tee -a "$REPORT"

        # transport lag, apply lag 모두 +00:00:00 이면 정상
        if echo "$DG_OUT" | grep -q "transport lag"; then
            TRANSPORT=$(echo "$DG_OUT" | grep "transport lag" | awk '{print $3}')
            if [ "$TRANSPORT" = "+00:00:00" ] || [ "$TRANSPORT" = "00:00:00" ]; then
                ok "Transport lag = 0 (Primary → Standby 전송 지연 없음)"
            else
                warn "Transport lag = $TRANSPORT (Failover 시 이 시간만큼 데이터 손실 가능)"
            fi
        fi

        if echo "$DG_OUT" | grep -q "apply lag"; then
            APPLY=$(echo "$DG_OUT" | grep "apply lag" | awk '{print $3}')
            if [ "$APPLY" = "+00:00:00" ] || [ "$APPLY" = "00:00:00" ]; then
                ok "Apply lag = 0 (Standby 적용 지연 없음)"
            else
                warn "Apply lag = $APPLY (Failover 시 이 시간만큼 미적용 Redo 존재)"
            fi
        fi
    else
        # DataGuard를 사용하지 않는 환경일 수 있음
        DB_ROLE=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT DATABASE_ROLE FROM V\\\$DATABASE;
EXIT;
EOF
" 2>/dev/null | tr -d ' \n')
        info "이 DB의 역할: $DB_ROLE"
        if [ "$DB_ROLE" = "PRIMARY" ]; then
            info "PRIMARY 노드 — DataGuard 통계는 Standby에서 확인"
        elif [ "$DB_ROLE" = "PHYSICALSTANDBY" ]; then
            info "PHYSICAL STANDBY 노드"
        else
            info "DataGuard 미사용 환경이거나 역할 확인 불가"
        fi
    fi

    # MRP0 프로세스: Standby에서 Redo 적용 중인지 확인
    MRP=$(su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT PROCESS, STATUS FROM V\\\$MANAGED_STANDBY WHERE PROCESS='MRP0';
EXIT;
EOF
" 2>/dev/null | tr -d ' ')
    if [ -n "$MRP" ]; then
        ok "MRP0 프로세스 확인 — Redo 동기화 중"
        echo "  상태: $MRP" | tee -a "$REPORT"
    else
        info "MRP0 없음 (Primary 서버이거나 동기화 중지 상태)"
    fi
fi

# ─────────────────────────────────────────────────────────────
# CHECK 4. 애플리케이션 접속 문자열 — VIP 사용 여부
# ─────────────────────────────────────────────────────────────
section "4. 접속 문자열 VIP 사용 여부 (Failover 효과의 핵심)"

echo "  [핵심 원리]" | tee -a "$REPORT"
echo "  앱/RVD가 Real IP로 접속하면 Failover 후 접속 불가." | tee -a "$REPORT"
echo "  VIP(12.230.210.207 / .203)로 접속해야 Failover 후 자동 연결." | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

# tnsnames.ora 에서 Real IP 사용 여부 확인
TNSNAMES=$(su - oracle -c "find \$ORACLE_HOME/network/admin -name tnsnames.ora 2>/dev/null | head -1" 2>/dev/null)
if [ -n "$TNSNAMES" ] && [ -f "$TNSNAMES" ]; then
    ok "tnsnames.ora 발견: $TNSNAMES"

    # VIP 사용 여부
    for VIP in "12.230.210.207" "12.230.210.203"; do
        if grep -q "$VIP" "$TNSNAMES" 2>/dev/null; then
            ok "  tnsnames.ora에 VIP $VIP 사용 확인 (Failover 후 자동 연결 가능)"
        fi
    done

    # Real IP 사용 여부 (위험)
    for REAL_IP in "12.230.210.205" "12.230.210.206" "12.230.210.201" "12.230.210.202"; do
        if grep -q "$REAL_IP" "$TNSNAMES" 2>/dev/null; then
            fail "  tnsnames.ora에 Real IP $REAL_IP 사용 — Failover 후 이 접속은 실패"
        fi
    done

    # PORT 1621 확인
    if grep -q "1621" "$TNSNAMES" 2>/dev/null; then
        ok "  포트 1621 사용 확인"
    else
        warn "  포트 1621 미확인 (표준 포트 1521이 설정된 항목 있는지 확인)"
    fi

    # PJOSCD 서비스명 확인
    if grep -qi "PJOSCD" "$TNSNAMES" 2>/dev/null; then
        ok "  서비스명 PJOSCD 확인"
    else
        warn "  PJOSCD 서비스명 미확인"
    fi
else
    warn "tnsnames.ora 위치를 자동으로 찾지 못함"
    info "  수동 확인: find / -name tnsnames.ora 2>/dev/null"
fi

# RVD 설정 파일에서 DB 접속 문자열 확인
echo "" | tee -a "$REPORT"
for RVD_CONF in /etc/rvd.conf /opt/tibco/rvd/rvd.conf /usr/tibco/rvd.conf; do
    if [ -f "$RVD_CONF" ]; then
        ok "RVD 설정 파일 발견: $RVD_CONF"
        for REAL_IP in "12.230.210.205" "12.230.210.206" "12.230.210.201" "12.230.210.202"; do
            if grep -q "$REAL_IP" "$RVD_CONF" 2>/dev/null; then
                fail "  RVD 설정에 Real IP $REAL_IP 사용 — Failover 후 RVD 접속 실패"
            fi
        done
        break
    fi
done

# ─────────────────────────────────────────────────────────────
# CHECK 5. Oracle 재기동 시 PJOSCD 자동 등록 가능성
# ─────────────────────────────────────────────────────────────
section "5. Oracle 재기동 시 PJOSCD 서비스 자동 등록 가능성"

if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then

    # listener.ora에 SID_LIST 또는 SERVICE_NAME 설정 여부
    # 설정이 있으면 Listener 기동과 동시에 서비스 등록 → 자동화 가능
    LISTENER_ORA=$(su - oracle -c "find \$ORACLE_HOME/network/admin -name listener.ora 2>/dev/null | head -1" 2>/dev/null)
    if [ -n "$LISTENER_ORA" ] && [ -f "$LISTENER_ORA" ]; then
        ok "listener.ora 발견: $LISTENER_ORA"

        if grep -qi "PJOSCD" "$LISTENER_ORA" 2>/dev/null; then
            ok "listener.ora에 PJOSCD 정적 등록됨 — 재기동 후 자동 등록"
        else
            warn "listener.ora에 PJOSCD 정적 등록 없음 — 동적 등록만 사용"
            info "  Oracle 기동 후 ALTER SYSTEM REGISTER 실행 필요 (start_services.sh가 자동 처리)"
        fi

        # 포트 1621 설정 확인
        if grep -q "1621" "$LISTENER_ORA" 2>/dev/null; then
            ok "listener.ora에 포트 1621 설정 확인"
        else
            fail "listener.ora에 포트 1621 미확인 — 기동 후 1621이 열리지 않을 수 있음"
        fi
    else
        warn "listener.ora 자동 발견 실패"
        info "  수동 확인: find / -name listener.ora 2>/dev/null"
    fi

    # 현재 Listener에서 PJOSCD 등록 확인 (기준점)
    if su - oracle -c "lsnrctl status" 2>/dev/null | grep -q "PJOSCD"; then
        ok "현재 Listener에 PJOSCD 등록 중 (현재 상태 정상)"
    else
        warn "현재 Listener에 PJOSCD 미등록"
    fi
else
    warn "Oracle 미기동 — Listener 등록 상태 확인 불가"
fi

# ─────────────────────────────────────────────────────────────
# CHECK 6. 서비스 자동 기동(systemctl enable) 설정
# ─────────────────────────────────────────────────────────────
section "6. Failover 후 서비스 자동 기동 설정"

echo "  Failover 후 서버가 재시작되면 서비스가 자동으로 올라와야 함." | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

for SVC in crond; do
    if systemctl is-enabled "$SVC" > /dev/null 2>&1; then
        ok "$SVC: systemctl enabled (재부팅 후 자동 기동)"
    else
        warn "$SVC: systemctl enabled 아님 — 재부팅/Failover 후 수동 기동 필요"
    fi
done

# Oracle 자동 기동 확인 (oratab, dbstart 설정)
ORATAB=""
for F in /etc/oratab /var/opt/oracle/oratab; do
    [ -f "$F" ] && ORATAB="$F" && break
done

if [ -n "$ORATAB" ]; then
    ok "oratab 발견: $ORATAB"
    # Y: 자동 기동, N: 수동 기동
    AUTO_START=$(grep -v "^#" "$ORATAB" 2>/dev/null | grep ":Y$" | head -3)
    if [ -n "$AUTO_START" ]; then
        ok "oratab에 자동 기동(Y) 설정된 인스턴스:"
        echo "$AUTO_START" | while read -r line; do echo "    $line" | tee -a "$REPORT"; done
    else
        warn "oratab에 자동 기동(Y) 설정 없음 — Failover 후 Oracle 수동 기동 필요"
        info "  수정 방법: oratab에서 :N 을 :Y 로 변경"
    fi
else
    warn "oratab 파일 없음 — Oracle 자동 기동 설정 확인 불가"
fi

# ─────────────────────────────────────────────────────────────
# CHECK 7. 상대 노드(인계 서버) 접근 가능 여부
# ─────────────────────────────────────────────────────────────
section "7. 상대 노드 상태 확인"

THIS_HOST=$(hostname)
echo "  이 서버: $THIS_HOST" | tee -a "$REPORT"

# 상대 노드 IP 목록 (이 서버의 IP를 제외한 나머지)
ALL_REAL_IPS="12.230.210.205 12.230.210.206 12.230.210.201 12.230.210.202"
MY_IPS=$(ip addr show | grep "inet " | awk '{print $2}' | cut -d/ -f1)

echo "" | tee -a "$REPORT"
echo "  [네트워크 도달성 확인 — ping 없이 TCP 체크]" | tee -a "$REPORT"

for IP in $ALL_REAL_IPS; do
    # 이 서버 자신의 IP는 건너뜀
    if echo "$MY_IPS" | grep -q "$IP"; then
        continue
    fi

    # SSH(22) 또는 Oracle(1621) 포트로 TCP 연결 가능 여부 확인
    # timeout + bash /dev/tcp: ping 없이 TCP 레벨 도달성 확인 (읽기 전용, 연결만 확인)
    if timeout 3 bash -c "echo >/dev/tcp/$IP/1621" 2>/dev/null; then
        ok "상대 노드 $IP:1621 응답 있음 (Oracle Listener 기동 중)"
    elif timeout 3 bash -c "echo >/dev/tcp/$IP/22" 2>/dev/null; then
        ok "상대 노드 $IP:22 응답 있음 (SSH 기동 중 — Oracle은 별도 확인)"
    else
        warn "상대 노드 $IP 에 1621/22 포트 모두 응답 없음"
    fi
done

# 외부에서 지정한 경우 상세 확인
if [ -n "$OTHER_NODE" ]; then
    echo "" | tee -a "$REPORT"
    echo "  [지정된 상대 노드: $OTHER_NODE]" | tee -a "$REPORT"
    if timeout 3 bash -c "echo >/dev/tcp/$OTHER_NODE/22" 2>/dev/null; then
        ok "상대 노드 SSH 접근 가능"
        info "  양 노드 설정 비교: ssh $OTHER_NODE 'ps -ef | grep -E \"pmon|rvd\"'"
    else
        warn "상대 노드 $OTHER_NODE SSH 접근 불가"
    fi
fi

# ─────────────────────────────────────────────────────────────
# CHECK 8. ARP 테이블 — VIP 이동 가능성 네트워크 검증
# ─────────────────────────────────────────────────────────────
section "8. 네트워크 — VIP 이동 가능성"

# arping: VIP가 네트워크 상에 존재하는지 확인 (ARP 레벨, 읽기 전용)
# Failover 후 VIP가 새 노드에서 Gratuitous ARP를 보내야 스위치가 인식
if command -v arping > /dev/null 2>&1; then
    for VIP in "12.230.210.207" "12.230.210.203"; do
        # -c 1: 1번만 체크, -I: 인터페이스 자동 선택
        NIC=$(ip route get "$VIP" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
        if [ -n "$NIC" ]; then
            ARP_OUT=$(arping -c 1 -I "$NIC" "$VIP" 2>/dev/null)
            if echo "$ARP_OUT" | grep -q "bytes from"; then
                ok "VIP $VIP ARP 응답 있음 (현재 네트워크에 존재)"
            else
                warn "VIP $VIP ARP 응답 없음"
            fi
        fi
    done
else
    # arping 없으면 arp 테이블로 대체 확인
    for VIP in "12.230.210.207" "12.230.210.203"; do
        ARP_ENTRY=$(arp -n "$VIP" 2>/dev/null | grep -v "no entry" | tail -1)
        if [ -n "$ARP_ENTRY" ]; then
            ok "ARP 테이블에 VIP $VIP 항목 있음: $ARP_ENTRY"
        else
            info "ARP 테이블에 VIP $VIP 없음 (다른 노드가 현재 보유 중일 수 있음)"
        fi
    done
fi

# ─────────────────────────────────────────────────────────────
# 최종 요약 및 판정
# ─────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
echo " FAILOVER READINESS 판정 결과" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
echo "  ✅ 정상:  $OK 항목" | tee -a "$REPORT"
echo "  ⚠️  경고:  $WARN 항목" | tee -a "$REPORT"
echo "  ❌ 실패:  $FAIL 항목" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -le 2 ]; then
    echo "  → 판정: 🟢 Failover 실행 시 성공 가능성 높음." | tee -a "$REPORT"
    echo "           실제 PM 시 Failover 진행 추천." | tee -a "$REPORT"
elif [ "$FAIL" -eq 0 ]; then
    echo "  → 판정: 🟡 경고 항목 검토 후 진행 가능." | tee -a "$REPORT"
    echo "           경고 내용을 확인하고 DBA/인프라 담당자와 협의." | tee -a "$REPORT"
else
    echo "  → 판정: 🔴 실패 항목 해결 전 Failover 진행 금지." | tee -a "$REPORT"
    echo "           ❌ 항목을 먼저 해결하세요." | tee -a "$REPORT"
fi

echo "" | tee -a "$REPORT"
echo "  리포트: $REPORT" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "  ─────────────────────────────────────────────────────" | tee -a "$REPORT"
echo "  Failover 검증의 핵심 원리" | tee -a "$REPORT"
echo "  ─────────────────────────────────────────────────────" | tee -a "$REPORT"
echo "  이 스크립트는 Failover를 실행하지 않고," | tee -a "$REPORT"
echo "  'Failover가 성공하려면 갖춰야 할 7가지 조건'을 검증합니다." | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "  1) HA 소프트웨어가 VIP를 제어 중인가" | tee -a "$REPORT"
echo "  2) Failover 스크립트 문법이 올바른가" | tee -a "$REPORT"
echo "  3) DataGuard lag이 0인가 (데이터 손실 없는가)" | tee -a "$REPORT"
echo "  4) 앱/RVD가 VIP로 접속하는가 (Real IP면 Failover 의미 없음)" | tee -a "$REPORT"
echo "  5) 재기동 후 PJOSCD가 자동 등록되는가" | tee -a "$REPORT"
echo "  6) 서비스가 재부팅 후 자동 기동하는가 (systemctl enable)" | tee -a "$REPORT"
echo "  7) 상대 노드가 인계받을 준비가 됐는가" | tee -a "$REPORT"
echo "  ─────────────────────────────────────────────────────" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"
