// SPDX-License-Identifier: GPL-3.0-or-later
//
// Golden traces of UHD's AD9361 driver (UHD 3.15 as v1 ran it,
// .tools/src/uhd/host/lib/usrp/common/ad9361_driver/ad9361_device.cpp,
// compiled unmodified), for tests/ad9361_golden.rs.
//
//   harness SCENARIOS OUTDIR
//
// For every [name] block of SCENARIOS it drives one ad9361_device_t with the
// block's commands and writes OUTDIR/name.trace:
//
//   > command          a command of the scenario, as written there
//   W rrr vv           poke8(0xrrr, 0xvv)
//   R rrr vv           peek8(0xrrr) answered 0xvv
//   S us               std::this_thread::sleep_for (us)
//   = value            the command's return value (%.17g)
//
// Reads are answered by the rule `settled` of host/b210/src/ad9361/mock.rs
// (the same table, transcribed below): every calibration done, every PLL
// locked. The client settings are the B210's (b200_impl.cpp,
// b200_ad9361_client_t, copied).
//
// Commands (the Rust driver's API, with the UHD call each one maps to):
//   init                      initialize()
//   rate R                    set_clock_rate(R)
//   channels RX TX            set_active_chains(tx & 1, tx & 2, rx & 1, rx & 2)
//   freq rx|tx F              tune(dir, F)
//   gain rx|tx CH G           set_gain(dir, CHAIN_1 + CH, G)
//   bandwidth rx|tx BW        set_bw_filter(dir, BW)
//   delays RX TX              set_interface_delays(RX, TX)
//   test tone|prbs            v1's UHD_AD936X_BIST=0x1B|0x09 (written to 0x3F4 at
//                             the end of set_active_chains): only right after a
//                             `channels`, which runs with the variable set
//   test loopback|none        data_port_loopback(true|false)
// A test change UHD has no call for (tone or PRBS switched off) is refused.

#include "ad9361_device.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using namespace uhd::usrp;

namespace golden {
FILE* out = nullptr;
void sleep_us(long long us)
{
    std::fprintf(out, "S %lld\n", us);
}
} // namespace golden

// b200_impl.cpp b200_ad9361_client_t (B200 + B210)
class b210_params : public ad9361_params
{
public:
    double get_band_edge(frequency_band_t band) override
    {
        switch (band) {
            case AD9361_RX_BAND0:
                return 2.2e9; // Port C
            case AD9361_RX_BAND1:
                return 4.0e9; // Port B
            case AD9361_TX_BAND0:
                return 2.5e9; // Port B
            default:
                return 0;
        }
    }
    clocking_mode_t get_clocking_mode() override
    {
        return clocking_mode_t::AD9361_XTAL_N_CLK_PATH;
    }
    digital_interface_mode_t get_digital_interface_mode() override
    {
        return AD9361_DDR_FDD_LVCMOS;
    }
    digital_interface_delays_t get_digital_interface_timing() override
    {
        digital_interface_delays_t delays;
        delays.rx_clk_delay  = 0;
        delays.rx_data_delay = 0xF;
        delays.tx_clk_delay  = 0;
        delays.tx_data_delay = 0xF;
        return delays;
    }
};

class recorder : public ad9361_io
{
public:
    uint8_t regs[1024] = {};
    // a "> test ..." line to print before the next 0x3F4 write
    std::string marker;

    recorder()
    {
        regs[0x0A3] = 0x4A;
    }

    // host/b210/src/ad9361/mock.rs `settled`
    uint8_t settled(uint32_t reg)
    {
        switch (reg) {
            case 0x037:
                return 0x0A;
            case 0x017: {
                const uint8_t ctrl = regs[0x014];
                return (ctrl & 0x20) ? 0x0A : (ctrl & 0x05) ? 0x05 : 0x00;
            }
            case 0x016:
                return 0x00;
            case 0x05E:
            case 0x244:
            case 0x284:
                return 0x80;
            case 0x247:
            case 0x287:
                return 0x02;
            case 0x1EB:
                return uint8_t(regs[0x1FB] * 3 + 1) & 0x3F;
            case 0x1EC:
                return regs[0x1FC] & 0x7F;
            case 0x1E6:
                return (regs[0x1F8] & 0x07) | 0x01;
            default:
                return regs[reg];
        }
    }

    uint8_t peek8(uint32_t reg) override
    {
        const uint8_t v = settled(reg);
        std::fprintf(golden::out, "R %03x %02x\n", reg, v);
        return v;
    }

    void poke8(uint32_t reg, uint8_t val) override
    {
        if (reg == 0x3F4 && !marker.empty()) {
            std::fprintf(golden::out, "> %s\n", marker.c_str());
            marker.clear();
        }
        regs[reg] = val;
        std::fprintf(golden::out, "W %03x %02x\n", reg, val);
    }
};

static std::vector<std::string> words(const std::string& line)
{
    std::istringstream s(line);
    std::vector<std::string> w;
    for (std::string x; s >> x;)
        w.push_back(x);
    return w;
}

static void fail(const std::string& why)
{
    std::cerr << "harness: " << why << "\n";
    std::exit(1);
}

static ad9361_device_t::direction_t dir_of(const std::string& s)
{
    if (s == "rx")
        return ad9361_device_t::RX;
    if (s == "tx")
        return ad9361_device_t::TX;
    fail("direction " + s);
    return ad9361_device_t::RX;
}

static void run(const std::string& name, const std::vector<std::string>& cmds, const std::string& outdir)
{
    const std::string path = outdir + "/" + name + ".trace";
    golden::out = std::fopen(path.c_str(), "w");
    if (!golden::out)
        fail("cannot write " + path);
    std::fprintf(golden::out,
        "# %s: UHD 3.15 ad9361_device.cpp driven by harness.cpp (generate.sh); "
        "do not edit\n",
        name.c_str());
    boost::shared_ptr<recorder> io(new recorder);
    boost::shared_ptr<b210_params> params(new b210_params);
    std::unique_ptr<ad9361_device_t> dev;
    bool bist = false, loopback = false;
    auto value = [](double v) { std::fprintf(golden::out, "= %.17g\n", v); };
    for (size_t i = 0; i < cmds.size(); i++) {
        const std::vector<std::string> w = words(cmds[i]);
        std::fprintf(golden::out, "> %s\n", cmds[i].c_str());
        if (w[0] == "init") {
            dev.reset(new ad9361_device_t(params, io));
            dev->initialize();
            continue;
        }
        if (!dev)
            fail(name + ": the first command must be init");
        if (w[0] == "rate") {
            value(dev->set_clock_rate(std::stod(w[1])));
        } else if (w[0] == "channels") {
            const unsigned rx = std::stoul(w[1]), tx = std::stoul(w[2]);
            const std::vector<std::string> next =
                i + 1 < cmds.size() ? words(cmds[i + 1]) : std::vector<std::string>();
            const bool test = next.size() == 2 && next[0] == "test"
                              && (next[1] == "tone" || next[1] == "prbs");
            if (test) {
                if (loopback)
                    fail(name + ": tone/PRBS over loopback has no UHD call");
                setenv("UHD_AD936X_BIST", next[1] == "tone" ? "0x1B" : "0x09", 1);
                io->marker = cmds[i + 1];
                bist = true;
            }
            dev->set_active_chains(tx & 1, tx & 2, rx & 1, rx & 2);
            unsetenv("UHD_AD936X_BIST");
            if (test) {
                if (!io->marker.empty())
                    fail(name + ": no 0x3F4 write for " + cmds[i + 1]);
                i++;
            }
        } else if (w[0] == "freq") {
            value(dev->tune(dir_of(w[1]), std::stod(w[2])));
        } else if (w[0] == "gain") {
            const auto chain = std::stoul(w[2]) == 0 ? ad9361_device_t::CHAIN_1
                                                     : ad9361_device_t::CHAIN_2;
            value(dev->set_gain(dir_of(w[1]), chain, std::stod(w[3])));
        } else if (w[0] == "bandwidth") {
            value(dev->set_bw_filter(dir_of(w[1]), std::stod(w[2])));
        } else if (w[0] == "delays") {
            dev->set_interface_delays(
                uint8_t(std::stoul(w[1], nullptr, 0)), uint8_t(std::stoul(w[2], nullptr, 0)));
        } else if (w[0] == "test" && (w[1] == "loopback" || w[1] == "none")) {
            if (bist)
                fail(name + ": UHD has no call that switches the BIST off");
            const bool on = w[1] == "loopback";
            if (on != loopback)
                dev->data_port_loopback(on);
            loopback = on;
        } else {
            fail(name + ": unknown command (tone/prbs only right after channels): " + cmds[i]);
        }
    }
    std::fclose(golden::out);
}

int main(int argc, char** argv)
{
    if (argc != 3)
        fail("usage: harness SCENARIOS OUTDIR");
    std::ifstream in(argv[1]);
    if (!in)
        fail(std::string("cannot read ") + argv[1]);
    std::vector<std::pair<std::string, std::vector<std::string>>> scenarios;
    for (std::string line; std::getline(in, line);) {
        line = line.substr(0, line.find('#'));
        const std::vector<std::string> w = words(line);
        if (w.empty())
            continue;
        if (w[0].front() == '[') {
            scenarios.push_back({w[0].substr(1, w[0].size() - 2), {}});
            continue;
        }
        if (scenarios.empty())
            fail("a command before the first [name]");
        std::string cmd = w[0];
        for (size_t k = 1; k < w.size(); k++)
            cmd += " " + w[k];
        scenarios.back().second.push_back(cmd);
    }
    for (const auto& s : scenarios) {
        try {
            run(s.first, s.second, argv[2]);
        } catch (const std::exception& e) {
            fail(s.first + ": UHD threw: " + e.what());
        }
        std::cout << s.first << "\n";
    }
    return 0;
}
