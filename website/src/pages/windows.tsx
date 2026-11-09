import React from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import styles from './windows.module.css';

const repoUrl = 'https://github.com/403access/nixos';
const toolkitUrl = `${repoUrl}/tree/main/windows`;

type Copy = {
  title: string;
  description: string;
  eyebrow: string;
  headline: string;
  headlineAccent: string;
  lede: string;
  primary: string;
  secondary: string;
  note: string;
  stats: [string, string][];
  layersTitle: string;
  layersLede: string;
  layers: {number: string; title: string; body: string}[];
  profilesTitle: string;
  profilesLede: string;
  profiles: {name: string; tag: string; body: string; items: string[]}[];
  keepsTitle: string;
  keeps: string[];
  removesTitle: string;
  removes: string[];
  warningTitle: string;
  warningBody: string;
  ctaTitle: string;
  ctaBody: string;
  ctaButton: string;
  terminalComment: string;
  terminalCommand: string;
  terminalOutput: string;
  docsPath: string;
};

const copy: Record<'en' | 'de', Copy> = {
  en: {
    title: 'Ultra-slim Windows 11 image',
    description:
      'Build a lean, unattended Windows 11 ISO in Docker with wimlib, xorriso and a first-boot debloat script.',
    eyebrow: 'Docker · Windows 11 · Open source',
    headline: 'Windows 11,',
    headlineAccent: 'minus the bloat.',
    lede:
      'A reproducible build toolkit for a lean Windows 11 ISO. Extract, select, inject, debloat, compress, repack — from a Docker container or a Nix shell, without DISM and without a Windows build host.',
    primary: 'Read the guide',
    secondary: 'Toolkit on GitHub',
    note: '3 profiles · generated local password · test in a VM',
    stats: [
      ['3', 'build profiles'],
      ['1', 'command'],
      ['0', 'DISM required'],
      ['100%', 'scriptable'],
    ],
    layersTitle: 'Three layers, one clean build.',
    layersLede:
      'The toolkit keeps install media, unattended setup and first-boot provisioning separate. That is what makes the result reproducible and debuggable.',
    layers: [
      {
        number: '01',
        title: 'Build media',
        body:
          'Extract the official ISO, apply one edition, clean caches, recapture install.wim and rebuild the BIOS and UEFI boot records with xorriso.',
      },
      {
        number: '02',
        title: 'Unattended setup',
        body:
          'A local administrator, no Microsoft account, optional TPM/Secure Boot/RAM checks, and a generated password instead of an empty one.',
      },
      {
        number: '03',
        title: 'First-boot debloat',
        body:
          'Remove provisioned AppX packages through Windows cmdlets, disable telemetry services and tasks, and apply policy values for a quieter desktop.',
      },
    ],
    profilesTitle: 'Pick how far you want to go.',
    profilesLede:
      'The safe profile changes almost nothing. The lean profile removes the consumer layer. Micro is deliberately experimental.',
    profiles: [
      {
        name: 'safe',
        tag: 'Daily driver',
        body: 'Unattended setup, cache cleanup and a recompressed WIM. No app removal.',
        items: ['Everything stays', 'Store · Defender · Update', 'Best compatibility'],
      },
      {
        name: 'lean',
        tag: 'Recommended',
        body: 'Consumer AppX and telemetry are removed; the services you need are kept.',
        items: ['Store · Defender · Update', 'OneDrive stays', 'Shorter first boot'],
      },
      {
        name: 'micro',
        tag: 'Experimental',
        body: 'Store, Xbox, OneDrive, search index, SysMain and optionally WinRE are removed.',
        items: ['Requires --experimental', 'Test in a VM', 'No Store or search'],
      },
    ],
    keepsTitle: 'What stays',
    keeps: [
      'NT kernel, Win32, WinUI and the classic desktop',
      'Explorer, Task Manager, CMD and PowerShell',
      'Network, storage, GPU and input drivers',
      'Win32 apps such as Firefox, 7-Zip and Notepad++',
      'Defender and Windows Update in safe and lean',
    ],
    removesTitle: 'What goes',
    removes: [
      'Xbox, Zune, Your Phone, News, Weather, Solitaire',
      'Clipchamp, Teams consumer, Office Hub, Mail/Calendar',
      'Telemetry services and scheduled tasks',
      'Cortana web search, Copilot and Recall policies',
      'Store, OneDrive and search index in micro',
    ],
    warningTitle: 'Ultra-slim is not a supported Windows configuration.',
    warningBody:
      'Heavy component removal can break Windows Update, drivers, .NET, the Store or recovery. Keep the original ISO and a recovery plan, and test the exact build in a VM before touching hardware.',
    ctaTitle: 'Build once. Boot lean.',
    ctaBody:
      'The complete guide covers the build script, unattended XML, first-boot profiles, QEMU testing, USB writing and the point where you should switch to DISM.',
    ctaButton: 'Open the guide',
    terminalComment: '# extract, inject, debloat, repack',
    terminalCommand:
      './build-win11-docker.sh --iso ~/Downloads/Win11.iso \\\n  --profile lean --locale de-DE',
    terminalOutput:
      'WIN11_SLIM.iso  4.1 GiB\nSHA256  a3f1…9c2e\nlocal password  ••••••••',
    docsPath: '/docs/guides/windows-11-slim-image',
  },
  de: {
    title: 'Ultra-schlankes Windows-11-Image',
    description:
      'Baue in Docker ein schlankes, unbeaufsichtigtes Windows-11-ISO mit wimlib, xorriso und einem Debloat-Skript für den ersten Start.',
    eyebrow: 'Docker · Windows 11 · Open Source',
    headline: 'Windows 11,',
    headlineAccent: 'ohne Ballast.',
    lede:
      'Ein reproduzierbares Toolkit für ein schlankes Windows-11-ISO. Entpacken, Edition wählen, Unattend injizieren, debloaten, komprimieren, neu packen — aus einem Docker-Container oder einer Nix-Shell, ohne DISM und ohne Windows-Build-Rechner.',
    primary: 'Anleitung lesen',
    secondary: 'Toolkit auf GitHub',
    note: '3 Profile · generiertes lokales Passwort · zuerst in der VM testen',
    stats: [
      ['3', 'Build-Profile'],
      ['1', 'Befehl'],
      ['0', 'DISM nötig'],
      ['100%', 'skriptbar'],
    ],
    layersTitle: 'Drei Ebenen, ein sauberer Build.',
    layersLede:
      'Das Toolkit trennt Installationsmedium, unbeaufsichtigtes Setup und First-Boot-Provisioning. Dadurch bleibt das Ergebnis reproduzierbar und debugbar.',
    layers: [
      {
        number: '01',
        title: 'Medium bauen',
        body:
          'Offizielles ISO entpacken, eine Edition anwenden, Caches bereinigen, install.wim neu aufnehmen und BIOS-/UEFI-Boot-Records mit xorriso neu bauen.',
      },
      {
        number: '02',
        title: 'Unbeaufsichtigtes Setup',
        body:
          'Lokaler Administrator, kein Microsoft-Konto, optionale TPM-/Secure-Boot-/RAM-Prüfungen und ein generiertes Passwort statt eines leeren.',
      },
      {
        number: '03',
        title: 'Debloat beim ersten Start',
        body:
          'Provisionierte AppX-Pakete über Windows-Cmdlets entfernen, Telemetrie-Dienste und -Tasks deaktivieren und Policy-Werte für einen ruhigeren Desktop setzen.',
      },
    ],
    profilesTitle: 'Wähle, wie weit du gehen willst.',
    profilesLede:
      'Das Safe-Profil ändert fast nichts. Lean entfernt die Consumer-Ebene. Micro ist bewusst experimentell.',
    profiles: [
      {
        name: 'safe',
        tag: 'Alltag',
        body: 'Unbeaufsichtigtes Setup, Cache-Bereinigung und neu komprimierte WIM. Keine App-Entfernung.',
        items: ['Alles bleibt', 'Store · Defender · Update', 'Beste Kompatibilität'],
      },
      {
        name: 'lean',
        tag: 'Empfohlen',
        body: 'Consumer-AppX und Telemetrie werden entfernt; benötigte Dienste bleiben.',
        items: ['Store · Defender · Update', 'OneDrive bleibt', 'Kürzerer erster Start'],
      },
      {
        name: 'micro',
        tag: 'Experimentell',
        body: 'Store, Xbox, OneDrive, Suchindex, SysMain und optional WinRE werden entfernt.',
        items: ['Braucht --experimental', 'In der VM testen', 'Kein Store, keine Suche'],
      },
    ],
    keepsTitle: 'Was bleibt',
    keeps: [
      'NT-Kernel, Win32, WinUI und klassischer Desktop',
      'Explorer, Task-Manager, CMD und PowerShell',
      'Netzwerk-, Speicher-, GPU- und Eingabetreiber',
      'Win32-Apps wie Firefox, 7-Zip und Notepad++',
      'Defender und Windows Update in safe und lean',
    ],
    removesTitle: 'Was geht',
    removes: [
      'Xbox, Zune, Ihr Smartphone, News, Wetter, Solitaire',
      'Clipchamp, Teams Consumer, Office Hub, Mail/Kalender',
      'Telemetrie-Dienste und geplante Aufgaben',
      'Cortana-Websuche, Copilot- und Recall-Policies',
      'Store, OneDrive und Suchindex in micro',
    ],
    warningTitle: 'Ultra-schlank ist keine unterstützte Windows-Konfiguration.',
    warningBody:
      'Aggressives Entfernen von Komponenten kann Windows Update, Treiber, .NET, den Store oder die Wiederherstellung beschädigen. Behalte das Original-ISO und einen Rettungsplan und teste genau den Build in einer VM, bevor du Hardware anfasst.',
    ctaTitle: 'Einmal bauen. Schlank booten.',
    ctaBody:
      'Die vollständige Anleitung deckt Build-Skript, Unattend-XML, First-Boot-Profile, QEMU-Tests, USB-Schreiben und den Punkt ab, an dem du zu DISM wechseln solltest.',
    ctaButton: 'Zur Anleitung',
    terminalComment: '# entpacken, injizieren, debloaten, neu packen',
    terminalCommand:
      './build-win11-docker.sh --iso ~/Downloads/Win11.iso \\\n  --profile lean --locale de-DE',
    terminalOutput:
      'WIN11_SLIM.iso  4,1 GiB\nSHA256  a3f1…9c2e\nlokales Passwort  ••••••••',
    docsPath: '/docs/guides/windows-11-slim-image',
  },
};

function Terminal({text}: {text: Copy}) {
  return (
    <div className={styles.terminal}>
      <div className={styles.terminalBar}>
        <span />
        <span />
        <span />
        <em>windows/</em>
      </div>
      <pre className={styles.terminalBody}>
        <code>
          <span className={styles.muted}>{text.terminalComment}</span>
          {'\n'}
          <span className={styles.prompt}>$ </span>
          <span className={styles.command}>{text.terminalCommand}</span>
          {'\n\n'}
          <span className={styles.ok}>✓ </span>
          {text.terminalOutput}
        </code>
      </pre>
    </div>
  );
}

export default function WindowsPage(): React.JSX.Element {
  const {i18n} = useDocusaurusContext();
  const lang = i18n.currentLocale === 'de' ? 'de' : 'en';
  const text = copy[lang];

  return (
    <Layout title={text.title} description={text.description}>
      <main>
        <header className={styles.hero}>
          <div className={styles.heroGlow} />
          <div className={clsx('container', styles.heroInner)}>
            <div className={styles.heroCopy}>
              <span className={styles.eyebrow}>
                <span className={styles.statusDot} />
                {text.eyebrow}
              </span>
              <h1>
                {text.headline}
                <br />
                <span className={styles.gradientText}>{text.headlineAccent}</span>
              </h1>
              <p className={styles.lede}>{text.lede}</p>
              <div className={styles.actions}>
                <Link
                  className={clsx('button button--lg', styles.primaryButton)}
                  to={text.docsPath}>
                  {text.primary}
                  <span aria-hidden="true"> →</span>
                </Link>
                <Link
                  className={clsx('button button--lg', styles.secondaryButton)}
                  href={toolkitUrl}>
                  {text.secondary}
                </Link>
              </div>
              <p className={styles.note}>{text.note}</p>
            </div>
            <Terminal text={text} />
          </div>
        </header>

        <section className={styles.stats} aria-label="At a glance">
          <div className={clsx('container', styles.statsInner)}>
            {text.stats.map(([value, label]) => (
              <div className={styles.stat} key={label}>
                <strong>{value}</strong>
                <span>{label}</span>
              </div>
            ))}
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <div className={styles.sectionHead}>
              <h2>{text.layersTitle}</h2>
              <p>{text.layersLede}</p>
            </div>
            <div className={styles.layerGrid}>
              {text.layers.map((layer) => (
                <article className={styles.layerCard} key={layer.number}>
                  <span className={styles.layerNumber}>{layer.number}</span>
                  <h3>{layer.title}</h3>
                  <p>{layer.body}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <div className={styles.sectionHead}>
              <h2>{text.profilesTitle}</h2>
              <p>{text.profilesLede}</p>
            </div>
            <div className={styles.profileGrid}>
              {text.profiles.map((profile) => (
                <article className={styles.profileCard} key={profile.name}>
                  <div className={styles.profileHead}>
                    <strong>{profile.name}</strong>
                    <span>{profile.tag}</span>
                  </div>
                  <p>{profile.body}</p>
                  <ul>
                    {profile.items.map((item) => (
                      <li key={item}>{item}</li>
                    ))}
                  </ul>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className={clsx('container', styles.split)}>
            <div className={styles.listCard}>
              <h2>{text.keepsTitle}</h2>
              <ul className={styles.checkList}>
                {text.keeps.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </div>
            <div className={clsx(styles.listCard, styles.removeCard)}>
              <h2>{text.removesTitle}</h2>
              <ul className={styles.removeList}>
                {text.removes.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <div className={styles.warning}>
              <span className={styles.warningMark}>!</span>
              <div>
                <h2>{text.warningTitle}</h2>
                <p>{text.warningBody}</p>
              </div>
            </div>
          </div>
        </section>

        <section className={styles.cta}>
          <div className={clsx('container', styles.ctaInner)}>
            <h2>{text.ctaTitle}</h2>
            <p>{text.ctaBody}</p>
            <div className={styles.actions}>
              <Link
                className={clsx('button button--lg', styles.primaryButton)}
                to={text.docsPath}>
                {text.ctaButton}
              </Link>
              <Link
                className={clsx('button button--lg', styles.secondaryButton)}
                href={toolkitUrl}>
                {text.secondary}
              </Link>
            </div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
