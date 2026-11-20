# Session log — fill in the measured column

Image sha256 prefix: `c1cc09dd`   Date: ______   Operator: ______
UHD version: ______   Host/USB: `lsusb -t` speed: ______

## Layer 0 - alive
| step | expected | measured | P/F |
|---|---|---|---|
| flash | no error, USRP B210 found | | |
| uhd_find_devices | codec reported (SPI works) | | |
| uhd_usrp_probe | 2 radios, 61.44 MHz master | | |

## Layer 1 - RX idle (both channels)
| step | expected | measured | P/F |
|---|---|---|---|
| 10 min capture | no O/D in console | | |
| rms / distinct codes | noise-like, no stuck runs | | |
| I/Q identity | tone appears on the right channel, right phase | | |

## Layer 2 - TX and the cable loop
| step | expected | measured | P/F |
|---|---|---|---|
| PA enable delay (scope) | 81 ns after run_tx, no runt | | |
| loop gain (wf_tone7_ref) | 1.0000 +- 0.01 after pad | | |
| loop residual | >= -55 dBc; worse = analogue | | |
| drive scaling (wf_tone7_low) | products fixed in absolute terms | | |
| IMD (wf_2tone) | products at the dither floor | | |
| LO leakage (wf_idle) | DC of the chain only | | |

## Layer 3 - MIMO and both directions
| step | expected | measured | P/F |
|---|---|---|---|
| gated start phase | 0.000 deg | | |
| naive start phase | -90.000 deg exactly | | |
| reverse path gain (source->RX->TX) | 1.0000 | | |
| channel crosstalk | <= pad isolation | | |

## Layer 4 - RF and rates
| step | expected | measured | P/F |
|---|---|---|---|
| tone image, in band | <= -61 dBc | | |
| x8 / x16 tilt | -0.402 / -0.788 dB (CIC, expected) | | |
| TX level vs rate | rate-independent | | |
| 10 min throughput, 2 ch | no sustained overrun | | |
| 200 us host stall | no sample loss | | |

## Observations
(everything that is not in a table above; no judgement, just numbers)

## Hardware-only items left open after this session
- AD9361 MIMO frame protocol and channel skew (scope)
- analogue IQ imbalance / DC calibration state
- PA compression at the operating point
- FX3 flag timing under sustained load
