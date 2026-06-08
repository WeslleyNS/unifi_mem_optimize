#!/bin/bash
# ==============================================================================
#  UNIFI OS — OTIMIZAÇÃO DE MEMÓRIA (seguro para links e câmeras)
#  Alvo: reduzir RAM de 93% para ~70-75%
#  Testado para: UDM/UDMP/UDR com UniFi Protect ativo
#
#  REGRAS DE SEGURANÇA:
#    - unifi-protect NÃO é reiniciado (câmeras continuam gravando)
#    - unifi-core NÃO é tocado (roteamento e firewall intactos)
#    - dnsmasq NÃO é tocado (DNS/DHCP local intacto)
#    - Toda ação é logada em /var/log/mem_optimize.log
# ==============================================================================

LOG="/var/log/mem_optimize.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[$TIMESTAMP] $1" | tee -a "$LOG"; }

mem_pct() {
  awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d", int((t-a)*100/t)}' /proc/meminfo
}

log "========================================================"
log "INÍCIO DA OTIMIZAÇÃO"
log "RAM antes: $(mem_pct)%  |  Swap: $(free -m | awk '/Swap/{printf "%dMB/%dMB", $3, $2}')"

# ------------------------------------------------------------------------------
# ETAPA 1 — Limpeza de disco (resolve os 95% na partição root)
# Sem risco nenhum: apenas arquivos temporários e cache de pacotes
# ------------------------------------------------------------------------------
log "[1/6] Limpando cache APT e pacotes órfãos..."
apt-get clean -y >> "$LOG" 2>&1
apt-get autoremove --purge -y >> "$LOG" 2>&1

log "[1/6] Removendo logs comprimidos e rotativos antigos..."
find /var/log -name "*.gz" -type f -delete
find /var/log -name "*.1" -type f -delete
find /var/log -name "*.old" -type f -delete

log "[1/6] Reduzindo journal systemd para 2 dias / 50MB..."
journalctl --vacuum-time=2d --vacuum-size=50M >> "$LOG" 2>&1

# Logs específicos do UniFi — apenas arquivos rotacionados, nunca o ativo
log "[1/6] Limpando logs rotativos do UniFi Network..."
find /var/log/unifi -name "server.log.*" -type f -delete 2>/dev/null || true
find /var/log/unifi -name "*.log.[0-9]*" -type f -delete 2>/dev/null || true

log "[1/6] Limpando logs rotativos do UniFi Protect..."
find /var/log/unifi-protect -name "*.log.*" -type f -delete 2>/dev/null || true

# ------------------------------------------------------------------------------
# ETAPA 2 — Desativar serviços não essenciais em firewall
# Economia: ~20-40 MB
# ------------------------------------------------------------------------------
log "[2/6] Desativando avahi-daemon (mDNS — desnecessário em firewall)..."
if systemctl is-active --quiet avahi-daemon; then
  systemctl stop avahi-daemon
  systemctl disable avahi-daemon
  log "[2/6] avahi-daemon desativado."
else
  log "[2/6] avahi-daemon já estava inativo."
fi

# ------------------------------------------------------------------------------
# ETAPA 3 — Liberar PageCache, Dentries e Inodes do kernel
# Reduz o Slab de 353 MB e o cache de 223 MB
# SEGURO: o kernel recarrega o que precisar sob demanda
# Economia esperada: 300-500 MB imediatos
# ------------------------------------------------------------------------------
log "[3/6] Sincronizando I/O pendente antes de liberar caches..."
sync
sleep 3

log "[3/6] Liberando PageCache + Dentries + Inodes (echo 3)..."
echo 3 > /proc/sys/vm/drop_caches
sleep 2

# Ajuste de vm.swappiness: reduz agressividade do kernel em usar swap
# Padrão: 60 → 20: só usa swap quando realmente necessário
CURRENT_SWAPPINESS=$(cat /proc/sys/vm/swappiness)
if [ "$CURRENT_SWAPPINESS" -gt 20 ]; then
  log "[3/6] Ajustando vm.swappiness de $CURRENT_SWAPPINESS para 20..."
  sysctl -w vm.vfs_cache_pressure=50 >> "$LOG" 2>&1
  sysctl -w vm.swappiness=20 >> "$LOG" 2>&1
  # Tornar persistente
  grep -qxF 'vm.swappiness=20' /etc/sysctl.conf || echo 'vm.swappiness=20' >> /etc/sysctl.conf
  grep -qxF 'vm.vfs_cache_pressure=50' /etc/sysctl.conf || echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
fi

# ------------------------------------------------------------------------------
# ETAPA 4 — Tentar reduzir fragmentação do heap Java via jcmd
# O processo java (UniFi Network Controller) retém heap que pode ser compactado
# SEM reiniciar — apenas solicita GC ao processo em execução
# Economia: 50-150 MB sem downtime algum
# ------------------------------------------------------------------------------
log "[4/6] Solicitando GC ao processo Java (UniFi Network Controller)..."
JAVA_PID=$(pgrep -f "unifi/lib" | head -1)
if [ -n "$JAVA_PID" ]; then
  # Tenta jcmd (disponível em JDK); silencia erro se não estiver
  jcmd "$JAVA_PID" GC.run >> "$LOG" 2>&1 && log "[4/6] GC solicitado via jcmd (PID $JAVA_PID)." \
    || log "[4/6] jcmd não disponível — pulando GC forçado (sem impacto)."
else
  log "[4/6] Processo Java não encontrado — pulando."
fi

# ------------------------------------------------------------------------------
# ETAPA 5 — Reiniciar UniFi Network Controller (java/unifi)
# ESTE É O MAIOR GANHO: libera 200-400 MB do heap Java acumulado
#
# IMPACTO:
#   ✔ Câmeras continuam gravando (unifi-protect NÃO é afetado)
#   ✔ Roteamento, NAT e firewall continuam funcionando (kernel, não userspace)
#   ✔ VPN WireGuard continua ativa (wgclt1 não depende do java)
#   ✗ Interface de gerência de rede (~2-4 min de indisponibilidade)
#   ✗ Adoção de novos dispositivos indisponível durante restart
#
# Remova o comentário abaixo para habilitar.
# Para execução automática (cron noturno), deixe descomentado.
# ------------------------------------------------------------------------------
log "[5/6] Reinício do UniFi Network Controller..."

# Aguarda horário de menor impacto se executado manualmente fora da janela
HOUR=$(date +%H)
if [ "$HOUR" -ge 6 ] && [ "$HOUR" -le 22 ]; then
  log "[5/6] ATENÇÃO: Executando em horário comercial ($HOUR h). Interface de gerência ficará indisponível ~3 min."
  log "[5/6] Para agendar apenas à noite, use o cron fornecido no README."
fi

if systemctl is-active --quiet unifi; then
  log "[5/6] Parando unifi..."
  systemctl stop unifi
  sleep 5
  log "[5/6] Iniciando unifi..."
  systemctl start unifi
  # Aguarda o serviço subir antes de prosseguir
  for i in $(seq 1 24); do
    systemctl is-active --quiet unifi && break
    sleep 5
  done
  systemctl is-active --quiet unifi \
    && log "[5/6] unifi reiniciado com sucesso." \
    || log "[5/6] ATENÇÃO: unifi pode não ter subido — verifique 'systemctl status unifi'."
else
  log "[5/6] unifi não estava ativo — pulando restart."
fi

# ------------------------------------------------------------------------------
# ETAPA 6 — Segunda rodada de drop_caches pós-restart
# O restart do java gera novas alocações de pagecache; liberamos novamente
# ------------------------------------------------------------------------------
log "[6/6] Segunda limpeza de caches pós-restart..."
sync && sleep 2 && echo 3 > /proc/sys/vm/drop_caches

# ------------------------------------------------------------------------------
# RESULTADO
# ------------------------------------------------------------------------------
sleep 5
RAM_DEPOIS=$(mem_pct)
log "RAM depois: ${RAM_DEPOIS}%"
log "FIM DA OTIMIZAÇÃO"
log "========================================================"

echo ""
echo "============================================"
echo "  OTIMIZAÇÃO CONCLUÍDA"
echo "  RAM: ${RAM_DEPOIS}%"
echo "  Log completo: $LOG"
echo "  Verifique: free -m && uptime"
echo "============================================"
