#!/usr/bin/env python3
"""kohya_patch_fortsetzen.py - Fortsetzen mit Gradient Accumulation in Kohya sd-scripts reparieren.

Kohya (sd-scripts 3e6935a, upstream main gleich) rechnet beim Fortsetzen mit --resume und
--skip_until_initial_step falsch, sobald --gradient_accumulation_steps > 1 ist:
  - initial_step wird erst mit der Accumulation malgenommen (Micro-Batches) und danach durch die
    Optimizer-Steps pro Epoche geteilt -> epoch_to_start ist um den Faktor Accumulation zu gross.
  - danach gilt global_step = Rest in Micro-Batches statt der erledigten Optimizer-Steps.
Folge: Ein Training, das bei Step 570 von 950 fortgesetzt wird, meldet sofort "fertig".

Der Patch rechnet in train_network.py so:
  steps_done      = erledigte Optimizer-Steps (aus train_state.json)
  steps_per_epoch = ceil(len(train_dataloader) / accumulation)
  epoch_to_start  = steps_done // steps_per_epoch
  in der angebrochenen Epoche werden (steps_done - epoch_to_start * steps_per_epoch) * accumulation
  Micro-Batches uebersprungen, global_step = steps_done.
Ohne --resume/--skip_until_initial_step aendert sich nichts.

Das Skript ersetzt genau festgelegte Textstellen. Fehlt eine davon (andere Kohya-Version), bricht es
mit Meldung ab und aendert nichts. Es kann gefahrlos mehrfach laufen: Die Marke RT-PATCH-FORTSETZEN
zeigt, dass der Patch drin ist (der Trainer lora_trainer_char_mm.py erlaubt das Fortsetzen im
normalen Profil nur mit dieser Marke). Rueckgaengig: git -C <sd-scripts> checkout -- train_network.py

Aufruf (wsl_einrichten.sh macht das nach dem checkout):
  python3 kohya_patch_fortsetzen.py [ZIEL] [--dry-run]
  ZIEL       train_network.py oder der sd-scripts-Ordner (Standard: $RT_KOHYA/sd-scripts, RT_KOHYA=/opt/rt/kohya)
  --dry-run  nur pruefen und anzeigen, nichts schreiben
  --help     nur diese Hilfe
Exit-Code 0 = gepatcht oder schon gepatcht, 1 = Fehler (nichts geaendert).
"""

import argparse
import difflib
import os
import sys
from pathlib import Path

MARKE = "RT-PATCH-FORTSETZEN"

# (Name, Originaltext, Ersatz) - Einrueckung wie in train_network.py
ERSETZUNGEN = [
    (
        "Startwert",
        """\
        epoch_to_start = 0
        if initial_step > 0:
            if args.skip_until_initial_step:
""",
        """\
        epoch_to_start = 0
        rt_steps_done = 0  # RT-PATCH-FORTSETZEN: erledigte Optimizer-Steps, nur mit skip_until_initial_step > 0
        if initial_step > 0:
            if args.skip_until_initial_step:
""",
    ),
    (
        "Epoche und Rest berechnen",
        """\
                initial_step *= args.gradient_accumulation_steps

                # set epoch to start to make initial_step less than len(train_dataloader)
                epoch_to_start = initial_step // math.ceil(len(train_dataloader) / args.gradient_accumulation_steps)
""",
        """\
                # RT-PATCH-FORTSETZEN: initial_step zaehlt hier erledigte Optimizer-Steps. Ganze Epochen ueber
                # epoch_to_start ueberspringen, in der angebrochenen Epoche nur den Rest als Micro-Batches.
                rt_steps_done = initial_step
                rt_steps_per_epoch = math.ceil(len(train_dataloader) / args.gradient_accumulation_steps)
                epoch_to_start = rt_steps_done // rt_steps_per_epoch
                initial_step = (rt_steps_done - epoch_to_start * rt_steps_per_epoch) * args.gradient_accumulation_steps
""",
    ),
    (
        "global_step setzen",
        """\
        if initial_step > 0:  # only if skip_until_initial_step is specified
            for skip_epoch in range(epoch_to_start):  # skip epochs
                logger.info(f"skipping epoch {skip_epoch+1} because initial_step (multiplied) is {initial_step}")
                initial_step -= len(train_dataloader)
            global_step = initial_step
""",
        """\
        if rt_steps_done > 0:  # RT-PATCH-FORTSETZEN: only if skip_until_initial_step is specified
            # ganze Epochen sind schon ueber epoch_to_start uebersprungen; initial_step ist nur noch der Rest
            # in der angebrochenen Epoche (Micro-Batches) und wird hier nicht noch einmal verringert
            for skip_epoch in range(epoch_to_start):  # skip epochs
                logger.info(f"skipping epoch {skip_epoch+1} (RT-PATCH-FORTSETZEN)")
            logger.info(
                f"RT-PATCH-FORTSETZEN: {rt_steps_done} steps done, resume in epoch {epoch_to_start+1}"
                f" after skipping {initial_step} micro-batches"
            )
            global_step = rt_steps_done
""",
    ),
    (
        "Fortschrittsbalken",
        """\
            range(args.max_train_steps - initial_step), smoothing=0, disable=not accelerator.is_local_main_process, desc="steps"
""",
        """\
            range(args.max_train_steps - global_step), smoothing=0, disable=not accelerator.is_local_main_process, desc="steps"  # RT-PATCH-FORTSETZEN
""",
    ),
]


def ziel_finden(angabe):
    if angabe:
        p = Path(angabe)
    else:
        p = Path(os.environ.get("RT_KOHYA", "/opt/rt/kohya")) / "sd-scripts"
    return p / "train_network.py" if p.is_dir() else p


def patchen(text):
    """Gibt (neuer_text, meldungen) zurueck; neuer_text None = Fehler, gleich text = schon gepatcht."""
    nl = "\r\n" if "\r\n" in text else "\n"
    paare = [(n, alt.replace("\n", nl), neu.replace("\n", nl)) for n, alt, neu in ERSETZUNGEN]
    if MARKE in text:
        fehlt = [n for n, _, neu in paare if text.count(neu) != 1]
        if fehlt:
            return None, [f"Marke {MARKE} ist da, aber diese Stellen passen nicht: {', '.join(fehlt)}",
                          "Datei zuruecksetzen (git checkout -- train_network.py) und neu patchen."]
        return text, ["schon gepatcht (Marke gefunden, alle Stellen passen)"]
    fehler = []
    for n, alt, _ in paare:
        k = text.count(alt)
        if k != 1:
            fehler.append(f"Stelle '{n}' {'nicht gefunden' if k == 0 else f'{k}x gefunden'}")
    if fehler:
        return None, fehler + ["Andere Kohya-Version? Erwartet sd-scripts 3e6935a. Nichts geaendert."]
    for _, alt, neu in paare:
        text = text.replace(alt, neu)
    return text, [f"{len(paare)} Stellen ersetzt"]


def main():
    ap = argparse.ArgumentParser(
        description="Kohya sd-scripts: Fortsetzen (--resume --skip_until_initial_step) mit Gradient Accumulation "
                    "reparieren. Ersetzt feste Textstellen in train_network.py, Marke " + MARKE + ".",
        epilog="Standardziel: $RT_KOHYA/sd-scripts/train_network.py (RT_KOHYA=/opt/rt/kohya). "
               "Rueckgaengig: git -C <sd-scripts> checkout -- train_network.py")
    ap.add_argument("ziel", nargs="?", help="train_network.py oder sd-scripts-Ordner")
    ap.add_argument("--dry-run", action="store_true", help="nur pruefen und Aenderungen anzeigen, nichts schreiben")
    a = ap.parse_args()

    datei = ziel_finden(a.ziel)
    if not datei.is_file():
        print(f"[kohya-patch] FEHLER: {datei} nicht gefunden")
        return 1
    with open(datei, encoding="utf-8", newline="") as f:
        text = f.read()
    neu, meldungen = patchen(text)
    for m in meldungen:
        print(f"[kohya-patch] {m}")
    if neu is None:
        print(f"[kohya-patch] FEHLER: {datei} nicht gepatcht")
        return 1
    if neu == text:
        print(f"[kohya-patch] {datei}: nichts zu tun")
        return 0
    try:
        compile(neu, str(datei), "exec")
    except SyntaxError as e:
        print(f"[kohya-patch] FEHLER: Ergebnis waere kein gueltiges Python ({e}) - nichts geaendert")
        return 1
    if a.dry_run:
        diff = difflib.unified_diff(text.splitlines(True), neu.splitlines(True), str(datei), str(datei) + " (gepatcht)")
        sys.stdout.writelines(diff)
        print(f"[kohya-patch] TEST-MODUS: {datei} nicht geaendert")
        return 0
    tmp = datei.with_name(datei.name + ".rt_tmp")
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(neu)
    os.replace(tmp, datei)
    print(f"[kohya-patch] {datei} gepatcht ({MARKE})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
