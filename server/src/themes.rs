use std::fs;

use serde::{Deserialize, Serialize};

use crate::config::AppConfig;

pub const PROFILES: [&str; 5] = ["xfce", "rice", "plasma", "gnome", "hyprland"];
pub const GTK_THEMES: [&str; 2] = ["catppuccin", "whitesur"];
pub const WALLPAPERS: [&str; 2] = ["catppuccin", "whitesur"];

fn matching_wallpaper(gtk_theme: &str) -> &'static str {
    if gtk_theme == "whitesur" {
        "whitesur"
    } else {
        "catppuccin"
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct CurrentTheme {
    pub profile: String,
    pub flavour: String,
    pub accent: String,
    #[serde(rename = "gtkTheme")]
    pub gtk_theme: String,
    #[serde(default)]
    pub wallpaper: String,
}

impl CurrentTheme {
    fn defaults() -> Self {
        Self {
            profile: "xfce".to_string(),
            flavour: "mocha".to_string(),
            accent: "blue".to_string(),
            gtk_theme: "catppuccin".to_string(),
            wallpaper: "catppuccin".to_string(),
        }
    }

    fn validated(self) -> Self {
        let defaults = Self::defaults();
        let gtk_theme = if GTK_THEMES.contains(&self.gtk_theme.as_str()) {
            self.gtk_theme
        } else {
            defaults.gtk_theme
        };
        let wallpaper = if WALLPAPERS.contains(&self.wallpaper.as_str()) {
            self.wallpaper
        } else {
            matching_wallpaper(&gtk_theme).to_string()
        };
        Self {
            profile: if PROFILES.contains(&self.profile.as_str()) {
                self.profile
            } else {
                defaults.profile
            },
            flavour: if ["mocha", "macchiato", "frappe", "latte"].contains(&self.flavour.as_str()) {
                self.flavour
            } else {
                defaults.flavour
            },
            accent: if self.accent.is_empty() {
                defaults.accent
            } else {
                self.accent
            },
            gtk_theme,
            wallpaper,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ThemeCard {
    pub id: String,
    pub name: String,
    pub description: String,
    pub details: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot: Option<String>,
    pub accent: String,
    pub current: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ThemeCatalog {
    pub current: CurrentTheme,
    pub profiles: Vec<ThemeCard>,
    #[serde(rename = "gtkThemes")]
    pub gtk_themes: Vec<ThemeCard>,
    pub wallpapers: Vec<ThemeCard>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThemeApplyRequest {
    pub profile: Option<String>,
    #[serde(rename = "gtkTheme")]
    pub gtk_theme: Option<String>,
    pub wallpaper: Option<String>,
}

pub fn read_current(config: &AppConfig) -> CurrentTheme {
    fs::read_to_string(&config.theme_file)
        .ok()
        .and_then(|contents| serde_json::from_str::<CurrentTheme>(&contents).ok())
        .map(CurrentTheme::validated)
        .unwrap_or_else(CurrentTheme::defaults)
}

pub fn catalog(config: &AppConfig) -> ThemeCatalog {
    let current = read_current(config);
    ThemeCatalog {
        profiles: profile_cards(&current),
        gtk_themes: gtk_cards(&current),
        wallpapers: wallpaper_cards(&current),
        current,
    }
}

pub fn apply(config: &AppConfig, request: ThemeApplyRequest) -> Result<CurrentTheme, String> {
    if request.profile.is_none() && request.gtk_theme.is_none() && request.wallpaper.is_none() {
        return Err("select a profile, GTK theme or wallpaper".to_string());
    }

    let mut current = read_current(config);
    if let Some(profile) = request.profile {
        if !PROFILES.contains(&profile.as_str()) {
            return Err(format!("unknown desktop profile '{profile}'"));
        }
        current.profile = profile;
    }
    if let Some(gtk_theme) = request.gtk_theme {
        if !GTK_THEMES.contains(&gtk_theme.as_str()) {
            return Err(format!("unknown GTK theme '{gtk_theme}'"));
        }
        let changed = current.gtk_theme != gtk_theme;
        current.gtk_theme = gtk_theme;
        if changed && request.wallpaper.is_none() {
            current.wallpaper = matching_wallpaper(&current.gtk_theme).to_string();
        }
    }
    if let Some(wallpaper) = request.wallpaper {
        if !WALLPAPERS.contains(&wallpaper.as_str()) {
            return Err(format!("unknown wallpaper '{wallpaper}'"));
        }
        current.wallpaper = wallpaper;
    }

    write_selection(config, &current)?;
    Ok(current)
}

fn write_selection(config: &AppConfig, theme: &CurrentTheme) -> Result<(), String> {
    if !config.nixos_dir.is_dir() {
        return Err(format!(
            "NixOS configuration directory {} does not exist",
            config.nixos_dir.display()
        ));
    }
    let desktop = config.nixos_dir.join("desktop");
    fs::create_dir_all(&desktop)
        .map_err(|error| format!("could not create {}: {error}", desktop.display()))?;
    let path = desktop.join("selected.nix");
    let contents = format!(
        "# Generated by NixOS Control. Changes are overwritten on the next theme selection.\n\
         {{ lib, ... }}:\n\
         {{\n\
           myDesktop.profile = lib.mkForce \"{}\";\n\
           myDesktop.flavour = lib.mkForce \"{}\";\n\
           myDesktop.accent = lib.mkForce \"{}\";\n\
           myDesktop.gtkTheme = lib.mkForce \"{}\";\n\
           myDesktop.wallpaperPreset = lib.mkForce \"{}\";\n\
         }}\n",
        theme.profile, theme.flavour, theme.accent, theme.gtk_theme, theme.wallpaper
    );
    fs::write(&path, contents)
        .map_err(|error| format!("could not write {}: {error}", path.display()))
}

fn profile_cards(current: &CurrentTheme) -> Vec<ThemeCard> {
    vec![
        card(
            "xfce",
            "XFCE",
            "The original lightweight X11 desktop with the Catppuccin or WhiteSur GTK theme.",
            &[
                "Lightweight X11 session",
                "LightDM login",
                "Works over VNC and xrdp",
                "Catppuccin or WhiteSur GTK",
            ],
            None,
            "#5aa9ff",
            current.profile == "xfce",
        ),
        card(
            "rice",
            "Catppuccin rice",
            "i3 with polybar, Rofi and picom blur, rounded corners and shadows.",
            &[
                "i3 tiling window manager",
                "Polybar and Rofi",
                "Picom blur and shadows",
                "Catppuccin Mocha by default",
            ],
            Some("desktop-rice"),
            "#cba6f7",
            current.profile == "rice",
        ),
        card(
            "plasma",
            "KDE Plasma 6",
            "KDE Plasma with the Catppuccin colour scheme, window decoration and SDDM theme.",
            &[
                "KDE Plasma 6",
                "Catppuccin Qt and SDDM themes",
                "Works over the VM's VNC display",
                "Full desktop settings UI",
            ],
            Some("desktop-plasma"),
            "#1e66f5",
            current.profile == "plasma",
        ),
        card(
            "gnome",
            "GNOME + WhiteSur",
            "GNOME Shell with the WhiteSur shell theme, dash-to-dock and blur-my-shell for a macOS-style top bar.",
            &[
                "GNOME Shell",
                "WhiteSur shell theme",
                "Dash to Dock",
                "Blur my Shell",
            ],
            None,
            "#a78bfa",
            current.profile == "gnome",
        ),
        card(
            "hyprland",
            "Hyprland",
            "Wayland tiling compositor for real hardware with a loopback-only VNC helper.",
            &[
                "Wayland tiling compositor",
                "wayvnc on 127.0.0.1",
                "Needs a real DRM device",
                "Not supported in the OrbStack VM",
            ],
            None,
            "#89b4fa",
            current.profile == "hyprland",
        ),
    ]
}

fn gtk_cards(current: &CurrentTheme) -> Vec<ThemeCard> {
    vec![
        card(
            "catppuccin",
            "Catppuccin",
            "Soft pastel GTK, icon and cursor themes that follow the selected flavour and accent.",
            &[
                "Mocha, Macchiato, Frappe and Latte",
                "14 accent colours",
                "Matching Papirus icons",
                "Matching cursors",
            ],
            None,
            "#cba6f7",
            current.gtk_theme == "catppuccin",
        ),
        card(
            "whitesur",
            "WhiteSur",
            "macOS-inspired GTK, icon and cursor theme with light and dark variants.",
            &[
                "Light and dark variants",
                "Blue, purple, pink and more accents",
                "WhiteSur icons and cursors",
                "Optional Plank dock",
            ],
            None,
            "#a8c7fa",
            current.gtk_theme == "whitesur",
        ),
    ]
}

fn wallpaper_cards(current: &CurrentTheme) -> Vec<ThemeCard> {
    vec![
        card(
            "catppuccin",
            "Catppuccin aurora",
            "The Catppuccin gradient with a subtle snowflake, shared by the rice, Plasma and SDDM login screen.",
            &[
                "Dark Catppuccin palette",
                "2560 x 1600 gradient",
                "Used by the rice and Plasma profiles",
                "Also used by the SDDM login theme",
            ],
            Some("wallpaper-catppuccin"),
            "#89b4fa",
            current.wallpaper == "catppuccin",
        ),
        card(
            "whitesur",
            "WhiteSur (macOS)",
            "The deep macOS-style wallpaper that matches the WhiteSur GTK theme and dock.",
            &[
                "macOS-style dark gradient",
                "Matches the WhiteSur GTK theme",
                "Applied to XFCE and GNOME sessions",
                "Used by the login screen",
            ],
            Some("wallpaper-whitesur"),
            "#a8c7fa",
            current.wallpaper == "whitesur",
        ),
    ]
}

#[allow(clippy::too_many_arguments)]
fn card(
    id: &str,
    name: &str,
    description: &str,
    details: &[&str],
    screenshot: Option<&str>,
    accent: &str,
    current: bool,
) -> ThemeCard {
    ThemeCard {
        id: id.to_string(),
        name: name.to_string(),
        description: description.to_string(),
        details: details.iter().map(|value| value.to_string()).collect(),
        screenshot: screenshot.map(str::to_string),
        accent: accent.to_string(),
        current,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn config(directory: &std::path::Path) -> AppConfig {
        let mut config = AppConfig::new(directory.join("token"), None, true, true);
        config.nixos_dir = directory.join("nixos");
        config.theme_file = directory.join("theme.json");
        config
    }

    #[test]
    fn defaults_and_catalog() {
        let directory = tempfile::tempdir().unwrap();
        let config = config(directory.path());
        let catalog = catalog(&config);
        assert_eq!(catalog.current.profile, "xfce");
        assert_eq!(catalog.current.wallpaper, "catppuccin");
        assert_eq!(catalog.profiles.len(), 5);
        assert_eq!(catalog.gtk_themes.len(), 2);
        assert_eq!(catalog.wallpapers.len(), 2);
        assert!(catalog.profiles.iter().any(|theme| theme.current));
        assert!(catalog.wallpapers.iter().any(|theme| theme.current));
        assert_eq!(
            catalog
                .profiles
                .iter()
                .find(|theme| theme.id == "plasma")
                .unwrap()
                .screenshot
                .as_deref(),
            Some("desktop-plasma")
        );
    }

    #[test]
    fn applies_a_profile_and_writes_the_selection() {
        let directory = tempfile::tempdir().unwrap();
        let config = config(directory.path());
        fs::create_dir_all(&config.nixos_dir).unwrap();

        let current = apply(
            &config,
            ThemeApplyRequest {
                profile: Some("plasma".to_string()),
                gtk_theme: Some("whitesur".to_string()),
                wallpaper: None,
            },
        )
        .unwrap();
        assert_eq!(current.profile, "plasma");
        assert_eq!(current.gtk_theme, "whitesur");
        assert_eq!(current.wallpaper, "whitesur");

        let selected = fs::read_to_string(config.nixos_dir.join("desktop/selected.nix")).unwrap();
        assert!(selected.contains("myDesktop.profile = lib.mkForce \"plasma\";"));
        assert!(selected.contains("myDesktop.gtkTheme = lib.mkForce \"whitesur\";"));
        assert!(selected.contains("myDesktop.wallpaperPreset = lib.mkForce \"whitesur\";"));
    }

    #[test]
    fn explicit_wallpaper_overrides_the_gtk_default() {
        let directory = tempfile::tempdir().unwrap();
        let config = config(directory.path());
        fs::create_dir_all(&config.nixos_dir).unwrap();

        let current = apply(
            &config,
            ThemeApplyRequest {
                profile: None,
                gtk_theme: Some("whitesur".to_string()),
                wallpaper: Some("catppuccin".to_string()),
            },
        )
        .unwrap();
        assert_eq!(current.gtk_theme, "whitesur");
        assert_eq!(current.wallpaper, "catppuccin");

        let current = apply(
            &config,
            ThemeApplyRequest {
                profile: None,
                gtk_theme: None,
                wallpaper: Some("whitesur".to_string()),
            },
        )
        .unwrap();
        assert_eq!(current.wallpaper, "whitesur");
    }

    #[test]
    fn derives_wallpaper_for_older_theme_files() {
        let directory = tempfile::tempdir().unwrap();
        let config = config(directory.path());
        fs::create_dir_all(directory.path()).unwrap();
        fs::write(
            &config.theme_file,
            r#"{"profile":"xfce","flavour":"mocha","accent":"blue","gtkTheme":"whitesur"}"#,
        )
        .unwrap();
        let current = read_current(&config);
        assert_eq!(current.gtk_theme, "whitesur");
        assert_eq!(current.wallpaper, "whitesur");
    }

    #[test]
    fn rejects_unknown_values() {
        let directory = tempfile::tempdir().unwrap();
        let config = config(directory.path());
        fs::create_dir_all(&config.nixos_dir).unwrap();
        let error = apply(
            &config,
            ThemeApplyRequest {
                profile: Some("windows".to_string()),
                gtk_theme: None,
                wallpaper: None,
            },
        )
        .unwrap_err();
        assert!(error.contains("unknown desktop profile"));
        assert_eq!(
            PathBuf::from(&config.theme_file),
            directory.path().join("theme.json")
        );
    }
}
