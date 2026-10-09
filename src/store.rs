use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

/// Overrides the note location; without it the note lives at `~/Documents/scratchpad.md`.
pub const NOTE_PATH_ENV: &str = "HYPR_SCRATCH_FILE";

const DEFAULT_FILE_NAME: &str = "scratchpad.md";
const STARTER_CONTENTS: &str = "# Scratchpad\n";

/// Saves are atomic: write a `.tmp` sibling, then rename over the note.
pub struct NoteStore {
    path: PathBuf,
}

impl NoteStore {
    pub fn from_env() -> Self {
        Self {
            path: default_path(),
        }
    }

    #[cfg(test)]
    fn at(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Reads the note, seeding it with starter contents on first run.
    pub fn load(&self) -> io::Result<String> {
        match fs::read_to_string(&self.path) {
            Ok(contents) => Ok(contents),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.save(STARTER_CONTENTS)?;
                Ok(STARTER_CONTENTS.to_owned())
            }
            Err(error) => Err(error),
        }
    }

    pub fn save(&self, contents: &str) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = temporary_path_for(&self.path);
        fs::write(&temporary, contents)?;
        fs::rename(&temporary, &self.path)?;
        Ok(())
    }
}

/// Public so `--print-config` reports the path this build actually uses.
pub fn default_path() -> PathBuf {
    if let Some(raw) = non_empty_env(NOTE_PATH_ENV) {
        return expand_home(raw);
    }
    if let Some(home) = non_empty_env("HOME") {
        return PathBuf::from(home)
            .join("Documents")
            .join(DEFAULT_FILE_NAME);
    }
    if let Some(data_home) = non_empty_env("XDG_DATA_HOME") {
        return PathBuf::from(data_home)
            .join("hypr-scratch")
            .join(DEFAULT_FILE_NAME);
    }
    PathBuf::from(DEFAULT_FILE_NAME)
}

fn non_empty_env(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

/// Expands a leading `~/`, since that is what people write in a path setting.
pub(crate) fn expand_home(raw: String) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/")
        && let Some(home) = non_empty_env("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    PathBuf::from(raw)
}

fn temporary_path_for(path: &Path) -> PathBuf {
    let mut temporary = path.as_os_str().to_os_string();
    temporary.push(".tmp");
    PathBuf::from(temporary)
}

#[cfg(test)]
mod tests {
    use super::NoteStore;
    use super::temporary_path_for;
    use std::fs;
    use std::path::PathBuf;

    fn scratch_dir(label: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "hypr-scratch-store-test-{label}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("test directory should be created");
        directory
    }

    #[test]
    fn save_then_load_round_trips() {
        let directory = scratch_dir("roundtrip");
        let store = NoteStore::at(directory.join("note.md"));

        store.save("hello scratch").expect("save should succeed");

        assert_eq!(store.load().expect("load should succeed"), "hello scratch");
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn load_seeds_a_missing_note() {
        let directory = scratch_dir("seed");
        let path = directory.join("note.md");
        let store = NoteStore::at(&path);

        let contents = store.load().expect("load should seed the note");

        assert!(path.exists(), "seeding should create the note on disk");
        assert_eq!(contents, store.load().expect("second load should succeed"));
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn save_replaces_the_note_without_leaving_a_temporary_file() {
        let directory = scratch_dir("atomic");
        let path = directory.join("note.md");
        let store = NoteStore::at(&path);

        store.save("first").expect("first save should succeed");
        store.save("second").expect("second save should succeed");

        assert_eq!(
            fs::read_to_string(&path).expect("note should read"),
            "second"
        );
        assert!(
            !temporary_path_for(&path).exists(),
            "the temporary file should not survive a successful save"
        );
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn save_creates_missing_parent_directories() {
        let directory = scratch_dir("parents");
        let store = NoteStore::at(directory.join("nested/deeper/note.md"));

        store.save("nested").expect("save should create parents");

        assert_eq!(store.load().expect("load should succeed"), "nested");
        let _ = fs::remove_dir_all(&directory);
    }
}
