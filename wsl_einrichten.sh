#!/bin/bash
# wsl_einrichten.sh - Kohya sd-scripts in der WSL-Distribution RemoteTraining einrichten (als root).
# Wird von einrichten.ps1 aufgerufen; kann gefahrlos mehrfach laufen (fertige Teile werden uebersprungen).
# Gleiche Version wie auf dem Haupt-PC: sd-scripts-Commit unten, Pakete aus kohya_pakete.txt.
# Danach der Patch fuers Fortsetzen mit Gradient Accumulation (kohya_patch_fortsetzen.py, Marke RT-PATCH-FORTSETZEN).
#   --help     nur diese Hilfe
#   --dry-run  nur anzeigen, nichts installieren
set -euo pipefail

SD_REPO=https://github.com/kohya-ss/sd-scripts.git
SD_COMMIT=3e6935a07edcb944407840ef74fcaf6fcad352f7
BASIS=/opt/rt
KOHYA=$BASIS/kohya
HIER=$(dirname "$(readlink -f "$0")")
PAKETE=$HIER/kohya_pakete.txt

DRY=0
case "${1:-}" in
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --dry-run) DRY=1 ;;
esac
schritt() { echo; echo "== $*"; }
tu() { echo "+ $*"; if [ "$DRY" = 0 ]; then "$@"; fi; }

schritt "Systempakete"
export DEBIAN_FRONTEND=noninteractive
tu apt-get update -q
tu apt-get install -y -q python3-venv python3-pip git p7zip-full curl ca-certificates

schritt "Ordner und WSL-Einstellungen"
tu mkdir -p $BASIS/projekte $BASIS/modelle $BASIS/downloads $BASIS/job
# Windows-PATH nicht anhaengen (macht Befehle in WSL langsam); wirkt nach dem naechsten Start der Distribution
if [ "$DRY" = 0 ]; then printf '[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf; else echo "+ /etc/wsl.conf schreiben"; fi

schritt "sd-scripts $SD_COMMIT"
if [ ! -d $KOHYA/sd-scripts/.git ]; then tu git clone -q $SD_REPO $KOHYA/sd-scripts; fi
if [ "$DRY" = 0 ] && ! git -C $KOHYA/sd-scripts cat-file -e "$SD_COMMIT^{commit}" 2>/dev/null; then
  tu git -C $KOHYA/sd-scripts fetch -q origin
fi
# Patch eines frueheren Laufs zuruecknehmen, sonst scheitert der checkout bei einem neuen Commit; er kommt gleich wieder drauf
if [ -d $KOHYA/sd-scripts/.git ]; then tu git -C $KOHYA/sd-scripts checkout -q -- train_network.py; fi
tu git -C $KOHYA/sd-scripts -c advice.detachedHead=false checkout -q $SD_COMMIT

schritt "Kohya-Patch: Fortsetzen mit Gradient Accumulation"
# Kohya rechnet beim Fortsetzen mit Accumulation > 1 die Epoche und global_step falsch (auch upstream);
# ohne die Marke faengt der Trainer im normalen Profil nach einem Abbruch neu an
tu python3 "$HIER/kohya_patch_fortsetzen.py" $KOHYA/sd-scripts

schritt "Python-Pakete (torch, xformers, ... - mehrere GB, dauert)"
HASH=$(sha256sum "$PAKETE" | cut -d' ' -f1)
if [ -f $KOHYA/.pakete_ok ] && [ "$(cat $KOHYA/.pakete_ok)" = "$HASH" ]; then
  echo "Pakete sind schon installiert (gleiche Liste)"
else
  [ -d $KOHYA/venv ] || tu python3 -m venv $KOHYA/venv
  tu $KOHYA/venv/bin/pip install -q --upgrade pip
  tu $KOHYA/venv/bin/pip install --progress-bar off -r "$PAKETE"
  tu $KOHYA/venv/bin/pip install -q --no-deps -e $KOHYA/sd-scripts
  if [ "$DRY" = 0 ]; then echo "$HASH" > $KOHYA/.pakete_ok; fi
fi

schritt "accelerate (wie auf dem Haupt-PC: eine GPU, bf16)"
if [ "$DRY" = 0 ]; then
  mkdir -p /root/.cache/huggingface/accelerate
  cat > /root/.cache/huggingface/accelerate/default_config.yaml <<'EOF'
compute_environment: LOCAL_MACHINE
debug: false
distributed_type: 'NO'
downcast_bf16: 'no'
enable_cpu_affinity: false
gpu_ids: all
machine_rank: 0
main_training_function: main
mixed_precision: bf16
num_machines: 1
num_processes: 1
rdzv_backend: static
same_network: true
tpu_env: []
tpu_use_cluster: false
tpu_use_sudo: false
use_cpu: false
EOF
else echo "+ accelerate default_config.yaml schreiben"; fi

schritt "GPU-Test"
tu $KOHYA/venv/bin/python -c "import torch; ok = torch.cuda.is_available(); print('torch', torch.__version__, '| CUDA', ok, '|', torch.cuda.get_device_name(0) if ok else '-'); assert ok, 'CUDA nicht verfuegbar'"
echo
echo "Kohya ist eingerichtet."
