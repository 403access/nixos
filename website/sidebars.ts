import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Getting started',
      collapsed: false,
      items: ['getting-started/quickstart', 'getting-started/ios-app'],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
        'guides/configuration',
        'guides/tailscale',
        'guides/flakes',
        'guides/troubleshooting',
      ],
    },
    {
      type: 'category',
      label: 'Reference',
      items: ['reference/api', 'reference/architecture', 'development'],
    },
  ],
};

export default sidebars;
