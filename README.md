# midi-lfo

MIDI CC LFO utility for norns.

This script provides 32 always-running LFO lanes that send MIDI CC values to a shared MIDI output device.

## Features

- 32 independent LFO lanes
- Per-lane routing:
  - MIDI channel
  - instrument type
  - context
  - parameter (auto-selects MIDI CC from mapping data)
- Per-lane LFO settings:
  - base CC value (0-127)
  - shape: sin, saw, reverse_saw, triangle, sample_hold
  - rate in Hz (0.001 to 20.00)
  - depth (0-127)
- MIDI input base-follow:
  - incoming CC on the selected MIDI device can update lane base values
  - matching is per-lane route (same MIDI channel and mapped CC)
  - base follows smoothly toward incoming values
- No toggle required; all LFO lanes run continuously
- State persistence across sessions

## Files

- bento_lfo_cc.lua: main norns script
- lib/bento_cc_index.lua: generated mapping data for instrument/context/parameter to MIDI CC

## Install

1. Copy this folder to dust scripts:
   ~/.local/share/SuperCollider/downloaded-quarks/
   or your normal norns scripts location if you manage scripts there.

2. Ensure the folder name is midi-lfo.

3. In norns, load script:
   midi-lfo/bento_lfo_cc

## Controls

- E1: page select
- E2: field select
- E3: adjust selected field
- K2: previous lane
- K3: next lane

## Pages

1. Global
- MIDI output device
- Selected lane

2. Route
- Lane MIDI channel
- Instrument type
- Context
- Parameter and CC target

3. LFO
- Base value
- Shape
- Rate (Hz)
- Depth

## Notes

- Output CC values are clamped to 0-127.
- LFO phase is continuous during edits.
- Sample and hold updates on cycle wrap.
- All lanes share the selected output MIDI device.
- MIDI base-follow only affects lanes that match incoming CC channel + CC number.
- If multiple lanes share the same channel + CC mapping, all matching lanes follow.
- Manual base edits (encoder or grid hold) apply immediately and continue following from there.
- Base-follow shifts the LFO center while depth, shape, and rate continue to apply normally.
