import test from 'node:test';
import assert from 'node:assert/strict';
import {
  defaultNixosProfile,
  defaultWindowsProfile,
  postInstallRecipes,
  renderNixosConfiguration,
  renderWindowsBuildArgs,
  validateNixosProfile,
  validateWindowsProfile,
} from '../src/profiles.js';
import { nixString, safeWindowsRelative } from '../src/util.js';

test('NixOS defaults validate and render', () => {
  const profile = validateNixosProfile(defaultNixosProfile());
  assert.equal(profile.kind, 'nixos');
  assert.equal(profile.hostName, 'nixos-image');
  const text = renderNixosConfiguration(profile, { repoRoot: '/etc/nixos' });
  assert.match(text, /networking\.hostName = "nixos-image"/);
  assert.match(text, /services\.openssh = \{/);
  assert.match(text, /ksm-zero-pages/);
  assert.match(text, /isoImage\.isoName = "nixos-image\.iso"/);
});

test('NixOS desktop profile imports the desktop module', () => {
  const profile = validateNixosProfile({ ...defaultNixosProfile(), desktop: 'gnome' });
  const text = renderNixosConfiguration(profile, { repoRoot: '/etc/nixos' });
  assert.match(text, /import "\/etc\/nixos\/desktop\/default\.nix"/);
  assert.match(text, /profile = "gnome"/);
});

test('NixOS rejects invalid hostnames and desktop names', () => {
  assert.throws(() => validateNixosProfile({ ...defaultNixosProfile(), hostName: '-bad' }), /hostName/);
  assert.throws(() => validateNixosProfile({ ...defaultNixosProfile(), desktop: 'kde' }), /desktop/);
  assert.throws(() => validateNixosProfile({ ...defaultNixosProfile(), imageName: '../x.iso' }), /imageName/);
});

test('Nix strings escape interpolation and quotes', () => {
  assert.equal(nixString('a"b${c}'), '"a\\"b\\${c}"');
});

test('Windows defaults validate and render build arguments', () => {
  const profile = validateWindowsProfile({ ...defaultWindowsProfile(), sourceIso: '/tmp/Win11.iso' });
  assert.equal(profile.kind, 'windows');
  assert.equal(profile.profile, 'lean');
  const args = renderWindowsBuildArgs(profile, {
    repoRoot: '/etc/nixos',
    sourceIso: '/tmp/Win11.iso',
    outputPath: '/tmp/out.iso',
    workDir: '/tmp/work',
    docker: true,
  });
  assert.equal(args[0], '/etc/nixos/windows/build-win11-docker.sh');
  assert.ok(args.includes('--autologon'));
  assert.ok(args.includes('--locale'));
  assert.ok(args.includes('en-US'));
});

test('Windows micro profile adds experimental and themes', () => {
  const profile = validateWindowsProfile({
    ...defaultWindowsProfile(),
    profile: 'micro',
    sourceIso: '/tmp/Win11.iso',
    themes: ['catppuccin-niivu'],
    themeDefault: 'Catppuccin Mocha',
    removeComponents: ['ai', 'search', 'printer', 'telemetry', 'store', 'edge'],
  });
  const args = renderWindowsBuildArgs(profile, {
    repoRoot: '/r/windows',
    sourceIso: '/tmp/Win11.iso',
    outputPath: '/tmp/out.iso',
    workDir: '/tmp/work',
    docker: false,
  });
  assert.ok(args.includes('--experimental'));
  assert.ok(args.includes('--theme'));
  assert.ok(args.includes('Catppuccin Mocha'));
  const recipes = postInstallRecipes(profile);
  assert.ok(recipes.includes('disable-ai'));
  assert.ok(recipes.includes('remove-edge'));
  assert.ok(recipes.includes('trim-memory'));
});

test('Windows rejects unsafe paths and names', () => {
  assert.throws(() => validateWindowsProfile({ ...defaultWindowsProfile(), sourceIso: 'relative.iso' }), /absolute/);
  assert.throws(() => validateWindowsProfile({ ...defaultWindowsProfile(), userName: 'bad user' }), /userName/);
  assert.throws(() => validateWindowsProfile({ ...defaultWindowsProfile(), computerName: 'a'.repeat(16) }), /computerName/);
  assert.throws(() => validateWindowsProfile({ ...defaultWindowsProfile(), outputName: '../x.iso' }), /outputName/);
});

test('Windows path safety rejects traversal', () => {
  assert.equal(safeWindowsRelative('Windows/SystemApps/Foo'), 'Windows/SystemApps/Foo');
  assert.throws(() => safeWindowsRelative('../../etc/passwd'), /traversal/);
  assert.throws(() => safeWindowsRelative('/Windows/System32'), /absolute|empty/);
});