// SPDX-License-Identifier: GPL-3.0-or-later

//! The Rust AD9361 driver against UHD's own C++, access for access.
//!
//! tests/ad9361_golden/*.trace are recorded from UHD 3.15's
//! ad9361_device.cpp (generate.sh, harness.cpp) running the scenarios of
//! tests/ad9361_golden/scenarios.txt with reads answered by
//! `ad9361::mock::settled`. Here the same scenarios run on `Ad9361` over
//! `Mock::settled()`, and the sequences must be equal: every SPI write
//! (register and value), every read (register and the value it got, so the
//! same decisions follow), every wait (us) and every return value (bit for
//! bit), in order. A POLL counts as its first read: UHD's wait loops read
//! once when the chip is already done, as `settled` says it is.
//!
//! The allowed differences (the driver's module header, changes from UHD):
//! - in each `init`, UHD's TX attenuation writes 0x073 .. 0x076 := 0 (0 dB)
//!   are ours with the maximum attenuation (0x67, 0x01, 0x67, 0x01: 359 =
//!   4 x 89.75 quarter-dB steps);
//! - the rate bands moved to keep ADI's clock limits: a scenario is compared
//!   up to its first `rate` command into a moved band (below 1.5625 MS/s,
//!   in (40, 41) MS/s, in (53.33, 58] MS/s), where UHD's driver runs a clock
//!   out of ADI's range. The RF PLL lock POLL needs no allowance: a POLL
//!   counts as its first read.
//!
//! Negative controls: a changed, dropped, added or swapped access in the
//! golden trace fails the comparison; the unmodified UHD trace differs from
//! ours exactly at the four attenuation writes of each init; the full
//! scenarios with a moved band do differ, at that `rate` command; another
//! read rule changes what the Rust driver writes.

use b210::ad9361::mock::{self, Access, Mock};
use b210::ad9361::{Ad9361, Dir, Test};
use std::fmt;
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
enum Line {
    Cmd(String),
    W(u16, u8),
    R(u16, u8),
    S(u32),
    Ret(f64),
}

impl fmt::Display for Line {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Line::Cmd(c) => write!(f, "> {c}"),
            Line::W(r, v) => write!(f, "W {r:03x} {v:02x}"),
            Line::R(r, v) => write!(f, "R {r:03x} {v:02x}"),
            Line::S(us) => write!(f, "S {us}"),
            Line::Ret(v) => write!(f, "= {v:?}"),
        }
    }
}

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/ad9361_golden")
}

/// scenarios.txt: the [name] blocks and their commands, whitespace normalised.
fn scenarios() -> Vec<(String, Vec<String>)> {
    let text = std::fs::read_to_string(dir().join("scenarios.txt")).unwrap();
    let mut out: Vec<(String, Vec<String>)> = Vec::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap().split_whitespace().collect::<Vec<_>>().join(" ");
        if line.is_empty() {
            continue;
        }
        if let Some(name) = line.strip_prefix('[') {
            out.push((name.trim_end_matches(']').to_string(), Vec::new()));
        } else {
            out.last_mut().expect("a command before the first [name]").1.push(line);
        }
    }
    out
}

fn parse_trace(name: &str) -> Vec<Line> {
    let path = dir().join(format!("{name}.trace"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e} (run generate.sh)", path.display()));
    let hex = |s: &str| u16::from_str_radix(s, 16).unwrap();
    text.lines()
        .filter(|l| !l.starts_with('#'))
        .map(|l| {
            let (tag, rest) = l.split_at(1);
            let rest = rest.trim();
            let w: Vec<&str> = rest.split(' ').collect();
            match tag {
                ">" => Line::Cmd(rest.to_string()),
                "W" => Line::W(hex(w[0]), hex(w[1]) as u8),
                "R" => Line::R(hex(w[0]), hex(w[1]) as u8),
                "S" => Line::S(rest.parse().unwrap()),
                "=" => Line::Ret(rest.parse().unwrap()),
                _ => panic!("{name}: bad line {l:?}"),
            }
        })
        .collect()
}

fn commands(trace: &[Line]) -> Vec<String> {
    trace.iter().filter_map(|l| if let Line::Cmd(c) = l { Some(c.clone()) } else { None }).collect()
}

/// A rate whose band this driver moved from UHD's (module doc).
fn moved_band(rate: f64) -> bool {
    rate < 1.5625e6 || (rate > 40e6 && rate < 41e6) || (rate > 640e6 / 12.0 && rate <= 58e6)
}

/// How many of a scenario's commands are compared: those before its first
/// `rate` into a moved band.
fn compared(cmds: &[String]) -> usize {
    cmds.iter()
        .position(|c| c.strip_prefix("rate ").is_some_and(|r| moved_band(r.parse().unwrap())))
        .unwrap_or(cmds.len())
}

/// A trace up to (not including) its command number `n`.
fn first_commands(trace: &[Line], n: usize) -> &[Line] {
    let end = trace.iter().enumerate().filter(|(_, l)| matches!(l, Line::Cmd(_))).nth(n).map_or(trace.len(), |(i, _)| i);
    &trace[..end]
}

/// The scenario on the Rust driver over `m`, as trace lines.
fn run(cmds: &[String], m: &mut Mock) -> Result<Vec<Line>, String> {
    fn drain(m: &mut Mock, out: &mut Vec<Line>) {
        for a in m.log.drain(..) {
            match a {
                Access::Write { reg, value } => out.push(Line::W(reg, value)),
                Access::Read { reg, value } => out.push(Line::R(reg, value)),
                Access::Wait { us } => out.push(Line::S(us)),
                Access::Poll { .. } => {} // its read is the Read before it
            }
        }
    }
    let dir = |s: &str| if s == "rx" { Dir::Rx } else { Dir::Tx };
    let num = |s: &str| s.parse::<f64>().unwrap();
    let byte = |s: &str| u8::from_str_radix(s.trim_start_matches("0x"), if s.starts_with("0x") { 16 } else { 10 }).unwrap();
    if cmds.first().map(String::as_str) != Some("init") {
        return Err("the first command must be init".into());
    }
    let mut out = vec![Line::Cmd(cmds[0].clone())];
    let mut d = Ad9361::init(m).map_err(|e| format!("init: {e}"))?;
    drain(d.bus(), &mut out);
    for cmd in &cmds[1..] {
        out.push(Line::Cmd(cmd.clone()));
        let w: Vec<&str> = cmd.split(' ').collect();
        let ret = match (w[0], w.len()) {
            ("rate", 2) => d.set_rate(num(w[1])).map(Some),
            ("channels", 3) => d.set_channels(byte(w[1]), byte(w[2])).map(|_| None),
            ("freq", 3) => d.set_lo(dir(w[1]), num(w[2])).map(Some),
            ("gain", 4) => d.set_gain(dir(w[1]), w[2].parse().unwrap(), num(w[3])).map(Some),
            ("bandwidth", 3) => d.set_bandwidth(dir(w[1]), num(w[2])).map(Some),
            ("delays", 3) => d.set_delays(byte(w[1]), byte(w[2])).map(|_| None),
            ("test", 2) => {
                let t = match w[1] {
                    "none" => Test::None,
                    "tone" => Test::Tone,
                    "prbs" => Test::Prbs,
                    "loopback" => Test::Loopback,
                    t => return Err(format!("test {t}")),
                };
                d.set_test(t).map(|_| None)
            }
            _ => return Err(format!("unknown command {cmd:?}")),
        }
        .map_err(|e| format!("{cmd}: {e}"))?;
        drain(d.bus(), &mut out);
        out.extend(ret.map(Line::Ret));
    }
    Ok(out)
}

/// The Rust driver on the compared part of a scenario, and UHD's trace of
/// the same part.
fn rust_and_golden(name: &str) -> (Vec<Line>, Vec<Line>) {
    let golden = parse_trace(name);
    let cmds = commands(&golden);
    let n = compared(&cmds);
    let actual = run(&cmds[..n], &mut Mock::settled()).unwrap_or_else(|e| panic!("{name}: {e}"));
    (actual, first_commands(&golden, n).to_vec())
}

fn rust(name: &str) -> Vec<Line> {
    rust_and_golden(name).0
}

const UHD_ATTEN: [Line; 4] = [Line::W(0x073, 0), Line::W(0x074, 0), Line::W(0x075, 0), Line::W(0x076, 0)];
const OUR_ATTEN: [Line; 4] = [Line::W(0x073, 0x67), Line::W(0x074, 0x01), Line::W(0x075, 0x67), Line::W(0x076, 0x01)];

/// Where the allowed difference lies: the start of UHD's attenuation writes,
/// exactly one run in each `init` block.
fn atten_positions(golden: &[Line]) -> Result<Vec<usize>, String> {
    let mut found = Vec::new();
    let mut block = String::new();
    let mut count = 0;
    for (i, l) in golden.iter().enumerate() {
        if let Line::Cmd(c) = l {
            if block == "init" && count != 1 {
                return Err(format!("{count} runs of UHD's attenuation writes in init"));
            }
            (block, count) = (c.clone(), 0);
        } else if block == "init" && golden[i..].starts_with(&UHD_ATTEN) {
            found.push(i);
            count += 1;
        }
    }
    if block == "init" && count != 1 {
        return Err(format!("{count} runs of UHD's attenuation writes in init"));
    }
    Ok(found)
}

/// UHD's trace with the allowed difference applied: what ours must equal.
fn ours(golden: &[Line]) -> Vec<Line> {
    let mut out = golden.to_vec();
    for i in atten_positions(golden).unwrap() {
        out[i..i + 4].clone_from_slice(&OUR_ATTEN);
    }
    out
}

/// Ok, or where the sequences first differ, with the command it belongs to.
fn compare(expected: &[Line], actual: &[Line]) -> Result<(), String> {
    let n = expected.iter().zip(actual).take_while(|(a, b)| a == b).count();
    if n == expected.len() && n == actual.len() {
        return Ok(());
    }
    let cmd = expected[..n].iter().rev().find_map(|l| if let Line::Cmd(c) = l { Some(c.as_str()) } else { None });
    let show = |s: &[Line]| s.get(n..(n + 3).min(s.len())).unwrap_or(&[]).iter().map(|l| l.to_string()).collect::<Vec<_>>().join(", ");
    Err(format!(
        "line {n} (in `{}`): expected [{}], got [{}] (lengths {} and {})",
        cmd.unwrap_or("?"),
        show(expected),
        show(actual),
        expected.len(),
        actual.len()
    ))
}

fn count(trace: &[Line], f: fn(&Line) -> bool) -> usize {
    trace.iter().filter(|l| f(l)).count()
}

#[test]
fn rust_driver_does_what_uhd_does() {
    let scenarios = scenarios();
    // every trace belongs to a scenario of scenarios.txt, and is current
    let mut traces: Vec<String> = std::fs::read_dir(dir())
        .unwrap()
        .filter_map(|e| e.unwrap().file_name().to_str()?.strip_suffix(".trace").map(String::from))
        .collect();
    traces.sort();
    let mut names: Vec<String> = scenarios.iter().map(|s| s.0.clone()).collect();
    names.sort();
    assert_eq!(traces, names, "traces and scenarios.txt differ: run generate.sh");

    let mut failures = Vec::new();
    println!("{:<18} {:>5} {:>7} {:>6} {:>6} {:>5} {:>8}", "scenario", "cmds", "writes", "reads", "waits", "diff", "packets");
    for (name, cmds) in &scenarios {
        let golden = parse_trace(name);
        assert_eq!(&commands(&golden), cmds, "{name}: trace not current with scenarios.txt: run generate.sh");
        let writes = count(&golden, |l| matches!(l, Line::W(..)));
        assert!(writes > 2000, "{name}: only {writes} writes: a vacuous trace");
        let n = compared(cmds);
        let golden = first_commands(&golden, n).to_vec();
        let mut m = Mock::settled();
        let actual = run(&cmds[..n], &mut m);
        // command packets a binding sends (before splitting at 126 operations);
        // UHD's driver makes one bus round trip per access
        let packets = m.round_trips;
        let diff = 4 * atten_positions(&golden).unwrap().len();
        println!(
            "{name:<18} {:>5} {writes:>7} {:>6} {:>6} {diff:>5} {packets:>8}",
            cmds.len(),
            count(&golden, |l| matches!(l, Line::R(..))),
            count(&golden, |l| matches!(l, Line::S(..)))
        );
        match actual {
            Ok(actual) => {
                if let Err(e) = compare(&ours(&golden), &actual) {
                    failures.push(format!("{name}: {e}"));
                }
            }
            Err(e) => failures.push(format!("{name}: {e}")),
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn every_changed_access_is_caught() {
    // a value changed in any line of the golden trace (write, read, wait,
    // return) fails the comparison, at that line
    let golden = parse_trace("b210_30m72_2r2t");
    let expected = ours(&golden);
    let actual = rust("b210_30m72_2r2t");
    compare(&expected, &actual).unwrap();
    let mut tried = 0;
    for i in (0..expected.len()).step_by(37) {
        let mut bad = expected.clone();
        bad[i] = match &bad[i] {
            Line::W(r, v) => Line::W(*r, v ^ 0x01),
            Line::R(r, v) => Line::R(*r, v ^ 0x80),
            Line::S(us) => Line::S(us + 1),
            Line::Ret(v) => Line::Ret(v + 1e-6),
            Line::Cmd(_) => continue,
        };
        let e = compare(&bad, &actual).expect_err("a changed line passed");
        assert!(e.starts_with(&format!("line {i} ")), "{e}");
        tried += 1;
    }
    assert!(tried > 100);
}

#[test]
fn a_dropped_added_or_swapped_write_is_caught() {
    let expected = ours(&parse_trace("b210_61m44_1r1t"));
    let actual = rust("b210_61m44_1r1t");
    let writes: Vec<usize> = (0..expected.len()).filter(|&i| matches!(expected[i], Line::W(..))).collect();
    for &i in writes.iter().step_by(211) {
        let mut dropped = expected.clone();
        dropped.remove(i);
        assert!(compare(&dropped, &actual).is_err(), "dropped {i}");
        let mut added = expected.clone();
        added.insert(i, expected[i].clone());
        assert!(compare(&added, &actual).is_err(), "added {i}");
        if let Some(j) = (i + 1..expected.len()).find(|&j| matches!(expected[j], Line::W(..)) && expected[j] != expected[i]) {
            let mut swapped = expected.clone();
            swapped.swap(i, j);
            assert!(compare(&swapped, &actual).is_err(), "swapped {i} {j}");
        }
    }
}

#[test]
fn uhd_unmodified_differs_only_in_the_tx_attenuation() {
    // without the allowed difference applied, every scenario differs from
    // ours exactly at the four attenuation writes of its init, nowhere else
    for (name, _) in scenarios() {
        let (actual, golden) = rust_and_golden(&name);
        assert_eq!(golden.len(), actual.len(), "{name}");
        let differ: Vec<usize> = (0..golden.len()).filter(|&i| golden[i] != actual[i]).collect();
        let allowed: Vec<usize> = atten_positions(&golden).unwrap().iter().flat_map(|&i| i..i + 4).collect();
        assert_eq!(allowed.len(), 4, "{name}");
        assert_eq!(differ, allowed, "{name}");
        assert_eq!(actual[allowed[0]..allowed[0] + 4], OUR_ATTEN, "{name}");
    }
}

#[test]
fn the_moved_rate_bands_are_compared_up_to_their_rate_command() {
    // which scenarios are cut, and where; init and the scenarios at 30.72 and
    // 61.44 MS/s are compared whole
    let cut: Vec<(String, usize, usize)> = scenarios()
        .into_iter()
        .filter(|(_, cmds)| compared(cmds) < cmds.len())
        .map(|(name, cmds)| (name, compared(&cmds), cmds.len()))
        .collect();
    assert_eq!(cut, [("b210_1m".to_string(), 1, 9), ("rates".into(), 1, 22), ("bandwidths".into(), 17, 20)]);
    // negative control: the full scenarios differ from UHD there, so the cut
    // is needed and not hiding anything before it
    let full = |name: &str| {
        let golden = ours(&parse_trace(name));
        run(&commands(&golden), &mut Mock::settled()).and_then(|actual| compare(&golden, &actual))
    };
    assert!(full("b210_1m").unwrap_err().contains("(in `rate 1e6`)"));
    assert!(full("bandwidths").unwrap_err().contains("(in `rate 1e6`)"));
    assert!(full("rates").unwrap_err().starts_with("rate 220e3: "), "below the minimum rate");
    assert!(moved_band(56e6) && !moved_band(50e6) && !moved_band(61.44e6) && !moved_band(30.72e6));
}

#[test]
fn another_read_rule_changes_the_writes() {
    // the traces depend on what the reads return: the same scenario with the
    // rx filter's C read one higher no longer matches UHD's trace
    let golden = ours(&parse_trace("bandwidths"));
    let mut shifted = Mock::new(|reg, regs| if reg == 0x1EC { mock::settled(reg, regs) + 1 } else { mock::settled(reg, regs) });
    let actual = run(&commands(&golden), &mut shifted).unwrap();
    let e = compare(&golden, &actual).expect_err("a different chip gave UHD's trace");
    assert!(e.contains("R 1ec"), "{e}");
}
