# 🛡️ UniFi Memory Optimizer v2.0-safe

> Otimização de memória RAM para UniFi OS (UDM / UDMP / UDR) de forma **persistente, segura e sem impacto no link/firewall**.

---

## 📋 Visão Geral

O script reduz o consumo de RAM de ~93% para ~60–70%, atuando nos maiores consumidores de memória do sistema (JVM do UniFi Network e MongoDB), sem tocar em nenhum serviço crítico de roteamento.

### Compatibilidade

| Hardware | RAM Total | Xmx Recomendado |
|---|---|---|
| UDM / UDR | 2 GB | 512–768 MB |
| UDM-Pro | 4 GB | 1024–1536 MB |
| UDM-SE | 8 GB | 2048–3072 MB |

---

## ⚡ Instalação Rápida

```bash
curl -fsSL https://raw.githubusercontent.com/WeslleyNS/unifi_mem_optimize/main/unifi_mem_optimize.sh -o /tmp/unifi_mem_optimize.sh && bash /tmp/unifi_mem_optimize.sh
```

> ⚠️ Execute **como root** via SSH no UniFi OS.

---

## 🔧 O Que o Script Faz (10 Etapas)

| Etapa | Ação | Impacto no Link |
|---|---|---|
| **1** | Backup automático do `system.properties` | Nenhum |
| **2** | Otimizar heap da JVM (Xmx, Xms, G1GC, Xss) | Nenhum |
| **3** | Limitar cache MongoDB WiredTiger | Nenhum |
| **4** | Reduzir retenção de dados para 7 dias | Nenhum |
| **5** | Tuning do kernel (`vm.swappiness`, `dirty_ratio`, etc.) | Nenhum |
| **6** | ~~zram~~ — *removido na versão conservadora* | — |
| **7** | Compactação do banco MongoDB (`compact`) | Nenhum |
| **8** | Limpeza de logs rotativos, APT cache, thumbnails | Nenhum |
| **9** | Desativar serviços irrelevantes (avahi, bluetooth, cups) | Nenhum |
| **10** | Reiniciar apenas o UniFi Network Controller (Java) | Nenhum |

---

## 🔒 Garantias de Segurança

### ✅ Serviços PRESERVADOS (nunca tocados)

| Serviço | Função |
|---|---|
| `unifi-core` | NAT, firewall, VPN, DHCP, DNS |
| `unifi-protect` | Câmeras IP — gravação contínua |
| `dnsmasq` | DNS/DHCP local |
| `ModemManager` | Backup WAN 3G/4G USB |

### 🚫 Removido vs. v2.0 Full (por segurança conservadora)

| Removido | Motivo |
|---|---|
| `zram` | Latência de compressão em CPU dual-core sob alta carga (DPI 500 Mbps+) |
| `vm.overcommit_memory=1` | Pode causar OOM kills inesperados em produção |
| Desativação do `ModemManager` | Quebraria failover WAN 3G/4G USB |

---

## ⚙️ Configurações Ajustáveis

Edite as variáveis no topo do script antes de executar:

```bash
UNIFI_XMX="768"        # Heap máximo da JVM (MB)
UNIFI_XMS="512"        # Heap inicial da JVM (MB)
MONGO_CACHE="192"      # Cache WiredTiger do MongoDB (MB)
RETENTION_DAYS="7"     # Retenção de estatísticas/eventos/alertas (dias)
```

---

## 📊 Parâmetros de Kernel Aplicados

```ini
vm.swappiness=10               # Usa swap apenas em emergência
vm.vfs_cache_pressure=50       # Equilibra inode vs. pagecache
vm.dirty_ratio=5               # Escreve para disco mais cedo
vm.dirty_background_ratio=2    # Inicia writeback mais cedo
vm.dirty_expire_centisecs=500  # Dados sujos expiram em 5s
vm.dirty_writeback_centisecs=100  # Writeback a cada 1s
vm.zone_reclaim_mode=0         # Evita reclamação agressiva de zonas
vm.min_free_kbytes=65536       # Mantém 64 MB livres para emergências
```

---

## 🔄 Como Reverter

```bash
# 1. Restaurar system.properties
cp /usr/lib/unifi/data/backups/system.properties.bak.<timestamp> \
   /usr/lib/unifi/data/system.properties

# 2. Remover tuning do kernel
rm /etc/sysctl.d/99-unifi-memory.conf
sysctl --system

# 3. Reiniciar o controller
systemctl restart unifi
```

---

## 📁 Arquivos Gerados

| Arquivo | Descrição |
|---|---|
| `/var/log/unifi_mem_optimize_v2_safe.log` | Log completo de execução |
| `/usr/lib/unifi/data/backups/system.properties.bak.*` | Backup com timestamp |
| `/etc/sysctl.d/99-unifi-memory.conf` | Tuning do kernel (persistente) |

---

## 📝 Changelog

### v2.0-safe (2026-07)
- ✅ Otimização da JVM com G1GC, Xmx/Xms configuráveis
- ✅ Limite do cache MongoDB WiredTiger
- ✅ Ajuste de retenção de dados (statdb, eventdb, alertdb)
- ✅ Tuning de kernel via sysctl.d (persistente após reboot)
- ✅ Compactação do banco MongoDB
- ✅ Detecção automática: UniFi OS vs. Controller Standalone
- ✅ Backup automático do system.properties
- 🚫 zram removido (conservador)
- 🚫 vm.overcommit_memory=1 removido (conservador)
- 🚫 ModemManager preservado (backup WAN 3G/4G)

### v1.0 (inicial)
- Limpeza de disco, logs e cache APT
- Desativação de avahi-daemon
- 6 etapas básicas

---

## 🧑‍💻 Autor

**Weslley Santos** — System Frame Redes e Serviços de TI  
Testado em: UDM, UDM-Pro, UDR com UniFi Protect ativo
