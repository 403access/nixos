use clap::Parser;

use nixos_control::peripherals::{
    hidpp::ProbeError, list_devices, probe, HidDeviceSummary, ProbeOptions, ProbeReport,
};

#[derive(Debug, Parser)]
#[command(
    name = "hidpp-probe",
    about = "Read-only inspector for Logitech Unifying, Nano, and Bolt receivers"
)]
struct Args {
    /// Print the report as JSON.
    #[arg(long)]
    json: bool,

    /// Per-request timeout in milliseconds.
    #[arg(long, default_value_t = 800)]
    timeout_ms: i32,

    /// Omit paired devices that are currently offline.
    #[arg(long)]
    online_only: bool,

    /// Force a specific hidraw path, for example /dev/hidraw2.
    #[arg(long)]
    path: Option<String>,

    /// List Logitech HID collections and exit.
    #[arg(long)]
    list: bool,
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();

    let args = Args::parse();

    if args.list {
        match list_devices() {
            Ok(devices) => {
                print_devices(&devices);
                return;
            }
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    let options = ProbeOptions {
        timeout_ms: args.timeout_ms.max(100),
        include_offline: !args.online_only,
        path: args.path,
    };

    match probe(&options) {
        Ok(report) => {
            if args.json {
                match serde_json::to_string_pretty(&report) {
                    Ok(text) => println!("{text}"),
                    Err(error) => {
                        eprintln!("could not encode report: {error}");
                        std::process::exit(1);
                    }
                }
            } else {
                print_report(&report);
            }
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(match error {
                ProbeError::NoReceiver => 2,
                _ => 1,
            });
        }
    }
}

fn print_devices(devices: &[HidDeviceSummary]) {
    if devices.is_empty() {
        println!("No Logitech HID collections found.");
        return;
    }

    for device in devices {
        println!(
            "{}  {:04x}:{:04x}  usage={:04x}:{:04x}  iface={}  {}",
            device.path,
            device.vendor_id,
            device.product_id,
            device.usage_page,
            device.usage,
            device.interface_number,
            device.product.as_deref().unwrap_or("(unknown)")
        );
    }
}

fn print_report(report: &ProbeReport) {
    let receiver = &report.receiver;

    println!("Receiver");
    println!(
        "  product       {}",
        receiver.product.as_deref().unwrap_or("(unknown)")
    );
    if let Some(manufacturer) = &receiver.manufacturer {
        println!("  manufacturer  {manufacturer}");
    }
    println!(
        "  usb           {:04x}:{:04x}",
        receiver.vendor_id, receiver.product_id
    );
    println!("  path          {}", receiver.path);
    println!(
        "  serial        {}",
        receiver.serial.as_deref().unwrap_or("(unknown)")
    );
    println!("  kind          {}", receiver.kind);
    println!(
        "  slots         {} max, {} paired, {} free",
        receiver.max_devices,
        receiver.paired_devices,
        receiver.max_devices.saturating_sub(receiver.paired_devices)
    );
    if let Some(remaining) = receiver.remaining_pairings {
        println!("  remaining     {remaining}");
    }
    if !receiver.firmware.is_empty() {
        println!("  firmware");
        for firmware in &receiver.firmware {
            println!(
                "    {:<10} {} {}",
                firmware.kind, firmware.name, firmware.version
            );
        }
    }

    if report.devices.is_empty() {
        println!("\nNo paired devices found.");
        return;
    }

    println!("\nDevices");
    for device in &report.devices {
        let state = if device.online { "online" } else { "offline" };
        println!(
            "  [{}] {}  {}",
            device.slot,
            state,
            device.kind.as_deref().unwrap_or("unknown")
        );
        if let Some(name) = &device.name {
            println!("      name      {name}");
        }
        if let Some(wpid) = &device.wpid {
            println!("      wpid      {wpid}");
        }
        if let Some(serial) = &device.serial {
            println!("      serial    {serial}");
        }
        if let Some(battery) = &device.battery {
            let percent = battery
                .percent
                .map(|percent| format!("{percent}%"))
                .unwrap_or_else(|| "unknown".to_string());
            let status = battery.status.as_deref().unwrap_or("unknown");
            let voltage = battery
                .voltage_mv
                .map(|millivolts| format!("  {millivolts} mV"))
                .unwrap_or_default();
            println!("      battery   {percent} ({status}){voltage}");
        }
        if let Some(signal) = &device.signal {
            let percent = signal
                .percent
                .map(|percent| format!(" ({percent}%)"))
                .unwrap_or_default();
            println!("      signal    {}{percent}", signal.raw);
        }
        for firmware in &device.firmware {
            println!(
                "      firmware  {:<10} {} {}",
                firmware.kind, firmware.name, firmware.version
            );
        }
    }
}
