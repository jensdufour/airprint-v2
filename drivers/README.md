# Drivers (optional — Canon UFR II)

The Canon UFR II Linux driver is **not** redistributable, so we don't ship
it in this repo. The installer (`scripts/canon-ufr2-install.sh`) will look
for a tarball **here** and install it automatically.

## How to supply the driver

Pick one of the three options.

### Option 1 — Drop the tarball into this folder (recommended)

1. Visit Canon's support page for the iR 1133 series, e.g.:
   <https://www.canon.de/support/business/products/imagerunner/imagerunner-1133-1133a-1133if.html?type=drivers&os=linux>
2. Download the **UFR II/UFRII LT Printer Driver for Linux** (filename looks
   like `linux-UFRII-drv-vXXX-uken-XX.tar.gz`).
3. Save it as **exactly**:

   ```
   drivers/canon-ufr2.tar.gz
   ```

4. Re-run the installer inside the LXC:

   ```bash
   pct enter <CTID>
   /opt/airprint-v2/scripts/canon-ufr2-install.sh
   /opt/airprint-v2/scripts/add-printer.sh
   ```

### Option 2 — Provide a download URL via env

```bash
CANON_UFR2_URL="https://gdlp01.c-wss.com/.../linux-UFRII-drv-vXXX-uken-XX.tar.gz" \
  /opt/airprint-v2/scripts/canon-ufr2-install.sh
```

The script will download, extract, and install the `.deb` packages it finds
inside.

### Option 3 — Skip the driver

Don't supply anything. The installer will fall back to a generic PostScript
PPD (works only if the printer's PostScript option board is fitted) or to
CUPS' driverless `sample.drv/generic.ppd` (basic printing only — no margin
correction, no duplex options surfaced).

## What the installer extracts and installs

The Canon tarball contains a `Debian/` (or similar) folder with two
packages:

- `cndrvcups-common_<ver>_amd64.deb` — shared filters and PPDs.
- `cndrvcups-ufr2_<ver>_amd64.deb` — UFR II-specific filter chain.

The installer also enables `i386` multiarch and pulls `libc6:i386` /
`libstdc++6:i386` because some older Canon binaries are 32-bit only. After
installation the PPDs end up in `/opt/cel/ppd/` and are symlinked into
`/usr/share/ppd/canon/` so `lpinfo -m` and `add-printer.sh` can find them.
