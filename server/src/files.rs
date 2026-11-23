use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use axum::http::StatusCode;
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

pub const MAX_DIRECTORY_ENTRIES: usize = 2000;
pub const MAX_SEARCH_RESULTS: usize = 500;
const MAX_SEARCH_VISITS: usize = 20_000;
const MAX_SEARCH_DEPTH: usize = 8;
const SEARCH_TIME_LIMIT: Duration = Duration::from_millis(1500);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub kind: String,
    pub size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,
    pub hidden: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileListing {
    pub root: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub entries: Vec<FileEntry>,
    pub total: usize,
    pub truncated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileSort {
    Name,
    Size,
    Modified,
    Type,
}

impl FileSort {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "name" => Some(Self::Name),
            "size" => Some(Self::Size),
            "modified" => Some(Self::Modified),
            "type" => Some(Self::Type),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileOrder {
    Asc,
    Desc,
}

impl FileOrder {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "asc" => Some(Self::Asc),
            "desc" => Some(Self::Desc),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileFilter {
    All,
    Files,
    Dirs,
}

impl FileFilter {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "all" => Some(Self::All),
            "files" => Some(Self::Files),
            "dirs" => Some(Self::Dirs),
            _ => None,
        }
    }

    fn matches(self, kind: &str) -> bool {
        match self {
            Self::All => true,
            Self::Files => kind == "file",
            Self::Dirs => kind == "dir",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOptions {
    pub query: Option<String>,
    pub sort: FileSort,
    pub order: FileOrder,
    pub filter: FileFilter,
    pub hidden: bool,
}

impl Default for FileOptions {
    fn default() -> Self {
        Self {
            query: None,
            sort: FileSort::Name,
            order: FileOrder::Asc,
            filter: FileFilter::All,
            hidden: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRequest {
    pub root: PathBuf,
    pub path: PathBuf,
    pub options: FileOptions,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileBrowseError {
    NotFound(String),
    Forbidden(String),
    Invalid(String),
    Io(String),
}

impl FileBrowseError {
    pub fn status(&self) -> StatusCode {
        match self {
            Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::Forbidden(_) => StatusCode::FORBIDDEN,
            Self::Invalid(_) => StatusCode::BAD_REQUEST,
            Self::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    pub fn message(&self) -> String {
        match self {
            Self::NotFound(message)
            | Self::Forbidden(message)
            | Self::Invalid(message)
            | Self::Io(message) => message.clone(),
        }
    }
}

/// Abstraction used by the HTTP layer so the files endpoint can be tested
/// without touching the host filesystem.
pub trait FileBrowser: Send + Sync {
    fn browse(&self, request: FileRequest) -> Result<FileListing, FileBrowseError>;
}

#[derive(Debug, Clone, Default)]
pub struct LocalFiles;

impl FileBrowser for LocalFiles {
    fn browse(&self, request: FileRequest) -> Result<FileListing, FileBrowseError> {
        browse(request)
    }
}

pub fn browse(request: FileRequest) -> Result<FileListing, FileBrowseError> {
    let root = canonical_directory(&request.root, "filesystem root")?;
    let path = canonical_directory(&request.path, "directory")?;
    if !path.starts_with(&root) {
        return Err(FileBrowseError::Forbidden(
            "path is outside the selected filesystem".to_string(),
        ));
    }

    let mut entries = Vec::new();
    let mut truncated = false;
    match request
        .options
        .query
        .as_deref()
        .map(str::trim)
        .filter(|query| !query.is_empty())
    {
        Some(query) => {
            search(&path, query, &request.options, &mut entries, &mut truncated);
        }
        None => {
            collect_directory(&path, &request.options, &mut entries, &mut truncated)?;
        }
    }

    sort_entries(&mut entries, request.options.sort, request.options.order);

    let parent = if path == root {
        None
    } else {
        path.parent()
            .filter(|parent| parent.starts_with(&root))
            .map(|parent| parent.to_string_lossy().to_string())
    };

    Ok(FileListing {
        root: root.to_string_lossy().to_string(),
        path: path.to_string_lossy().to_string(),
        parent,
        total: entries.len(),
        entries,
        truncated,
    })
}

fn canonical_directory(path: &Path, label: &str) -> Result<PathBuf, FileBrowseError> {
    if !path.is_absolute() {
        return Err(FileBrowseError::Invalid(format!(
            "{label} must be an absolute path"
        )));
    }
    let canonical = fs::canonicalize(path)
        .map_err(|error| FileBrowseError::NotFound(format!("{}: {error}", path.display())))?;
    if !canonical.is_dir() {
        return Err(FileBrowseError::Invalid(format!(
            "{} is not a directory",
            path.display()
        )));
    }
    Ok(canonical)
}

fn collect_directory(
    path: &Path,
    options: &FileOptions,
    entries: &mut Vec<FileEntry>,
    truncated: &mut bool,
) -> Result<(), FileBrowseError> {
    let read = fs::read_dir(path)
        .map_err(|error| FileBrowseError::Io(format!("{}: {error}", path.display())))?;
    for item in read {
        if entries.len() >= MAX_DIRECTORY_ENTRIES {
            *truncated = true;
            break;
        }
        let Ok(item) = item else {
            continue;
        };
        let Some(entry) = read_entry(&item.path()) else {
            continue;
        };
        if !options.hidden && entry.hidden {
            continue;
        }
        if !options.filter.matches(&entry.kind) {
            continue;
        }
        entries.push(entry);
    }
    Ok(())
}

fn search(
    start: &Path,
    query: &str,
    options: &FileOptions,
    entries: &mut Vec<FileEntry>,
    truncated: &mut bool,
) {
    const SKIP_DIRS: [&str; 3] = ["/proc", "/sys", "/dev"];
    let needle = query.to_lowercase();
    let started = Instant::now();
    let mut visited = 0usize;
    let mut stack = vec![(start.to_path_buf(), 0usize)];

    while let Some((directory, depth)) = stack.pop() {
        if entries.len() >= MAX_SEARCH_RESULTS
            || visited >= MAX_SEARCH_VISITS
            || started.elapsed() > SEARCH_TIME_LIMIT
        {
            *truncated = true;
            break;
        }

        let Ok(read) = fs::read_dir(&directory) else {
            continue;
        };
        for item in read {
            visited += 1;
            if visited >= MAX_SEARCH_VISITS || started.elapsed() > SEARCH_TIME_LIMIT {
                *truncated = true;
                break;
            }
            let Ok(item) = item else {
                continue;
            };
            let path = item.path();
            let Some(entry) = read_entry(&path) else {
                continue;
            };
            if !options.hidden && entry.hidden {
                continue;
            }
            if entry.name.to_lowercase().contains(&needle) && options.filter.matches(&entry.kind) {
                entries.push(entry);
                if entries.len() >= MAX_SEARCH_RESULTS {
                    *truncated = true;
                    break;
                }
            }
            if depth < MAX_SEARCH_DEPTH
                && item.file_type().map(|kind| kind.is_dir()).unwrap_or(false)
            {
                let skip = SKIP_DIRS.iter().any(|ignored| path == Path::new(ignored));
                if !skip {
                    stack.push((path, depth + 1));
                }
            }
        }
    }
}

fn read_entry(path: &Path) -> Option<FileEntry> {
    let name = path.file_name()?.to_string_lossy().to_string();
    let metadata = fs::symlink_metadata(path).ok()?;
    let file_type = metadata.file_type();
    let kind = if file_type.is_symlink() {
        "symlink"
    } else if file_type.is_dir() {
        "dir"
    } else if file_type.is_file() {
        "file"
    } else {
        "other"
    };
    let modified = metadata
        .modified()
        .ok()
        .map(|time| DateTime::<Utc>::from(time).to_rfc3339_opts(SecondsFormat::Secs, true));
    Some(FileEntry {
        name: name.clone(),
        path: path.to_string_lossy().to_string(),
        kind: kind.to_string(),
        size: if file_type.is_dir() {
            0
        } else {
            metadata.len()
        },
        modified,
        hidden: name.starts_with('.'),
    })
}

fn sort_entries(entries: &mut [FileEntry], sort: FileSort, order: FileOrder) {
    entries.sort_by(|left, right| {
        let left_dir = left.kind == "dir";
        let right_dir = right.kind == "dir";
        let by_kind = right_dir.cmp(&left_dir);
        let mut by_key = match sort {
            FileSort::Name => left.name.to_lowercase().cmp(&right.name.to_lowercase()),
            FileSort::Size => left.size.cmp(&right.size),
            FileSort::Modified => left.modified.cmp(&right.modified),
            FileSort::Type => extension(&left.name).cmp(&extension(&right.name)),
        };
        if order == FileOrder::Desc {
            by_key = by_key.reverse();
        }
        by_kind
            .then(by_key)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
    });
}

fn extension(name: &str) -> String {
    Path::new(name)
        .extension()
        .map(|value| value.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn fixture() -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        fs::create_dir(root.join("docs")).unwrap();
        fs::create_dir(root.join("docs/nested")).unwrap();
        fs::write(root.join("alpha.txt"), b"alpha").unwrap();
        fs::write(root.join("beta.log"), b"1".repeat(2048)).unwrap();
        fs::write(root.join("docs/guide.txt"), b"guide").unwrap();
        fs::write(root.join("docs/nested/deep.txt"), b"deep").unwrap();
        fs::write(root.join(".hidden"), b"hidden").unwrap();
        directory
    }

    fn request(root: &Path, path: &Path, options: FileOptions) -> FileRequest {
        FileRequest {
            root: root.to_path_buf(),
            path: path.to_path_buf(),
            options,
        }
    }

    #[test]
    fn lists_directories_first_and_hides_dotfiles() {
        let directory = fixture();
        let root = directory.path();
        let listing = browse(request(root, root, FileOptions::default())).unwrap();
        let canonical = fs::canonicalize(root).unwrap();
        assert_eq!(listing.root, canonical.to_string_lossy());
        assert_eq!(listing.path, canonical.to_string_lossy());
        assert!(listing.parent.is_none());
        assert_eq!(listing.total, 3);
        assert_eq!(listing.entries[0].name, "docs");
        assert_eq!(listing.entries[0].kind, "dir");
        assert!(listing.entries.iter().all(|entry| entry.name != ".hidden"));
    }

    #[test]
    fn sorts_by_size_and_filters_directories() {
        let directory = fixture();
        let root = directory.path();
        let listing = browse(request(
            root,
            root,
            FileOptions {
                sort: FileSort::Size,
                order: FileOrder::Desc,
                filter: FileFilter::Files,
                ..FileOptions::default()
            },
        ))
        .unwrap();
        assert_eq!(listing.entries.len(), 2);
        assert_eq!(listing.entries[0].name, "beta.log");
        assert_eq!(listing.entries[1].name, "alpha.txt");
    }

    #[test]
    fn searches_nested_files_and_respects_the_type_filter() {
        let directory = fixture();
        let root = directory.path();
        let listing = browse(request(
            root,
            root,
            FileOptions {
                query: Some("txt".to_string()),
                filter: FileFilter::Files,
                ..FileOptions::default()
            },
        ))
        .unwrap();
        let names: Vec<&str> = listing
            .entries
            .iter()
            .map(|entry| entry.name.as_str())
            .collect();
        assert_eq!(names, vec!["alpha.txt", "deep.txt", "guide.txt"]);
    }

    #[test]
    fn rejects_paths_outside_the_selected_root() {
        let directory = fixture();
        let root = directory.path().join("docs");
        let error = browse(request(&root, directory.path(), FileOptions::default())).unwrap_err();
        assert!(matches!(error, FileBrowseError::Forbidden(_)));
    }

    #[test]
    fn includes_hidden_files_when_requested() {
        let directory = fixture();
        let root = directory.path();
        let listing = browse(request(
            root,
            root,
            FileOptions {
                hidden: true,
                ..FileOptions::default()
            },
        ))
        .unwrap();
        assert!(listing.entries.iter().any(|entry| entry.name == ".hidden"));
    }

    #[test]
    fn hidden_flag_requires_a_readable_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("locked");
        fs::write(&path, b"x").unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o000);
        fs::set_permissions(&path, permissions).unwrap();
        let entry = read_entry(&path);
        assert!(entry.is_some());
    }
}
