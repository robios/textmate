# Bundle Taps and Subscriptions

TextMate ships a signed bundle index served by MacroMates. A *subscription*
installs a bundle straight from a GitHub repository instead, and a *tap* is a
repository that publishes a catalogue of such bundles — one address to add,
after which its bundles show up in the bundle list like any other.

Everything lives in *Preferences → Bundles*. There is no separate menu.

## The Bundles pane

The pane has two lists. The upper one is the familiar bundle list, with an
install checkbox and a **Source** column saying where each bundle comes from
(`Built-in`, `Official`, `Local`, a tap name, or one of the `Subscribed · …`
states below). The lower one is the **Sources** list: one row per tap or
one-off repository, with columns *Source*, *Repository*, *Branch*,
*Auto-Update* and *Bundles*.

## Adding a tap

Click **+** under the Sources list. A blank row appears with the Repository
cell in edit mode; type `owner/repository`, optionally a branch, and press
**Return** — Return is what commits the row, tabbing away leaves it pending.
**−** removes the selected source, or takes back a row you are still typing.

You do not declare whether the address is a tap or a plain bundle repository:
TextMate looks for a catalogue and, if there is none, treats the repository as
a single bundle.

Adding a tap **installs nothing**. Its bundles simply appear in the bundle
list above, and you tick the ones you want.

Typing an owner with no repository (`owner`) offers to subscribe to that
owner's public repositories in bulk; ones whose name ends in `.tmbundle` are
pre-selected.

Removing a tap keeps whatever you installed from it. Each installed bundle
keeps following the branch, tag or revision it is on, and can be updated or
removed on its own afterwards.

## The catalogue

A tap is an ordinary GitHub repository with a property list at
`Taps/bundles.plist`. Top level:

| Key             | Required | Meaning                                     |
|-----------------|----------|---------------------------------------------|
| `schemaVersion` | no       | Currently `1`; missing means `1`. A catalogue declaring a higher version is refused rather than half-understood. |
| `name`          | no       | Display name of the tap                     |
| `bundles`       | yes      | Array of bundle entries                     |

Each entry in `bundles`:

| Key           | Required | Meaning                                                        |
|---------------|----------|----------------------------------------------------------------|
| `uuid`        | yes      | The bundle's own UUID, checked against its `info.plist`         |
| `name`        | yes      | Display name                                                    |
| `url`         | yes      | GitHub URL of the bundle repository                             |
| `ref`         | no       | Branch, tag or revision; defaults to `main`. A revision is how a curator pins a bundle. |
| `category`    | no       | Groups the bundle in the pane's scope bar                       |
| `description` | no       | Shown in the Description column                                 |
| `grammars`    | no       | Array of `{ scope, uuid, name, firstLineMatch, fileTypes }`, so a tap's grammars can take part in the "install a bundle for this file type?" prompt before the bundle is installed |

Malformed entries are dropped one by one rather than failing the whole
catalogue; within one catalogue the first entry for a UUID wins. Two different
taps may list forks of the same bundle — a candidate is identified by the pair
(tap, UUID).

## Trust

Nothing fetched from GitHub is signed, so nothing updates itself until you say
so. There are two switches, and either one is enough:

* **Tap-level** — the *Auto-Update* checkbox on the source row. "I trust this
  source", said once instead of once per bundle.
* **Bundle-level** — right-click a bundle in the list and pick *Update
  Automatically*.

Until one of them is on, the daily check still notices a new revision but only
*offers* it: the Source column reads `Subscribed · update available` and the
context menu's *Update* becomes enabled. The context menu also has *Compare
Changes…*, which is what you want before accepting an update, and *Open
Repository Page*.

Ticking either box applies an update that is already waiting, in the same
step — a row that stayed at "update available" until the next scheduled wake
would read as the checkbox not having worked. Unticking is never retroactive:
it stops the next update, it does not undo the last one.

Tap-level trust is deliberately narrow. It does not cover a bundle when

* it came from a one-off repository rather than a tap,
* you picked its branch, tag or revision yourself rather than following the
  catalogue,
* it has been dropped from the catalogue, or
* the tap is gone.

In those cases the per-bundle switch is the only one that counts, and *Update
Automatically* shows the effective state: if the tap already covers a bundle,
its checkmark is on and disabled, with a tooltip naming the tap.

One thing no amount of trust overrides: if the catalogue starts pointing a
bundle at a *different repository*, updates pause with an explanation. That is
what stops a compromised catalogue from redirecting a subscription somewhere
else and having the new source installed automatically.

## Updates

The global checkbox **Check for updates and install trusted bundles
automatically** governs the scheduled check; it runs roughly once a day.
**Refresh Now** checks the bundle index, every tap catalogue and every
subscription immediately, whether or not scheduled checks are enabled. The
footer shows when the index was last updated.

Two hidden user defaults exist for the impatient or the wary — no UI, set them
with `defaults write`:

| Key                     | Meaning                                            |
|-------------------------|----------------------------------------------------|
| `bundleUpdateFrequency` | Poll interval in seconds; overrides the daily default |
| `disableBundleUpdates`  | The inverse of the checkbox above                   |

## Replacing an official bundle

If a tap offers its own version of a bundle that MacroMates also signs — a
fork with fixes, say — installing it is a **Replace**, and TextMate asks first:

> Replace the official “…” bundle?

The point of the dialog is the asymmetry: the official bundle is verified with
TextMate's signing key, a subscription is not — it is code from a GitHub
repository, and the only thing TextMate can check is that the UUID still
matches. The official copy stays installed until the replacement is in place,
and the swap is journalled, so there is no moment where the bundle is missing.

Unticking such a bundle offers to put the official one back:

> Restore the official “…” bundle? — **Restore Official** / **Just Remove** /
> **Cancel**

*Restore Official* re-downloads and verifies the signed copy before removing
the subscription; *Just Remove* leaves you without either.

Mandatory bundles cannot be replaced at all.

Bundles installed in the app itself are marked `Built-in` and are likewise not
replaceable.

## Where things end up

| Path                                                                       | Contents                                       |
|----------------------------------------------------------------------------|------------------------------------------------|
| `~/Library/Application Support/TextMate/Subscriptions.plist`                 | The registry of taps and subscriptions          |
| `~/Library/Application Support/TextMate/Subscribed/Bundles/`                 | Installed subscribed bundles                    |
| `~/Library/Application Support/TextMate/Subscribed/Cache/Taps/`              | Cached catalogues, so the list survives being offline |
| `~/Library/Application Support/TextMate/Subscribed/Transactions/`            | In-flight install/replace/restore transactions, recovered at launch |

The `Subscribed` directory is searched *after* `Managed`, so an officially
signed bundle wins a UUID collision by default. Displacing one is the explicit
Replace above, never a side effect of load order.

Networking is confined to `github.com` and its sibling hosts; redirects that
leave that set are refused. `api.github.com` is only contacted when you ask to
enumerate an owner's repositories.

## Status vocabulary

The Source column is terse on purpose:

| Text                            | Meaning                                                              |
|---------------------------------|----------------------------------------------------------------------|
| `Subscribed`                    | Installed from a subscription, up to date                             |
| `Subscribed · <tap>`            | …and the tap it came from                                             |
| `Subscribed · update available` | A newer revision exists and is waiting for you                        |
| `Subscribed · replaces official`| Installed over a signed bundle                                        |
| `Subscribed · source changed`   | The catalogue now points at a different repository; updates are paused |
| `Subscribed · unavailable`      | The revision could not be resolved                                    |
| `Subscribed · not in effect`    | Installed, but another copy earlier in the search order is the one being loaded — shown in orange, and badges the Bundles toolbar icon |
