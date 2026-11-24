# The B210 open FPGA container image: synthesis and bitstream assembly.
#
# Composes the atomic images without rebuilding their sources:
#   yosys    -> /opt/fpga from the Yosys image
#   prjxray  -> /opt/fpga from the Project X-Ray image
#
# Place and route is NOT in here: nextpnr is built on the host from pinned
# sources by scripts/toolchain.sh, together with the device database that
# scripts/assemble.sh mounts into this image at /opt/fpga/share/prjxray-db.

ARG BASE_IMAGE
ARG YOSYS_IMAGE
ARG PRJXRAY_IMAGE

FROM ${YOSYS_IMAGE} AS yosys
FROM ${PRJXRAY_IMAGE} AS prjxray

FROM ${BASE_IMAGE}

COPY --from=yosys /opt/fpga /opt/fpga
COPY --from=prjxray /opt/fpga /opt/fpga

ENV PATH="/opt/fpga/venv/bin:/opt/fpga/bin:${PATH}"
ENV FPGA_HOME=/opt/fpga
ENV PRJXRAY_DB=/opt/fpga/share/prjxray-db

RUN yosys -V \
 && test -x "$(command -v fasm2frames)" \
 && test -x "$(command -v xc7frames2bit)" \
 && test -x "$(command -v bittool)"

WORKDIR /work
CMD ["/bin/bash"]
