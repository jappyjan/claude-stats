# Releasing ClaudeStats

Releases are produced entirely by CI from a tag push. The maintainer never
runs `swift build` for distribution.

## One-time setup (do this once for the lifetime of the repo)

1. **Generate the Sparkle EdDSA keypair.** Sparkle ships a `generate_keys`
   tool inside its SPM artifacts. After `swift build` resolves Sparkle, run:

       SIGN_DIR=$(find .build -name sign_update -type f -perm +111 | head -1 | xargs dirname)
       "$SIGN_DIR/generate_keys"

   It stores the private key in the macOS Keychain and prints the public
   key (base64) to stdout. Export the private key:

       "$SIGN_DIR/generate_keys" -p > /tmp/sparkle-pub.txt  # public
       "$SIGN_DIR/generate_keys" -x /tmp/sparkle-priv.txt   # export private

   Keep both files private. The private key never enters the repo.

2. **Add the GitHub repo secrets** (Settings → Secrets and variables →
   Actions → New repository secret):

   - `SPARKLE_PRIVATE_KEY` — contents of `/tmp/sparkle-priv.txt`
   - `SPARKLE_PUBLIC_KEY` — contents of `/tmp/sparkle-pub.txt` (single
     line, base64, no quotes)

3. **Create an empty `gh-pages` branch** for the appcast:

       git switch --orphan gh-pages
       git commit --allow-empty -m "init gh-pages"
       git push -u origin gh-pages
       git switch main

4. **Enable GitHub Pages** in Settings → Pages → "Deploy from a branch"
   → Branch: `gh-pages`, Folder: `/ (root)`. Wait ~1 minute, then verify
   `https://jappyjan.github.io/claude-stats/` loads (404 is fine until the
   first release runs; we just need Pages to be enabled).

5. **Delete the temp key files** from disk:

       shred -u /tmp/sparkle-priv.txt /tmp/sparkle-pub.txt 2>/dev/null \
         || rm /tmp/sparkle-priv.txt /tmp/sparkle-pub.txt

## Per-release procedure

That's the whole procedure:

    git tag v1.0.4
    git push --tags

CI does the rest: builds the `.app`, codesigns ad-hoc, builds the DMG and
ZIP, signs the ZIP with the Sparkle EdDSA key, uploads release assets,
generates the appcast, and pushes the appcast to `gh-pages`. Users on the
prior Sparkle-equipped version receive the standard Sparkle prompt within
24 hours.

## When something goes wrong

- **Workflow failed mid-run, before any asset uploaded.** Safe to delete
  the tag (`git tag -d v1.0.4 && git push --delete origin v1.0.4`), fix
  the issue, and re-tag.

- **Workflow failed AFTER asset upload but before appcast push.** The
  release exists on GitHub but no users see it (appcast still references
  the previous release). Re-run the failed job from the Actions UI — both
  upload and appcast steps are idempotent.

- **Sparkle prompt doesn't appear on user's machine.** Check
  Console.app for messages starting with "Sparkle" — most common causes
  are: SUFeedURL pointing somewhere wrong, EdDSA public key in Info.plist
  doesn't match the signing key, or GitHub Pages not yet serving the new
  appcast (DNS / CDN propagation can take a few minutes).
