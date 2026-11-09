import React from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import useBaseUrl from '@docusaurus/useBaseUrl';
import styles from './index.module.css';

const repoUrl = 'https://github.com/403access/nixos';

type IconName =
  | 'gauge'
  | 'terminal'
  | 'database'
  | 'refresh'
  | 'shield'
  | 'code'
  | 'phone'
  | 'lock'
  | 'server'
  | 'host';

function Icon({name}: {name: IconName}) {
  const paths: Record<IconName, React.ReactNode> = {
    gauge: (
      <>
        <path d="M4 15a8 8 0 1 1 16 0" />
        <path d="M12 15l3.6-3.6" />
        <circle cx="12" cy="15" r="1.2" />
      </>
    ),
    terminal: (
      <>
        <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
        <path d="M7.5 9l3 3-3 3" />
        <path d="M13 15h3.5" />
      </>
    ),
    database: (
      <>
        <ellipse cx="12" cy="5.5" rx="7" ry="2.8" />
        <path d="M5 5.5v6.5c0 1.6 3.1 2.8 7 2.8s7-1.2 7-2.8V5.5" />
        <path d="M5 12v6c0 1.6 3.1 2.8 7 2.8s7-1.2 7-2.8v-6" />
      </>
    ),
    refresh: (
      <>
        <path d="M20.5 12a8.5 8.5 0 1 1-2.5-6" />
        <path d="M20.5 3.5V9H15" />
      </>
    ),
    shield: (
      <>
        <path d="M12 3l7 2.8v6c0 4.4-3 7.4-7 9-4-1.6-7-4.6-7-9v-6z" />
        <path d="M9.2 12l1.9 1.9 3.7-3.9" />
      </>
    ),
    code: (
      <>
        <path d="M8 7l-5 5 5 5" />
        <path d="M16 7l5 5-5 5" />
        <path d="M13.5 4l-3 16" />
      </>
    ),
    phone: (
      <>
        <rect x="7" y="2.5" width="10" height="19" rx="2.5" />
        <path d="M10.5 18.5h3" />
      </>
    ),
    lock: (
      <>
        <rect x="5" y="10" width="14" height="10" rx="2" />
        <path d="M8.5 10V7.5a3.5 3.5 0 0 1 7 0V10" />
      </>
    ),
    server: (
      <>
        <rect x="3.5" y="4" width="17" height="6.5" rx="1.5" />
        <rect x="3.5" y="13.5" width="17" height="6.5" rx="1.5" />
        <path d="M7 7.2h.01M7 16.7h.01" />
      </>
    ),
    host: (
      <>
        <rect x="3.5" y="3.5" width="17" height="13" rx="2" />
        <path d="M8 20.5h8M12 16.5v4" />
      </>
    ),
  };

  return (
    <svg
      className={styles.icon}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true">
      {paths[name]}
    </svg>
  );
}

const features: {icon: IconName; title: string; body: string}[] = [
  {
    icon: 'gauge',
    title: 'A dashboard that tells the truth',
    body: 'Hostname, NixOS and kernel versions, uptime, CPU, memory, load, root disk, ZFS pool health, temperatures, IP addresses and Tailscale state — refreshed on demand.',
  },
  {
    icon: 'terminal',
    title: 'systemd, under control',
    body: 'Search and filter every unit. Start, stop, restart, reload, enable or disable services at boot, and read the journal without opening a terminal.',
  },
  {
    icon: 'database',
    title: 'ZFS at a glance',
    body: 'Pool usage and health, full zpool status output, datasets and filesystem usage. Know that tank is ONLINE before you need to care.',
  },
  {
    icon: 'refresh',
    title: 'Rebuild from the couch',
    body: 'Browse NixOS generations and run nixos-rebuild switch, boot, test, dry-activate or dry-build. Watch live job output and cancel a build that should not ship.',
  },
  {
    icon: 'shield',
    title: 'Secure by default',
    body: 'The server requires a 256-bit bearer token on every request. Tailscale Serve adds automatic HTTPS, or use the WireGuard VPN already running on your FRITZ!Box.',
  },
  {
    icon: 'code',
    title: 'Small enough to audit',
    body: 'A small Rust server, a SwiftUI app, and a single NixOS module. No cloud, no account, no telemetry. Read the whole thing over a coffee.',
  },
];

const screens: {file: string; label: string; caption: string}[] = [
  {file: 'dashboard', label: 'Dashboard', caption: 'System at a glance'},
  {file: 'services', label: 'Services', caption: 'systemd units & logs'},
  {file: 'storage', label: 'Storage', caption: 'ZFS pools & datasets'},
  {file: 'system', label: 'System', caption: 'Generations & rebuilds'},
  {file: 'settings', label: 'Settings', caption: 'Connection & token'},
];

const steps = [
  {
    number: '01',
    title: 'Enable the module',
    body: 'Import nixos-control.nix and turn on services.nixos-control. The Rust server is built by Nix — nothing to install by hand.',
    link: {label: 'Server quickstart', to: '/docs/getting-started/quickstart'},
  },
  {
    number: '02',
    title: 'Pick your VPN',
    body: 'Tailscale Serve terminates TLS on your tailnet and forwards to localhost. Already use FRITZ!Box WireGuard? Point the app at the LAN address instead.',
    link: {label: 'Connection guides', to: '/docs/guides/configuration'},
  },
  {
    number: '03',
    title: 'Pair the iPhone app',
    body: 'Build the SwiftUI app with XcodeGen, enter your MagicDNS URL and the token from nixos-control-token, and connect from anywhere.',
    link: {label: 'Build the iOS app', to: '/docs/getting-started/ios-app'},
  },
];

function Phone({
  file,
  label,
  className,
}: {
  file: string;
  label: string;
  className?: string;
}) {
  return (
    <div className={clsx(styles.phone, className)}>
      <div className={styles.phoneScreen}>
        <img
          src={useBaseUrl(`/img/screenshots/${file}.png`)}
          alt={`${label} screen of the NixOS Control iPhone app`}
          loading="lazy"
        />
      </div>
    </div>
  );
}

function HeroVisual() {
  return (
    <div className={styles.heroVisual} aria-hidden="true">
      <div className={styles.glow} />
      <div className={clsx(styles.floatCard, styles.floatCardTop)}>
        <div className={styles.floatTitle}>
          <span className={styles.statusDot} />
          All systems operational
        </div>
        <div className={styles.floatRows}>
          <span>tank</span>
          <span className={styles.ok}>ONLINE</span>
        </div>
        <div className={styles.floatRows}>
          <span>load</span>
          <span>0.42 · 0.38 · 0.31</span>
        </div>
      </div>
      <Phone file="dashboard" label="Dashboard" className={styles.heroPhone} />
      <div className={clsx(styles.floatCard, styles.floatCardBottom)}>
        <div className={styles.floatTitle}>
          <span className={styles.ok}>✓</span>
          Rebuild complete
        </div>
        <div className={styles.floatRows}>
          <span>nixos-rebuild switch</span>
          <span>42s</span>
        </div>
      </div>
    </div>
  );
}

function Flow() {
  const nodes: {icon: IconName; title: string; sub: string}[] = [
    {icon: 'phone', title: 'iPhone app', sub: 'SwiftUI · iOS 17+'},
    {icon: 'lock', title: 'Tailscale Serve', sub: 'HTTPS · :443'},
    {icon: 'server', title: 'nixos-control', sub: 'Rust · 127.0.0.1:8787'},
    {icon: 'host', title: 'NixOS host', sub: 'systemd · ZFS · nix'},
  ];

  return (
    <div className={styles.flow}>
      {nodes.map((node, index) => (
        <React.Fragment key={node.title}>
          <div className={styles.flowNode}>
            <div className={styles.flowIcon}>
              <Icon name={node.icon} />
            </div>
            <strong>{node.title}</strong>
            <span>{node.sub}</span>
          </div>
          {index < nodes.length - 1 && (
            <div className={styles.flowArrow}>
              <span className={styles.flowLine} />
              <span className={styles.flowLabel}>
                {index === 0 ? 'tailnet' : index === 1 ? 'localhost' : 'run'}
              </span>
              <span className={styles.flowLine} />
            </div>
          )}
        </React.Fragment>
      ))}
    </div>
  );
}

export default function Home(): React.JSX.Element {
  return (
    <Layout
      title="Your NixOS machine, in your pocket"
      description="An open-source iPhone app and a tiny Rust API server for monitoring and managing a NixOS machine over Tailscale or WireGuard. Dashboards, systemd, ZFS and nixos-rebuild, self-hosted.">
      <main>
        <header className={styles.hero}>
          <div className={styles.heroGlow} />
          <div className={clsx('container', styles.heroInner)}>
            <div className={styles.heroCopy}>
              <span className={styles.eyebrow}>
                <span className={styles.statusDot} />
                Open source · Self-hosted · Tailscale or WireGuard
              </span>
              <h1>
                Your NixOS machine,
                <br />
                <span className={styles.gradientText}>in your pocket.</span>
              </h1>
              <p className={styles.lede}>
                NixOS Control is an iPhone app and a tiny Rust API server for
                monitoring and managing your NixOS host. Dashboards, systemd
                services, ZFS, generations and rebuilds — without opening a
                terminal, without a cloud account.
              </p>
              <div className={styles.actions}>
                <Link
                  className={clsx('button button--lg', styles.primaryButton)}
                  to="/docs/getting-started/quickstart">
                  Get started
                  <span aria-hidden="true"> →</span>
                </Link>
                <Link
                  className={clsx('button button--lg', styles.secondaryButton)}
                  href={repoUrl}>
                  View on GitHub
                </Link>
              </div>
              <p className={styles.heroNote}>
                Free and open source · Rust · No telemetry
              </p>
            </div>
            <HeroVisual />
          </div>
        </header>

        <section className={styles.stats} aria-label="At a glance">
          <div className={clsx('container', styles.statsInner)}>
            {[
              ['5', 'purpose-built screens'],
              ['0', 'server dependencies'],
              ['256-bit', 'bearer token auth'],
              ['100%', 'self-hosted'],
            ].map(([value, label]) => (
              <div className={styles.stat} key={label}>
                <strong>{value}</strong>
                <span>{label}</span>
              </div>
            ))}
          </div>
        </section>

        <section className={styles.section} id="features">
          <div className="container">
            <div className={styles.sectionHead}>
              <span className={styles.kicker}>Everything you reach for</span>
              <h2>Serious control, without the ceremony.</h2>
              <p>
                The operations you actually run on a home server, designed for a
                phone instead of a terminal window.
              </p>
            </div>
            <div className={styles.featureGrid}>
              {features.map((feature) => (
                <article className={styles.featureCard} key={feature.title}>
                  <div className={styles.featureIcon}>
                    <Icon name={feature.icon} />
                  </div>
                  <h3>{feature.title}</h3>
                  <p>{feature.body}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.section} id="screens">
          <div className="container">
            <div className={styles.sectionHead}>
              <span className={styles.kicker}>Designed for the small screen</span>
              <h2>Every screen you need.</h2>
              <p>
                Five focused tabs, native SwiftUI, and fixture data in the
                simulator so you can see exactly what ships.
              </p>
            </div>
            <div className={styles.screensRow}>
              {screens.map((screen) => (
                <figure className={styles.screenItem} key={screen.file}>
                  <Phone file={screen.file} label={screen.label} />
                  <figcaption>
                    <strong>{screen.label}</strong>
                    <span>{screen.caption}</span>
                  </figcaption>
                </figure>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.section} id="architecture">
          <div className="container">
            <div className={styles.split}>
              <div className={styles.splitCopy}>
                <span className={styles.kicker}>How it fits together</span>
                <h2>One token. Your VPN. No cloud.</h2>
                <p>
                  The API server listens only where you tell it to. Tailscale
                  Serve terminates TLS and forwards traffic from your tailnet,
                  or the app can use your FRITZ!Box WireGuard VPN over the home
                  network — so the phone reaches the machine even when it is away
                  from home.
                </p>
                <ul className={styles.checkList}>
                  <li>256-bit random token, compared in constant time</li>
                  <li>Tailscale ACLs decide who can reach port 443</li>
                  <li>WireGuard mode keeps port 8787 behind the firewall</li>
                  <li>Read-only mode available for monitoring only</li>
                  <li>Rebuilds can be disabled independently of power actions</li>
                </ul>
                <Link className={styles.textLink} to="/docs/reference/architecture">
                  Read the architecture notes →
                </Link>
              </div>
              <div className={styles.diagramCard}>
                <Flow />
                <div className={styles.diagramCaption}>
                  <span className={styles.statusDot} />
                  Encrypted end to end over WireGuard
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className={styles.section} id="quickstart">
          <div className="container">
            <div className={styles.sectionHead}>
              <span className={styles.kicker}>Up and running in minutes</span>
              <h2>Three steps to your pocket.</h2>
            </div>
            <div className={styles.quickstart}>
              <ol className={styles.steps}>
                {steps.map((step) => (
                  <li className={styles.step} key={step.number}>
                    <span className={styles.stepNumber}>{step.number}</span>
                    <div>
                      <h3>{step.title}</h3>
                      <p>{step.body}</p>
                      <Link className={styles.textLink} to={step.link.to}>
                        {step.link.label} →
                      </Link>
                    </div>
                  </li>
                ))}
              </ol>
              <div className={styles.terminal}>
                <div className={styles.terminalBar}>
                  <span />
                  <span />
                  <span />
                  <em>configuration.nix</em>
                </div>
                <pre className={styles.terminalBody}>
                  <code>
                    <span className={styles.muted}># import the module &amp; turn it on</span>
                    {'\n'}
                    <span className={styles.kw}>imports</span> = [ ./nixos-control.nix ];
                    {'\n'}
                    <span className={styles.kw}>services.nixos-control.enable</span> = <span className={styles.bool}>true</span>;
                    {'\n\n'}
                    <span className={styles.muted}>$</span> sudo nixos-rebuild switch
                    {'\n'}
                    <span className={styles.ok}>✓</span> nixos-control listening on 127.0.0.1:8787
                    {'\n\n'}
                    <span className={styles.muted}>$</span> sudo nixos-control-token
                    {'\n'}
                    a3f1c9e2d84b7f06a1c5e9d20b7f4c3e
                  </code>
                </pre>
              </div>
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <div className={styles.security}>
              <div className={styles.securityIcon}>
                <Icon name="shield" />
              </div>
              <div>
                <h2>A leaked token is root. Treat it that way.</h2>
                <p>
                  The server runs as root because it talks to systemd, reads the
                  journal, manages ZFS and invokes nixos-rebuild. That power is
                  why the defaults are conservative: loopback-only binding, no
                  public ports, bearer-token auth on every route, and clear
                  switches to disable rebuild and power actions.
                </p>
              </div>
              <Link
                className={clsx('button button--lg', styles.secondaryButton)}
                to="/docs/guides/tailscale">
                Read the security guide
              </Link>
            </div>
          </div>
        </section>

        <section className={styles.cta}>
          <div className={clsx('container', styles.ctaInner)}>
            <h2>Take control of your NixOS box.</h2>
            <p>
              Clone the repository, enable the module, and keep your server in
              your pocket.
            </p>
            <div className={styles.actions}>
              <Link
                className={clsx('button button--lg', styles.primaryButton)}
                to="/docs/getting-started/quickstart">
                Start the quickstart
              </Link>
              <Link
                className={clsx('button button--lg', styles.secondaryButton)}
                href={repoUrl}>
                Star on GitHub
              </Link>
            </div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
