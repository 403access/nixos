use std::time::Duration;

use crate::commands::CommandRunner;
use crate::models::{DatasetInfo, DiskUsage, FilesystemInfo, PoolInfo, StorageSnapshot};
use crate::util::{parse_f64, parse_i64, split_lines};

pub fn collect_storage(runner: &dyn CommandRunner) -> StorageSnapshot {
    StorageSnapshot {
        pools: collect_pools(runner),
        datasets: collect_datasets(runner),
        filesystems: collect_filesystems(runner),
    }
}

pub fn collect_pools(runner: &dyn CommandRunner) -> Vec<PoolInfo> {
    let result = runner.run(
        "zpool",
        &[
            "list",
            "-Hp",
            "-o",
            "name,size,allocated,free,health,fragmentation",
        ],
        Duration::from_secs(8),
    );
    if result.error.is_some() {
        return Vec::new();
    }
    parse_pools(&result.output)
}

pub fn parse_pools(output: &str) -> Vec<PoolInfo> {
    let mut pools = Vec::new();
    for line in split_lines(output) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 6 {
            continue;
        }
        pools.push(PoolInfo {
            name: fields[0].to_string(),
            size: parse_i64(fields[1]),
            allocated: parse_i64(fields[2]),
            free: parse_i64(fields[3]),
            health: fields[4].to_string(),
            fragmentation: fields[5].to_string(),
        });
    }
    pools
}

pub fn collect_root_disk(runner: &dyn CommandRunner) -> DiskUsage {
    let result = runner.run("df", &["-B1", "-P", "/"], Duration::from_secs(5));
    if result.error.is_some() {
        return DiskUsage {
            mount: "/".to_string(),
            ..DiskUsage::default()
        };
    }
    parse_root_disk(&result.output)
}

pub fn parse_root_disk(output: &str) -> DiskUsage {
    for line in split_lines(output) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 6 || fields[0] == "Filesystem" {
            continue;
        }
        return DiskUsage {
            mount: fields[5].to_string(),
            total: parse_i64(fields[1]),
            used: parse_i64(fields[2]),
            available: parse_i64(fields[3]),
            use_percent: parse_f64(fields[4].trim_end_matches('%')),
        };
    }
    DiskUsage {
        mount: "/".to_string(),
        ..DiskUsage::default()
    }
}

pub fn collect_datasets(runner: &dyn CommandRunner) -> Vec<DatasetInfo> {
    let result = runner.run(
        "zfs",
        &[
            "list",
            "-Hp",
            "-o",
            "name,used,avail,refer,mountpoint",
            "-t",
            "filesystem,volume",
        ],
        Duration::from_secs(10),
    );
    if result.error.is_some() {
        return Vec::new();
    }
    parse_datasets(&result.output)
}

pub fn parse_datasets(output: &str) -> Vec<DatasetInfo> {
    let mut datasets = Vec::new();
    for line in split_lines(output) {
        let mut fields: Vec<&str> = line.splitn(5, '\t').collect();
        if fields.len() != 5 {
            fields = line.split_whitespace().collect();
        }
        if fields.len() != 5 {
            continue;
        }
        datasets.push(DatasetInfo {
            name: fields[0].to_string(),
            used: parse_i64(fields[1]),
            available: parse_i64(fields[2]),
            refer: parse_i64(fields[3]),
            mountpoint: fields[4].to_string(),
        });
    }
    datasets
}

pub fn collect_filesystems(runner: &dyn CommandRunner) -> Vec<FilesystemInfo> {
    let result = runner.run(
        "df",
        &[
            "-B1", "-P", "-T", "-l", "-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs", "-x",
            "squashfs", "-x", "overlay",
        ],
        Duration::from_secs(10),
    );
    if result.error.is_some() && result.output.trim().is_empty() {
        return Vec::new();
    }
    parse_filesystems(&result.output)
}

pub fn parse_filesystems(output: &str) -> Vec<FilesystemInfo> {
    let mut filesystems = Vec::new();
    for line in split_lines(output) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 7 || fields[0] == "Filesystem" {
            continue;
        }
        let size = parse_i64(fields[2]);
        if size <= 0
            || fields[1] == "df"
            || fields[0].starts_with("usage:")
            || fields[0].starts_with("df:")
        {
            continue;
        }
        filesystems.push(FilesystemInfo {
            source: fields[0].to_string(),
            fstype: fields[1].to_string(),
            size,
            used: parse_i64(fields[3]),
            available: parse_i64(fields[4]),
            use_percent: parse_f64(fields[5].trim_end_matches('%')),
            mountpoint: fields[6..].join(" "),
        });
        if filesystems.len() >= 100 {
            break;
        }
    }
    filesystems
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;

    struct FixtureRunner;

    impl CommandRunner for FixtureRunner {
        fn run(&self, program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
            match (program, args.first().copied()) {
                ("zpool", Some("list")) => CommandOutput::success(
                    "tank\t1000000\t400000\t600000\tONLINE\t12\n",
                ),
                ("df", Some("-B1")) if args.contains(&"/") => CommandOutput::success(
                    "Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/sda1 1000000 400000 600000 40% /\n",
                ),
                ("zfs", Some("list")) => CommandOutput::success(
                    "tank\t400000\t600000\t100000\t/tank\ntank/data\t1000\t600000\t1000\t/tank/data\n",
                ),
                ("df", Some("-B1")) => CommandOutput::success(
                    "Filesystem Type 1-blocks Used Available Capacity Mounted on\n/dev/sda1 ext4 1000000 400000 600000 40% /\nproc proc 0 0 0 - /proc\n",
                ),
                _ => CommandOutput::failure("", "unexpected command"),
            }
        }

        fn exists(&self, _program: &str) -> bool {
            true
        }
    }

    #[test]
    fn parses_zpool_list_output() {
        let pools = parse_pools("tank\t100 40 60 ONLINE 12\nbroken pool\n");
        assert_eq!(pools.len(), 1);
        assert_eq!(pools[0].name, "tank");
        assert_eq!(pools[0].size, "100".parse::<i64>().unwrap());
    }

    #[test]
    fn parses_root_disk_usage() {
        let disk = parse_root_disk(
            "Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p2 1000 400 600 40% /\n",
        );
        assert_eq!(disk.mount, "/");
        assert_eq!(disk.total, 1000);
        assert_eq!(disk.used, 400);
        assert_eq!(disk.available, 600);
        assert_eq!(disk.use_percent, 40.0);
    }

    #[test]
    fn parses_tab_and_space_separated_datasets() {
        let datasets =
            parse_datasets("tank\t400\t600\t100\t/tank\ntank/data 10 600 10 /tank/data\nbad\n");
        assert_eq!(datasets.len(), 2);
        assert_eq!(datasets[0].name, "tank");
        assert_eq!(datasets[0].mountpoint, "/tank");
        assert_eq!(datasets[1].name, "tank/data");
    }

    #[test]
    fn parses_filesystems_and_skips_pseudo_filesystems() {
        let filesystems = parse_filesystems(
            "Filesystem Type 1-blocks Used Available Capacity Mounted on\n\
/dev/sda1 ext4 1000 400 600 40% /\n\
proc proc 0 0 0 - /proc\n\
/dev/sdb1 btrfs 2000 1000 1000 50% /mnt/my disk\n",
        );
        assert_eq!(filesystems.len(), 2);
        assert_eq!(filesystems[0].source, "/dev/sda1");
        assert_eq!(filesystems[0].fstype, "ext4");
        assert_eq!(filesystems[0].mountpoint, "/");
        assert_eq!(filesystems[1].mountpoint, "/mnt/my disk");
    }

    #[test]
    fn filesystems_are_capped_at_one_hundred() {
        let mut output =
            String::from("Filesystem Type 1-blocks Used Available Capacity Mounted on\n");
        for index in 0..150 {
            output.push_str(&format!(
                "/dev/sd{index} ext4 1000 400 600 40% /mnt/{index}\n"
            ));
        }
        assert_eq!(parse_filesystems(&output).len(), 100);
    }

    #[test]
    fn collects_the_complete_storage_snapshot() {
        let snapshot = collect_storage(&FixtureRunner);
        assert_eq!(snapshot.pools.len(), 1);
        assert_eq!(snapshot.datasets.len(), 2);
        assert_eq!(snapshot.filesystems.len(), 1);
        assert_eq!(snapshot.filesystems[0].source, "/dev/sda1");
    }

    #[test]
    fn failed_commands_return_empty_collections() {
        struct FailingRunner;
        impl CommandRunner for FailingRunner {
            fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
                CommandOutput::failure("", "boom")
            }
            fn exists(&self, _program: &str) -> bool {
                false
            }
        }

        assert!(collect_pools(&FailingRunner).is_empty());
        assert!(collect_datasets(&FailingRunner).is_empty());
        assert!(collect_filesystems(&FailingRunner).is_empty());
        let disk = collect_root_disk(&FailingRunner);
        assert_eq!(disk.mount, "/");
        assert_eq!(disk.total, 0);
    }
}
