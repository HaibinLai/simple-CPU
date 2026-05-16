#!/usr/bin/env python3
"""Generate CPU architecture block diagram as PNG for README."""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

def draw():
    fig, ax = plt.subplots(1, 1, figsize=(18, 11), dpi=150)
    ax.set_xlim(0, 18)
    ax.set_ylim(0, 11)
    ax.set_aspect('equal')
    ax.axis('off')
    fig.patch.set_facecolor('#FAFAFA')

    # --- Color palette ---
    C_FETCH  = '#4A90D9'   # blue
    C_DECODE = '#5B9BD5'   # lighter blue
    C_EX     = '#F4A460'   # sandy orange
    C_MEM    = '#66CDAA'   # medium aquamarine
    C_WB     = '#DA70D6'   # orchid
    C_OOO    = '#FF6B6B'   # coral red
    C_PRED   = '#87CEEB'   # sky blue
    C_CACHE  = '#98D8C8'   # mint
    C_CDB    = '#FFD700'   # gold
    C_LIGHT  = '#F0F0F0'

    def box(x, y, w, h, label, color, fontsize=9, sublabel=None, alpha=0.85):
        rect = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.08",
                              facecolor=color, edgecolor='#333', linewidth=1.2, alpha=alpha)
        ax.add_patch(rect)
        if sublabel:
            ax.text(x + w/2, y + h/2 + 0.15, label, ha='center', va='center',
                    fontsize=fontsize, fontweight='bold', color='#1a1a1a')
            ax.text(x + w/2, y + h/2 - 0.2, sublabel, ha='center', va='center',
                    fontsize=6.5, color='#444')
        else:
            ax.text(x + w/2, y + h/2, label, ha='center', va='center',
                    fontsize=fontsize, fontweight='bold', color='#1a1a1a')

    def arrow(x1, y1, x2, y2, color='#555', lw=1.5, style='->', head=0.12):
        ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                    arrowprops=dict(arrowstyle=style, color=color, lw=lw,
                                   connectionstyle='arc3,rad=0'))

    def curved_arrow(x1, y1, x2, y2, color='#555', lw=1.2, rad=0.2):
        ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                    arrowprops=dict(arrowstyle='->', color=color, lw=lw,
                                   connectionstyle=f'arc3,rad={rad}'))

    # ============================================================
    # Title
    # ============================================================
    ax.text(9, 10.6, '2-Wide OoO Superscalar RV32I CPU', ha='center', va='center',
            fontsize=16, fontweight='bold', color='#1a1a1a')
    ax.text(9, 10.25, '8-Stage Pipeline  ·  Dual Issue  ·  Out-of-Order Execution  ·  In-Order Commit',
            ha='center', va='center', fontsize=9, color='#555')

    # ============================================================
    # Front-end (top row)
    # ============================================================
    # BPU
    box(0.3, 8.5, 2.0, 1.2, 'BPU', C_PRED, 9, 'TAGE + BTB + RAS')
    # I-Cache
    box(0.3, 7.0, 2.0, 1.0, 'I-Cache', C_CACHE, 9, '2-way SA, 2KB')
    # IF
    box(2.8, 7.5, 1.5, 1.2, 'IF', C_FETCH, 11)
    # IFQ
    box(4.8, 7.5, 1.8, 1.2, 'IFQ', C_FETCH, 10, 'dual-pop')
    # ID1
    box(7.1, 7.5, 1.3, 1.2, 'ID1', C_DECODE, 10, 'decode')
    # ID2
    box(8.8, 7.5, 1.5, 1.2, 'ID2', C_DECODE, 10, 'reg read')

    # Arrows: front-end flow
    arrow(2.3, 8.1, 2.8, 8.1, C_FETCH)    # I$ → IF
    arrow(2.3, 9.1, 2.8, 8.7, C_PRED)     # BPU → IF
    arrow(4.3, 8.1, 4.8, 8.1, C_FETCH)    # IF → IFQ
    arrow(6.6, 8.1, 7.1, 8.1, C_FETCH)    # IFQ → ID1
    arrow(8.4, 8.1, 8.8, 8.1, C_DECODE)   # ID1 → ID2

    # ============================================================
    # Rename / ROB / RS (middle section)
    # ============================================================
    # Rename
    box(10.8, 8.2, 1.8, 0.9, 'Rename', C_OOO, 9, 'free-list + busy')
    arrow(10.3, 8.1, 10.8, 8.6, C_OOO)  # ID2 → Rename

    # ROB
    box(13.0, 8.2, 2.0, 0.9, 'ROB (16)', C_OOO, 9, '2-wide commit')
    arrow(12.6, 8.6, 13.0, 8.6, C_OOO)  # Rename → ROB

    # PRF
    box(15.5, 8.2, 1.8, 0.9, 'PRF (64)', C_OOO, 9, '6R / 4W')
    arrow(15.0, 8.6, 15.5, 8.6, C_OOO)  # ROB → PRF

    # RS
    box(10.8, 6.5, 2.0, 1.2, 'RS (8)', C_OOO, 11, 'unified, CDB wakeup')
    arrow(11.8, 8.2, 11.8, 7.7, C_OOO)  # Rename → RS (down)

    # ============================================================
    # Slot0 pipeline (middle-left)
    # ============================================================
    s0y = 5.0
    box(7.5, s0y, 1.3, 0.9, 'EX1', C_EX, 10)
    box(9.0, s0y, 1.3, 0.9, 'EX2', C_EX, 10)
    box(10.5, s0y, 1.3, 0.9, 'AGU', C_EX, 10)
    box(12.0, s0y, 1.3, 0.9, 'MEM', C_MEM, 10)
    box(13.5, s0y, 1.2, 0.9, 'WB', C_WB, 10)

    # slot0 label
    ax.text(10.5, 4.6, 'slot0 (full: ALU / load / store / branch / jump)',
            ha='center', va='center', fontsize=7.5, color='#666', style='italic')

    # Arrows: slot0 flow
    arrow(8.8, 5.45, 9.0, 5.45, C_EX)
    arrow(10.3, 5.45, 10.5, 5.45, C_EX)
    arrow(11.8, 5.45, 12.0, 5.45, C_MEM)
    arrow(13.3, 5.45, 13.5, 5.45, C_WB)

    # RS A-path → slot0 EX1
    ax.text(9.6, 6.3, 'A-path', ha='center', fontsize=7.5, color=C_OOO, fontweight='bold')
    curved_arrow(10.8, 6.8, 8.8, 5.9, C_OOO, 1.5, 0.15)

    # ID2 → slot0 EX1 (in-order)
    curved_arrow(9.5, 7.5, 8.2, 5.9, '#555', 1.2, 0.1)

    # ============================================================
    # Slot1 pipeline (below slot0)
    # ============================================================
    s1y = 3.2
    box(7.5, s1y, 1.6, 0.9, 'EX1b', C_EX, 10)
    box(13.5, s1y, 1.2, 0.9, 'WB', C_WB, 10)

    # slot1 label
    ax.text(10.5, 2.85, 'slot1 (1-cycle: ALU / load / store / branch)',
            ha='center', va='center', fontsize=7.5, color='#666', style='italic')

    # dotted line from EX1b to WB (1-cycle path)
    ax.annotate('', xy=(13.5, 3.65), xytext=(9.1, 3.65),
                arrowprops=dict(arrowstyle='->', color=C_WB, lw=1.5,
                                linestyle='dashed'))
    ax.text(11.3, 3.85, '1-cycle writeback', ha='center', fontsize=7, color='#888')

    # RS B-path → slot1 EX1b
    ax.text(9.2, 6.15, 'B-path', ha='center', fontsize=7.5, color=C_OOO, fontweight='bold')
    curved_arrow(10.8, 6.5, 9.1, 4.1, C_OOO, 1.5, 0.25)

    # ID2 → slot1 EX1b (in-order paired)
    curved_arrow(9.5, 7.5, 8.0, 4.1, '#555', 1.2, 0.15)

    # ============================================================
    # D-Cache
    # ============================================================
    box(12.0, 1.5, 2.5, 0.9, 'D-Cache', C_CACHE, 10, '2-way SA, 2KB, dual-port')
    # MEM → D$
    curved_arrow(12.6, s0y, 13.0, 2.4, C_MEM, 1.2, -0.15)
    # EX1b → D$ (slot1 load/store)
    curved_arrow(8.3, s1y, 12.0, 1.95, C_MEM, 1.0, -0.15)
    ax.text(10.0, 2.1, 'port B', ha='center', fontsize=6.5, color=C_MEM)
    ax.text(13.5, 3.0, 'port A', ha='center', fontsize=6.5, color=C_MEM)

    # ============================================================
    # CDB (bottom broadcast bus)
    # ============================================================
    cdb_y = 1.9
    # CDB bar
    rect = FancyBboxPatch((4.0, cdb_y + 0.55), 12, 0.35, boxstyle="round,pad=0.05",
                          facecolor=C_CDB, edgecolor='#B8860B', linewidth=1.5, alpha=0.7)
    ax.add_patch(rect)
    ax.text(10.0, cdb_y + 0.72, 'Common Data Bus (CDB) — 2-lane broadcast + RS wakeup',
            ha='center', va='center', fontsize=8, fontweight='bold', color='#333')

    # WB slot0 → CDB
    curved_arrow(14.1, s0y, 14.1, cdb_y + 0.9, C_CDB, 1.2, 0)
    # WB slot1 → CDB
    curved_arrow(14.1, s1y, 15.0, cdb_y + 0.9, C_CDB, 1.2, -0.1)

    # CDB → RS (wakeup, going up)
    curved_arrow(10.0, cdb_y + 0.9, 11.0, 6.5, C_CDB, 1.0, -0.4)
    ax.text(9.0, 4.5, 'wakeup', ha='center', fontsize=7, color='#B8860B', rotation=70)

    # CDB → ROB (done)
    curved_arrow(14.5, cdb_y + 0.9, 14.0, 8.2, C_CDB, 1.0, -0.15)

    # ============================================================
    # Forwarding label
    # ============================================================
    fwd_rect = FancyBboxPatch((5.5, 4.35), 5.5, 0.35, boxstyle="round,pad=0.04",
                              facecolor='#FFE4B5', edgecolor='#DEB887', linewidth=0.8, alpha=0.6)
    ax.add_patch(fwd_rect)
    ax.text(8.25, 4.52, '← ptag-based forwarding (5-stage deep) →',
            ha='center', va='center', fontsize=7, color='#8B4513')

    # ============================================================
    # Legend
    # ============================================================
    legend_items = [
        (C_FETCH,  'Fetch'),
        (C_DECODE, 'Decode'),
        (C_EX,     'Execute'),
        (C_MEM,    'Memory'),
        (C_WB,     'Writeback'),
        (C_OOO,    'OoO (RS/ROB/Rename)'),
        (C_PRED,   'Branch Prediction'),
        (C_CACHE,  'Cache'),
        (C_CDB,    'CDB'),
    ]
    lx, ly = 0.5, 5.5
    for i, (color, label) in enumerate(legend_items):
        r = mpatches.FancyBboxPatch((lx, ly - i*0.45), 0.35, 0.3,
                                    boxstyle="round,pad=0.03",
                                    facecolor=color, edgecolor='#555', linewidth=0.6, alpha=0.85)
        ax.add_patch(r)
        ax.text(lx + 0.5, ly - i*0.45 + 0.15, label, va='center', fontsize=7, color='#333')

    plt.tight_layout(pad=0.5)
    out = 'docs/cpu_architecture.png'
    fig.savefig(out, dpi=150, bbox_inches='tight', facecolor='#FAFAFA')
    print(f'Saved to {out}')
    plt.close()

if __name__ == '__main__':
    draw()
