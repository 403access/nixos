import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// GitHub Pages project sites are served from /<repo>/. Set SITE_BASE_URL=/ to
// deploy at the domain root (for example when using a custom domain).
const siteUrl = process.env.SITE_URL ?? 'https://403access.github.io';
const baseUrl = process.env.SITE_BASE_URL ?? '/nixos/';
const repoUrl = 'https://github.com/403access/nixos';

const config: Config = {
  title: 'NixOS Control',
  tagline: 'Your NixOS machine, in your pocket.',
  favicon: 'img/favicon.svg',

  url: siteUrl,
  baseUrl,

  organizationName: '403access',
  projectName: 'nixos',

  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'de'],
    localeConfigs: {
      en: {
        label: 'English',
        direction: 'ltr',
        htmlLang: 'en',
      },
      de: {
        label: 'Deutsch',
        direction: 'ltr',
        htmlLang: 'de',
      },
    },
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          routeBasePath: 'docs',
          editUrl: `${repoUrl}/tree/main/website/`,
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/social-card.png',
    metadata: [
      {
        name: 'description',
        content:
          'An open-source iPhone app, a tiny Rust API server, selectable Catppuccin desktop profiles, and a Docker-first toolkit for building a lean Windows 11 ISO.',
      },
      {name: 'keywords', content: 'NixOS, Docker, Tailscale, WireGuard, FRITZ!Box, iOS, SwiftUI, Rust, ZFS, systemd, self-hosted, Catppuccin, KDE Plasma, Hyprland, desktop, Windows 11, slim Windows, wimlib, unattend, ISO, debloat'},
      {name: 'theme-color', content: '#080b14'},
      {property: 'og:type', content: 'website'},
    ],
    colorMode: {
      defaultMode: 'dark',
      disableSwitch: true,
      respectPrefersColorScheme: false,
    },
    navbar: {
      title: 'NixOS Control',
      logo: {
        alt: 'NixOS Control logo',
        src: 'img/logo.svg',
      },
      items: [
        {
          to: '/docs/',
          position: 'left',
          label: 'Documentation',
        },
        {
          to: '/docs/guides/desktop',
          position: 'left',
          label: 'Desktop',
        },
        {
          to: '/windows',
          position: 'left',
          label: 'Windows 11',
        },
        {
          href: `${repoUrl}`,
          position: 'left',
          label: 'GitHub',
        },
        {
          type: 'localeDropdown',
          position: 'right',
        },
        {
          to: '/docs/getting-started/quickstart',
          position: 'right',
          label: 'Get started',
          className: 'navbar-cta',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Documentation',
          items: [
            {label: 'Introduction', to: '/docs/'},
            {label: 'Server quickstart', to: '/docs/getting-started/quickstart'},
            {label: 'iOS app', to: '/docs/getting-started/ios-app'},
            {label: 'Windows 11', to: '/docs/guides/windows-11-slim-image'},
            {label: 'API reference', to: '/docs/reference/api'},
          ],
        },
        {
          title: 'Project',
          items: [
            {label: 'GitHub', href: repoUrl},
            {label: 'Issues', href: `${repoUrl}/issues`},
            {label: 'Releases', href: `${repoUrl}/releases`},
            {label: 'Development', to: '/docs/development'},
          ],
        },
        {
          title: 'Built with',
          items: [
            {label: 'NixOS', href: 'https://nixos.org'},
            {label: 'Tailscale', href: 'https://tailscale.com'},
            {label: 'SwiftUI', href: 'https://developer.apple.com/xcode/swiftui/'},
            {label: 'Go', href: 'https://go.dev'},
          ],
        },
      ],
      copyright: `NixOS Control is open source. Built with Docusaurus. © ${new Date().getFullYear()}`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'go', 'swift', 'nix', 'json', 'yaml'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
