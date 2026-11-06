# Final B210 Open FPGA toolchain image.
#
# Composes the atomic images without rebuilding their sources:
#   yosys    -> /opt/fpga from the Yosys image
#   nextpnr  -> /opt/fpga from the nextpnr image
#   prjxray  -> /opt/fpga from the Project X-Ray image
#
# The final image is the only image the project build uses. The atomic images
# can also be built and used on their own with the tools-* Make targets.

ARG BASE_IMAGE
ARG YOSYS_IMAGE
ARG NEXTPNR_IMAGE
ARG PRJXRAY_IMAGE

FROM ${YOSYS_IMAGE} AS yosys
FROM ${NEXTPNR_IMAGE} AS nextpnr
FROM ${PRJXRAY_IMAGE} AS prjxray

FROM ${BASE_IMAGE}

COPY --from=yosys /opt/fpga /opt/fpga
COPY --from=nextpnr /opt/fpga /opt/fpga
COPY --from=prjxray /opt/fpga /opt/fpga

ENV PATH="/opt/fpga/venv/bin:/opt/fpga/bin:${PATH}"
ENV FPGA_HOME=/opt/fpga
ENV PRJXRAY_DB=/opt/fpga/share/prjxray-db
ENV NEXTPNR_CHIPDB=/opt/fpga/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin

RUN yosys -V \
 && (nextpnr-himbaechel --version 2>/dev/null || nextpnr-himbaechel --help >/dev/null) \
 && test -x "$(command -v fasm2frames)" \
 && test -x "$(command -v xc7frames2bit)" \
 && test -x "$(command -v bittool)" \
 && test -s "$NEXTPNR_CHIPDB"

WORKDIR /work
CMD ["/bin/bash"]
