# Project X-Ray device data

This directory contains the Project X-Ray (CC0 1.0) bitstream database subset
needed for the B210's Kintex-7 `xc7k325tffg676-1` part:

- `kintex7/` shared tile, segment, site, and routing tables;
- `kintex7/xc7k325t/` fabric grid;
- `kintex7/xc7k325tffg676-1/` package and part definition;
- `kintex7/mapping/` part-to-fabric mapping;
- `artix7/timings/` the 7-series SDF timing tables used by nextpnr's chip
  database generator for carry, mux, and BRAM timing.

The files are unmodified database output. No compiler, place-and-route tool,
or vendor tool is included. The data is vendored because the current F4PGA
`prjxray-db` release only ships the Kintex-7 70T device; the 325T tables are
required to place and route the B210 design and to assemble its bitstream.

The database is licensed CC0 1.0. See `LICENSE`.

Upstream project: https://github.com/F4PGA/prjxray-db
