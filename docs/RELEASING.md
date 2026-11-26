# Releasing SwarfGRBL

A release is a universal **SwarfGRBL.app**, signed with a Developer ID and notarized, in two forms:
**SwarfGRBL.dmg** (what people download) and **SwarfGRBL.zip** (what Sparkle downloads to update an
installed copy), plus **appcast.xml** (what Sparkle checks). GitHub Actions builds all of them for free
(the repository is public) on its macOS 26 runner.

## Before tagging a release

A tag publishes to everyone who downloads or updates, so check the commit you'll tag on your own Macs
and on the machine first. GitHub's tests are a second check, not the gate.

1. **Tests on the design Mac:** `scripts/ci.sh` on the commit you'll tag (it tests `HEAD` in a clean
   worktree, so commit first). It must pass.
2. **Install it on both Macs:** `scripts/build-app.sh` on the design Mac. Update the garage Mac
   from its update banner, or run `build-app.sh` there too.
3. **On the machine.** Do an air run with the bit raised well clear of the stock, and keep a hand near the stop.
   - [ ] Connect over USB. The start-up `$$` check passes, or flags only what you expect.
   - [ ] Home (`$H`), then jog each axis both ways. A jog towards the end of travel stops short of it.
   - [ ] Probe Z on the touch plate. Then a probe that misses gives ALARM 5.
   - [ ] Air-cut `samples/test-square.nc`. Progress and time left move sensibly.
   - [ ] During the run: Hold (top bar), Stop spindle, then Resume. The spindle spins back up before it carries on.
   - [ ] During the run: Pause (Job panel). It stops at the current line, the spindle goes off and Z rises to the top.
         **Resume…** carries on from that line with the safe lead-in.
   - [ ] Stop mid-move. The job remembers the line the cutter was on. If GRBL alarmed, home again.
   - [ ] Resume from a line after a stop. The preamble goes to safe Z first.
   - [ ] Start refuses a job that would go past the travel, for example with Z zero set too high.
   - [ ] Spindle on and off from the UI (`M3 S…` / `M5`), if anything touching it changed.
4. **Two Macs.** Whichever Mac doesn't own the machine:
   - [ ] mirrors the machine state and console, and its Pause works;
   - [ ] receives a file added on the other Mac (library sync);
   - [ ] has a file group copied over before the first file starts.
5. **Anything new in this release:** try it on the machine, and update `README.md` if behaviour changed.
6. **Updates** (from the second release on): after the release is out, one installed copy of the
   previous release shows the update and installs it, keeping its settings and library.

Then tag it (below). The release workflow runs the tests once more before building.

## When GitHub CI fails

- **"The job was not acquired by Runner"**: no free macOS runner (the free pool runs short).
  `.github/workflows/retry.yml` re-runs CI and Release runs like that by itself, up to three times. If
  it still fails, re-run it from the Actions page later.
- **A test failed**: treat it as real. A test that only fails on a slow runner usually waits for a
  state that lasts a moment, or gives the system too little time. Reproduce it with the CPU busy:
  `for i in $(seq 12); do (yes > /dev/null &); done; swift test --package-path swift; pkill yes`.

## Making a release

```sh
git tag v2.1
git push origin v2.1
```

`.github/workflows/release.yml` then runs the tests and `scripts/release.sh 2.1`, and makes the GitHub
Release from the tag with generated notes. The version comes from the tag. The build number is the
commit time, so Sparkle always treats a later release as newer.

- **Signed and notarized** (all the secrets below are set): the release is published as the latest one.
  The website's download link and every installed copy's update check pick it up straight away.
- **Anything missing**: the release is left as a **draft** with a warning in the run. Drafts aren't
  visible to `releases/latest`, so nobody downloads or updates to an unsigned build. Delete the draft
  (and the tag), fix the secrets, and tag again.

**Actions → Release → Run workflow** builds a version without publishing anything. The files are kept
as the run's artifact for a few days. `scripts/release.sh 2.1` does the same on a Mac, into `dist/`;
`dist/release.env` says whether the build was signed, notarized and given an appcast.

## Links for the website

| What | URL |
|---|---|
| Download (always the latest release) | `https://github.com/Swarf-Suite/SwarfGRBL/releases/latest/download/SwarfGRBL.dmg` |
| Release notes | `https://github.com/Swarf-Suite/SwarfGRBL/releases/latest` |
| Sparkle feed (baked into the app) | `https://github.com/Swarf-Suite/SwarfGRBL/releases/latest/download/appcast.xml` |

The feed URL is in every installed copy's Info.plist, so it mustn't change (unless a release first
ships a new `SG_FEED_URL`).

## Secrets

Set them in **Settings → Secrets and variables → Actions** on GitHub, or with `gh secret set NAME`.
Only workflows run from this repository's tags and branches can read them; pull requests from forks
can't.

| Secret | What |
|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | Signs each update. Its public half is `scripts/sparkle-public-key.txt`, baked into the app |
| `MACOS_CERT_P12` | The Developer ID Application certificate and its private key, as a base64 `.p12` |
| `MACOS_CERT_PASSWORD` | The `.p12`'s password |
| `NOTARY_KEY_P8` | An App Store Connect API key (the `.p8` file's text) for notarization |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys list |

### The Sparkle key (once)

The key pair was made with Sparkle's `generate_keys` and the private half is in the login keychain
of the design Mac (account `kerfline`, its name from before the rename). To set the secret from it:

```sh
swift/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account kerfline -x /tmp/k
gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/k && rm /tmp/k
```

**Keep the private key safe and never lose it.** Every installed copy only accepts updates signed with
it. If it's lost, installed copies can't be updated, and everyone has to download the app again.

### The Developer ID certificate (once the Apple Developer membership is active)

1. On the design Mac, in Xcode: **Settings → Accounts → (team) → Manage Certificates → + → Developer ID
   Application**. That puts the certificate and its private key in the login keychain. Local builds
   (`scripts/build-app.sh`) then sign with it automatically.
2. In **Keychain Access**, find "Developer ID Application: …", select the certificate *and* its key, and
   **File → Export Items…** as `DeveloperID.p12` with a strong password.
3. `base64 -i DeveloperID.p12 | gh secret set MACOS_CERT_P12`, then `gh secret set MACOS_CERT_PASSWORD`
   (it asks for the password). Delete the `.p12`.

### The notary key

1. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api): **Users and
   Access → Integrations → App Store Connect API → Team Keys → +**, with the **Developer** role.
2. Download the `.p8` (it can only be downloaded once) and note the **Key ID** and the **Issuer ID**.
3. `gh secret set NOTARY_KEY_P8 < AuthKey_XXXX.p8`, `gh secret set NOTARY_KEY_ID`,
   `gh secret set NOTARY_ISSUER_ID`. Keep the `.p8` somewhere safe or delete it (a new key can be made).

## Moving the two Macs to releases

Builds from git (`scripts/build-app.sh`) and releases are both **SwarfGRBL.app**
(`io.github.swarf-suite.swarfgrbl`); a release updates from GitHub, a build from git from its checkout. To move
a Mac over from KerfLine or GCode Controller 2.0: quit it, install SwarfGRBL from the dmg, and open it. Its first launch copies
the old settings (role, names, machine setup) and moves the library folder, and macOS asks once more for Documents and
local network access. After that, the Developer ID signature keeps those permissions across updates.
Delete `GCode Controller 2.0.app` from `~/Applications` once SwarfGRBL is working. Keep the checkout to
try changes before releasing them.
