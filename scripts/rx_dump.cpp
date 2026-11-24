// rx_dump - timed, fixed-length receive capture to raw files.
//
//   rx_dump <device args> <rate> <channels: 0 | 0,1> <samples> <out prefix>
//           [freq_hz] [gain_db] [otw: sc16|sc12|sc8] [tx_tone_hz]
//
// With tx_tone_hz the same channels also transmit, for the whole capture, a
// complex tone at that baseband frequency and half of full scale (channel n
// at tx_tone_hz * (n + 1), so the two transmitters are told apart).  The
// block that is sent over and over is written to <prefix>_tx_ch<n>.sc16.
//
// Writes <prefix>_ch<n>.sc16 (interleaved int16 I,Q exactly as the FPGA sent
// them, no host scaling) and prints one summary line.  Exit status 0 only
// when every requested sample arrived and the streamer reported no error.
// Built against the measuring UHD by `scripts/toolchain.sh uhd`; with
// UHD_AD936X_BIST set the AD9361 replaces the antenna signal by its digital
// test tone, which makes the capture a check of the sample path itself; with
// UHD_AD936X_LOOPBACK it returns the transmit data on the receive port, so
// the transmitted tone checks the transmit path the same way.
#include <uhd/types/tune_request.hpp>
#include <uhd/usrp/multi_usrp.hpp>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char* argv[])
{
    if (argc < 6) {
        std::cerr << "usage: rx_dump <args> <rate> <channels> <samples> <prefix> "
                     "[freq] [gain] [otw] [tx_tone_hz]\n";
        return 2;
    }
    const std::string args = argv[1], chans = argv[3], prefix = argv[5];
    const double rate    = std::atof(argv[2]);
    const size_t total   = std::strtoull(argv[4], nullptr, 0);
    const double freq    = argc > 6 ? std::atof(argv[6]) : 100e6;
    const double gain    = argc > 7 ? std::atof(argv[7]) : 0.0;
    const std::string otw = argc > 8 ? argv[8] : "sc16";
    const double tx_tone  = argc > 9 ? std::atof(argv[9]) : 0.0;

    std::vector<size_t> channels;
    for (size_t pos = 0; pos < chans.size(); pos += 2)
        channels.push_back(size_t(chans[pos] - '0'));

    auto usrp = uhd::usrp::multi_usrp::make(args);
    for (size_t ch : channels) {
        usrp->set_rx_rate(rate, ch);
        usrp->set_rx_freq(uhd::tune_request_t(freq), ch);
        usrp->set_rx_gain(gain, ch);
    }
    uhd::stream_args_t stream_args("sc16", otw);
    stream_args.channels = channels;
    auto rx = usrp->get_rx_stream(stream_args);
    uhd::tx_streamer::sptr tx;
    if (tx_tone != 0.0) {
        for (size_t ch : channels) {
            usrp->set_tx_rate(rate, ch);
            usrp->set_tx_freq(uhd::tune_request_t(freq), ch);
            usrp->set_tx_gain(0.0, ch);
        }
        tx = usrp->get_tx_stream(stream_args);
    }

    std::vector<std::vector<std::complex<int16_t>>> data(
        channels.size(), std::vector<std::complex<int16_t>>(total));
    // The transmit waveform, computed once: one block holding a whole number
    // of periods of every channel's tone, sent over and over, so the sender
    // does no arithmetic while streaming.
    std::vector<std::vector<std::complex<int16_t>>> wave(channels.size());
    if (tx) {
        size_t block = 0;
        for (size_t n = 8192; n <= (size_t(1) << 20) && block == 0; n++) {
            const double cycles = tx_tone * double(n) / rate;
            if (std::fabs(cycles - std::round(cycles)) < 1e-9)
                block = n;
        }
        if (block == 0) {
            std::cerr << "rx_dump: no block up to 2^20 samples holds whole periods of "
                      << tx_tone << " Hz at " << rate << " S/s\n";
            return 2;
        }
        for (size_t c = 0; c < channels.size(); c++) {
            const double step = 2 * M_PI * tx_tone * double(channels[c] + 1) / rate;
            wave[c].resize(block);
            for (size_t n = 0; n < block; n++)
                wave[c][n] = std::complex<int16_t>(int16_t(std::lround(16384 * std::cos(step * double(n)))),
                    int16_t(std::lround(16384 * std::sin(step * double(n)))));
            std::ofstream f(prefix + "_tx_ch" + std::to_string(channels[c]) + ".sc16", std::ios::binary);
            f.write(reinterpret_cast<const char*>(wave[c].data()), block * 4);
        }
    }

    // One synchronous time set for both radio cores: the streamer aligns
    // channels by timestamp, and with a fixed master clock nothing else
    // brings the two time counters together.
    usrp->set_time_now(uhd::time_spec_t(0.0));
    uhd::stream_cmd_t cmd(uhd::stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_DONE);
    cmd.num_samps  = total;
    cmd.stream_now = false;
    cmd.time_spec  = uhd::time_spec_t(0.3);
    rx->issue_stream_cmd(cmd);

    std::atomic<bool> stop(false);
    std::atomic<size_t> tx_underruns(0);
    std::thread tx_thread;
    if (tx) {
        tx_thread = std::thread([&]() {
            const size_t block = wave[0].size();
            uhd::tx_metadata_t tmd;
            tmd.start_of_burst = true;
            tmd.has_time_spec  = true;
            tmd.time_spec      = uhd::time_spec_t(0.2);
            while (!stop) {
                std::vector<void*> tb;
                for (auto& w : wave)
                    tb.push_back(w.data());
                tx->send(tb, block, tmd, 1.0);
                tmd.start_of_burst = false;
                tmd.has_time_spec  = false;
                uhd::async_metadata_t am;
                while (tx->recv_async_msg(am, 0.0))
                    if (am.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW)
                        tx_underruns++;
            }
            tmd.end_of_burst = true;
            tx->send("", 0, tmd);
        });
    }

    uhd::rx_metadata_t md;
    size_t got = 0, errors = 0;
    std::string first_error;
    while (got < total) {
        std::vector<void*> buffs;
        for (auto& d : data)
            buffs.push_back(&d[got]);
        const size_t n = rx->recv(buffs, total - got, md, 3.0);
        if (md.error_code != uhd::rx_metadata_t::ERROR_CODE_NONE) {
            if (errors++ == 0)
                first_error = md.strerror();
            if (md.error_code == uhd::rx_metadata_t::ERROR_CODE_TIMEOUT)
                break;
        }
        got += n;
    }
    stop = true;
    if (tx_thread.joinable())
        tx_thread.join();
    for (size_t i = 0; i < channels.size(); i++) {
        std::ofstream f(prefix + "_ch" + std::to_string(channels[i]) + ".sc16",
            std::ios::binary);
        f.write(reinterpret_cast<const char*>(data[i].data()), got * 4);
    }
    std::printf("rx_dump: %zu/%zu samples x %zu ch at %.3f MS/s (actual %.6f), "
                "errors %zu%s%s, tx underruns %zu\n",
        got, total, channels.size(), rate / 1e6, usrp->get_rx_rate(channels[0]) / 1e6,
        errors, errors ? ": " : "", first_error.c_str(), size_t(tx_underruns));
    return (got == total && errors == 0 && tx_underruns == 0) ? 0 : 1;
}
