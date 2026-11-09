#!/usr/bin/env python3
"""Render a safe unattend.xml for the Windows 11 slim-image build."""

from __future__ import annotations

import argparse
import html
from pathlib import Path

INPUT_LOCALES = {
    "de-DE": "0407:00000407",
    "en-GB": "0809:00000809",
    "en-US": "0409:00000409",
    "es-ES": "0c0a:00000c0a",
    "fr-FR": "040c:0000040c",
    "it-IT": "0410:00000410",
    "ja-JP": "0411:00000411",
    "nl-NL": "0413:00000413",
    "pl-PL": "0415:00000415",
    "pt-BR": "0416:00000416",
    "ru-RU": "0419:00000419",
    "tr-TR": "041f:0000041f",
    "zh-CN": "0804:00000804",
}


def xml(value: str) -> str:
    """Escape a value for XML text or an attribute."""
    return html.escape(value, quote=True)


def product_key_block(product_key: str) -> str:
    if not product_key:
        return ""
    return (
        "                <ProductKey>\n"
        f"                    <Key>{xml(product_key)}</Key>\n"
        "                </ProductKey>"
    )


def specialize_block(computer_name: str) -> str:
    if not computer_name:
        return ""
    return (
        '        <component name="Microsoft-Windows-Shell-Setup" '
        'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" '
        'language="neutral" versionScope="nonSxS" '
        'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
        f"            <ComputerName>{xml(computer_name)}</ComputerName>\n"
        "        </component>"
    )


def autologon_block(user_name: str, password: str, enabled: bool) -> str:
    if not enabled:
        return ""
    return (
        "            <AutoLogon>\n"
        "                <Password>\n"
        f"                    <Value>{xml(password)}</Value>\n"
        "                    <PlainText>true</PlainText>\n"
        "                </Password>\n"
        "                <Enabled>true</Enabled>\n"
        f"                <Username>{xml(user_name)}</Username>\n"
        "                <LogonCount>1</LogonCount>\n"
        "            </AutoLogon>"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--input-locale", default=None)
    parser.add_argument("--user", default="Admin")
    parser.add_argument("--password", default="")
    parser.add_argument("--timezone", default="UTC")
    parser.add_argument("--index", default="1")
    parser.add_argument("--product-key", default="")
    parser.add_argument("--computer-name", default="")
    parser.add_argument("--autologon", action="store_true")
    parser.add_argument("--input-locale-fallback", action="store_true")
    args = parser.parse_args()

    input_locale = args.input_locale or INPUT_LOCALES.get(args.locale)
    if not input_locale:
        if not args.input_locale_fallback:
            raise SystemExit(
                f"Unknown locale {args.locale!r}; pass --input-locale or "
                "--input-locale-fallback."
            )
        input_locale = INPUT_LOCALES["en-US"]

    template = args.template.read_text(encoding="utf-8")
    replacements = {
        "@@ARCH@@": "amd64",
        "@@LOCALE@@": xml(args.locale),
        "@@INPUT_LOCALE@@": xml(input_locale),
        "@@PRODUCT_KEY_BLOCK@@": product_key_block(args.product_key),
        "@@INDEX@@": xml(args.index),
        "@@SPECIALIZE_BLOCK@@": specialize_block(args.computer_name),
        "@@TIMEZONE@@": xml(args.timezone),
        "@@USER_NAME@@": xml(args.user),
        "@@USER_PASSWORD@@": xml(args.password),
        "@@AUTOLOGON_BLOCK@@": autologon_block(
            args.user, args.password, args.autologon
        ),
    }
    for placeholder, value in replacements.items():
        template = template.replace(placeholder, value)

    args.output.write_text(template, encoding="utf-8")


if __name__ == "__main__":
    main()
