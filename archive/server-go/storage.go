package main

import (
	"strings"
	"time"
)

type DatasetInfo struct {
	Name       string `json:"name"`
	Used       int64  `json:"used"`
	Available  int64  `json:"available"`
	Refer      int64  `json:"refer"`
	Mountpoint string `json:"mountpoint"`
}

type FilesystemInfo struct {
	Source     string  `json:"source"`
	FSType     string  `json:"fstype"`
	Size       int64   `json:"size"`
	Used       int64   `json:"used"`
	Available  int64   `json:"available"`
	UsePercent float64 `json:"use_percent"`
	Mountpoint string  `json:"mountpoint"`
}

type StorageSnapshot struct {
	Pools       []PoolInfo       `json:"pools"`
	Datasets    []DatasetInfo    `json:"datasets"`
	Filesystems []FilesystemInfo `json:"filesystems"`
}

func collectStorage() StorageSnapshot {
	pools := collectPools()
	if pools == nil {
		pools = []PoolInfo{}
	}
	datasets := collectDatasets()
	if datasets == nil {
		datasets = []DatasetInfo{}
	}
	filesystems := collectFilesystems()
	if filesystems == nil {
		filesystems = []FilesystemInfo{}
	}

	return StorageSnapshot{
		Pools:       pools,
		Datasets:    datasets,
		Filesystems: filesystems,
	}
}

func collectDatasets() []DatasetInfo {
	datasets := []DatasetInfo{}
	output, err := runCmd(10*time.Second, "zfs", "list", "-Hp", "-o", "name,used,avail,refer,mountpoint", "-t", "filesystem,volume")
	if err != nil {
		return datasets
	}

	for _, line := range splitLines(output) {
		fields := strings.SplitN(line, "\t", 5)
		if len(fields) != 5 {
			fields = strings.Fields(line)
		}
		if len(fields) != 5 {
			continue
		}
		datasets = append(datasets, DatasetInfo{
			Name:       fields[0],
			Used:       parseInt64(fields[1]),
			Available:  parseInt64(fields[2]),
			Refer:      parseInt64(fields[3]),
			Mountpoint: fields[4],
		})
	}
	return datasets
}

func collectFilesystems() []FilesystemInfo {
	filesystems := []FilesystemInfo{}
	output, err := runCmd(10*time.Second, "df", "-B1", "-P", "-T", "-l",
		"-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs", "-x", "squashfs", "-x", "overlay")
	if err != nil && strings.TrimSpace(output) == "" {
		return filesystems
	}

	for _, line := range splitLines(output) {
		fields := strings.Fields(line)
		if len(fields) < 7 || fields[0] == "Filesystem" {
			continue
		}
		size := parseInt64(fields[2])
		if size <= 0 || fields[1] == "df" || strings.HasPrefix(fields[0], "usage:") || strings.HasPrefix(fields[0], "df:") {
			continue
		}
		filesystems = append(filesystems, FilesystemInfo{
			Source:     fields[0],
			FSType:     fields[1],
			Size:       size,
			Used:       parseInt64(fields[3]),
			Available:  parseInt64(fields[4]),
			UsePercent: parseFloat(strings.TrimSuffix(fields[5], "%")),
			Mountpoint: strings.Join(fields[6:], " "),
		})
		if len(filesystems) >= 100 {
			break
		}
	}
	return filesystems
}
