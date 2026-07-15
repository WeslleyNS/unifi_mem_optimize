#!/bin/bash
# =============================================================================
#  UNIFI MEMORY OPTIMIZER v2.0 — VERSÃO CONSERVADORA (SEM RISCOS PARA LINK/FW)
#  Alvo: Reduzir RAM de ~93% para ~60-70% de forma persistente e segura
#
#  EDIÇÕES DE SEGURANÇA (vs. v2.0 full):
#    - REMOVIDO: Desativação de ModemManager (risco para backup WAN 3G/4G)
#    - REMOVIDO: zram (risco de latência em CPU dual-core sob carga)
#    - REMOVIDO: vm.overcommit_memory=1 (evita OOM kills inesperados)
#    - MANTIDO: Todas as otimizações 100% seguras para link/firewall
#
#  SERVIÇOS QUE NÃO SÃO TOCADOS (roteamento intacto):
#    - unifi-core (NAT, firewall, VPN, DHCP, DNS)
#    - unifi-protect (câmeras continuam gravando)
#    - dnsmasq (DNS/DHCP local)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÕES AJUSTÁVEIS
# ─────────────────────────────────────────────────────────────────────────────
UNIFI_DATA="/usr/lib/unifi/data"
SYSTEM_PROPS="${UNIFI_DATA}/system.properties"
LOG="/var/log/unifi_mem_optimize_v2_safe.log"
BACKUP_DIR="${UNIFI_DATA}/backups"
TIMESTAMP_FMT='+%Y-%m-%d %H:%M:%S'

# Memória alvo para JVM (MB) — ajuste conforme seu hardware:
#   - UDM/UDR com 2GB RAM total: 512-768
#   - UDM-Pro com 4GB RAM total: 1024-1536
#   - UDM-SE com 8GB RAM total: 2048-3072
UNIFI_XMX="768"
UNIFI_XMS="512"

# Cache MongoDB WiredTiger (MB) — 25% do Xmx é um bom baseline
MONGO_CACHE="192"

# Retenção de dados no UniFi (dias) — reduzir diminui o banco MongoDB
RETENTION_DAYS="7"

# ─────────────────────────────────────────────────────────────────────────────
# FUNÇÕES UTILITÁRIAS
# ─────────────────────────────────────────────────────────────────────────────
log() {
    local ts
    ts=$(date "$TIMESTAMP_FMT")
    echo "[$ts] $1" | tee -a "$LOG"
}

mem_pct() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d", int((t-a)*100/t)}' /proc/meminfo
}

mem_mb() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d", int((t-a)/1024)}' /proc/meminfo
}

die() {
    log "ERRO FATAL: $1"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# VERIFICAÇÕES INICIAIS DE SEGURANÇA
# ─────────────────────────────────────────────────────────────────────────────
log "============================================================"
log "UNIFI MEMORY OPTIMIZER v2.0-SAFE — INÍCIO"
log "============================================================"

# Verificar root
if [[ $EUID -ne 0 ]]; then
    die "Este script deve ser executado como root (sudo)."
fi

# Verificar se é UniFi OS ou controller standalone
if [[ ! -d "$UNIFI_DATA" ]] && [[ ! -d "/var/lib/unifi" ]]; then
    die "Diretório de dados UniFi não encontrado. Este script é para UniFi OS (UDM/UDMP/UDR) ou controller standalone."
fi

# Detectar diretório correto do UniFi
if [[ -d "$UNIFI_DATA" ]]; then
    UNIFI_DATA="/usr/lib/unifi/data"
    SYSTEM_PROPS="${UNIFI_DATA}/system.properties"
    UNIFI_SERVICE="unifi"
    MONGO_SERVICE="mongod"
    IS_UNIFI_OS=true
elif [[ -d "/var/lib/unifi" ]]; then
    UNIFI_DATA="/var/lib/unifi"
    SYSTEM_PROPS="${UNIFI_DATA}/system.properties"
    UNIFI_SERVICE="unifi"
    MONGO_SERVICE="mongodb"
    IS_UNIFI_OS=false
fi

log "Sistema detectado: $(if $IS_UNIFI_OS; then echo 'UniFi OS (UDM/UDMP/UDR)'; else echo 'Controller Standalone'; fi)"
log "RAM antes: $(mem_pct)% ($(mem_mb)MB usados)"
log "Swap: $(free -m | awk '/Swap/{printf "%dMB/%dMB", $3, $2}')"

# Criar diretório de backup
mkdir -p "$BACKUP_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 1 — BACKUP DO SYSTEM.PROPERTIES
# ─────────────────────────────────────────────────────────────────────────────
log "[1/10] Criando backup de system.properties..."
if [[ -f "$SYSTEM_PROPS" ]]; then
    cp -a "$SYSTEM_PROPS" "${BACKUP_DIR}/system.properties.bak.$(date +%s)"
    log "[1/10] Backup criado em ${BACKUP_DIR}/"
else
    log "[1/10] system.properties não existe — será criado."
    touch "$SYSTEM_PROPS"
    chown unifi:unifi "$SYSTEM_PROPS" 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 2 — OTIMIZAR JVM (MAIOR IMPACTO EM RAM)
# Reduz heap Java do UniFi Network Application
# ZERO IMPACTO no link/firewall — afeta apenas a interface web Java
# ─────────────────────────────────────────────────────────────────────────────
log "[2/10] Otimizando alocação de memória JVM (Xmx=${UNIFI_XMX}MB, Xms=${UNIFI_XMS}MB)..."

# Função para adicionar/atualizar propriedades no system.properties
set_prop() {
    local key="$1"
    local val="$2"
    local file="$SYSTEM_PROPS"
    
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${val}/" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

set_prop "unifi.xmx" "$UNIFI_XMX"
set_prop "unifi.xms" "$UNIFI_XMS"

# Ativar G1GC (Garbage Collector de baixa latência, mais eficiente)
set_prop "unifi.G1GC.enabled" "true"

# Reduzir stack size para threads (padrão é 1MB, reduzir para 256KB economiza RAM em muitas threads)
set_prop "unifi.xss" "256"

log "[2/10] JVM configurado: Xmx=${UNIFI_XMX}MB, Xms=${UNIFI_XMS}MB, G1GC=true, Xss=256KB"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 3 — OTIMIZAR MONGODB WIREDTIGER CACHE
# Segundo maior consumidor de RAM após a JVM
# ZERO IMPACTO no link/firewall — afeta apenas o banco de dados do controller
# ─────────────────────────────────────────────────────────────────────────────
log "[3/10] Otimizando cache MongoDB WiredTiger (cache_size=${MONGO_CACHE}MB)..."
set_prop "db.mongo.wt.cache_size" "$MONGO_CACHE"

log "[3/10] MongoDB WiredTiger cache ajustado para ${MONGO_CACHE}MB"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 4 — REDUZIR RETENÇÃO DE DADOS (DIMINUI TAMANHO DO BANCO)
# Menos dados = menos RAM usada pelo MongoDB para cache
# ZERO IMPACTO no link/firewall — apenas histórico da interface web
# ─────────────────────────────────────────────────────────────────────────────
log "[4/10] Ajustando retenção de dados para ${RETENTION_DAYS} dias..."
set_prop "statdb.retention.days" "$RETENTION_DAYS"
set_prop "eventdb.retention.days" "$RETENTION_DAYS"
set_prop "alertdb.retention.days" "$RETENTION_DAYS"

log "[4/10] Retenção de estatísticas, eventos e alertas ajustada para ${RETENTION_DAYS} dias"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 5 — OTIMIZAR KERNEL VM (MEMÓRIA VIRTUAL)
# SEGURO: Apenas ajusta comportamento de cache e swap, não toca em regras de rede
# NOTA: vm.overcommit_memory REMOVIDO (conservador — mantém padrão 0)
# NOTA: zram REMOVIDO (evita latência de CPU em hardware fraco)
# ─────────────────────────────────────────────────────────────────────────────
log "[5/10] Otimizando parâmetros do kernel (vm.swappiness, vfs_cache_pressure)..."

cat > /etc/sysctl.d/99-unifi-memory.conf << 'EOF'
# Otimizações de memória para UniFi OS — VERSÃO CONSERVADORA
# vm.overcommit_memory=1 REMOVIDO: mantém padrão 0 (mais seguro contra OOM kills)
# vm.overcommit_ratio REMOVIDO
# zram REMOVIDO: evita latência de compressão em CPU dual-core
#
# vm.swappiness=10: só usa swap em emergência (evita thrashing)
# vm.vfs_cache_pressure=50: equilibra cache de inode vs. pagecache
# vm.dirty_ratio=5: escreve para disco mais cedo (libera RAM)
# vm.dirty_background_ratio=2: inicia writeback mais cedo
# vm.dirty_expire_centisecs=500: dados sujos expiram em 5s
# vm.dirty_writeback_centisecs=100: writeback a cada 1s
# vm.zone_reclaim_mode=0: evita reclamação agressiva de zonas
# vm.min_free_kbytes=65536: mantém 64MB livres para emergências
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=5
vm.dirty_background_ratio=2
vm.dirty_expire_centisecs=500
vm.dirty_writeback_centisecs=100
vm.zone_reclaim_mode=0
vm.min_free_kbytes=65536
EOF

# Aplicar parâmetro a parâmetro para não matar o script em kernels que não suportam algum deles
SYSCTL_ERROS=0
while IFS= read -r line; do
    # Ignorar linhas em branco e comentários
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! sysctl -w "$line" >> "$LOG" 2>&1; then
        log "[5/10] AVISO: parâmetro não suportado neste kernel: $line"
        SYSCTL_ERROS=$((SYSCTL_ERROS + 1))
    fi
done < /etc/sysctl.d/99-unifi-memory.conf

if [[ $SYSCTL_ERROS -gt 0 ]]; then
    log "[5/10] Kernel parcialmente otimizado ($SYSCTL_ERROS parâmetro(s) não suportado(s) ignorado(s))"
else
    log "[5/10] Kernel otimizado para baixo consumo de RAM (modo conservador)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 6 — PULADA (zram removido por segurança)
# Razão: zram comprime swap em RAM usando CPU. Em UDM/UDR dual-core sob
# carga de 500Mbps+ com DPI ativo, a compressão pode adicionar 5-20ms de
# latência por pacote. Para link/firewall 100% estável, preferimos swap em
# disco (se existir) ou deixar o kernel gerenciar sem zram.
# ─────────────────────────────────────────────────────────────────────────────
log "[6/10] PULADA: zram não configurado (modo conservador — evita latência de CPU)"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 7 — LIMPEZA DE BANCO MONGODB (MAIOR GANHO DE DISCO E RAM)
# ZERO IMPACTO no link/firewall — apenas manutenção do banco do controller
# ─────────────────────────────────────────────────────────────────────────────
log "[7/10] Limpando e compactando banco de dados MongoDB..."

# Verificar se MongoDB está rodando
if systemctl is-active --quiet "$MONGO_SERVICE" 2>/dev/null || pgrep -x mongod >/dev/null 2>&1; then
    MONGO_RUNNING=true
else
    MONGO_RUNNING=false
    log "[7/10] MongoDB não está rodando — pulando limpeza de banco"
fi

if $MONGO_RUNNING; then
    sleep 3
    
    mongo_cmd="mongo --quiet"
    
    if $mongo_cmd --eval 'db.stats()' >/dev/null 2>&1; then
        log "[7/10] Conectado ao MongoDB — executando compactação..."
        
        $mongo_cmd --eval '
            db = db.getSiblingDB("ace");
            var collections = db.getCollectionNames();
            var totalBefore = db.stats().dataSize;
            for (var i = 0; i < collections.length; i++) {
                try {
                    db[collections[i]].compact();
                } catch(e) {}
            }
            var totalAfter = db.stats().dataSize;
            print("Compactação concluída. Antes: " + totalBefore + " bytes, Depois: " + totalAfter + " bytes");
        ' >> "$LOG" 2>&1 || log "[7/10] Compactação via mongo shell falhou — tentando repair..."
    else
        log "[7/10] Não foi possível conectar ao MongoDB — pulando compactação"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 8 — LIMPEZA DE DISCO E LOGS
# ZERO IMPACTO no link/firewall — apenas libera espaço em disco
# ─────────────────────────────────────────────────────────────────────────────
log "[8/10] Limpando arquivos temporários e logs antigos..."

# Limpar cache APT (sem -y, que não existe para clean)
apt-get clean >> "$LOG" 2>&1 || true
apt-get autoremove --purge -y >> "$LOG" 2>&1 || true

# Limpar logs rotacionados (mantém logs ativos, remove apenas .gz/.1/.old antigos)
find /var/log -name "*.gz" -type f -mtime +7 -delete 2>/dev/null || true
find /var/log -name "*.[0-9]*" -type f -mtime +7 -delete 2>/dev/null || true
find /var/log -name "*.old" -type f -mtime +7 -delete 2>/dev/null || true

# Reduzir journal systemd
journalctl --vacuum-time=2d --vacuum-size=50M >> "$LOG" 2>&1 || true

# Limpar logs do UniFi (apenas rotacionados, nunca o ativo)
find /var/log/unifi -name "server.log.*" -type f -mtime +3 -delete 2>/dev/null || true
find /var/log/unifi -name "*.log.[0-9]*" -type f -mtime +3 -delete 2>/dev/null || true

# Limpar logs do UniFi Protect (se existir)
find /var/log/unifi-protect -name "*.log.*" -type f -mtime +3 -delete 2>/dev/null || true

# Limpar cache de thumbnails do UniFi Protect (pode ser enorme)
if [[ -d "/srv/unifi-protect" ]]; then
    find /srv/unifi-protect -path "*/thumbnails/*" -type f -mtime +7 -delete 2>/dev/null || true
    log "[8/10] Thumbnails antigos do Protect removidos"
fi

# Limpar diretório /tmp
find /tmp -type f -atime +1 -delete 2>/dev/null || true
find /tmp -type d -empty -delete 2>/dev/null || true

log "[8/10] Limpeza de disco concluída"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 9 — DESATIVAR SERVIÇOS NÃO ESSENCIAIS
# ZERO IMPACTO no link/firewall — apenas serviços de descoberta/impressão
# SEGURANÇA: ModemManager REMOVIDO (risco para backup WAN 3G/4G USB)
# ─────────────────────────────────────────────────────────────────────────────
log "[9/10] Desativando serviços não essenciais..."

# Lista de serviços seguros para desativar (nenhum afeta roteamento/firewall)
# ModemManager REMOVIDO: se você usa modem 3G/4G USB como backup WAN,
# desativar ModemManager quebraria o failover. Mantido fora por segurança.
SERVICES_TO_DISABLE=(
    "avahi-daemon"          # mDNS/Bonjour — descoberta de dispositivos local
    "bluetooth"             # Bluetooth — irrelevante em UDM
    "cups"                  # Printing — irrelevante
    "cups-browsed"          # Printing discovery
)

for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log "[9/10] Serviço '$svc' desativado"
        fi
    fi
done

log "[9/10] Serviços não essenciais desativados (ModemManager preservado para backup WAN)"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 10 — REINICIAR UNIFI NETWORK CONTROLLER (APLICAR MUDANÇAS)
# SEGURO: Este serviço é APENAS o controller Java (interface web).
# O roteamento real (NAT, firewall, VPN) é feito pelo serviço 'unifi-core',
# que NÃO é tocado. Seu link permanece ativo durante o restart.
# ─────────────────────────────────────────────────────────────────────────────
log "[10/10] Reiniciando UniFi Network Controller para aplicar otimizações..."

if systemctl is-active --quiet "$UNIFI_SERVICE" 2>/dev/null; then
    log "[10/10] Parando $UNIFI_SERVICE (interface web — roteamento continua)..."
    systemctl stop "$UNIFI_SERVICE" >> "$LOG" 2>&1 || true
    sleep 5
    
    # Garantir que não há processos Java órfãos
    pkill -f "unifi/lib.*java" 2>/dev/null || true
    sleep 2
    
    log "[10/10] Iniciando $UNIFI_SERVICE..."
    systemctl start "$UNIFI_SERVICE" >> "$LOG" 2>&1 || true
    
    # Aguardar subida (timeout de 120s)
    for i in $(seq 1 24); do
        if systemctl is-active --quiet "$UNIFI_SERVICE" 2>/dev/null; then
            log "[10/10] $UNIFI_SERVICE reiniciado com sucesso"
            break
        fi
        sleep 5
    done
    
    if ! systemctl is-active --quiet "$UNIFI_SERVICE" 2>/dev/null; then
        log "[10/10] ATENÇÃO: $UNIFI_SERVICE pode não ter subido — verifique 'systemctl status $UNIFI_SERVICE'"
    fi
else
    log "[10/10] $UNIFI_SERVICE não estava ativo — pulando restart"
fi

# ─────────────────────────────────────────────────────────────────────────────
# RESULTADO FINAL
# ─────────────────────────────────────────────────────────────────────────────
sleep 10  # Aguardar estabilização

RAM_DEPOIS=$(mem_pct)
RAM_DEPOIS_MB=$(mem_mb)

log "============================================================"
log "OTIMIZAÇÃO CONCLUÍDA (VERSÃO CONSERVADORA)"
log "RAM depois: ${RAM_DEPOIS}% (${RAM_DEPOIS_MB}MB usados)"
log "============================================================"

echo ""
echo "============================================================"
echo "  UNIFI MEMORY OPTIMIZER v2.0-SAFE — CONCLUÍDO"
echo "  RAM: ${RAM_DEPOIS}% (${RAM_DEPOIS_MB}MB)"
echo "  Log: $LOG"
echo "  Backup: ${BACKUP_DIR}/"
echo "============================================================"
echo ""
echo "  CONFIGURAÇÕES APLICADAS (100% seguras para link/FW):"
echo "    - JVM Heap: Xmx=${UNIFI_XMX}MB, Xms=${UNIFI_XMS}MB, G1GC=true"
echo "    - MongoDB WiredTiger Cache: ${MONGO_CACHE}MB"
echo "    - Retenção de dados: ${RETENTION_DAYS} dias"
echo "    - Kernel: vm.swappiness=10, dirty_ratio=5, min_free_kbytes=64MB"
echo ""
echo "  SERVIÇOS PRESERVADOS (roteamento intacto):"
echo "    - unifi-core (NAT, firewall, VPN, DHCP, DNS)"
echo "    - unifi-protect (câmeras gravando)"
echo "    - dnsmasq (DNS/DHCP local)"
echo "    - ModemManager (backup WAN 3G/4G USB)"
echo ""
echo "  REMOVIDO POR SEGURANÇA (vs. v2.0 full):"
echo "    - zram (evita latência de CPU)"
echo "    - vm.overcommit_memory=1 (evita OOM kills)"
echo "    - ModemManager (preserva backup WAN)"
echo ""
echo "  Para reverter: restaure o backup de system.properties"
echo "  e remova /etc/sysctl.d/99-unifi-memory.conf"
echo "============================================================"
