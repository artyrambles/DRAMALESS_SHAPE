#!/usr/bin/env python3
"""
Per-species battle data.

`func_84302658` in src/fragments/62 DMAs a 0xB90-byte table per species out of
the 0x70D3A0 segment, addressed through the D_80075BD0 pointer table. It is an
array of 0x10-byte entries: byte 0 is an index into that Pokemon's animation
list, byte 1 indexes the auxiliary (texture) animation list.

  entries 0..164   one per move, so entry n drives move n + 1
  entries 165+     fixed battle contexts

Every one of the 151 species' tables indexes only animations that species
actually has, which is what confirms the layout.
"""
import os
import struct

STRIDE = 0xB90
ENTRY = 0x10
N_MOVES = 165

# `evidence` records how far each label can be trusted:
#   code  - the battle code in src/fragments/62 names the slot outright
#   data  - inferred from what the referenced animation does, measured over all
#           151 species
CONTEXT_SLOTS = {
    165: ('idle', 'code',
          'The standby loop. func_8432B0A4 restores this slot whenever the Pokemon '
          'returns to neutral, and it resolves to animation 0 for all 151 species.'),
    166: ('attack_default', 'data',
          'Resolves to animation 2 for 149/151 species, the same animation slots '
          '178-181 use in the reaction paths. Called "hit" until the move table '
          'was read against it: it is the animation most of a species\' MOVES '
          'play, the default attack rather than a damage reaction (the name has '
          'to match lib/StadiumPack.lua\'s CONTEXT and StadiumBuild\'s CONTEXTS).'),
    167: ('faint', 'data',
          'The referenced animation always ends far from the standing pose - the '
          'model collapses to 0.03-0.84x its idle height, or leaves the frame '
          'entirely for fliers.'),
    168: ('entrance', 'code+data',
          'The default slot in func_8430506C / func_8432AF70. The referenced '
          'animation ends at exactly idle height, so it is a full cycle that '
          'settles back into the standby pose.'),
    169: ('reaction_169', 'data', 'Resolves to the idle animation for 139/151 species.'),
    170: ('reaction_170', 'data', 'Split between the idle and hit animations.'),
    171: ('reaction_171', 'data', 'Resolves to the idle animation for 138/151 species.'),
    172: ('reaction_172', 'data', 'Resolves to the idle animation for 148/151 species.'),
    173: ('reaction_173', 'data', 'Resolves to the hit animation for 97/151 species.'),
    174: ('reaction_174', 'data', 'Resolves to the idle animation for 138/151 species.'),
    175: ('struggle', 'code', 'Passed as slot 0xAF to func_84305A74.'),
    176: ('idle_alt', 'code',
          'Substituted for the idle slot when battle flag 0x200 is set.'),
    177: ('faint_alt', 'data', 'Same animation as slot 167 for almost every species.'),
    178: ('flinch', 'code',
          'Used when the incoming move is one of the two listed in D_84384598.'),
    179: ('reaction_179', 'data', 'Resolves to the hit animation for all 151 species.'),
    180: ('reaction_180', 'data', 'Resolves to the hit animation for all 151 species.'),
    181: ('reaction_181', 'data', 'Resolves to the hit animation for all 151 species.'),
    182: ('reaction_182', 'data',
          'Resolves to animation 0 for 136 species and animation 1 for the other 15.'),
    183: ('entrance_alt', 'data', 'Same animation as slot 168 for every species.'),
    184: ('idle_return', 'code', 'Passed as slot 0xB8 to func_84305A74.'),
}

MOVE_CONSTANTS = 'oldnotes/stadium1/constants/move_constants.s'


def load_move_names(repo_root='.'):
    """Move IDs come from the repo's own extracted constants when available."""
    path = os.path.join(repo_root, MOVE_CONSTANTS)
    names = {}
    if os.path.exists(path):
        for line in open(path, encoding='utf-8', errors='replace'):
            # the file also carries an ABC_* section indexing moves alphabetically
            # by their Japanese names; only the real move IDs are wanted
            if ' EQU ' not in line or line.startswith('ABC_'):
                continue
            name, val = line.split(' EQU ')
            val = val.split(';', 1)[0].strip()
            if val:
                names[int(val, 0)] = name.strip().replace('_', ' ').title()
    return {i: names.get(i, f'Move {i}') for i in range(1, N_MOVES + 1)}


class BattleTables:
    def __init__(self, rom):
        from rom import BATTLE_DATA, PTR_TABLE_VRAM
        self.rom = rom
        self.base = BATTLE_DATA
        self.ptr_table = rom.vram_to_rom(PTR_TABLE_VRAM)

    def offset(self, species):
        raw = self.rom.u32(self.ptr_table + (species - 1) * 4)
        return self.base + (raw & 0xFFFFFF)

    def rows(self, species):
        """Returns [(animIndex, auxIndex)] for every entry, aux 0xFF -> -1."""
        o = self.offset(species)
        out = []
        for e in range(STRIDE // ENTRY):
            anim = self.rom.data[o + e * ENTRY]
            aux = self.rom.data[o + e * ENTRY + 1]
            out.append((anim, -1 if aux == 0xFF else aux))
        return out


SPECIES = {}
_NAMES = (
    "Bulbasaur Ivysaur Venusaur Charmander Charmeleon Charizard Squirtle Wartortle Blastoise "
    "Caterpie Metapod Butterfree Weedle Kakuna Beedrill Pidgey Pidgeotto Pidgeot Rattata Raticate "
    "Spearow Fearow Ekans Arbok Pikachu Raichu Sandshrew Sandslash NidoranF Nidorina Nidoqueen "
    "NidoranM Nidorino Nidoking Clefairy Clefable Vulpix Ninetales Jigglypuff Wigglytuff Zubat "
    "Golbat Oddish Gloom Vileplume Paras Parasect Venonat Venomoth Diglett Dugtrio Meowth Persian "
    "Psyduck Golduck Mankey Primeape Growlithe Arcanine Poliwag Poliwhirl Poliwrath Abra Kadabra "
    "Alakazam Machop Machoke Machamp Bellsprout Weepinbell Victreebel Tentacool Tentacruel Geodude "
    "Graveler Golem Ponyta Rapidash Slowpoke Slowbro Magnemite Magneton Farfetchd Doduo Dodrio "
    "Seel Dewgong Grimer Muk Shellder Cloyster Gastly Haunter Gengar Onix Drowzee Hypno Krabby "
    "Kingler Voltorb Electrode Exeggcute Exeggutor Cubone Marowak Hitmonlee Hitmonchan Lickitung "
    "Koffing Weezing Rhyhorn Rhydon Chansey Tangela Kangaskhan Horsea Seadra Goldeen Seaking "
    "Staryu Starmie MrMime Scyther Jynx Electabuzz Magmar Pinsir Tauros Magikarp Gyarados Lapras "
    "Ditto Eevee Vaporeon Jolteon Flareon Porygon Omanyte Omastar Kabuto Kabutops Aerodactyl "
    "Snorlax Articuno Zapdos Moltres Dratini Dragonair Dragonite Mewtwo Mew").split()
for _i, _n in enumerate(_NAMES):
    SPECIES[_i + 1] = _n
