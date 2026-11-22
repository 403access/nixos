import path from 'node:path';
import {
  assertEnum,
  assertRegex,
  clampInt,
  isObject,
  nixString,
  safeName,
} from './util.js';

export const NIXOS_DESKTOPS = ['none', 'xfce', 'rice', 'plasma', 'hyprland', 'gnome'];
export const WINDOWS_PROFILES = ['safe', 'lean', 'micro'];
export const WINDOWS_COMPONENTS = [
  'store',
  'edge',
  'ai',
  'onedrive',
  'printer',
  'xbox',
  'search',
  'telemetry',
];
export const WINDOWS_RECIPES = [
  'disable-ai',
  'disable-gaming',
  'disable-search',
  'disable-telemetry',
  'minimal',
  'printer-off',
  'remove-edge',
  'remove-store',
  'trim-memory',
  'trim-stock',
];

const HOSTNAME = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
const LINUX_USER = /^[a-z_][a-z0-9_-]{0,31}$/;
const PACKAGE = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/;
const LOCALE = /^[a-z]{2,3}_[A-Z]{2}\.UTF-8$/;
const TIMEZONE = /^[A-Za-z0-9_+-]+(?:\/[A-Za-z0-9_+-]+)*$/;
const WIN_LOCALE = /^[a-z]{2}-[A-Z]{2}$/;
const WIN_USER = /^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$/;
const WIN_COMPUTER = /^[A-Za-z0-9][A-Za-z0-9-]{0,14}$/;
const THEME_ID = /^[a-z0-9][a-z0-9-]{0,63}$/;
const ABSOLUTE_POSIX = /^\/[^\0]*$/;

function strings(value, label, { max = 100, pattern } = {}) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new Error(`${label} must be an array`);
  if (value.length > max) throw new Error(`${label} has more than ${max} entries`);
  return value.map((item) => {
    const text = String(item).trim();
    if (pattern && !pattern.test(text)) throw new Error(`${label} contains an invalid entry: ${text}`);
    return text;
  });
}

export function defaultNixosProfile() {
  return {
    kind: 'nixos',
    name: 'nixos-minimal',
    hostName: 'nixos-image',
    user: 'nixos',
    desktop: 'none',
    locale: 'en_US.UTF-8',
    timezone: 'UTC',
    ssh: true,
    libvirt: false,
    bluetooth: false,
    ksm: true,
    passwordlessSudo: false,
    initialPassword: 'nixos',
    packages: ['git', 'curl', 'vim'],
    imageName: 'nixos-image.iso',
    stateVersion: '25.05',
    extraConfig: '',
  };
}

export function defaultWindowsProfile() {
  return {
    kind: 'windows',
    name: 'windows-lean',
    profile: 'lean',
    sourceIso: '',
    locale: 'en-US',
    userName: 'Windows-PC',
    computerName: 'WINDOWS-VM',
    autologon: true,
    removeWinRE: false,
    solid: false,
    themes: [],
    themeDefault: '',
    removeComponents: ['onedrive', 'telemetry', 'xbox'],
    postInstall: [],
    memoryGiB: 4,
    vcpus: 2,
    outputName: 'Win11-lean.iso',
  };
}

export function validateNixosProfile(input = {}) {
  if (!isObject(input)) throw new Error('profile must be an object');
  const base = defaultNixosProfile();
  const desktop = assertEnum(String(input.desktop ?? base.desktop), NIXOS_DESKTOPS, 'desktop');
  const hostName = assertRegex(String(input.hostName ?? base.hostName), HOSTNAME, 'hostName');
  const user = assertRegex(String(input.user ?? base.user), LINUX_USER, 'user');
  const locale = assertRegex(String(input.locale ?? base.locale), LOCALE, 'locale');
  const timezone = assertRegex(String(input.timezone ?? base.timezone), TIMEZONE, 'timezone');
  const stateVersion = assertRegex(String(input.stateVersion ?? base.stateVersion), /^\d{2}\.\d{2}$/, 'stateVersion');
  const imageName = safeName(String(input.imageName ?? base.imageName), 'imageName');
  const initialPassword = String(input.initialPassword ?? base.initialPassword);
  if (initialPassword.length < 4 || initialPassword.length > 128) {
    throw new Error('initialPassword must be 4-128 characters');
  }
  const packages = strings(input.packages ?? base.packages, 'packages', { pattern: PACKAGE });
  const extraConfig = String(input.extraConfig ?? '');
  if (extraConfig.length > 20_000) throw new Error('extraConfig is too large');

  return {
    kind: 'nixos',
    name: safeName(String(input.name ?? base.name), 'name'),
    hostName,
    user,
    desktop,
    locale,
    timezone,
    ssh: Boolean(input.ssh ?? base.ssh),
    libvirt: Boolean(input.libvirt ?? base.libvirt),
    bluetooth: Boolean(input.bluetooth ?? base.bluetooth),
    ksm: Boolean(input.ksm ?? base.ksm),
    passwordlessSudo: Boolean(input.passwordlessSudo ?? base.passwordlessSudo),
    initialPassword,
    packages,
    imageName,
    stateVersion,
    extraConfig,
  };
}

export function validateWindowsProfile(input = {}) {
  if (!isObject(input)) throw new Error('profile must be an object');
  const base = defaultWindowsProfile();
  const profile = assertEnum(String(input.profile ?? base.profile), WINDOWS_PROFILES, 'profile');
  const locale = assertRegex(String(input.locale ?? base.locale), WIN_LOCALE, 'locale');
  const userName = assertRegex(String(input.userName ?? base.userName), WIN_USER, 'userName');
  const computerName = assertRegex(String(input.computerName ?? base.computerName), WIN_COMPUTER, 'computerName');
  const sourceIso = String(input.sourceIso ?? '');
  if (sourceIso && !ABSOLUTE_POSIX.test(sourceIso)) {
    throw new Error('sourceIso must be an absolute path on the build host');
  }
  const themes = strings(input.themes ?? base.themes, 'themes', { pattern: THEME_ID });
  const removeComponents = strings(input.removeComponents ?? base.removeComponents, 'removeComponents', {
    pattern: new RegExp(`^(${WINDOWS_COMPONENTS.join('|')})$`),
  });
  const postInstall = strings(input.postInstall ?? base.postInstall, 'postInstall', {
    pattern: new RegExp(`^(${WINDOWS_RECIPES.join('|')})$`),
  });
  const outputName = safeName(String(input.outputName ?? base.outputName), 'outputName');
  if (!outputName.toLowerCase().endsWith('.iso')) throw new Error('outputName must end in .iso');
  const themeDefault = String(input.themeDefault ?? '').trim();
  if (themeDefault && themeDefault.length > 128) throw new Error('themeDefault is too long');

  return {
    kind: 'windows',
    name: safeName(String(input.name ?? base.name), 'name'),
    profile,
    sourceIso,
    locale,
    userName,
    computerName,
    autologon: Boolean(input.autologon ?? base.autologon),
    removeWinRE: Boolean(input.removeWinRE ?? base.removeWinRE),
    solid: Boolean(input.solid ?? base.solid),
    themes,
    themeDefault,
    removeComponents,
    postInstall,
    memoryGiB: clampInt(input.memoryGiB ?? base.memoryGiB, 4, 64, base.memoryGiB),
    vcpus: clampInt(input.vcpus ?? base.vcpus, 2, 32, base.vcpus),
    outputName,
  };
}

export function validateProfile(kind, input) {
  if (kind === 'nixos') return validateNixosProfile(input);
  if (kind === 'windows') return validateWindowsProfile(input);
  throw new Error('kind must be "nixos" or "windows"');
}

export function profilePresets() {
  return {
    nixos: [
      {
        id: 'nixos-minimal',
        label: 'NixOS minimal',
        description: 'Headless SSH image, KSM enabled, no desktop.',
        profile: validateNixosProfile({ name: 'nixos-minimal' }),
      },
      {
        id: 'nixos-desktop',
        label: 'NixOS GNOME desktop',
        description: 'GNOME profile with SSH, libvirt and Bluetooth.',
        profile: validateNixosProfile({
          name: 'nixos-desktop',
          hostName: 'nixos-desktop',
          desktop: 'gnome',
          libvirt: true,
          bluetooth: true,
          packages: ['git', 'curl', 'vim', 'firefox'],
          imageName: 'nixos-desktop.iso',
        }),
      },
    ],
    windows: [
      {
        id: 'windows-lean',
        label: 'Windows 11 lean',
        description: 'Unattended lean image, auto-logon, no OneDrive/Xbox telemetry bloat.',
        profile: validateWindowsProfile({ name: 'windows-lean' }),
      },
      {
        id: 'windows-micro',
        label: 'Windows 11 micro',
        description: 'Aggressively stripped lab image. Test in a VM first.',
        profile: validateWindowsProfile({
          name: 'windows-micro',
          profile: 'micro',
          autologon: true,
          removeWinRE: true,
          solid: true,
          removeComponents: [...WINDOWS_COMPONENTS],
          postInstall: ['disable-ai', 'trim-memory', 'printer-off'],
          outputName: 'Win11-micro.iso',
        }),
      },
      {
        id: 'windows-lab',
        label: 'Windows 11 lab VM',
        description: 'Safe profile with 8 GiB / 4 vCPU defaults and auto-logon.',
        profile: validateWindowsProfile({
          name: 'windows-lab',
          profile: 'safe',
          autologon: true,
          memoryGiB: 8,
          vcpus: 4,
          outputName: 'Win11-lab.iso',
        }),
      },
    ],
  };
}

function ksmUnit(profile) {
  if (!profile.ksm) return '';
  return `
  systemd.services.ksm-zero-pages = {
    description = "Enable KSM with zero-page merging";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathExists = "/sys/kernel/mm/ksm/run";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      echo 1 > /sys/kernel/mm/ksm/run
      echo 1 > /sys/kernel/mm/ksm/use_zero_pages
      echo 500 > /sys/kernel/mm/ksm/pages_to_scan
      echo 50 > /sys/kernel/mm/ksm/sleep_millisecs
    '';
  };
`;
}

/**
 * Render a standalone NixOS configuration suitable for:
 *   nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage \
 *     -I nixos-config=/path/configuration.nix
 */
export function renderNixosConfiguration(profile, { repoRoot = '/etc/nixos' } = {}) {
  const p = validateNixosProfile(profile);
  const groups = ['"wheel"'];
  if (p.libvirt) groups.push('"libvirtd"');
  if (p.bluetooth) groups.push('"bluetooth"');
  const imports = p.desktop === 'none'
    ? ''
    : `\n  imports = [ (import ${nixString(path.posix.join(repoRoot, 'desktop/default.nix'))}) ];\n`;
  const desktop = p.desktop === 'none'
    ? ''
    : `
  myDesktop = {
    enable = true;
    profile = ${nixString(p.desktop)};
    user = ${nixString(p.user)};
  };
`;
  const packages = p.packages.length
    ? `\n  environment.systemPackages = with pkgs; [ ${p.packages.join(' ')} ];`
    : '';

  return `# Generated by image-studio. Do not edit by hand.
{ config, pkgs, lib, ... }:
{
  system.stateVersion = ${nixString(p.stateVersion)};
  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = ${nixString(p.hostName)};
  time.timeZone = ${nixString(p.timezone)};
  i18n.defaultLocale = ${nixString(p.locale)};
${imports}
  services.openssh = {
    enable = ${p.ssh ? 'true' : 'false'};
    openFirewall = ${p.ssh ? 'true' : 'false'};
    settings.PasswordAuthentication = true;
  };

  users.users.${nixString(p.user)} = {
    isNormalUser = true;
    initialPassword = ${nixString(p.initialPassword)};
    extraGroups = [ ${groups.join(' ')} ];
  };
  security.sudo.wheelNeedsPassword = ${p.passwordlessSudo ? 'false' : 'true'};

  virtualisation.libvirtd.enable = ${p.libvirt ? 'true' : 'false'};
  hardware.bluetooth = {
    enable = ${p.bluetooth ? 'true' : 'false'};
    powerOnBoot = true;
  };
  services.qemuGuest.enable = true;
${ksmUnit(p)}${packages}${desktop}
  isoImage.isoName = ${nixString(p.imageName)};
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;
  documentation.enable = false;
${p.extraConfig}
}
`;
}

/** Build the argv for windows/build-win11.sh (or the Docker wrapper). */
export function renderWindowsBuildArgs(profile, {
  repoRoot = '/etc/nixos',
  sourceIso,
  outputPath,
  workDir,
  docker = true,
  force = true,
} = {}) {
  const p = validateWindowsProfile(profile);
  const iso = sourceIso || p.sourceIso;
  if (!iso) throw new Error('sourceIso is required');
  const script = docker
    ? path.posix.join(repoRoot, 'windows/build-win11-docker.sh')
    : path.posix.join(repoRoot, 'windows/build-win11.sh');
  const args = [
    script,
    '--iso', iso,
    '--profile', p.profile,
    '--locale', p.locale,
    '--user', p.userName,
    '--computer-name', p.computerName,
    '--out', outputPath,
    '--workdir', workDir,
  ];
  if (p.autologon) args.push('--autologon');
  if (p.removeWinRE) args.push('--remove-winre');
  if (p.solid) args.push('--solid');
  if (p.profile === 'micro') args.push('--experimental');
  for (const theme of p.themes) args.push('--theme', theme);
  if (p.themeDefault) args.push('--theme-default', p.themeDefault);
  if (force) args.push('--force');
  return args;
}

/** Human-readable command preview for the UI. */
export function previewWindowsBuild(profile, options) {
  return renderWindowsBuildArgs(profile, options).join(' ');
}

/** Minimal post-install recipe list for a bundle manifest. */
export function postInstallRecipes(profile) {
  const p = validateWindowsProfile(profile);
  const recipes = new Set(p.postInstall);
  const mapping = {
    ai: 'disable-ai',
    search: 'disable-search',
    printer: 'printer-off',
    telemetry: 'disable-telemetry',
    store: 'remove-store',
    edge: 'remove-edge',
  };
  for (const component of p.removeComponents) {
    if (mapping[component]) recipes.add(mapping[component]);
  }
  if (p.removeComponents.some((item) => ['onedrive', 'xbox'].includes(item))) recipes.add('trim-stock');
  if (p.profile === 'micro') recipes.add('trim-memory');
  return [...recipes];
}